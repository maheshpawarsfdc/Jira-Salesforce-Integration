/**
 * StaticResourceToolingQueueable.cls
 *
 * Creates/updates/deletes a StaticResource via the Tooling API's REST
 * sobject endpoint (/tooling/sobjects/StaticResource), instead of the
 * Metadata-API zip-deploy path (ZipBuilder + Zippex) the rest of this
 * project uses for everything else.
 *
 * WHY THIS EXISTS — Zippex (the pure-Apex zip library ZipBuilder uses)
 * represents binary file content as a hex-encoded string internally,
 * which is 2x the byte size, then copies that representation multiple
 * times while assembling the archive (decoded Blob, hex string, growing
 * archive string, final re-encoded base64). For a real ~1.2MB PNG this
 * was directly reproduced to blow past both the 6MB synchronous and
 * 12MB async Apex heap limits (System.LimitException: Apex heap size
 * too large) well before Salesforce's actual 5MB static-resource cap
 * ever comes into play. The Tooling API path needs the file in memory
 * as base64 text only ONCE (no zip, no hex round-trip), so it survives
 * dramatically larger files on the same governor budget.
 *
 * KNOWN CEILING — Apex Strings have a hard, unconditional limit of
 * 6,000,000 characters (System.StringException: String length exceeds
 * maximum), independent of heap size and not something this code can
 * work around. Base64 inflates bytes by 4/3, so the practical ceiling
 * for this approach is roughly 4.5 MB of source file content (verified
 * directly: 4.2 MB succeeds, and the same 6M-char ceiling means the raw
 * inbound Jira attachment payload itself couldn't survive much past
 * that as base64-in-JSON either — this is a platform limit on the
 * transport format, not something fixable by changing how the file is
 * packaged on the Salesforce side alone).
 *
 * Runs as a Queueable (async, 12MB heap budget, isolated from whatever
 * heap the synchronous Stage 1/1.5/1.6/2 LLM pipeline already used)
 * rather than inline during processDmlOperations(), the same way
 * ZipDeployQueueable is kept separate from the synchronous request
 * handling for the zip-deploy path.
 *
 * The Tooling API is synchronous (the callout's HTTP response IS the
 * result) — unlike the Metadata API zip-deploy, there is no async job
 * to poll (no Deploypoller equivalent needed here).
 */
public class StaticResourceToolingQueueable implements Queueable, Database.AllowsCallouts {
  private static final String TOOLING_BASE = '/services/data/v60.0/tooling/sobjects/StaticResource';
  private static final String TOOLING_QUERY = '/services/data/v60.0/tooling/query/?q=';

  private String issueKey;
  private String apiName;
  private String fileName;
  private String mimeType;
  private String cacheControl;
  private String base64Content;
  private Boolean isDelete;

  // ── Constructor for DEPLOY (create or update) ──
  public StaticResourceToolingQueueable(
    String issueKey,
    String apiName,
    String fileName,
    String mimeType,
    String cacheControl,
    String base64Content
  ) {
    this.issueKey = issueKey;
    this.apiName = apiName;
    this.fileName = fileName;
    this.mimeType = String.isNotBlank(mimeType)
      ? mimeType
      : 'application/octet-stream';
    this.cacheControl = String.isNotBlank(cacheControl)
      ? cacheControl
      : 'Public';
    this.base64Content = base64Content;
    this.isDelete = false;
  }

  // ── Constructor for DELETE ──
  public StaticResourceToolingQueueable(String issueKey, String apiName) {
    this.issueKey = issueKey;
    this.apiName = apiName;
    this.isDelete = true;
  }

