@RestResource(urlMapping='/Agentforce')
global class JiraInboundController {
  @HttpPost
  global static Map<String, String> handleRequest() {
    String issueKey = null;
    String llmResponse = null;
    Boolean success = false;

    try {
      // ── STEP 1: Parse incoming Jira payload ──
      // Use getBody() instead of toString() to avoid UTF-8 conversion errors
      Blob bodyBlob = RestContext.request.requestBody;
      String body = bodyBlob.toString();

      System.debug(
        'JiraInbound: Received request body length: ' + body.length()
      );

      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        body
      );

      issueKey = (String) payload.get('issueKey');
      String summary = (String) payload.get('summary');
      String description = (String) payload.get('description');

      // Ambient context so any ErrorLogger.log() deep in the stack tags this ticket.
      ErrorLogger.currentJiraKey = issueKey;

      System.debug(
        'JiraInbound: Received ticket ' + issueKey + ' — ' + summary
      );

      // ── STEP 2: Validate ──
      if (String.isBlank(issueKey) || String.isBlank(summary)) {
        throw new IllegalArgumentException(
          'issueKey and summary are required.'
        );
      }

      // ── STEP 3: Parse attachments ──
      List<Object> rawAttachments = (List<Object>) payload.get('attachments');
      if (rawAttachments != null && !rawAttachments.isEmpty()) {
        System.debug(
          'JiraInbound: Processing ' + rawAttachments.size() + ' attachment(s)'
        );

        for (Object a : rawAttachments) {
          Map<String, Object> att = (Map<String, Object>) a;
          String fileName = (String) att.get('fileName');
          String base64Data = (String) att.get('base64Content');
          String mimeType = (String) att.get('mimeType');

          if (String.isBlank(fileName)) {
            System.debug('JiraInbound: Skipping attachment with no fileName');
            continue;
          }

          if (String.isBlank(base64Data)) {
            System.debug(
              'JiraInbound: Skipping attachment [' +
                fileName +
                '] — no base64Content'
            );
            continue;
          }

          // Validate base64 string
          try {
            // Test decode to validate base64 format
            Blob testBlob = EncodingUtil.base64Decode(base64Data);
            System.debug(
              'JiraInbound: Validated attachment [' +
                fileName +
                '], size=' +
                testBlob.size() +
                ' bytes'
            );
          } catch (Exception e) {
            System.debug(
              'JiraInbound: Invalid base64 for [' +
                fileName +
                ']: ' +
                e.getMessage()
            );
            ErrorLogger.log(e, issueKey);
            continue;
          }

          StaticResourceHelper.currentAttachments.put(
            fileName,
            new Map<String, String>{
              'base64Content' => base64Data,
              'mimeType' => String.isNotBlank(mimeType)
                ? mimeType
                : 'application/octet-stream'
            }
          );
        }

        System.debug(
          'JiraInbound: Loaded ' +
            StaticResourceHelper.currentAttachments.size() +
            ' valid attachment(s)'
        );
      } else {
        System.debug('JiraInbound: No attachments in payload');
      }

      // Release the raw request body / parsed payload now — everything
      // needed from them (issueKey, summary, description, attachments)
      // has already been extracted into StaticResourceHelper.currentAttachments
      // and the locals above. For an attachment-bearing ticket, `body` and
      // `payload` are still holding a full base64 copy of every attachment
      // (on top of the copy now sitting in currentAttachments) for no
      // reason — and STAGE 1-2 below (org state + up to 3 LLM calls) is
      // heap-hungry on its own. Dropping the references here lets the GC
      // reclaim that memory before the heavy part of the transaction runs,
      // instead of carrying a dead ~1.3x-inflated copy of the attachment
      // through the whole request.
      body = null;
      payload = null;
      rawAttachments = null;

      // ── STEP 4: Let the AI read the story and execute ──
      llmResponse = LLMService.processJiraTicket(
        issueKey,
        summary,
        description
      );
      success = true;

      System.debug('JiraInbound: Done. Response: ' + llmResponse);
    } catch (Exception e) {
      success = false;
      llmResponse = 'Error: ' + e.getMessage();
      System.debug('JiraInbound: Exception — ' + e.getMessage());
      System.debug('JiraInbound: Stack trace — ' + e.getStackTraceString());
      ErrorLogger.log(e, issueKey);

      if (issueKey != null) {
        try {
          JiraCallbackService.storeDeploymentStatus(
            issueKey,
            'error',
            llmResponse,
            'exception'
          );
        } catch (Exception je) {
          System.debug(
            'JiraInbound: Failed to store error status — ' + je.getMessage()
          );
          ErrorLogger.log(je, issueKey);
        }
      }
    } finally {
      // Persist any deferred ErrorLogger / queued DML after all callouts are done.
      FunctionHelper.flushNonMetadataDmlQueues();
      FunctionHelper.deferErrorLogDml = false;
      // Clear attachments for next request
      StaticResourceHelper.currentAttachments.clear();
      ErrorLogger.currentJiraKey = null;
    }

    return new Map<String, String>{
      'issueKey' => issueKey,
      'status' => success ? 'success' : 'error',
      'message' => llmResponse
    };
  }
}
