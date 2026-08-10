/**
 * StaticResourceHelper.cls
 *
 * Handles Static Resource operations via the Tooling API (see
 * StaticResourceToolingQueueable for why this doesn't go through the
 * Metadata-API zip-deploy path everything else in this project uses).
 *
 * Files come from Jira ticket attachments.
 * currentAttachments is populated by JiraInboundController
 * before LLMService runs.
 */
public class StaticResourceHelper {
  private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

  // ─────────────────────────────────────────────────────────────
  // ATTACHMENTS
  // Populated by JiraInboundController before LLMService runs.
  // Key   = fileName  (e.g. logo.png)
  // Value = { base64Content, mimeType }
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Map<String, String>> currentAttachments = new Map<String, Map<String, String>>();

  // ─────────────────────────────────────────────────────────────
  // PENDING TOOLING OPS
  // Count of StaticResourceToolingQueueable jobs enqueued this
  // transaction but not yet executed (Queueable execution is genuinely
  // async — it hasn't run by the time this same transaction finishes).
  // LLMService checks this to skip its own immediate synchronous
  // "success"/"error" post-back-to-Jira when the only work done was a
  // pending Tooling API static resource op — otherwise Jira would see a
  // premature "success" before the actual create/update/delete callout
  // has even happened, followed by a second (possibly contradicting)
  // status once the queueable really finishes. Reset per ticket in
  // LLMService.processJiraTicket()'s hard-reset block.
  // ─────────────────────────────────────────────────────────────
  public static Integer pendingToolingOps = 0;

  // ─────────────────────────────────────────────────────────────
  // DEPLOY (create or update)
  // Enqueues a Tooling API callout (StaticResourceToolingQueueable)
  // instead of going through ZipBuilder/Zippex's Metadata-API zip-deploy
  // path. Zippex represents binary content as a hex string internally
  // (2x the byte size) and copies it several times while assembling the
  // archive — for a real ~1.2MB attachment this was directly reproduced
  // to throw "System.LimitException: Apex heap size too large" (up to
  // ~24MB peak), nowhere near Salesforce's actual 5MB static-resource
  // cap. The Tooling API needs the file in memory as base64 text only
  // ONCE, so it survives dramatically larger attachments on the same
  // governor budget — verified directly up to ~4.2MB. (Files much closer
  // to 5MB hit a separate, unconditional Apex limit — String length
  // exceeds maximum: 6,000,000 characters — which no packaging change on
  // this side can route around; see StaticResourceToolingQueueable's
  // class comment.)
  // ─────────────────────────────────────────────────────────────
  public static void deployStaticResource(Map<String, Object> args) {
    String apiName = getRequired(args, 'apiName');
    String fileName = getRequired(args, 'fileName');
    String cacheControl = getOptional(args, 'cacheControl', 'Public');

    System.debug('StaticResourceHelper.deployStaticResource() called');
    System.debug(
      'apiName=' +
        apiName +
        ' fileName=' +
        fileName +
        ' cacheControl=' +
        cacheControl
    );

    // Look up attachment from current ticket
    Map<String, String> att = currentAttachments.get(fileName);
    if (att == null) {
      throw new StaticResourceException(
        'Attachment not found: ' +
          fileName +
          '. Call static_resource_list first to see available files.'
      );
    }

    String mimeType = att.get('mimeType');
    String base64Data = att.get('base64Content');

    System.enqueueJob(
      new StaticResourceToolingQueueable(
        ErrorLogger.currentJiraKey,
        apiName,
        fileName,
        mimeType,
        cacheControl,
        base64Data
      )
    );
    pendingToolingOps++;

    System.debug(
      'StaticResourceHelper.deployStaticResource(): [' +
        apiName +
        '] queued for Tooling API deploy'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // DELETE
  // Enqueues a Tooling API DELETE (StaticResourceToolingQueueable) —
  // same rationale as deployStaticResource() above. This also sidesteps
  // whatever Metadata-API-specific delete quirks other metadata types
  // have (see the AssignmentRules delete investigation elsewhere in this
  // project): the Tooling API's StaticResource endpoint supports a plain
  // HTTP DELETE against the record's Id, which actually removes it.
  // ─────────────────────────────────────────────────────────────
  public static void deleteStaticResource(Map<String, Object> args) {
    String apiName = getRequired(args, 'apiName');

    System.debug(
      'StaticResourceHelper.deleteStaticResource() called: apiName=' + apiName
    );

    System.enqueueJob(
      new StaticResourceToolingQueueable(ErrorLogger.currentJiraKey, apiName)
    );
    pendingToolingOps++;

    System.debug(
      'StaticResourceHelper.deleteStaticResource(): [' +
        apiName +
        '] queued for Tooling API delete'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Helpers
  // ─────────────────────────────────────────────────────────────
  private static String escapeXml(String val) {
    if (String.isBlank(val)) {
      return '';
    }
    return val.replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
      .replace('"', '&quot;')
      .replace('\'', '&apos;');
  }

  private static String getRequired(Map<String, Object> args, String key) {
    Object val = args?.get(key);
    if (val == null || String.isBlank(String.valueOf(val))) {
      throw new StaticResourceException('Required parameter missing: ' + key);
    }
    return String.valueOf(val).trim();
  }

  private static String getOptional(
    Map<String, Object> args,
    String key,
    String defaultValue
  ) {
    Object val = args?.get(key);
    if (val == null) {
      return defaultValue;
    }
    String strVal = String.valueOf(val).trim();
    if (String.isBlank(strVal) || strVal == 'null') {
      return defaultValue;
    }
    return strVal;
  }

  public class StaticResourceException extends Exception {
  }
}