  public void execute(QueueableContext ctx) {
    System.debug(
      '[STATIC-RESOURCE-TOOLING] execute() start | apiName=' +
        apiName +
        ' | isDelete=' +
        isDelete
    );
    try {
      String existingId = findExistingId(apiName);

      if (isDelete) {
        if (existingId == null) {
          postStatus(
            'success',
            'Static resource [' +
              apiName +
              '] does not exist — nothing to delete.'
          );
          return;
        }
        HttpResponse res = callout(
          'DELETE',
          TOOLING_BASE + '/' + existingId,
          null
        );
        if (res.getStatusCode() == 204) {
          postStatus('success', 'Deleted static resource [' + apiName + '].');
        } else {
          postStatus(
            'error',
            'Failed to delete static resource [' +
              apiName +
              ']: HTTP ' +
              res.getStatusCode() +
              ' — ' +
              res.getBody()
          );
        }
        return;
      }

      // ── DEPLOY (create or update) ──
      // Build the JSON body via direct string concatenation, not
      // JSON.serialize(Map) — serializing a Map holding the base64
      // string creates a second full-size copy of it, which is exactly
      // the kind of redundant copy this class exists to avoid. Release
      // base64Content the instant it's folded into jsonBody.
      String jsonBody =
        '{"Name":"' +
        escapeJson(apiName) +
        '","ContentType":"' +
        escapeJson(mimeType) +
        '","CacheControl":"' +
        escapeJson(cacheControl) +
        '","Body":"' +
        base64Content +
        '"}';
      base64Content = null;

      HttpResponse res = String.isNotBlank(existingId)
        ? callout('PATCH', TOOLING_BASE + '/' + existingId, jsonBody)
        : callout('POST', TOOLING_BASE, jsonBody);
      jsonBody = null;

      Integer status = res.getStatusCode();
      if (status == 201 || status == 204) {
        postStatus(
          'success',
          'Static resource [' +
            apiName +
            '] deployed from [' +
            fileName +
            ']' +
            (existingId != null ? ' (updated)' : ' (created)') +
            '.'
        );
      } else {
        postStatus(
          'error',
          'Failed to deploy static resource [' +
            apiName +
            ']: HTTP ' +
            status +
            ' — ' +
            res.getBody()
        );
      }
    } catch (Exception e) {
      System.debug(
        '[STATIC-RESOURCE-TOOLING] ERROR — ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
      ErrorLogger.log(e, issueKey);
      postStatus(
        'error',
        'Static resource operation failed for [' +
          apiName +
          ']: ' +
          e.getMessage()
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Looks up the existing StaticResource's Id by Name, if any —
  // determines create (POST) vs update (PATCH), and lets delete
  // no-op cleanly when the target is already absent.
  // ─────────────────────────────────────────────────────────────
  private String findExistingId(String name) {
    String q =
      'SELECT Id FROM StaticResource WHERE Name = \'' +
      String.escapeSingleQuotes(name) +
      '\'';
    HttpResponse res = callout(
      'GET',
      TOOLING_QUERY + EncodingUtil.urlEncode(q, 'UTF-8'),
      null
    );
    if (res.getStatusCode() != 200) {
      return null;
    }
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );
    List<Object> records = (List<Object>) parsed.get('records');
    if (records == null || records.isEmpty()) {
      return null;
    }
    Map<String, Object> rec = (Map<String, Object>) records[0];
    return (String) rec.get('Id');
  }

  private HttpResponse callout(String method, String path, String body) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint(Url.getOrgDomainUrl().toExternalForm() + path);
    req.setMethod(method);
    req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);
    if (body != null) {
      req.setBody(body);
    }
    Http http = new Http();
    return http.send(req);
  }

  private void postStatus(String status, String message) {
    System.debug(
      '[STATIC-RESOURCE-TOOLING] status=' + status + ' — ' + message
    );
    try {
      JiraCallbackService.storeDeploymentStatus(
        issueKey,
        status,
        message,
        null
      );
    } catch (Exception je) {
      System.debug(
        '[STATIC-RESOURCE-TOOLING] failed to post Jira status — ' +
        je.getMessage()
      );
      ErrorLogger.log(je, issueKey);
    }
  }

  private String escapeJson(String val) {
    if (String.isBlank(val)) {
      return '';
    }
    return val.replace('\\', '\\\\').replace('"', '\\"');
  }

  public class StaticResourceToolingException extends Exception {
  }
}
