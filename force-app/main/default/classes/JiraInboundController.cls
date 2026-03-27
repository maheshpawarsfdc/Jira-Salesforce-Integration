@RestResource(urlMapping='/Agentforce')
global class JiraInboundController {

    @HttpPost
    global static Map<String, String> handleRequest() {
        String issueKey    = null;
        String llmResponse = null;
        Boolean success    = false;

        try {
            // ── STEP 1: Parse incoming Jira payload ──
            // Use getBody() instead of toString() to avoid UTF-8 conversion errors
            Blob bodyBlob = RestContext.request.requestBody;
            String body   = bodyBlob.toString();
            
            System.debug('JiraInbound: Received request body length: ' + body.length());
            
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body);

            issueKey           = (String) payload.get('issueKey');
            String summary     = (String) payload.get('summary');
            String description = (String) payload.get('description');

            System.debug('JiraInbound: Received ticket ' + issueKey + ' — ' + summary);

            // ── STEP 2: Validate ──
            if (String.isBlank(issueKey) || String.isBlank(summary)) {
                throw new IllegalArgumentException('issueKey and summary are required.');
            }

            // ── STEP 3: Parse attachments ──
            List<Object> rawAttachments = (List<Object>) payload.get('attachments');
            if (rawAttachments != null && !rawAttachments.isEmpty()) {
                System.debug('JiraInbound: Processing ' + rawAttachments.size() + ' attachment(s)');
                
                for (Object a : rawAttachments) {
                    Map<String, Object> att = (Map<String, Object>) a;
                    String fileName    = (String) att.get('fileName');
                    String base64Data  = (String) att.get('base64Content');
                    String mimeType    = (String) att.get('mimeType');
                    
                    if (String.isBlank(fileName)) {
                        System.debug('JiraInbound: Skipping attachment with no fileName');
                        continue;
                    }
                    
                    if (String.isBlank(base64Data)) {
                        System.debug('JiraInbound: Skipping attachment [' + fileName + '] — no base64Content');
                        continue;
                    }
                    
                    // Validate base64 string
                    try {
                        // Test decode to validate base64 format
                        Blob testBlob = EncodingUtil.base64Decode(base64Data);
                        System.debug('JiraInbound: Validated attachment [' + fileName + '], size=' + testBlob.size() + ' bytes');
                    } catch (Exception e) {
                        System.debug('JiraInbound: Invalid base64 for [' + fileName + ']: ' + e.getMessage());
                        continue;
                    }
                    
                    StaticResourceHelper.currentAttachments.put(fileName, new Map<String, String>{
                        'base64Content' => base64Data,
                        'mimeType'      => String.isNotBlank(mimeType) ? mimeType : 'application/octet-stream'
                    });
                }
                
                System.debug('JiraInbound: Loaded ' + StaticResourceHelper.currentAttachments.size() + ' valid attachment(s)');
            } else {
                System.debug('JiraInbound: No attachments in payload');
            }

            // ── STEP 4: Let the AI read the story and execute ──
            llmResponse = LLMService.processJiraTicket(issueKey, summary, description);
            success     = true;

            System.debug('JiraInbound: Done. Response: ' + llmResponse);

        } catch (Exception e) {
            success     = false;
            llmResponse = 'Error: ' + e.getMessage(); //llmResponse = 'Something went wrong. Please check logs.';
            System.debug('JiraInbound: Exception — ' + e.getMessage());
            System.debug('JiraInbound: Stack trace — ' + e.getStackTraceString());
        } finally {
            // Clear attachments for next request
            StaticResourceHelper.currentAttachments.clear();
        }

        // ── STEP 5: Post result back to Jira as a comment ──
        // Note: Commenting out for now to avoid hitting Jira API limits during testing. Can be re-enabled later.

        // if (String.isNotBlank(issueKey)) {
        //     try {
        //         String comment = JiraCallbackService.buildResultComment(issueKey, llmResponse, success);
        //         JiraCallbackService.postComment(issueKey, comment);
        //         JiraCallbackService.updateTicketStatus(issueKey, success);
        //     } catch (Exception e) {
        //         System.debug('JiraInbound: Failed to post comment — ' + e.getMessage());
        //     }
        // }

        return new Map<String, String>{
            'issueKey' => issueKey,
            'status'   => success ? 'success' : 'error',
            'message'  => llmResponse
        };
    }
}