public class ZipDeployQueueable implements Queueable, Database.AllowsCallouts {

    private Map<String, String> files;
    private Map<String, String> binaryFiles;
    private String              metadataTypesJson;  // Set<String> values need JSON round-trip
    private String              issueKey;

    public ZipDeployQueueable(String issueKey) {
        this.issueKey          = issueKey;
        // Snapshot ZipBuilder state — these are the static maps populated during tool calls
        this.files             = ZipBuilder.files.clone();
        this.binaryFiles       = ZipBuilder.binaryFiles.clone();
        this.metadataTypesJson = JSON.serialize(ZipBuilder.metadataTypes);
    }

    public void execute(QueueableContext ctx) {
        System.debug('ZipDeployQueueable.execute() — restoring ZipBuilder state for issue: ' + issueKey);
        System.debug('⏱ [1] ZipDeployQueueable started: ' + Datetime.now());


        // Restore static ZipBuilder state in the new transaction
        ZipBuilder.files         = files;
        ZipBuilder.binaryFiles   = binaryFiles;
        ZipBuilder.metadataTypes = (Map<String, Set<String>>)
            JSON.deserialize(metadataTypesJson, Map<String, Set<String>>.class);

        try {
            System.debug('ZipDeployQueueable: building ZIP (' + files.size() + ' text + '
             + binaryFiles.size() + ' binary file(s))...');
             System.debug('⏱ [2] Starting ZIP build: ' + Datetime.now());

            String base64Zip = ZipBuilder.buildBase64Zip();
            ZipBuilder.clear();
            System.debug('⏱ [3] ZIP built, starting deploy: ' + Datetime.now());


            System.debug('ZipDeployQueueable: ZIP built — starting deploy...');
            String jobId = DeployService.deploy(base64Zip, issueKey);
            System.debug('ZipDeployQueueable: deploy started. jobId = ' + jobId);
            System.debug('⏱ [4] Deploy submitted to Metadata API: ' + Datetime.now());


        } catch (Exception e) {
            System.debug('ZipDeployQueueable: ERROR — ' + e.getMessage());
            System.debug('ZipDeployQueueable: stack trace — ' + e.getStackTraceString());
            try {
                JiraCallbackService.postComment(
                    issueKey,
                    '❌ Deploy failed to start: ' + e.getMessage()
                );
            } catch (Exception je) {
                System.debug('ZipDeployQueueable: failed to post Jira comment — ' + je.getMessage());
            }
        }
    }
}