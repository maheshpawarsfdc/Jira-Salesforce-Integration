public class JiraCallbackService {
    
    private static final String JIRA_BASE_URL   = App_Config__c.getOrgDefaults().Jira_Base_URL__c;
    private static final String JIRA_API_TOKEN  = App_Config__c.getOrgDefaults().Jira_API_Token__c;
    private static final String JIRA_USER_EMAIL = App_Config__c.getOrgDefaults().Jira_User_Email__c;
    
    // ─────────────────────────────────────────────────────────────
    // POST RESULT AS COMMENT ON JIRA TICKET
    // ─────────────────────────────────────────────────────────────
    public static void postComment(String issueKey, String comment) {
        String endpoint = JIRA_BASE_URL 
            + '/rest/api/3/issue/' 
            + issueKey 
            + '/comment';
        
        // Jira API v3 requires ADF (Atlassian Document Format) for comment body
        Map<String, Object> requestBody = new Map<String, Object>{
            'body' => new Map<String, Object>{
                'type'    => 'doc',
                'version' => 1,
                'content' => new List<Object>{
                    new Map<String, Object>{
                        'type'    => 'paragraph',
                        'content' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'text',
                                'text' => comment
                            }
                        }
                    }
                }
            }
        };
        
        // Jira uses Basic Auth: Base64(email:apiToken)
        String credentials = JIRA_USER_EMAIL + ':' + JIRA_API_TOKEN;
        String encodedCredentials = EncodingUtil.base64Encode(
            Blob.valueOf(credentials)
        );
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Basic ' + encodedCredentials);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(30000);
        req.setBody(JSON.serialize(requestBody));
        
        Http http     = new Http();
        HttpResponse res = http.send(req);
        
        System.debug('JiraCallbackService: Response status: ' + res.getStatusCode());
        System.debug('JiraCallbackService: Response body: ' + res.getBody());
        
        if (res.getStatusCode() != 201) {
            throw new JiraCallbackException(
                'Failed to post comment to Jira. Status: ' 
                + res.getStatusCode() 
                + ' Body: ' + res.getBody()
            );
        }
    }
    
    // ─────────────────────────────────────────────────────────────
    // UPDATE JIRA TICKET STATUS
    // ─────────────────────────────────────────────────────────────
    public static void updateTicketStatus(String issueKey, Boolean success) {
        try {
            // First get available transitions for this ticket
            String transitionId = getTransitionId(issueKey, success);
            if (String.isBlank(transitionId)) {
                System.debug('JiraCallbackService: No matching transition found');
                return;
            }
            
            // Apply the transition
            String endpoint = JIRA_BASE_URL
                + '/rest/api/3/issue/'
                + issueKey
                + '/transitions';
            
            Map<String, Object> requestBody = new Map<String, Object>{
                'transition' => new Map<String, Object>{
                    'id' => transitionId
                }
            };
            
            String credentials = JIRA_USER_EMAIL + ':' + JIRA_API_TOKEN;
            String encodedCredentials = EncodingUtil.base64Encode(
                Blob.valueOf(credentials)
            );
            
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Authorization', 'Basic ' + encodedCredentials);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(requestBody));
            
            Http http        = new Http();
            HttpResponse res = http.send(req);
            
            System.debug('JiraCallbackService: Transition status: ' + res.getStatusCode());
            
        } catch (Exception e) {
            // Don't fail the whole flow just because status update failed
            System.debug('JiraCallbackService: Failed to update ticket status: ' + e.getMessage());
        }
    }
    
    // ─────────────────────────────────────────────────────────────
    // GET TRANSITION ID
    // Finds the transition ID for Done or Failed
    // ─────────────────────────────────────────────────────────────
    private static String getTransitionId(String issueKey, Boolean success) {
        String endpoint = JIRA_BASE_URL
            + '/rest/api/3/issue/'
            + issueKey
            + '/transitions';
        
        String credentials = JIRA_USER_EMAIL + ':' + JIRA_API_TOKEN;
        String encodedCredentials = EncodingUtil.base64Encode(
            Blob.valueOf(credentials)
        );
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Basic ' + encodedCredentials);
        req.setHeader('Accept', 'application/json');
        req.setTimeout(30000);
        
        Http http        = new Http();
        HttpResponse res = http.send(req);
        
        if (res.getStatusCode() != 200) {
            return null;
        }
        
        Map<String, Object> responseBody = (Map<String, Object>) JSON.deserializeUntyped(
            res.getBody()
        );
        List<Object> transitions = (List<Object>) responseBody.get('transitions');
        
        // Look for Done on success, Failed/Cancelled on failure
        List<String> successNames = new List<String>{ 'done', 'complete', 'completed', 'resolved' };
        List<String> failureNames = new List<String>{ 'failed', 'cancelled', 'canceled', 'blocked' };
        List<String> targetNames  = success ? successNames : failureNames;
        
        for (Object raw : transitions) {
            Map<String, Object> transition = (Map<String, Object>) raw;
            String name = ((String) transition.get('name')).toLowerCase();
            for (String target : targetNames) {
                if (name.contains(target)) {
                    return (String) transition.get('id');
                }
            }
        }
        return null;
    }
    
    // ─────────────────────────────────────────────────────────────
    // BUILD RESULT COMMENT
    // Formats the LLM response into a clean Jira comment
    // ─────────────────────────────────────────────────────────────
    public static String buildResultComment(
        String issueKey, 
        String llmResponse, 
        Boolean success
    ) {
        String status = success ? '✅ Completed' : '❌ Failed';
        
        return '🤖 Salesforce AI Assistant — ' + status
            + '\n\n'
            + llmResponse
            + '\n\n'
            + '━━━━━━━━━━━━━━━━━━━━'
            + '\nProcessed by Salesforce AI Integration'
            + '\nOrg: ' + UserInfo.getOrganizationName()
            + '\nTimestamp: ' + DateTime.now().format('yyyy-MM-dd HH:mm:ss z');
    }
    
    public class JiraCallbackException extends Exception {}
}