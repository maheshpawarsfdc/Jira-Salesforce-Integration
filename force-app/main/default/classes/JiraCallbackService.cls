public class JiraCallbackService {
    
    private static final String JIRA_BASE_URL   = App_Config__c.getOrgDefaults().Jira_Base_URL__c;
    private static final String JIRA_API_TOKEN  = App_Config__c.getOrgDefaults().Jira_API_Token__c;
    private static final String JIRA_USER_EMAIL = App_Config__c.getOrgDefaults().Jira_User_Email__c;
    
    // ─────────────────────────────────────────────────────────────
    // STORE DEPLOYMENT STATUS IN JIRA ISSUE PROPERTY
    // This is a key-value storage per issue that Forge app can read
    // ─────────────────────────────────────────────────────────────
    public static void storeDeploymentStatus(String issueKey, String status, String message, String deployId) {
        String endpoint = JIRA_BASE_URL 
            + '/rest/api/3/issue/' 
            + issueKey 
            + '/properties/agentforce-deploy-status';
        
        Map<String, Object> statusData = new Map<String, Object>{
            'status'    => status,     // 'success' | 'error'
            'message'   => message,
            'deployId'  => deployId,
            'timestamp' => DateTime.now().getTime()
        };
        
        String credentials = JIRA_USER_EMAIL + ':' + JIRA_API_TOKEN;
        String encodedCredentials = EncodingUtil.base64Encode(Blob.valueOf(credentials));
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('PUT');  // PUT to create or update the property
        req.setHeader('Authorization', 'Basic ' + encodedCredentials);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);
        req.setBody(JSON.serialize(statusData));
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        System.debug('JiraCallbackService: Store status response: ' + res.getStatusCode());
        System.debug('JiraCallbackService: Response body: ' + res.getBody());
        
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            System.debug('JiraCallbackService: Failed to record deploy-status property in Jira for '
                + issueKey + ' (deploy outcome was [' + status + '])');
        } else {
            // NOTE: this confirms the Jira property write succeeded — the deploy
            // itself may have failed. Always read `status` to see the real result.
            System.debug('JiraCallbackService: Recorded deploy-status property in Jira for '
                + issueKey + ' (deploy outcome was [' + status + '])');
        }
    }
    
    public class JiraCallbackException extends Exception {}
}