/**
 * DeployPoller.cls
 *
 * Queueable job that polls Salesforce Metadata API deploy status.
 * Re-enqueues itself every poll cycle until deploy is complete.
 * Posts final result to Jira when done.
 *
 * INSTANTIATED via Type.forName from DeployService to avoid
 * circular compile-time dependency. Fields must be public.
 *
 * HOW IT WORKS:
 * 1. DeployService creates DeployPoller via Type.forName, sets fields, enqueues
 * 2. DeployPoller.execute() checks deploy status via its own MetadataPort
 * 3. If not done → re-enqueues itself (up to MAX_ATTEMPTS)
 * 4. If done → posts result to Jira via JiraCallbackService
 */
public class Deploypoller implements Queueable, Database.AllowsCallouts {
  private static final Integer MAX_ATTEMPTS = 20; // max ~100 seconds total
  private static final String API_VERSION = '61.0';

  // Public so DeployService can set them after Type.forName instantiation
  public String jobId;
  public String issueKey;
  public Integer attempt;
  public String pendingZip2DataJson;
  public String apexTestContextJson;

  // ─────────────────────────────────────────────────────────────
  // CONSTRUCTORS
  // ─────────────────────────────────────────────────────────────
  public DeployPoller() {
  }

  public DeployPoller(String jobId, String issueKey, Integer attempt) {
    this.jobId = jobId;
    this.issueKey = issueKey;
    this.attempt = attempt;
  }

  // ─────────────────────────────────────────────────────────────
  // PORT
  // ─────────────────────────────────────────────────────────────
  private MetadataPort getPort() {
    MetadataPort p = new MetadataPort();
    p.endpoint_x =
      'https://' +
      DomainCreator.getOrgMyDomainHostname() +
      '/services/Soap/m/' +
      API_VERSION;
    p.SessionHeader = new MetadataService.SessionHeader_element();
    p.SessionHeader.sessionId = UserInfo.getSessionId();
    return p;
  }

