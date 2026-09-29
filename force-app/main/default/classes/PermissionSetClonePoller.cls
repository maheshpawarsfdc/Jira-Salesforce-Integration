/**
 * PermissionSetClonePoller.cls
 *
 * Queueable job that polls a Metadata API PermissionSet RETRIEVE to
 * completion, then deploys the cloned+patched permission set as its own
 * small follow-up ZIP.
 *
 * WHY THIS EXISTS:
 * PermissionSetHelper.clonePermissionSet() used to retrieve+poll the
 * source permission set synchronously, in a tight loop with no real delay
 * between poll attempts (Apex has no synchronous sleep). That was not
 * enough real wall-clock time for the retrieve job to finish server-side
 * under real load, and it kept timing out even after the attempt budget
 * was raised from 10 to 30 — see permissionset-clone-reliability-and-
 * override-gap memory.
 *
 * This mirrors FlexiPagePlacementPoller's proven approach for the SAME
 * class of problem (polling a Metadata API async job to completion):
 * re-enqueue via System.enqueueJob for a couple of fast hops, then fall
 * back to System.schedule (PermissionSetClonePollerScheduler), which runs
 * each retry in a fresh transaction with no queueable stack depth — giving
 * genuine elapsed time across ~20 attempts instead of back-to-back
 * callouts with no delay between them.
 *
 * HOW IT WORKS:
 * 1. LLMResponseProcessor resolves the source PS name, starts the retrieve
 *    (one quick callout via PermissionSetHelper.startCloneRetrieve), and
 *    enqueues this poller with the resulting asyncId + clone target
 *    params. That happens synchronously but returns immediately — it
 *    never waits for the retrieve.
 * 2. execute() checks retrieve status via PermissionSetHelper.
 * 3. Not done yet -> re-enqueue (fast path) or reschedule (fallback), up
 *    to MAX_ATTEMPTS.
 * 4. Done -> PermissionSetHelper.buildClonedPermissionSetXml() extracts +
 *    patches the XML (label/description swap, compound-field strip,
 *    object-permission overrides), then deploys JUST the new permission
 *    set as its own follow-up ZIP via the EXISTING ZipDeployQueueable.
 *    forZip2() + DeployPoller — reused unmodified — which posts its own
 *    follow-up Jira comment once that resolves. Failure/timeout paths post
 *    directly via JiraCallbackService instead, since there is no deploy to
 *    hand off to.
 *
 * This never touches the ticket's own ZIP1 deploy (if any) — that already
 * succeeded (or failed) independently before this poller ever runs, same
 * as FlexiPagePlacementPoller's relationship to the component's own ZIP1.
 */
public class PermissionSetClonePoller implements Queueable, Database.AllowsCallouts {
  private static final Integer MAX_ATTEMPTS = 20; // mirrors DeployPoller/FlexiPagePlacementPoller: ~100s+ of real async time
  private static final Integer FAST_PATH_MAX_HOPS = 2;

  public String asyncId;
  public String sourceApiName;
  public String newApiName;
  public String newLabel;
  public String description;
  // Serialized List<Object> — JSON round-trip since Queueable fields must
  // be primitive/String types.
  public String objectPermissionOverridesJson;
  public String issueKey;
  public Integer attempt;
  public Integer queueableHops = 0;

