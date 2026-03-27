/**
 * DeployService.cls
 *
 * Handles deployment of ZIP file to Salesforce via Metadata API.
 *
 * HOW IT WORKS:
 * 1. Receives base64 ZIP from ZipBuilder
 * 2. Calls MetadataPort.deploy() → returns jobId immediately
 * 3. Enqueues DeployPoller to check status asynchronously
 * 4. Returns jobId for tracking
 *
 * WHY ASYNC?
 * Salesforce deploy is not instant — it can take 5-60 seconds.
 * We cannot block the main transaction — it would timeout.
 * So we enqueue a Queueable job (DeployPoller) that:
 *   → checks status every 5 seconds
 *   → re-enqueues itself until done
 *   → posts final result to Jira when complete
 */
public class DeployService {

    private static final String API_VERSION = '61.0';

    // ─────────────────────────────────────────────────────────────
    // PORT
    // ─────────────────────────────────────────────────────────────
    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('DeployService: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/' + API_VERSION;
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('DeployService: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // DEPLOY
    // Takes base64 ZIP, deploys it, enqueues poller
    // Returns jobId for tracking
    // ─────────────────────────────────────────────────────────────
    public static String deploy(String base64Zip, String issueKey) {
        System.debug('DeployService.deploy() called for issue: ' + issueKey);

        // Build deploy options
        MetadataService.DeployOptions options = new MetadataService.DeployOptions();
        options.allowMissingFiles  = false;
        options.autoUpdatePackage  = false;
        options.checkOnly          = false;
        options.ignoreWarnings     = true;
        options.performRetrieve    = false;
        options.purgeOnDelete      = false;
        options.rollbackOnError    = true;
        options.singlePackage      = true;
        options.testLevel          = 'NoTestRun';
        options.runTests           = new List<String>();

        System.debug('DeployService: sending ZIP to Metadata API...');
        MetadataService.AsyncResult asyncResult = port.deploy(base64Zip, options);
        String jobId = asyncResult.id;

        System.debug('DeployService: deploy started. jobId = ' + jobId + '. Caller is responsible for polling.');

        return jobId;
    }

    // ─────────────────────────────────────────────────────────────
    // CHECK STATUS
    // Called by DeployPoller to check if deploy is complete
    // ─────────────────────────────────────────────────────────────
    public static MetadataService.DeployResult checkStatus(String jobId) {
        System.debug('DeployService.checkStatus() called for jobId: ' + jobId);
        MetadataService.DeployResult result = port.checkDeployStatus(jobId, true);
        System.debug('DeployService: status=' + result.status + ', done=' + result.done);
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PARSE RESULT
    // Converts DeployResult into a human readable message
    // ─────────────────────────────────────────────────────────────
    public static String parseResult(MetadataService.DeployResult result) {
        if (result.success) {
            return '✅ Deploy successful. '
                + result.numberComponentsDeployed + ' component(s) deployed.';
        }

        // Build error message
        String error = '❌ Deploy failed. ';

        if (String.isNotBlank(result.errorMessage)) {
            error += result.errorMessage;
        }

        // Include component level errors if available
        if (result.details != null && result.details.componentFailures != null) {
            for (MetadataService.DeployMessage msg : result.details.componentFailures) {
                if (!msg.success) {
                    error += '\n- ' + msg.fullName + ': ' + msg.problem;
                }
            }
        }

        System.debug('DeployService: deploy failed - ' + error);
        return error;
    }

    public class DeployServiceException extends Exception {}
}