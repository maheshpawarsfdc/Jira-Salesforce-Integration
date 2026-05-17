public class ZipDeployQueueable implements Queueable, Database.AllowsCallouts {
  private Map<String, String> files;
  private Map<String, String> binaryFiles;
  private String metadataTypesJson; // Set<String> values need JSON round-trip
  private String issueKey;
  private String pendingZip2DataJson;
  private String apexTestContextJson;

  // ── Constructor for ZIP 1: snapshot ZipBuilder state, no chained data
  public ZipDeployQueueable(String issueKey) {
    this.issueKey = issueKey;
    // Snapshot ZipBuilder state — these are the static maps populated during tool calls
    this.files = ZipBuilder.files.clone();
    this.binaryFiles = ZipBuilder.binaryFiles.clone();
    this.metadataTypesJson = JSON.serialize(ZipBuilder.metadataTypes);
  }

  // ── Constructor for ZIP 1: snapshot ZipBuilder state + carry zip2 data forward
  public ZipDeployQueueable(String issueKey, String pendingZip2DataJson) {
    this.issueKey = issueKey;
    this.files = ZipBuilder.files.clone();
    this.binaryFiles = ZipBuilder.binaryFiles.clone();
    this.metadataTypesJson = JSON.serialize(ZipBuilder.metadataTypes);
    this.pendingZip2DataJson = pendingZip2DataJson;
  }

  // ── Constructor for Apex-first deploy: snapshot ZipBuilder + carry test context
  public ZipDeployQueueable(
    String issueKey,
    String pendingZip2DataJson,
    String apexTestContextJson
  ) {
    this.issueKey = issueKey;
    this.files = ZipBuilder.files.clone();
    this.binaryFiles = ZipBuilder.binaryFiles.clone();
    this.metadataTypesJson = JSON.serialize(ZipBuilder.metadataTypes);
    this.pendingZip2DataJson = pendingZip2DataJson;
    this.apexTestContextJson = apexTestContextJson;
  }

  // ── Private no-arg constructor — used only by forZip2 factory
  private ZipDeployQueueable() {
  }

  // ── Static factory for ZIP 2: receives files directly, no ZipBuilder snapshot needed
  public static ZipDeployQueueable forZip2(
    String issueKey,
    String zip2DataJson
  ) {
    ZipDeployQueueable q = new ZipDeployQueueable();
    q.issueKey = issueKey;
    Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
      zip2DataJson
    );
    q.files = (Map<String, String>) JSON.deserialize(
      JSON.serialize(data.get('files')),
      Map<String, String>.class
    );
    q.binaryFiles = (Map<String, String>) JSON.deserialize(
      JSON.serialize(data.get('binaryFiles')),
      Map<String, String>.class
    );
    q.metadataTypesJson = (String) data.get('metadataTypesJson');
    return q;
  }

  public void execute(QueueableContext ctx) {
    String stage = String.isBlank(pendingZip2DataJson) &&
      (this.files != null && !this.files.isEmpty())
      ? 'ZIP1-or-ZIP2'
      : (String.isNotBlank(pendingZip2DataJson)
          ? 'ZIP1 (with pending ZIP2)'
          : 'ZIP1/ZIP2');
    System.debug(
      '[DEPLOY-TRACE] ZipDeployQueueable.execute START | issue=' +
        issueKey +
        ' | stage=' +
        stage +
        ' | files=' +
        (files == null ? null : files.keySet()) +
        ' | hasPendingZip2=' +
        String.isNotBlank(pendingZip2DataJson)
    );
    System.debug(
      'ZipDeployQueueable.execute() — restoring ZipBuilder state for issue: ' +
      issueKey
    );
    System.debug('[1] ZipDeployQueueable started: ' + Datetime.now());

    // Restore static ZipBuilder state in the new transaction
    ZipBuilder.files = files;
    ZipBuilder.binaryFiles = binaryFiles;
    ZipBuilder.metadataTypes = (Map<String, Set<String>>) JSON.deserialize(
      metadataTypesJson,
      Map<String, Set<String>>.class
    );

    try {
      System.debug(
        'ZipDeployQueueable: building ZIP (' +
          files.size() +
          ' text + ' +
          binaryFiles.size() +
          ' binary file(s))...'
      );
      System.debug('[2] Starting ZIP build: ' + Datetime.now());

      String base64Zip = ZipBuilder.buildBase64Zip();
      ZipBuilder.clear();
      System.debug('[3] ZIP built, starting deploy: ' + Datetime.now());

      System.debug('ZipDeployQueueable: ZIP built — starting deploy...');
      String jobId = DeployService.deploy(
        base64Zip,
        issueKey,
        pendingZip2DataJson,
        apexTestContextJson
      );
      System.debug('ZipDeployQueueable: deploy started. jobId = ' + jobId);
      System.debug('[4] Deploy submitted to Metadata API: ' + Datetime.now());
    } catch (Exception e) {
      System.debug('ZipDeployQueueable: ERROR — ' + e.getMessage());
      System.debug(
        'ZipDeployQueueable: stack trace — ' + e.getStackTraceString()
      );
      ErrorLogger.log(e, issueKey);
      try {
        JiraCallbackService.storeDeploymentStatus(
          issueKey,
          'error',
          'Deploy failed to start: ' + e.getMessage(),
          null
        );
      } catch (Exception je) {
        System.debug(
          'ZipDeployQueueable: failed to post Jira comment — ' + je.getMessage()
        );
        ErrorLogger.log(je, issueKey);
      }
    }
  }
}