  public void execute(QueueableContext ctx) {
    FunctionHelper.deferErrorLogDml = true;
    System.debug(
      'PermissionSetClonePoller.execute(): attempt ' +
        attempt +
        '/' +
        MAX_ATTEMPTS +
        ', asyncId=' +
        asyncId +
        ', source=' +
        sourceApiName +
        ', issue=' +
        issueKey
    );

    try {
      MetadataService.RetrieveResult result = PermissionSetHelper.checkCloneRetrieveStatus(
        asyncId
      );
      System.debug(
        'PermissionSetClonePoller: status=' +
          result.status +
          ', done=' +
          result.done
      );

      if (result.done) {
        if (result.status == 'Failed') {
          postGap(
            'Retrieving the ' +
              sourceApiName +
              ' permission set failed: ' +
              result.errorMessage
          );
          abortStaleJobs();
          return;
        }
        finishClone(result.zipFile);
        abortStaleJobs();
      } else if (attempt >= MAX_ATTEMPTS) {
        postGap(
          'Retrieving the ' +
            sourceApiName +
            ' permission set timed out after ' +
            MAX_ATTEMPTS +
            ' async poll attempts. The org may be under load — re-run this ' +
            'ticket, or clone it manually via Setup.'
        );
        abortStaleJobs();
      } else {
        reEnqueueOrSchedule();
      }
    } catch (Exception e) {
      System.debug('PermissionSetClonePoller: ERROR - ' + e.getMessage());
      ErrorLogger.log(e, issueKey);
      postGap('Permission set clone poller error: ' + e.getMessage());
      abortStaleJobs();
    } finally {
      // See Deploypoller's identical fix for why this is required — every
      // callout this method makes (checkCloneRetrieveStatus,
      // postStatusToJira) has already happened by the time we reach here
      // on every path, so flushing now is safe, and nothing else in this
      // queueable ever flushes it otherwise.
      FunctionHelper.flushNonMetadataDmlQueues();
      FunctionHelper.deferErrorLogDml = false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // DONE — extract+patch XML, hand off to a follow-up deploy
  // ─────────────────────────────────────────────────────────────
  private void finishClone(String zipBase64) {
    List<Object> overrides = null;
    if (String.isNotBlank(objectPermissionOverridesJson)) {
      try {
        overrides = (List<Object>) JSON.deserializeUntyped(
          objectPermissionOverridesJson
        );
      } catch (Exception e) {
        System.debug(
          'PermissionSetClonePoller: failed to parse objectPermissionOverridesJson — ' +
          e.getMessage()
        );
      }
    }

    String xml;
    try {
      xml = PermissionSetHelper.buildClonedPermissionSetXml(
        sourceApiName,
        zipBase64,
        newApiName,
        newLabel,
        description,
        overrides
      );
    } catch (Exception e) {
      postGap(
        'Cloning the ' +
          sourceApiName +
          ' permission set failed: ' +
          e.getMessage()
      );
      return;
    }

    ZipBuilder.clear();
    ZipBuilder.addFile(
      'PermissionSet',
      newApiName,
      'permissionsets/' + newApiName + '.permissionset-meta.xml',
      xml
    );
    String zip2DataJson = JSON.serialize(
      new Map<String, Object>{
        'files' => ZipBuilder.files,
        'binaryFiles' => ZipBuilder.binaryFiles,
        'metadataTypesJson' => JSON.serialize(ZipBuilder.metadataTypes)
      }
    );
    ZipBuilder.clear();

    ZipDeployQueueable cloneDeploy = ZipDeployQueueable.forZip2(
      issueKey,
      zip2DataJson
    );
    cloneDeploy.deploySummaryNote =
      '✅ Created permission set "' +
      newApiName +
      '" (cloned from ' +
      sourceApiName +
      ').';
    System.debug(
      '[DEPLOY-TRACE] PermissionSetClonePoller handing off clone ZIP | ' +
        'issue=' +
        issueKey +
        ' | newApiName=' +
        newApiName
    );
    System.enqueueJob(cloneDeploy);
  }

  // ─────────────────────────────────────────────────────────────
  // RE-POLL — same fast-path-then-schedule pattern as DeployPoller/
  // FlexiPagePlacementPoller
  // ─────────────────────────────────────────────────────────────
  private void reEnqueueOrSchedule() {
    Integer nextAttempt = attempt + 1;
    Integer nextHops = (queueableHops == null ? 0 : queueableHops) + 1;

    if (nextHops <= FAST_PATH_MAX_HOPS) {
      System.debug(
        'PermissionSetClonePoller: not done, re-enqueuing (fast path, hop ' +
          nextHops +
          '/' +
          FAST_PATH_MAX_HOPS +
          ')'
      );
      PermissionSetClonePoller nextPoller = new PermissionSetClonePoller();
      nextPoller.asyncId = asyncId;
      nextPoller.sourceApiName = sourceApiName;
      nextPoller.newApiName = newApiName;
      nextPoller.newLabel = newLabel;
      nextPoller.description = description;
      nextPoller.objectPermissionOverridesJson = objectPermissionOverridesJson;
      nextPoller.issueKey = issueKey;
      nextPoller.attempt = nextAttempt;
      nextPoller.queueableHops = nextHops;
      System.enqueueJob(nextPoller);
    } else {
      System.debug(
        'PermissionSetClonePoller: not done, fast-path hops exhausted — ' +
        'falling back to System.schedule'
      );
      String cronExp = buildCronInSeconds(5);
      String jobName = 'PermissionSetClonePoller_' + asyncId + '_' + attempt;
      PermissionSetClonePollerScheduler sched = new PermissionSetClonePollerScheduler(
        asyncId,
        sourceApiName,
        newApiName,
        newLabel,
        description,
        objectPermissionOverridesJson,
        issueKey,
        nextAttempt
      );
      System.schedule(jobName, cronExp, sched);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // TERMINAL PATHS — post directly to Jira (no deploy job to hand off to)
  // ─────────────────────────────────────────────────────────────
  private void postGap(String reason) {
    System.debug(
      '[PERMSET-CLONE-ASYNC] GAP for issue [' + issueKey + ']: ' + reason
    );
    postStatusToJira('error', '⚠️ Permission set clone incomplete: ' + reason);
  }

  private void postStatusToJira(String status, String message) {
    try {
      JiraCallbackService.storeDeploymentStatus(
        issueKey,
        status,
        message,
        null
      );
    } catch (Exception e) {
      System.debug(
        'PermissionSetClonePoller: failed to post Jira comment — ' +
        e.getMessage()
      );
      ErrorLogger.log(e, issueKey);
    }
  }

  private String buildCronInSeconds(Integer secondsFromNow) {
    Datetime dt = Datetime.now().addSeconds(secondsFromNow);
    return dt.second() +
      ' ' +
      dt.minute() +
      ' ' +
      dt.hour() +
      ' ' +
      dt.day() +
      ' ' +
      dt.month() +
      ' ? ' +
      dt.year();
  }

  // ─────────────────────────────────────────────────────────────
  // ABORT STALE SCHEDULED JOBS FOR THIS CLONE
  // Mirrors FlexiPagePlacementPoller.abortStaleJobs() — cleans up any
  // scheduled jobs an earlier poll cycle of this same clone created.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private void abortStaleJobs() {
    try {
      String namePattern = 'PermissionSetClonePoller_' + asyncId + '_%';
      for (CronTrigger ct : [
        SELECT Id, CronJobDetail.Name
        FROM CronTrigger
        WHERE
          CronJobDetail.Name LIKE :namePattern
          AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
      ]) {
        try {
          System.abortJob(ct.Id);
        } catch (Exception innerEx) {
          System.debug(
            'PermissionSetClonePoller: could not abort job ' +
              ct.CronJobDetail.Name +
              ': ' +
              innerEx.getMessage()
          );
        }
      }
    } catch (Exception e) {
      System.debug(
        'PermissionSetClonePoller: stale job cleanup failed: ' + e.getMessage()
      );
      // Non-fatal — do not let cleanup failure block terminal processing
    }
  }
}
