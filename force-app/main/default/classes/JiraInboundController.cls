@RestResource(urlMapping='/Agentforce')
global class JiraInboundController {

    @HttpPost
    global static Map<String, String> handleRequest() {
        String issueKey    = null;
        String llmResponse = null;
        Boolean success    = false;

        try {
            // ── STEP 1: Parse incoming Jira payload ──
            String body                 = RestContext.request.requestBody.toString();
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body);

            issueKey               = (String) payload.get('issueKey');
            String summary         = (String) payload.get('summary');
            String description     = (String) payload.get('description');

            System.debug('JiraInbound: Received ticket ' + issueKey + ' — ' + summary);

            // ── STEP 2: Validate ──
            if (String.isBlank(issueKey) || String.isBlank(summary)) {
                throw new IllegalArgumentException('issueKey and summary are required.');
            }

            // ── STEP 3: Let the AI read the story and execute ──
            llmResponse = LLMService.processJiraTicket(issueKey, summary, description);
            success     = true;

            System.debug('JiraInbound: Done. Response: ' + llmResponse);

        } catch (Exception e) {
            success     = false;
            llmResponse = 'Error: ' + e.getMessage();
            System.debug('JiraInbound: Exception — ' + e.getMessage());
        }

        // ── STEP 4: Post result back to Jira as a comment ──
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