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

    private static final Integer MAX_ATTEMPTS = 20;  // max ~100 seconds total
    private static final String  API_VERSION  = '61.0';

    // Public so DeployService can set them after Type.forName instantiation
    public String  jobId;
    public String  issueKey;
    public Integer attempt;
    public String  pendingZip2DataJson;

    // ─────────────────────────────────────────────────────────────
    // CONSTRUCTORS
    // ─────────────────────────────────────────────────────────────
    public DeployPoller() {}

    public DeployPoller(String jobId, String issueKey, Integer attempt) {
        this.jobId    = jobId;
        this.issueKey = issueKey;
        this.attempt  = attempt;
    }

    // ─────────────────────────────────────────────────────────────
    // PORT
    // ─────────────────────────────────────────────────────────────
    private MetadataPort getPort() {
        MetadataPort p = new MetadataPort();
        p.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/Soap/m/' + API_VERSION;
        p.SessionHeader = new MetadataService.SessionHeader_element();
        p.SessionHeader.sessionId = UserInfo.getSessionId();
        return p;
    }

    // ─────────────────────────────────────────────────────────────
    // EXECUTE — called by Salesforce async framework
    // ─────────────────────────────────────────────────────────────
    public void execute(QueueableContext ctx) {
        System.debug('');
        System.debug('DeployPoller.execute(): attempt ' + attempt + '/' + MAX_ATTEMPTS
            + ', jobId=' + jobId + ', issue=' + issueKey);
        System.debug('[5] DeployPoller attempt ' + attempt + ' started: ' + Datetime.now());

        try {
            MetadataService.DeployResult result = getPort().checkDeployStatus(jobId, true);
            System.debug('DeployPoller: status=' + result.status + ', done=' + result.done);
            System.debug('[6] Got deploy status [' + result.status + '] done=' + result.done + ' at: ' + Datetime.now());

            if (result.done) {
                System.debug('[7] Deploy DONE at: ' + Datetime.now());
                System.debug('[DEPLOY-TRACE] DeployPoller DONE | issue=' + issueKey
                    + ' | jobId=' + jobId + ' | success=' + result.success
                    + ' | hasPendingZip2=' + String.isNotBlank(pendingZip2DataJson)
                    + ' | components=' + result.numberComponentsDeployed);
                
                // ── Check if deployment was successful ────────────
                if (result.success) {
                    if (String.isNotBlank(pendingZip2DataJson)) {
                        System.debug('DeployPoller: ZIP 1 succeeded — enqueuing ZIP 2 deploy for issue: ' + issueKey);
                        System.debug('[DEPLOY-TRACE] ZIP1 SUCCESS -> enqueuing ZIP2 for issue=' + issueKey);
                        System.enqueueJob(ZipDeployQueueable.forZip2(issueKey, pendingZip2DataJson));
                    } else {
                        String successMsg = 'Successfully deployed! '
                            + result.numberComponentsDeployed + ' component(s) deployed.';
                        System.debug('DeployPoller: deploy SUCCESS. Posting to Jira: ' + successMsg);
                        System.debug('[DEPLOY-TRACE] FINAL SUCCESS (no chained ZIP2) for issue=' + issueKey);
                        postStatusToJira(issueKey, 'success', successMsg, jobId);
                    }
                } else {
                    // ── Deploy failed — extract error details ─────
                    String errorMsg = parseFailureResult(result);
                    System.debug('DeployPoller: deploy FAILED. Posting to Jira: ' + errorMsg);
                    System.debug('[DEPLOY-TRACE] FAILED (chain stops) | issue=' + issueKey
                        + ' | hadPendingZip2=' + String.isNotBlank(pendingZip2DataJson)
                        + ' | errorPreview=' + errorMsg.abbreviate(300));
                    postStatusToJira(issueKey, 'error', errorMsg, jobId);
                }

            } else if (attempt >= MAX_ATTEMPTS) {
                // ── Max attempts reached without completion ────────
                System.debug('DeployPoller: MAX_ATTEMPTS reached.');
                String timeoutMsg = 'Deploy timed out after ' + MAX_ATTEMPTS + ' attempts. '
                    + 'Status: ' + result.status + '. Check Salesforce deployment status manually.';
                postStatusToJira(issueKey, 'error', timeoutMsg, jobId);

            } else {
                // ── Not done yet, schedule next poll ──────────────
                System.debug('⏱ [6b] Not done, scheduling next poll at: ' + Datetime.now());
                System.debug('DeployPoller: not done yet (status=' + result.status + '). Re-enqueuing...');
                
                // Use System.schedule instead of System.enqueueJob to avoid
                // Salesforce queueable stack depth limit (max 5 chained queueables).
                String cronExp = buildCronIn2Seconds();
                String jobName = 'DeployPoller_' + jobId + '_' + attempt;
                System.schedule(jobName, cronExp, new Deploypollerscheduler(jobId, issueKey, attempt + 1, pendingZip2DataJson));
            }

        } catch (Exception e) {
            System.debug('DeployPoller: ERROR - ' + e.getMessage());
            ErrorLogger.log(e, issueKey);
            String exceptionMsg = 'Deploy poller error: ' + e.getMessage() + ' | ' + e.getStackTraceString();
            postStatusToJira(issueKey, 'error', exceptionMsg, jobId);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Helper method to post status to Jira (via issue properties)
    // ─────────────────────────────────────────────────────────────
    private static void postStatusToJira(String issueKey, String status, String message, String deployId) {
        try {
            JiraCallbackService.storeDeploymentStatus(issueKey, status, message, deployId);
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
            for (MetadataService.DeployMessage failure : result.details.componentFailures) {
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
        return dt.second() + ' ' + dt.minute() + ' ' + dt.hour()
            + ' ' + dt.day() + ' ' + dt.month() + ' ? ' + dt.year();
    }

    // ─────────────────────────────────────────────────────────────
    // PARSE RESULT — human readable deploy outcome (kept for backwards compat)
    // ─────────────────────────────────────────────────────────────
    private String parseResult(MetadataService.DeployResult result) {
        if (result.success) {
            return 'Deploy successful. '
                + result.numberComponentsDeployed + ' component(s) deployed.';
        }
        return parseFailureResult(result);
    }
}