  // ─────────────────────────────────────────────────────────────
  // EXECUTE — called by Salesforce async framework
  // ─────────────────────────────────────────────────────────────
  public void execute(QueueableContext ctx) {
    FunctionHelper.deferErrorLogDml = true;
    System.debug('');
    System.debug(
      'DeployPoller.execute(): attempt ' +
        attempt +
        '/' +
        MAX_ATTEMPTS +
        ', jobId=' +
        jobId +
        ', issue=' +
        issueKey
    );
    System.debug(
      '[5] DeployPoller attempt ' + attempt + ' started: ' + Datetime.now()
    );

    try {
      MetadataService.DeployResult result = getPort()
        .checkDeployStatus(jobId, true);
      System.debug(
        'DeployPoller: status=' + result.status + ', done=' + result.done
      );
      System.debug(
        '[6] Got deploy status [' +
          result.status +
          '] done=' +
          result.done +
          ' at: ' +
          Datetime.now()
      );

      if (result.done) {
        System.debug('[7] Deploy DONE at: ' + Datetime.now());
        System.debug(
          '[DEPLOY-TRACE] DeployPoller DONE | issue=' +
            issueKey +
            ' | jobId=' +
            jobId +
            ' | success=' +
            result.success +
            ' | hasPendingZip2=' +
            String.isNotBlank(pendingZip2DataJson) +
            ' | components=' +
            result.numberComponentsDeployed
        );

        // ── Check if deployment was successful ────────────
        if (result.success) {
          if (String.isNotBlank(apexTestContextJson)) {
            System.debug(
              '[DEPLOY-TRACE] ZIP1 SUCCESS (Apex-first) -> chaining to ApexTestRunQueueable for issue=' +
              issueKey
            );
            System.enqueueJob(
              ApexTestRunQueueable.fromJson(issueKey, apexTestContextJson)
            );
          } else if (String.isNotBlank(pendingZip2DataJson)) {
            System.debug(
              'DeployPoller: ZIP 1 succeeded — enqueuing ZIP 2 deploy for issue: ' +
              issueKey
            );
            System.debug(
              '[DEPLOY-TRACE] ZIP1 SUCCESS -> enqueuing ZIP2 for issue=' +
              issueKey
            );
            System.enqueueJob(
              ZipDeployQueueable.forZip2(issueKey, pendingZip2DataJson)
            );
          } else {
            String successMsg =
              'Successfully deployed! ' +
              result.numberComponentsDeployed +
              ' component(s) deployed.';
            System.debug(
              'DeployPoller: deploy SUCCESS. Posting to Jira: ' + successMsg
            );
            System.debug(
              '[DEPLOY-TRACE] FINAL SUCCESS (no chained ZIP2) for issue=' +
              issueKey
            );

            // ── POST-DEPLOY VERIFICATION ──────────────────────────
            // Salesforce says success but we verify the components
            // actually exist in the org before telling Jira success.
            String verificationWarning = verifyDeploy(result);
            if (String.isNotBlank(verificationWarning)) {
              successMsg +=
                '\n\n⚠️ Please double check the following:\n' +
                verificationWarning;
              System.debug(
                '[DEPLOY-TRACE] Verification warnings found: ' +
                verificationWarning
              );
            }
            // ── END VERIFICATION ──────────────────────────────────

            postStatusToJira(issueKey, 'success', successMsg, jobId);
            // ── ABORT STALE POLLER JOBS ───────────────────────────────
            abortPollerJobsForThisDeploy();
            // ── END ABORT STALE POLLER JOBS ───────────────────────────
          }
        } else {
          // ── Deploy failed — extract error details ─────
          String errorMsg = parseFailureResult(result);
          System.debug(
            'DeployPoller: deploy FAILED. Posting to Jira: ' + errorMsg
          );
          System.debug(
            '[DEPLOY-TRACE] FAILED (chain stops) | issue=' +
              issueKey +
              ' | hadPendingZip2=' +
              String.isNotBlank(pendingZip2DataJson) +
              ' | errorPreview=' +
              errorMsg.abbreviate(300)
          );
          postStatusToJira(issueKey, 'error', errorMsg, jobId);
          abortPollerJobsForThisDeploy();
        }
      } else if (attempt >= MAX_ATTEMPTS) {
        // ── Max attempts reached without completion ────────
        System.debug('DeployPoller: MAX_ATTEMPTS reached.');
        String timeoutMsg =
          'Deploy timed out after ' +
          MAX_ATTEMPTS +
          ' attempts. ' +
          'Status: ' +
          result.status +
          '. Check Salesforce deployment status manually.';

        postStatusToJira(issueKey, 'error', timeoutMsg, jobId);
        abortPollerJobsForThisDeploy();
      } else {
        // ── Not done yet, schedule next poll ──────────────
        System.debug(
          '⏱ [6b] Not done, scheduling next poll at: ' + Datetime.now()
        );
        System.debug(
          'DeployPoller: not done yet (status=' +
            result.status +
            '). Re-enqueuing...'
        );

        // Use System.schedule instead of System.enqueueJob to avoid
        // Salesforce queueable stack depth limit (max 5 chained queueables).
        String cronExp = buildCronIn2Seconds();
        String jobName = 'DeployPoller_' + jobId + '_' + attempt;
        DeployPollerScheduler sched = new DeployPollerScheduler(
          jobId,
          issueKey,
          attempt + 1,
          pendingZip2DataJson
        );
        sched.apexTestContextJson = apexTestContextJson;
        System.schedule(jobName, cronExp, sched);
      }
    } catch (Exception e) {
      System.debug('DeployPoller: ERROR - ' + e.getMessage());
      ErrorLogger.log(e, issueKey);
      String exceptionMsg =
        'Deploy poller error: ' +
        e.getMessage() +
        ' | ' +
        e.getStackTraceString();
      postStatusToJira(issueKey, 'error', exceptionMsg, jobId);
      abortPollerJobsForThisDeploy();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Helper method to post status to Jira (via issue properties)
  // ─────────────────────────────────────────────────────────────
  private static void postStatusToJira(
    String issueKey,
    String status,
    String message,
    String deployId
  ) {
    try {
      JiraCallbackService.storeDeploymentStatus(
        issueKey,
        status,
        message,
        deployId
      );
    } catch (Exception e) {
      System.debug('postStatusToJira error: ' + e.getMessage());
      ErrorLogger.log(e, issueKey);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PARSE FAILURE RESULT — extract error details
  // ─────────────────────────────────────────────────────────────
  private String parseFailureResult(MetadataService.DeployResult result) {
    String errorMsg = 'Deploy failed. ';

    if (String.isNotBlank(result.errorMessage)) {
      errorMsg += result.errorMessage + ' ';
    }

    if (result.details != null && result.details.componentFailures != null) {
      errorMsg += '\n\nComponent failures:\n';
      for (
        MetadataService.DeployMessage failure : result.details.componentFailures
      ) {
        if (!failure.success) {
          errorMsg += '- ' + failure.fullName + ': ' + failure.problem + '\n';
        }
      }
    }

    return errorMsg;
  }

  // ─────────────────────────────────────────────────────────────
  // CRON BUILDER — returns a cron expression for ~2 seconds from now
  // ─────────────────────────────────────────────────────────────
  private String buildCronIn2Seconds() {
    Datetime dt = Datetime.now().addSeconds(2);
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
  // ABORT STALE POLLER JOBS FOR THIS DEPLOY
  // Called on all terminal paths to ensure scheduled jobs created
  // by earlier poll cycles of the same deploy are cleaned up.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private void abortPollerJobsForThisDeploy() {
    try {
      String namePattern = 'DeployPoller_' + jobId + '_%';
      for (CronTrigger ct : [
        SELECT Id, CronJobDetail.Name
        FROM CronTrigger
        WHERE
          CronJobDetail.Name LIKE :namePattern
          AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
      ]) {
        try {
          System.abortJob(ct.Id);
          System.debug(
            'DeployPoller: aborted stale scheduler job: ' +
            ct.CronJobDetail.Name
          );
        } catch (Exception inner1) {
          System.debug(
            'DeployPoller: could not abort job ' +
              ct.CronJobDetail.Name +
              ': ' +
              inner1.getMessage()
          );
        }
      }
    } catch (Exception e) {
      System.debug('DeployPoller: stale job cleanup failed: ' + e.getMessage());
      // Non-fatal — do not let cleanup failure block terminal processing
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PARSE RESULT — human readable deploy outcome (kept for backwards compat)
  // ─────────────────────────────────────────────────────────────
  private String parseResult(MetadataService.DeployResult result) {
    if (result.success) {
      return 'Deploy successful. ' +
        result.numberComponentsDeployed +
        ' component(s) deployed.';
    }
    return parseFailureResult(result);
  }

  // ─────────────────────────────────────────────────────────────
  // VERIFY DEPLOY
  // After Salesforce says success, we check the deployed components
  // actually exist in the org. Returns a warning string listing
  // anything that could not be confirmed. Empty string = all good.
  //
  // Verification strategy per type:
  //   CustomObject  → Schema.getGlobalDescribe() — no callout
  //   CustomField   → Schema field describe — no callout
  //   ApexClass     → SOQL on ApexClass — no callout
  //   ApexTrigger   → SOQL on ApexTrigger — no callout
  //   Layout        → Tooling API query — 1 callout
  //   Everything else → trusted, not verified
  // ─────────────────────────────────────────────────────────────
  private String verifyDeploy(MetadataService.DeployResult result) {
    List<String> warnings = new List<String>();

    try {
      if (
        result.details == null ||
        result.details.componentSuccesses == null ||
        result.details.componentSuccesses.isEmpty()
      ) {
        System.debug(
          '[VERIFY] No componentSuccesses in result — skipping verification'
        );
        return '';
      }

      // Collect what was deployed by type
      List<String> customObjects = new List<String>();
      List<String> customFields = new List<String>();
      List<String> apexClasses = new List<String>();
      List<String> apexTriggers = new List<String>();
      List<String> layouts = new List<String>();

      for (
        MetadataService.DeployMessage msg : result.details.componentSuccesses
      ) {
        if (
          msg == null ||
          String.isBlank(msg.componentType) ||
          String.isBlank(msg.fullName)
        ) {
          continue;
        }
        String cType = msg.componentType.toLowerCase();
        String cName = msg.fullName;

        if (cType == 'customobject') {
          customObjects.add(cName);
        } else if (cType == 'customfield') {
          customFields.add(cName);
        } else if (cType == 'apexclass') {
          apexClasses.add(cName);
        } else if (cType == 'apextrigger') {
          apexTriggers.add(cName);
        } else if (cType == 'layout') {
          layouts.add(cName);
        }
        // StaticResource, PermissionSet, Profile, CustomLabel etc
        // are trusted — Salesforce success is enough for these
      }

      System.debug(
        '[VERIFY] Verifying — objects=' +
          customObjects.size() +
          ' fields=' +
          customFields.size() +
          ' classes=' +
          apexClasses.size() +
          ' triggers=' +
          apexTriggers.size() +
          ' layouts=' +
          layouts.size()
      );

      // ── 1. Verify CustomObjects via Schema ────────────────
      Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
      for (String objName : customObjects) {
        // fullName from deploy result is the API name e.g. MyObject__c
        if (!globalDescribe.containsKey(objName.toLowerCase())) {
          warnings.add('Object not found after deploy: ' + objName);
          System.debug('[VERIFY] MISS — CustomObject: ' + objName);
        } else {
          System.debug('[VERIFY] OK — CustomObject: ' + objName);
        }
      }

      // ── 2. Verify CustomFields via Schema ─────────────────
      // fullName format from deploy result: ObjectName__c.FieldName__c
      for (String fieldFullName : customFields) {
        if (!fieldFullName.contains('.')) {
          continue; // unexpected format, skip
        }
        String objName = fieldFullName.substringBefore('.');
        String fieldName = fieldFullName.substringAfter('.');

        Schema.SObjectType objType = globalDescribe.get(objName.toLowerCase());
        if (objType == null) {
          warnings.add('Parent object not found for field: ' + fieldFullName);
          System.debug(
            '[VERIFY] MISS — parent object missing for field: ' + fieldFullName
          );
          continue;
        }

        Map<String, Schema.SObjectField> fieldMap = objType.getDescribe()
          .fields.getMap();
        if (!fieldMap.containsKey(fieldName.toLowerCase())) {
          warnings.add('Field not found after deploy: ' + fieldFullName);
          System.debug('[VERIFY] MISS — CustomField: ' + fieldFullName);
        } else {
          System.debug('[VERIFY] OK — CustomField: ' + fieldFullName);
        }
      }

      // ── 3. Verify ApexClasses via SOQL ───────────────────
      if (!apexClasses.isEmpty()) {
        Set<String> foundClasses = new Set<String>();
        for (ApexClass cls : [
          SELECT Name
          FROM ApexClass
          WHERE Name IN :apexClasses AND Status = 'Active'
        ]) {
          foundClasses.add(cls.Name.toLowerCase());
        }
        for (String clsName : apexClasses) {
          if (!foundClasses.contains(clsName.toLowerCase())) {
            warnings.add('Apex class not found after deploy: ' + clsName);
            System.debug('[VERIFY] MISS — ApexClass: ' + clsName);
          } else {
            System.debug('[VERIFY] OK — ApexClass: ' + clsName);
          }
        }
      }

      // ── 4. Verify ApexTriggers via SOQL ──────────────────
      if (!apexTriggers.isEmpty()) {
        Set<String> foundTriggers = new Set<String>();
        for (ApexTrigger trg : [
          SELECT Name
          FROM ApexTrigger
          WHERE Name IN :apexTriggers AND Status = 'Active'
        ]) {
          foundTriggers.add(trg.Name.toLowerCase());
        }
        for (String trgName : apexTriggers) {
          if (!foundTriggers.contains(trgName.toLowerCase())) {
            warnings.add('Apex trigger not found after deploy: ' + trgName);
            System.debug('[VERIFY] MISS — ApexTrigger: ' + trgName);
          } else {
            System.debug('[VERIFY] OK — ApexTrigger: ' + trgName);
          }
        }
      }

      // ── 5. Verify Layouts via Tooling API ─────────────────
      // fullName format: ObjectName__c-Layout Name
      // We verify the layout exists — we cannot easily verify
      // individual fields inside the layout via Tooling API
      // without multiple callouts, so we check existence only.
      if (!layouts.isEmpty()) {
        for (String layoutFullName : layouts) {
          try {
            // Layout fullName format: ObjectApiName-Layout Name
            // Tooling API Name field stores just the layout label part
            if (!layoutFullName.contains('-')) {
              System.debug(
                '[VERIFY] Layout fullName unexpected format, skipping: ' +
                layoutFullName
              );
              continue;
            }
            String objPart = layoutFullName.substringBefore('-');
            String layoutName = layoutFullName.substringAfter('-');

            String query =
              'SELECT Id, Name FROM Layout' +
              ' WHERE Name = \'' +
              String.escapeSingleQuotes(layoutName) +
              '\'' +
              ' LIMIT 1';

            String endpoint =
              'https://' +
              DomainCreator.getOrgMyDomainHostname() +
              '/services/data/v61.0/tooling/query?q=' +
              EncodingUtil.urlEncode(query, 'UTF-8');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(15000);

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200) {
              Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                res.getBody()
              );
              Integer totalSize = (Integer) body.get('totalSize');
              if (totalSize == null || totalSize == 0) {
                warnings.add(
                  'Layout not found after deploy: ' +
                    layoutFullName +
                    '. The layout section may not have updated correctly.'
                );
                System.debug('[VERIFY] MISS — Layout: ' + layoutFullName);
              } else {
                System.debug('[VERIFY] OK — Layout: ' + layoutFullName);
              }
            } else {
              // Tooling API failed — do not block success, just log
              System.debug(
                '[VERIFY] Layout Tooling API call failed (' +
                  res.getStatusCode() +
                  ') for: ' +
                  layoutFullName +
                  ' — skipping layout verification'
              );
            }
          } catch (Exception layoutEx) {
            // Non-fatal — layout verification failure should not
            // turn a real success into an error
            System.debug(
              '[VERIFY] Layout verification exception for [' +
                layoutFullName +
                ']: ' +
                layoutEx.getMessage()
            );
          }
        }
      }
    } catch (Exception e) {
      // Verification itself failed — log it but do not affect
      // the deploy result. Better to report success with no
      // verification than to report error on a good deploy.
      System.debug(
        '[VERIFY] verifyDeploy() exception: ' +
          e.getMessage() +
          ' | ' +
          e.getStackTraceString()
      );
      ErrorLogger.log(e, issueKey);
    }

    return warnings.isEmpty() ? '' : String.join(warnings, '\n');
  }
}
