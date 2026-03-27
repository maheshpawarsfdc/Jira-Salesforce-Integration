/**
 * DeployQueueable.cls
 *
 * Replaces ZipDeployQueueable. Handles two cases in one class:
 *
 * Fast path (text-only metadata):
 *   LLMService builds the ZIP synchronously and passes base64Zip directly.
 *   This job: calls deploy() → immediately checks status → if done, posts to Jira.
 *   If not done after first check, enqueues DeployPoller with attempt=1.
 *
 * Slow path (binary files like static resources):
 *   LLMService passes the ZipBuilder state snapshot.
 *   This job: builds ZIP (needs 60s CPU) → deploy() → immediate check → same as above.
 *
 * Saves 1–3 seconds vs old approach by:
 *   1. Eliminating the extra ZipDeployQueueable queue hop for text-only deploys
 *   2. Checking deploy status immediately after deploy() — many simple deploys
 *      finish before this job's callout completes
 */
public class DeployQueueable implements Queueable, Database.AllowsCallouts {

    private String              base64Zip;         // set on fast path
    private Map<String, String> files;             // set on slow path
    private Map<String, String> binaryFiles;       // set on slow path
    private String              metadataTypesJson; // set on slow path
    private String              issueKey;

    // ─────────────────────────────────────────────────────────────
    // FAST PATH constructor — ZIP already built by LLMService
    // ─────────────────────────────────────────────────────────────
    public DeployQueueable(String base64Zip, String issueKey) {
        this.base64Zip = base64Zip;
        this.issueKey  = issueKey;
    }

    // ─────────────────────────────────────────────────────────────
    // SLOW PATH constructor — binary files, build ZIP here
    // ─────────────────────────────────────────────────────────────
    public DeployQueueable(String issueKey) {
        this.issueKey          = issueKey;
        this.files             = ZipBuilder.files.clone();
        this.binaryFiles       = ZipBuilder.binaryFiles.clone();
        this.metadataTypesJson = JSON.serialize(ZipBuilder.metadataTypes);
    }

    // ─────────────────────────────────────────────────────────────
    // EXECUTE
    // ─────────────────────────────────────────────────────────────
    public void execute(QueueableContext ctx) {
        System.debug('DeployQueueable.execute() — issue: ' + issueKey);

        try {
            // ── Step 1: Build ZIP if on slow path ────────────────
            if (base64Zip == null) {
                System.debug('DeployQueueable: slow path — restoring ZipBuilder state and building ZIP...');
                ZipBuilder.files         = files;
                ZipBuilder.binaryFiles   = binaryFiles;
                ZipBuilder.metadataTypes = (Map<String, Set<String>>)
                    JSON.deserialize(metadataTypesJson, Map<String, Set<String>>.class);
                base64Zip = ZipBuilder.buildBase64Zip();
                ZipBuilder.clear();
            }

            // ── Step 2: Submit deploy ─────────────────────────────
            System.debug('DeployQueueable: submitting deploy for issue: ' + issueKey);
            String jobId = DeployService.deploy(base64Zip, issueKey);
            System.debug('DeployQueueable: deploy submitted. jobId = ' + jobId);

            // ── Step 3: Immediate status check ───────────────────
            // The Metadata API often finishes simple deploys (1-2 files) by the time
            // our SOAP checkStatus callout round-trips. This catches those cases
            // without needing any polling at all.
            MetadataService.DeployResult result = DeployService.checkStatus(jobId);
            System.debug('DeployQueueable: immediate status check — done=' + result.done + ', status=' + result.status);

            if (result.done) {
                String message = DeployService.parseResult(result);
                System.debug('DeployQueueable: deploy already done! Posting to Jira: ' + message);
                JiraCallbackService.postComment(issueKey, message);

            } else {
                // Not done yet — hand off to DeployPoller
                System.debug('DeployQueueable: not done yet — enqueuing DeployPoller attempt 1');
                DeployPoller poller = new DeployPoller(jobId, issueKey, 1);
                System.enqueueJob(poller);
            }

        } catch (Exception e) {
            System.debug('DeployQueueable: ERROR — ' + e.getMessage());
            System.debug('DeployQueueable: stack trace — ' + e.getStackTraceString());
            try {
                JiraCallbackService.postComment(
                    issueKey,
                    '❌ Deploy failed to start: ' + e.getMessage()
                );
            } catch (Exception je) {
                System.debug('DeployQueueable: failed to post Jira comment — ' + je.getMessage());
            }
        }
    }
}