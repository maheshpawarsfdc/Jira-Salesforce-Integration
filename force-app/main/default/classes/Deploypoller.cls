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

        try {
            MetadataService.DeployResult result = getPort().checkDeployStatus(jobId, true);
            System.debug('DeployPoller: status=' + result.status + ', done=' + result.done);

            if (result.done) {
                String message = parseResult(result);
                System.debug('DeployPoller: deploy DONE. Posting to Jira: ' + message);
                JiraCallbackService.postComment(issueKey, message);

            } else if (attempt >= MAX_ATTEMPTS) {
                String timeoutMsg = '⚠️ Deploy is taking longer than expected. '
                    + 'Job ID: ' + jobId + '. '
                    + 'Please check Salesforce Setup → Deploy Status for the result.';
                System.debug('DeployPoller: MAX_ATTEMPTS reached.');
                JiraCallbackService.postComment(issueKey, timeoutMsg);

            } else {
                System.debug('DeployPoller: not done yet (status=' + result.status + '). Re-enqueuing...');
                // Use System.schedule instead of System.enqueueJob to avoid
                // Salesforce queueable stack depth limit (max 5 chained queueables).
                // Each scheduled job starts a fresh stack — no depth accumulation.
                Integer waitSecs = (attempt <= 2) ? 2 : 3;
                String cronExp = buildCronInSeconds(waitSecs);
                String jobName = 'DeployPoller_' + jobId + '_' + attempt;
                System.schedule(jobName, cronExp, new Deploypollerscheduler(jobId, issueKey, attempt + 1));
            }

        } catch (Exception e) {
            System.debug('DeployPoller: ERROR - ' + e.getMessage());
            String errorMsg = '❌ Error checking deploy status: ' + e.getMessage()
                + '. Job ID: ' + jobId
                + '. Check Salesforce Setup → Deploy Status manually.';
            try {
                JiraCallbackService.postComment(issueKey, errorMsg);
            } catch (Exception jiraEx) {
                System.debug('DeployPoller: Failed to post error to Jira: ' + jiraEx.getMessage());
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PARSE RESULT — human readable deploy outcome
    // ─────────────────────────────────────────────────────────────
    // Returns a cron expression for ~3 seconds from now
    private String buildCronInSeconds(Integer seconds) {
        Datetime dt = Datetime.now().addSeconds(seconds);
        return dt.second() + ' ' + dt.minute() + ' ' + dt.hour()
            + ' ' + dt.day() + ' ' + dt.month() + ' ? ' + dt.year();
    }

    private String parseResult(MetadataService.DeployResult result) {
        if (result.success) {
            return '✅ Deploy successful. '
                + result.numberComponentsDeployed + ' component(s) deployed.';
        }

        String error = '❌ Deploy failed. ';
        if (String.isNotBlank(result.errorMessage)) {
            error += result.errorMessage;
        }
        if (result.details != null && result.details.componentFailures != null) {
            for (MetadataService.DeployMessage msg : result.details.componentFailures) {
                if (!msg.success) {
                    error += '\n- ' + msg.fullName + ': ' + msg.problem;
                }
            }
        }
        return error;
    }

}