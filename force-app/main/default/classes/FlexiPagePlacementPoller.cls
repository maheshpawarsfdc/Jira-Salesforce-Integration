/**
 * FlexiPagePlacementPoller.cls
 *
 * Queueable job that polls a Metadata API FlexiPage RETRIEVE to completion,
 * then deploys the modified page as its own small follow-up ZIP.
 *
 * WHY THIS EXISTS:
 * FlexiPageHelper.backstopLwcPagePlacement() used to retrieve+poll the
 * target FlexiPage synchronously, in a tight loop with no real delay
 * between poll attempts (Apex has no synchronous sleep). That was nowhere
 * near enough real wall-clock time for a large page's retrieve job to
 * finish server-side, and it kept timing out for pages like
 * Account_Record_Page — see flexipage-retrieve-timeout-followup memory.
 *
 * This mirrors DeployPoller's proven approach for the SAME class of
 * problem (polling a Metadata API async job to completion): re-enqueue via
 * System.enqueueJob for a couple of fast hops, then fall back to
 * System.schedule (FlexiPagePlacementPollerScheduler), which runs each
 * retry in a fresh transaction with no queueable stack depth — giving
 * genuine elapsed time across ~20 attempts instead of ~40 back-to-back
 * callouts with no delay between them.
 *
 * HOW IT WORKS:
 * 1. FlexiPageHelper.backstopLwcPagePlacement() starts the retrieve (one
 *    quick callout) and enqueues this poller with the resulting asyncId.
 * 2. execute() checks retrieve status via FlexiPageHelper.
 * 3. Not done yet → re-enqueue (fast path) or reschedule (fallback), up to
 *    MAX_ATTEMPTS.
 * 4. Done → apply every requested component to the retrieved XML, then
 *    deploy JUST the modified FlexiPage as its own follow-up ZIP via the
 *    EXISTING ZipDeployQueueable.forZip2() + DeployPoller — reused
 *    unmodified — which posts its own follow-up Jira comment once that
 *    resolves. Failure/timeout/nothing-to-apply paths post directly via
 *    JiraCallbackService instead, since there is no deploy to hand off to.
 *
 * This never touches the component's own ZIP1 deploy — that already
 * succeeded (or failed) independently before this poller ever runs.
 */
public class FlexiPagePlacementPoller implements Queueable, Database.AllowsCallouts {
  private static final Integer MAX_ATTEMPTS = 20; // mirrors DeployPoller: ~100s+ of real async time
  // Same queueable stack-depth reasoning as DeployPoller (max chain depth 5).
  // This poller's FIRST enqueue happens from synchronous Apex (not from
  // inside another Queueable), so it actually has more headroom than
  // DeployPoller does — but the fast hops barely add real wait time either
  // way (they fire almost immediately); the System.schedule-backed hops are
  // what buy genuine elapsed time. Kept at 2 to stay conservative and
  // consistent with DeployPoller's own choice.
  private static final Integer FAST_PATH_MAX_HOPS = 2;

  public String asyncId;
  public String pageName;
  public String pageType;
  public String objectApiName;
  public String regionName;
  public Boolean allowAnyRegionFallback;
  public List<String> lwcComponentNames;
  public String issueKey;
  public Integer attempt;
  public Integer queueableHops = 0;

  public void execute(QueueableContext ctx) {
    FunctionHelper.deferErrorLogDml = true;
    System.debug(
      'FlexiPagePlacementPoller.execute(): attempt ' +
        attempt +
        '/' +
        MAX_ATTEMPTS +
        ', asyncId=' +
        asyncId +
        ', page=' +
        pageName +
        ', issue=' +
        issueKey
    );

    try {
      MetadataService.RetrieveResult result = FlexiPageHelper.checkFlexiPageRetrieveStatus(
        asyncId
      );
      System.debug(
        'FlexiPagePlacementPoller: status=' +
          result.status +
          ', done=' +
          result.done
      );

      if (result.done) {
        if (result.status == 'Failed') {
          postGap(
            'Retrieving the ' +
              pageName +
              ' page failed: ' +
              result.errorMessage
          );
          abortStaleJobs();
          return;
        }
        finishPlacement(result.zipFile);
        abortStaleJobs();
      } else if (attempt >= MAX_ATTEMPTS) {
        postGap(
          'Retrieving the ' +
            pageName +
            ' page timed out after ' +
            MAX_ATTEMPTS +
            ' async poll attempts. The page may be large or the org may ' +
            'be under load — re-run this ticket, or add the component ' +
            'manually via App Builder.'
        );
        abortStaleJobs();
      } else {
        reEnqueueOrSchedule();
      }
    } catch (Exception e) {
      System.debug('FlexiPagePlacementPoller: ERROR - ' + e.getMessage());
      ErrorLogger.log(e, issueKey);
      postGap('Placement poller error: ' + e.getMessage());
      abortStaleJobs();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // DONE — extract XML, apply components, hand off to a follow-up deploy
  // ─────────────────────────────────────────────────────────────
  private void finishPlacement(String zipBase64) {
    String xml;
    try {
      xml = FlexiPageHelper.extractXmlFromRetrieveZip(pageName, zipBase64);
    } catch (Exception e) {
      postGap('Retrieving the ' + pageName + ' page failed: ' + e.getMessage());
      return;
    }

    Map<String, Object> applied = FlexiPageHelper.applyComponentsToXml(
      xml,
      pageName,
      regionName,
      allowAnyRegionFallback,
      lwcComponentNames
    );
    String modifiedXml = (String) applied.get('modifiedXml');
    Integer appliedCount = (Integer) applied.get('appliedCount');
    Integer alreadyPresentCount = (Integer) applied.get('alreadyPresentCount');

    if (modifiedXml == null) {
      if (alreadyPresentCount > 0) {
        postSuccessNote(
          '✅ Already present on the ' +
            FlexiPageHelper.describeTarget(pageType, objectApiName) +
            ' (' +
            pageName +
            ').'
        );
      } else {
        postGap(
          'No usable region found on ' +
            pageName +
            '. Component deployed but not added to the page.'
        );
      }
      return;
    }

    // Stage the modified FlexiPage AND re-include every placed component's
    // OWN bundle (unmodified — just fetched back via Tooling API, not
    // changed) in this SAME deploy package. Required: a FlexiPage deploy
    // that references a Lightning component NOT included in that same
    // package can fail with "We couldn't retrieve the design time
    // component information for component c:X", even when the component
    // already exists and deployed fine moments earlier in ZIP1 — see
    // FlexiPageHelper.fetchLwcBundleFiles()'s doc comment for the full
    // incident writeup.
    ZipBuilder.clear();
    ZipBuilder.addFile(
      'FlexiPage',
      pageName,
      'flexipages/' + pageName + '.flexipage',
      modifiedXml
    );
    for (String componentName : lwcComponentNames) {
      if (String.isBlank(componentName)) {
        continue;
      }
      Map<String, String> bundleFiles = FlexiPageHelper.fetchLwcBundleFiles(
        componentName
      );
      for (String filePath : bundleFiles.keySet()) {
        ZipBuilder.addFile(
          'LightningComponentBundle',
          componentName,
          filePath,
          bundleFiles.get(filePath)
        );
      }
    }
    String zip2DataJson = JSON.serialize(
      new Map<String, Object>{
        'files' => ZipBuilder.files,
        'binaryFiles' => ZipBuilder.binaryFiles,
        'metadataTypesJson' => JSON.serialize(ZipBuilder.metadataTypes)
      }
    );
    ZipBuilder.clear();

    ZipDeployQueueable placementDeploy = ZipDeployQueueable.forZip2(
      issueKey,
      zip2DataJson
    );
    placementDeploy.deploySummaryNote =
      '✅ Added to the ' +
      regionName +
      ' region of the ' +
      FlexiPageHelper.describeTarget(pageType, objectApiName) +
      ' (' +
      pageName +
      ').';
    System.debug(
      '[DEPLOY-TRACE] FlexiPagePlacementPoller handing off placement ZIP | ' +
        'issue=' +
        issueKey +
        ' | page=' +
        pageName +
        ' | appliedCount=' +
        appliedCount
    );
    System.enqueueJob(placementDeploy);
  }

  // ─────────────────────────────────────────────────────────────
  // RE-POLL — same fast-path-then-schedule pattern as DeployPoller
  // ─────────────────────────────────────────────────────────────
  private void reEnqueueOrSchedule() {
    Integer nextAttempt = attempt + 1;
    Integer nextHops = (queueableHops == null ? 0 : queueableHops) + 1;

    if (nextHops <= FAST_PATH_MAX_HOPS) {
      System.debug(
        'FlexiPagePlacementPoller: not done, re-enqueuing (fast path, hop ' +
          nextHops +
          '/' +
          FAST_PATH_MAX_HOPS +
          ')'
      );
      FlexiPagePlacementPoller nextPoller = new FlexiPagePlacementPoller();
      nextPoller.asyncId = asyncId;
      nextPoller.pageName = pageName;
      nextPoller.pageType = pageType;
      nextPoller.objectApiName = objectApiName;
      nextPoller.regionName = regionName;
      nextPoller.allowAnyRegionFallback = allowAnyRegionFallback;
      nextPoller.lwcComponentNames = lwcComponentNames;
      nextPoller.issueKey = issueKey;
      nextPoller.attempt = nextAttempt;
      nextPoller.queueableHops = nextHops;
      System.enqueueJob(nextPoller);
    } else {
      System.debug(
        'FlexiPagePlacementPoller: not done, fast-path hops exhausted — ' +
        'falling back to System.schedule'
      );
      String cronExp = buildCronInSeconds(5);
      String jobName = 'FlexiPagePoller_' + asyncId + '_' + attempt;
      FlexiPagePlacementPollerScheduler sched = new FlexiPagePlacementPollerScheduler(
        asyncId,
        pageName,
        pageType,
        objectApiName,
        regionName,
        allowAnyRegionFallback,
        JSON.serialize(lwcComponentNames),
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
      '[FLEXIPAGE-ASYNC] GAP for issue [' + issueKey + ']: ' + reason
    );
    // 'error' here describes the PLACEMENT outcome only, same as DeployPoller's
    // own zip2-completion messages — the component itself already deployed
    // successfully in ZIP1 and was reported on separately; this status
    // overwrites the same Jira issue property with the placement follow-up.
    postStatusToJira('error', '⚠️ Not added to a page: ' + reason);
  }

  private void postSuccessNote(String note) {
    System.debug('[FLEXIPAGE-ASYNC] ' + note);
    postStatusToJira('success', note);
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
        'FlexiPagePlacementPoller: failed to post Jira comment — ' +
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
  // ABORT STALE SCHEDULED JOBS FOR THIS PLACEMENT
  // Mirrors DeployPoller.abortPollerJobsForThisDeploy() — cleans up any
  // scheduled jobs an earlier poll cycle of this same placement created.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private void abortStaleJobs() {
    try {
      String namePattern = 'FlexiPagePoller_' + asyncId + '_%';
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
            'FlexiPagePlacementPoller: could not abort job ' +
              ct.CronJobDetail.Name +
              ': ' +
              innerEx.getMessage()
          );
        }
      }
    } catch (Exception e) {
      System.debug(
        'FlexiPagePlacementPoller: stale job cleanup failed: ' + e.getMessage()
      );
      // Non-fatal — do not let cleanup failure block terminal processing
    }
  }
}
