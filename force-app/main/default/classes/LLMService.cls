public class LLMService {

    private static final String GROQ_BASE_URL = App_Config__c.getOrgDefaults().Groq_Base_URL__c;
    private static final String GROQ_API_KEY  = App_Config__c.getOrgDefaults().Groq_API_Key__c;
    private static final String GROQ_MODEL    = App_Config__c.getOrgDefaults().Groq_Model__c;

    private static final Integer MAX_ITERATIONS = 10;

    // ── API CALL + TOKEN TRACKING ──────────────────────────────
    private static Integer apiCallCount     = 0;
    private static Integer totalPromptTokens     = 0;
    private static Integer totalCompletionTokens = 0;
    private static Integer totalTokens          = 0;

    private static String pendingZip2DataJson;

    // ── METADATA PORT (lazy-init, same pattern as ProfileHelper) ──
    private static MetadataPort metaPort {
        get {
            if (metaPort == null) {
                System.debug('LLMService: initializing MetadataPort...');
                metaPort = new MetadataPort();
                metaPort.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                metaPort.SessionHeader = new MetadataService.SessionHeader_element();
                metaPort.SessionHeader.sessionId = getMetadataSessionId();
                System.debug('LLMService: MetadataPort ready.');
            }
            return metaPort;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // ENTRY POINT — called from JiraInboundController
    // ─────────────────────────────────────────────────────────────
    public static String processJiraTicket(String issueKey, String summary, String description) {

        // Hard reset per ticket to prevent stale metadata from any previous run
        // (especially after failed/aborted flows) from leaking into this request.
        pendingZip2DataJson = null;
        ZipBuilder.clear();
        FunctionHelper.clearQueues();

        // Ambient ticket context so any ErrorLogger.log() in deep helpers tags this key.
        ErrorLogger.currentJiraKey = issueKey;
        FunctionHelper.deferErrorLogDml = true;

        System.debug('JIRA AI ASSISTANT — NEW REQUEST');
        System.debug('► Issue Key  : ' + issueKey);
        System.debug('► Summary    : ' + summary);
        System.debug('► Description: ' + description);

        // ── STAGE 1: Read org state ────────────────────────────
        // runOrgCheck — pure Apex, no LLM call, always runs.
        //               Covers: existing fields/objects, sharing models,
        //               layout structure, CSV pre-read, custom labels,
        //               Apex class names, VF page names.
        System.debug('── STAGE 1: Reading org state...');
        Map<String, Object> orgState = runOrgCheck(summary, description);

        System.debug('── Org check complete. orgState: ' + JSON.serialize(orgState));

        // ── STAGE 1.5: Route — select relevant prompt sections ──
        // Small LLM call classifies ticket into feature keys.
        // PromptService assembles the final system prompt from CMT records.
        System.debug('── STAGE 1.5: Routing prompt sections...');
        String systemPrompt = runRouterStage(summary, description);
        System.debug('── STAGE 1.5 complete. System prompt length: ' + systemPrompt.length());

        // ── STAGE 2: Generate XML files ────────────────────────
        // LLM generates all XML based on ticket + org state
        System.debug('── STAGE 2: Generating XML...');
        String result = runXmlGenerationStage(issueKey, summary, description, orgState, systemPrompt);
        System.debug('── STAGE 2 complete.');


    // ── ZIP DEPLOY (async) ─────────────────────────────────────
    // Flush DML first — enqueue follows immediately, no callout after
    if (ZipBuilder.hasFiles()) {
        flushDmlQueues();
        FunctionHelper.deferErrorLogDml = false;
        System.debug('LLMService: ZipBuilder has files, enqueueing deploy...');
        System.enqueueJob(new ZipDeployQueueable(issueKey, pendingZip2DataJson));
        pendingZip2DataJson = null;
        ZipBuilder.clear();
        return result + '\n⏳ Deploying...';
    }

    // ── FINAL SUMMARY ─────────────────────────────────────────
        System.debug('╔══════════════════════════════════════╗');
        System.debug('║         LLM USAGE SUMMARY            ║');
        System.debug('╠══════════════════════════════════════╣');
        System.debug('║  API Calls        : ' + apiCallCount);
        System.debug('║  Prompt Tokens    : ' + totalPromptTokens);
        System.debug('║  Completion Tokens: ' + totalCompletionTokens);
        System.debug('║  Total Tokens     : ' + totalTokens);
        System.debug('╚══════════════════════════════════════╝');
        apiCallCount = 0; totalPromptTokens = 0; totalCompletionTokens = 0; totalTokens = 0;


    // ── SYNC RESULT (DML-only path) ────────────────────────────
    // storeDeploymentStatus makes an HTTP callout.
    // Salesforce forbids callouts after DML in the same transaction,
    // so the callout MUST happen before flushDmlQueues().
    try {
        JiraCallbackService.storeDeploymentStatus(
            issueKey,
            FunctionHelper.hadError ? 'error' : 'success',
            result,
            'sync-' + DateTime.now().getTime()
        );
    } catch (Exception e) {
        System.debug('LLMService: storeDeploymentStatus FAILED — ' + e.getMessage());
        ErrorLogger.log(e);
    }

    // DML flush comes AFTER the callout — safe now
    flushDmlQueues();
    FunctionHelper.deferErrorLogDml = false;
    FunctionHelper.hadError = false;

        // ── FINAL SUMMARY ─────────────────────────────────────────
        System.debug('');
        System.debug('╔══════════════════════════════════════╗');
        System.debug('║         LLM USAGE SUMMARY            ║');
        System.debug('╠══════════════════════════════════════╣');
        System.debug('║  API Calls        : ' + apiCallCount);
        System.debug('║  Prompt Tokens    : ' + totalPromptTokens);
        System.debug('║  Completion Tokens: ' + totalCompletionTokens);
        System.debug('║  Total Tokens     : ' + totalTokens);
        System.debug('╚══════════════════════════════════════╝');

        // Reset for next request
        apiCallCount          = 0;
        totalPromptTokens     = 0;
        totalCompletionTokens = 0;
        totalTokens           = 0;

        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // FLUSH DML QUEUES
    // Extracted so each exit path can call it at the right moment:
    //   ZIP path  → flush BEFORE enqueue (no callout follows)
    //   Sync path → flush AFTER storeDeploymentStatus callout
    // ─────────────────────────────────────────────────────────────
    private static void flushDmlQueues() {
        if (!FunctionHelper.recordsToInsert.isEmpty()) {
            System.debug('LLMService: inserting ' + FunctionHelper.recordsToInsert.size() + ' queued record(s)');
            insert FunctionHelper.recordsToInsert;
            FunctionHelper.recordsToInsert.clear();
        }
        if (!FunctionHelper.recordsToDelete.isEmpty()) {
            System.debug('LLMService: deleting ' + FunctionHelper.recordsToDelete.size() + ' queued record(s)');
            delete FunctionHelper.recordsToDelete;
            FunctionHelper.recordsToDelete.clear();
        }
        if (!FunctionHelper.permissionSetsToDelete.isEmpty()) {
            for (String psName : FunctionHelper.permissionSetsToDelete) {
                PermissionSetHelper.addDestructiveXml(psName);
            }
            FunctionHelper.permissionSetsToDelete.clear();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // LIGHTWEIGHT ORG CHECK
    // Reads existing fields on objects mentioned in the ticket
    // so XML generation stage knows what already exists
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> runOrgCheck(String summary, String description) {
        Map<String, Object> orgState = new Map<String, Object>();
        Map<String, Object> sharingModels = new Map<String, Object>();
        Map<String, Object> existingFields = new Map<String, Object>();
        List<String> existingObjects = new List<String>();

        try {
            // Check every custom object mentioned or likely involved
            for (Schema.SObjectType objType : Schema.getGlobalDescribe().values()) {
                Schema.DescribeSObjectResult describe = objType.getDescribe();
                if (!describe.isCustom()) continue;

                String apiName = describe.getName();

                // Only check objects relevant to this ticket
                String ticketText = (summary + ' ' + description).toLowerCase();
                String objShortName = apiName.replace('__c', '').replace('_', '').toLowerCase();
                if (!ticketText.contains(objShortName) && !ticketText.contains(apiName.toLowerCase())) continue;

                existingObjects.add(apiName);

                // Get all field names
                List<String> fieldNames = new List<String>();
                Boolean hasMasterDetail = false;

                for (Schema.SObjectField f : describe.fields.getMap().values()) {
                    Schema.DescribeFieldResult fr = f.getDescribe();
                    fieldNames.add(fr.getName());
                    
                    if (fr.isCascadeDelete()) {
                        hasMasterDetail = true;
                        System.debug('runOrgCheck: MasterDetail on [' + apiName + '] field [' + fr.getName() + ']');
                    }
                }

                existingFields.put(apiName, fieldNames);
                sharingModels.put(apiName, hasMasterDetail ? 'ControlledByParent' : 'ReadWrite');
            }

            // ── Standard objects mentioned in the ticket ───────────────────────────
            // The custom-object loop above skips standard objects entirely (isCustom() filter).
            // Without their field metadata the LLM guesses API names and frequently appends
            // __c to standard fields (e.g. AnnualRevenue__c instead of AnnualRevenue).
            Set<String> standardObjectNames = new Set<String>{
                'Account', 'Contact', 'Lead', 'Opportunity', 'Case',
                'Task', 'Event', 'Campaign', 'User', 'Product2',
                'Order', 'Contract', 'Asset', 'Solution', 'Pricebook2',
                'PricebookEntry', 'Quote', 'QuoteLineItem',
                'OpportunityLineItem', 'CampaignMember', 'CaseComment',
                'EmailMessage', 'FeedItem', 'ContentDocument',
                'ContentVersion', 'Attachment', 'Note'
            };

            String ticketTextStd = (summary + ' ' + description).toLowerCase();
            for (String stdObjName : standardObjectNames) {
                if (!ticketTextStd.contains(stdObjName.toLowerCase())) continue;
                try {
                    Schema.SObjectType stdObjType = Schema.getGlobalDescribe().get(stdObjName);
                    if (stdObjType == null) continue;
                    Schema.DescribeSObjectResult stdDescribe = stdObjType.getDescribe();
                    List<String> stdFieldNames = new List<String>();
                    for (Schema.SObjectField f : stdDescribe.fields.getMap().values()) {
                        stdFieldNames.add(f.getDescribe().getName());
                    }
                    // NOT added to existingObjects — avoids triggering the layout-fetch
                    // loop below which would incorrectly generate layout XML for standard objects.
                    existingFields.put(stdObjName, stdFieldNames);
                    System.debug('runOrgCheck: standard object [' + stdObjName + '] — '
                        + stdFieldNames.size() + ' field(s) added to existingFields');
                } catch (Exception e) {
                    System.debug('runOrgCheck: failed to describe standard object ['
                        + stdObjName + '] — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            orgState.put('existingObjects', existingObjects);
            orgState.put('existingFields', existingFields);
            orgState.put('sharingModels', sharingModels);

            // ── Get layout structure for relevant objects ──────────────
            // Always fetch layouts for custom objects already in scope. Adding
            // fields to an existing object implicitly requires the layout XML
            // to be regenerated so the new fields appear on the page layout,
            // even when the ticket text does not mention "layout" or "section".
            if (!existingObjects.isEmpty()) {
                Map<String, List<Map<String, Object>>> layoutsByObject = new Map<String, List<Map<String, Object>>>();

                for (String objName : existingObjects) {
                    try {
                        List<Map<String, Object>> layouts = PageLayoutHelper.listPageLayouts(
                            new Map<String, Object>{ 'objectApiName' => objName }
                        );

                        List<Map<String, Object>> layoutDetails = new List<Map<String, Object>>();
                        for (Map<String, Object> layout : layouts) {
                            String fullName = (String) layout.get('fullName');
                            Map<String, Object> structure = getLayoutStructure(fullName);
                            if (structure != null) {
                                layoutDetails.add(structure);
                            }
                        }

                        if (!layoutDetails.isEmpty()) {
                            layoutsByObject.put(objName, layoutDetails);
                        }
                    } catch (Exception e) {
                        System.debug('runOrgCheck: layout fetch failed for [' + objName + ']: ' + e.getMessage());
                    }
                }

                orgState.put('existingLayouts', layoutsByObject);
            }
            
            // Detect CSV attachments and pre-read them
            if (!StaticResourceHelper.currentAttachments.isEmpty()) {
                List<Map<String, Object>> csvSummaries = new List<Map<String, Object>>();
                
                for (String fileName : StaticResourceHelper.currentAttachments.keySet()) {
                    if (fileName.toLowerCase().endsWith('.csv')) {
                        try {
                            // Read and cache rows — returns only column names + row count
                            Map<String, Object> readResult = CsvProcessor.readCsv(
                                new Map<String, Object>{ 'fileName' => fileName }
                            );
                            csvSummaries.add(new Map<String, Object>{
                                'fileName'  => fileName,
                                'columns'   => readResult.get('columns'),
                                'totalRows' => readResult.get('totalRows')
                            });
                            System.debug('runOrgCheck: pre-read CSV [' + fileName + '] — ' 
                                + readResult.get('totalRows') + ' rows, columns=' + readResult.get('columns'));
                        } catch (Exception e) {
                            System.debug('runOrgCheck: CSV read failed [' + fileName + '] — ' + e.getMessage());
                        }
                    }
                }
                
                if (!csvSummaries.isEmpty()) {
                    orgState.put('csvFiles', csvSummaries);
                }
            }
            String ticketTextLower = (summary + ' ' + description).toLowerCase();
            // ── Fetch existing Queues via pure Apex SOQL ──────────────
            // No LLM tool loop needed — SOQL is fast and free of token cost
            if (ticketTextLower.contains('queue')) {
                try {
                    List<Map<String, Object>> queueList = new List<Map<String, Object>>();

                    for (Group g : [
                        SELECT Id, Name, DeveloperName, Email,
                               DoesSendEmailToMembers
                        FROM Group
                        WHERE Type = 'Queue'
                        ORDER BY Name
                    ]) {
                        List<String> sobjectTypes = new List<String>();
                        for (QueueSobject qs : [
                            SELECT SobjectType FROM QueueSobject WHERE QueueId = :g.Id
                        ]) {
                            sobjectTypes.add(qs.SobjectType);
                        }

                        List<String> members = new List<String>();
                        for (GroupMember gm : [
                            SELECT UserOrGroup.Name
                            FROM GroupMember
                            WHERE GroupId = :g.Id
                        ]) {
                            members.add((String) gm.getSObject('UserOrGroup').get('Name'));
                        }

                        queueList.add(new Map<String, Object>{
                            'developerName'          => g.DeveloperName,
                            'name'                   => g.Name,
                            'email'                  => g.Email,
                            'doesSendEmailToMembers' => g.DoesSendEmailToMembers,
                            'sobjectTypes'           => sobjectTypes,
                            'members'                => members
                        });
                    }

                    if (!queueList.isEmpty()) {
                        orgState.put('existingQueues', queueList);
                        System.debug('runOrgCheck: fetched ' + queueList.size() + ' queue(s)');
                    }

                    
                } catch (Exception e) {
                    System.debug('runOrgCheck: queue fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Public Groups via pure Apex SOQL ───────
            if (ticketTextLower.contains('public group')) {
                try {
                    List<Map<String, Object>> groupList = new List<Map<String, Object>>();

                    for (Group g : [
                        SELECT Id, Name, DeveloperName,
                               DoesIncludeBosses, DoesSendEmailToMembers
                        FROM Group
                        WHERE Type = 'Regular'
                        ORDER BY Name
                    ]) {
                        List<String> members = new List<String>();
                        for (GroupMember gm : [
                            SELECT UserOrGroup.Name
                            FROM GroupMember
                            WHERE GroupId = :g.Id
                        ]) {
                            members.add((String) gm.getSObject('UserOrGroup').get('Name'));
                        }

                        groupList.add(new Map<String, Object>{
                            'developerName'          => g.DeveloperName,
                            'name'                   => g.Name,
                            'doesIncludeBosses'      => g.DoesIncludeBosses,
                            'doesSendEmailToMembers' => g.DoesSendEmailToMembers,
                            'members'                => members
                        });
                    }

                    if (!groupList.isEmpty()) {
                        orgState.put('existingGroups', groupList);
                        System.debug('runOrgCheck: fetched ' + groupList.size() + ' public group(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: public group fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Assignment Rules via Metadata API ──────────
            if (ticketTextLower.contains('assignment rule')) {
                try {
                    List<Map<String, Object>> assignmentRulesState = new List<Map<String, Object>>();

                    // Always check both Lead and Case
                    for (String objType : new List<String>{ 'Lead', 'Case' }) {
                        Map<String, Object> state = getAssignmentRulesState(objType);
                        if (state != null) {
                            assignmentRulesState.add(state);
                        }
                    }

                    if (!assignmentRulesState.isEmpty()) {
                        orgState.put('existingAssignmentRules', assignmentRulesState);
                        System.debug('runOrgCheck: fetched assignment rules state');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: assignment rules fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Named Credentials via Metadata API ─────────
            // Fetched directly in runOrgCheck (not via LLM read stage) so the
            // LLM gets full NC details — protocol, authProvider, oauthScope,
            // username — without needing a separate tool-calling loop.
            // Note: password is NEVER returned by any API (stored encrypted).
            if (ticketTextLower.contains('named credential')) {
                try {
                    List<Map<String, Object>> ncState = getNamedCredentialsState();
                    if (ncState != null && !ncState.isEmpty()) {
                        orgState.put('existingNamedCredentials', ncState);
                        System.debug('runOrgCheck: fetched ' + ncState.size() + ' named credential(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: named credentials fetch failed — ' + e.getMessage());
                    //ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Auth Providers via SOQL ────────────────────────
            // Fetched directly in runOrgCheck() (same pattern as Named Credentials)
            // so the LLM gets full AP details without a separate tool-calling loop.
            // Note: consumerSecret is NEVER returned by any API (stored encrypted).
            if (ticketTextLower.contains('auth provider')
                || ticketTextLower.contains('authentication provider')
                || ticketTextLower.contains('authprovider')) {
                try {
                    List<Map<String, Object>> apState = getAuthProvidersState();
                    if (apState != null && !apState.isEmpty()) {
                        orgState.put('existingAuthProviders', apState);
                        System.debug('runOrgCheck: fetched ' + apState.size() + ' auth provider(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: auth providers fetch failed — ' + e.getMessage());
                }
            }

            // ── Fetch layout names for standard objects mentioned in record-type tickets ──
            // Stored under "standardObjectLayoutNames" (NOT "existingLayouts") so the
            // LLM gets the correct fullName (e.g. "Account-Account Layout") without
            // triggering the Scenario B / MANDATORY PRE-FLIGHT rule, which would force
            // it to generate a Layout XML file for a standard object — something that
            // must NEVER happen (standard layouts already exist in every org).
            if (ticketTextLower.contains('record type')) {
                Set<String> stdObjects = new Set<String>{
                    'Account', 'Case', 'Contact', 'Lead', 'Opportunity',
                    'Task', 'Event', 'Campaign', 'Order', 'Contract',
                    'Asset', 'Solution', 'Product2', 'Pricebook2'
                };
                Map<String, Object> stdLayoutNames = new Map<String, Object>();
                for (String stdObj : stdObjects) {
                    if (!ticketTextLower.contains(stdObj.toLowerCase())) continue;
                    try {
                        List<Map<String, Object>> layouts = PageLayoutHelper.listPageLayouts(
                            new Map<String, Object>{ 'objectApiName' => stdObj }
                        );
                        List<String> fullNames = new List<String>();
                        for (Map<String, Object> layout : layouts) {
                            String fn = (String) layout.get('fullName');
                            if (String.isNotBlank(fn)) fullNames.add(fn);
                        }
                        if (!fullNames.isEmpty()) {
                            stdLayoutNames.put(stdObj, fullNames);
                            System.debug('runOrgCheck: standardObjectLayoutNames['
                                + stdObj + '] = ' + fullNames);
                        }
                    } catch (Exception e) {
                        System.debug('runOrgCheck: layout fetch failed for std obj ['
                            + stdObj + ']: ' + e.getMessage());
                    }
                }
                if (!stdLayoutNames.isEmpty()) {
                    orgState.put('standardObjectLayoutNames', stdLayoutNames);
                }
            }

            // ── Fetch existing Business Processes ────────────────────────────────
            // Case, Lead, Opportunity and Solution record types REQUIRE a
            // <businessProcess> element. Without it Salesforce rejects with:
            //   "Required field is missing: businessProcess"
            if (ticketTextLower.contains('record type')) {
                Set<String> processDrivenObjects = new Set<String>{ 'case', 'lead', 'opportunity', 'solution' };
                Boolean mentionsProcessObject = false;
                for (String pObj : processDrivenObjects) {
                    if (ticketTextLower.contains(pObj)) { mentionsProcessObject = true; break; }
                }
                if (mentionsProcessObject) {
                    try {
                        Map<String, List<String>> bpByObject = new Map<String, List<String>>();
                        for (BusinessProcess bp : [
                            SELECT Id, Name, TableEnumOrId, IsActive
                            FROM BusinessProcess
                            WHERE IsActive = true
                            ORDER BY TableEnumOrId, Name
                        ]) {
                            String objKey = bp.TableEnumOrId;
                            if (!bpByObject.containsKey(objKey)) {
                                bpByObject.put(objKey, new List<String>());
                            }
                            bpByObject.get(objKey).add(bp.Name);
                        }
                        if (!bpByObject.isEmpty()) {
                            orgState.put('existingBusinessProcesses', bpByObject);
                            System.debug('runOrgCheck: existingBusinessProcesses = '
                                + JSON.serialize(bpByObject));
                        } else {
                            System.debug('runOrgCheck: no active Business Processes found in org');
                        }
                    } catch (Exception e) {
                        System.debug('runOrgCheck: business process fetch failed — ' + e.getMessage());
                    }
                }
            }

            // ── Fetch existing Record Types via SOQL ──────────────────────
            if (ticketTextLower.contains('record type')) {
                try {
                    List<Map<String, Object>> rtList = new List<Map<String, Object>>();

                    for (RecordType rt : [
                        SELECT Id, Name, DeveloperName, SobjectType,
                            IsActive, Description
                        FROM RecordType
                        WHERE NamespacePrefix = null
                        ORDER BY SobjectType, DeveloperName
                    ]) {
                        rtList.add(new Map<String, Object>{
                            'developerName' => rt.DeveloperName,
                            'label'         => rt.Name,
                            'sobjectType'   => rt.SobjectType,
                            'isActive'      => rt.IsActive,
                            'description'   => rt.Description
                        });
                    }

                    if (!rtList.isEmpty()) {
                        orgState.put('existingRecordTypes', rtList);
                        System.debug('runOrgCheck: fetched ' + rtList.size() + ' record type(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: record type fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Apex Trigger + Handler class ───────────────
            // Covers: trigger create, trigger update, add/remove trigger events.
            // Uses the same direct Tooling API path as MetadataHelper —
            // NO LLM tool-calling loop. Result goes into orgState so the
            // XML generation stage knows whether to MERGE or CREATE FRESH.
            //
            // Object detection: we look for common standard objects and any
            // custom object (__c) mentioned in the ticket text.
            if (ticketTextLower.contains('trigger')) {
                try {
                    // Detect which object the ticket is targeting
                    // Check standard objects first
                    List<String> candidateObjects = new List<String>();
                    Set<String> stdTriggerObjects = new Set<String>{
                        'Account', 'Contact', 'Lead', 'Opportunity', 'Case',
                        'Task', 'Event', 'Campaign', 'Order', 'Contract',
                        'Asset', 'Product2', 'Quote', 'Pricebook2'
                    };
                    for (String stdObj : stdTriggerObjects) {
                        if (ticketTextLower.contains(stdObj.toLowerCase())) {
                            candidateObjects.add(stdObj);
                        }
                    }
                    // Check custom objects (__c) already found in org
                    List<Object> existingObjs = (List<Object>) orgState.get('existingObjects');
                    if (existingObjs != null) {
                        for (Object o : existingObjs) {
                            String objName = String.valueOf(o);
                            String shortName = objName.replace('__c', '').replace('_', ' ').toLowerCase();
                            if (ticketTextLower.contains(shortName) || ticketTextLower.contains(objName.toLowerCase())) {
                                candidateObjects.add(objName);
                            }
                        }
                    }

                    if (!candidateObjects.isEmpty()) {
                        // Use first matched object (most specific match wins)
                        String targetObject = candidateObjects[0];
                        System.debug('runOrgCheck: checking apex trigger on object [' + targetObject + ']');

                        Map<String, Object> triggerState = getApexTriggerState(targetObject);

                        if (triggerState != null) {
                            // Restructure into existingTrigger + existingHandlerClass
                            // keys the LLM system prompt expects
                            orgState.put('existingTrigger', new Map<String, Object>{
                                'name' => triggerState.get('name'),
                                'body' => triggerState.get('body')
                            });

                            if (triggerState.containsKey('handlerName')) {
                                orgState.put('existingHandlerClass', new Map<String, Object>{
                                    'name' => triggerState.get('handlerName'),
                                    'body' => triggerState.get('handlerBody')
                                });
                            } else {
                                orgState.put('existingHandlerClass', null);
                            }

                            System.debug('runOrgCheck: existingTrigger = [' + triggerState.get('name') + ']');
                        } else {
                            orgState.put('existingTrigger', null);
                            orgState.put('existingHandlerClass', null);
                            System.debug('runOrgCheck: no existing trigger found on [' + targetObject + ']');
                        }
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: trigger state fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Apex Class body ────────────────────────────────
            // Covers: create class, update class, add method to class, delete class.
            // Extracts the class name from the ticket text by looking for known
            // patterns like "class MyClassName" or "MyClassName class".
            // Result goes into orgState.existingClass for the generation stage.
            if (ticketTextLower.contains('class') && !ticketTextLower.contains('trigger')) {
                try {
                    // Simple class name extraction — look for PascalCase words near "class" keyword
                    // Pattern: word boundary, uppercase letter, followed by alphanumeric
                    String combined = summary + ' ' + description;
                    Pattern clsPat = Pattern.compile('(?i)class\\s+([A-Z][A-Za-z0-9_]+)');
                    Matcher clsMatch = clsPat.matcher(combined);
                    String detectedClassName = null;
                    if (clsMatch.find()) {
                        detectedClassName = clsMatch.group(1);
                    }

                    if (String.isNotBlank(detectedClassName)) {
                        System.debug('runOrgCheck: detected class name [' + detectedClassName + '] — fetching from org');
                        Map<String, Object> classState = getApexClassState(detectedClassName);
                        orgState.put('existingClass', classState); // null if not found
                        System.debug('runOrgCheck: existingClass = ' + (classState != null ? classState.get('name') : 'null'));
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: class state fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing LWC component ─────────────────────────────────
            // Covers: create LWC, update LWC, add property/method to existing LWC.
            // Keywords: "lwc", "lightning web component", "lightning component"
            // Note: "component" alone is too broad and is intentionally excluded.
            if (ticketTextLower.contains('lwc')
                    || ticketTextLower.contains('lightning web component')
                    || ticketTextLower.contains('lightning component')) {
                try {
                    String detectedComponentName = extractLwcComponentName(summary + ' ' + description);

                    if (String.isNotBlank(detectedComponentName)) {
                        System.debug('runOrgCheck: detected LWC name [' + detectedComponentName + '] — fetching from org');
                        Map<String, Object> componentState = getLwcComponentState(detectedComponentName);
                        orgState.put('existingLwcComponent', componentState); // null = create mode
                        System.debug('runOrgCheck: existingLwcComponent = '
                            + (componentState != null ? componentState.get('developerName') : 'null (create mode)'));
                    } else {
                        System.debug('runOrgCheck: no LWC component name found in ticket — create mode assumed');
                        orgState.put('existingLwcComponent', null);
                    }

                    // ── Also detect Apex controller referenced by this LWC ──────────
                    // LWC tickets say "use AccountController" or "calls InvoiceService"
                    // without the word "class" — the existing class-detection block
                    // (which fires only on "class") would miss these.
                    String combined = summary + ' ' + description;
                    Pattern controllerPat = Pattern.compile(
                        '([A-Z][A-Za-z0-9_]+(?:Controller|Service|Handler|Helper))'
                    );
                    Matcher controllerMatch = controllerPat.matcher(combined);
                    String detectedControllerName = null;
                    while (controllerMatch.find()) {
                        String candidate = controllerMatch.group(1);
                        // Exclude known Salesforce built-in names
                        Set<String> sfBuiltInControllers = new Set<String>{
                            'LightningController', 'StandardController', 'ApexPages'
                        };
                        if (!sfBuiltInControllers.contains(candidate)) {
                            detectedControllerName = candidate;
                            break;
                        }
                    }

                    if (String.isNotBlank(detectedControllerName)) {
                        System.debug('runOrgCheck: detected LWC Apex controller [' + detectedControllerName + '] — fetching from org');
                        Map<String, Object> controllerState = getApexClassState(detectedControllerName);
                        // null = controller does not exist yet; LLM will generate it fresh
                        orgState.put('existingLwcApexController', controllerState);
                        System.debug('runOrgCheck: existingLwcApexController = '
                            + (controllerState != null ? controllerState.get('name') : 'null (will be created)'));
                    }

                } catch (Exception e) {
                    System.debug('runOrgCheck: LWC state fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch existing Custom Labels ─────────────────────────────────
            // Covers: custom label create, update, delete, translate.
            // Uses Tooling API directly — no LLM tool loop needed.
            if (ticketTextLower.contains('custom label') || ticketTextLower.contains('update label')
                    || ticketTextLower.contains('label')) {
                try {
                    Map<String, Object> labelResult = MetadataHelper.runToolingApiQuery(
                        'SELECT Id, Name, Value, Language, MasterLabel, Category FROM ExternalString WHERE NamespacePrefix = null ORDER BY Name'
                    );
                    List<Object> labelRecords = (List<Object>) labelResult.get('records');
                    if (labelRecords != null && !labelRecords.isEmpty()) {
                        List<Map<String, Object>> labelList = new List<Map<String, Object>>();
                        for (Object raw : labelRecords) {
                            Map<String, Object> rec = (Map<String, Object>) raw;
                            labelList.add(new Map<String, Object>{
                                'name'        => rec.get('Name'),
                                'masterLabel' => rec.get('MasterLabel'),
                                'value'       => rec.get('Value'),
                                'language'    => rec.get('Language'),
                                'category'    => rec.get('Category')
                            });
                        }
                        orgState.put('existingCustomLabels', labelList);
                        System.debug('runOrgCheck: fetched ' + labelList.size() + ' custom label(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: custom labels fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch Apex Class names ────────────────────────────────────────
            // Covers: permission set / profile class access grants.
            if (ticketTextLower.contains('class access') || ticketTextLower.contains('apex class')
                    || ticketTextLower.contains('apex classes')) {
                try {
                    Map<String, Object> classResult = MetadataHelper.runToolingApiQuery(
                        'SELECT Name FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name'
                    );
                    List<Object> classRecords = (List<Object>) classResult.get('records');
                    if (classRecords != null && !classRecords.isEmpty()) {
                        List<String> classList = new List<String>();
                        for (Object raw : classRecords) {
                            Map<String, Object> rec = (Map<String, Object>) raw;
                            classList.add((String) rec.get('Name'));
                        }
                        orgState.put('apexClasses', classList);
                        System.debug('runOrgCheck: fetched ' + classList.size() + ' Apex class(es)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: Apex classes fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

            // ── Fetch Visualforce Page names ──────────────────────────────────
            // Covers: permission set / profile VF page access grants.
            if (ticketTextLower.contains('visualforce') || ticketTextLower.contains('page access')) {
                try {
                    Map<String, Object> pageResult = MetadataHelper.runToolingApiQuery(
                        'SELECT Name FROM ApexPage WHERE NamespacePrefix = null ORDER BY Name'
                    );
                    List<Object> pageRecords = (List<Object>) pageResult.get('records');
                    if (pageRecords != null && !pageRecords.isEmpty()) {
                        List<String> pageList = new List<String>();
                        for (Object raw : pageRecords) {
                            Map<String, Object> rec = (Map<String, Object>) raw;
                            pageList.add((String) rec.get('Name'));
                        }
                        orgState.put('visualforcePages', pageList);
                        System.debug('runOrgCheck: fetched ' + pageList.size() + ' Visualforce page(s)');
                    }
                } catch (Exception e) {
                    System.debug('runOrgCheck: Visualforce pages fetch failed — ' + e.getMessage());
                    ErrorLogger.log(e);
                }
            }

        } catch (Exception e) {
            System.debug('runOrgCheck failed: ' + e.getMessage());
            ErrorLogger.log(e);
        }

        return orgState;
    }

    // ─────────────────────────────────────────────────────────────
    // GET LAYOUT STRUCTURE FOR ORG STATE
    // Retrieves existing layout sections + fields so LLM can
    // regenerate the full XML when modifying an existing layout
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getLayoutStructure(String fullName) {
        try {
            List<Metadata.Metadata> retrieved = Metadata.Operations.retrieve(
                Metadata.MetadataType.Layout,
                new List<String>{ fullName }
            );

            if (retrieved == null || retrieved.isEmpty() || retrieved[0] == null) {
                return null;
            }

            Metadata.Layout layout = (Metadata.Layout) retrieved[0];
            List<Map<String, Object>> sections = new List<Map<String, Object>>();

            if (layout.layoutSections != null) {
                for (Metadata.LayoutSection section : layout.layoutSections) {
                    // Flatten columns back to an ordered field list
                    // Fields go: left[0], right[0], left[1], right[1]...
                    // so we interleave them to preserve the original left/right distribution
                    List<String> leftFields     = new List<String>();
                    List<String> leftBehaviors  = new List<String>();
                    List<String> rightFields    = new List<String>();
                    List<String> rightBehaviors = new List<String>();

                    if (section.layoutColumns != null && section.layoutColumns.size() > 0) {
                        Metadata.LayoutColumn leftCol = section.layoutColumns[0];
                        if (leftCol.layoutItems != null) {
                            for (Metadata.LayoutItem item : leftCol.layoutItems) {
                                if (String.isNotBlank(item.field)) {
                                    leftFields.add(item.field);
                                    leftBehaviors.add(behaviorToString(item.behavior));
                                }
                            }
                        }
                    }
                    if (section.layoutColumns != null && section.layoutColumns.size() > 1) {
                        Metadata.LayoutColumn rightCol = section.layoutColumns[1];
                        if (rightCol.layoutItems != null) {
                            for (Metadata.LayoutItem item : rightCol.layoutItems) {
                                if (String.isNotBlank(item.field)) {
                                    rightFields.add(item.field);
                                    rightBehaviors.add(behaviorToString(item.behavior));
                                }
                            }
                        }
                    }

                    // Skip non-field sections (Custom Links, Mobile Cards, related-list
                    // placeholders, etc.). These contain <customLinks> / mobile-card items
                    // — NOT <field> items — so there is no valid way for the LLM to re-emit
                    // them. Including them in org state causes the LLM to output empty
                    // <layoutItems><behavior></behavior><field></field></layoutItems> blocks
                    // which the Metadata API rejects with:
                    //   "'' is not a valid value for the enum 'UiBehavior'".
                    if (leftFields.isEmpty() && rightFields.isEmpty()) {
                        System.debug('getLayoutStructure: skipping non-field section ['
                            + section.label + '] in layout [' + fullName + ']');
                        continue;
                    }

                    sections.add(new Map<String, Object>{
                        'label'          => section.label,
                        'leftFields'     => leftFields,
                        'leftBehaviors'  => leftBehaviors,
                        'rightFields'    => rightFields,
                        'rightBehaviors' => rightBehaviors
                    });
                }
            }

            return new Map<String, Object>{
                'fullName' => fullName,
                'sections' => sections
            };

        } catch (Exception e) {
            System.debug('getLayoutStructure failed for [' + fullName + ']: ' + e.getMessage());
            return null;
        }
    }

    // Maps a Metadata.UiBehavior enum to the XML string used in Layout files.
    // Used by getLayoutStructure so org state carries the existing behavior of
    // every layout item — the LLM can then re-emit the layout with the SAME
    // behavior and avoid errors like "Field:Name must be Readonly" on objects
    // whose Name field is AutoNumber.
    private static String behaviorToString(Metadata.UiBehavior b) {
        if (b == null) return 'Edit';
        if (b == Metadata.UiBehavior.Required) return 'Required';
        if (b == Metadata.UiBehavior.Readonly) return 'Readonly';
        return 'Edit';
    }


    // ─────────────────────────────────────────────────────────────
    // GET ASSIGNMENT RULES STATE
    // Reads full AssignmentRules metadata for Lead or Case via the
    // SOAP Metadata API (same proven pattern as ProfileHelper).
    // Returns rule + entry + criteria detail so the LLM can
    // regenerate the complete file on update or delete.
    //
    // Replaces three broken Tooling API methods that failed because
    // AssignmentRuleEntry and AssignmentRuleFilter do not exist as
    // queryable Tooling API objects.
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getAssignmentRulesState(String objectType) {
        try {
            MetadataService.IReadResult readResult = metaPort.readMetadata(
                'AssignmentRules', new String[]{ objectType }
            );
            MetadataService.Metadata[] records = readResult.getRecords();

            if (records == null || records.isEmpty() || records[0] == null) {
                System.debug('getAssignmentRulesState: no AssignmentRules found for [' + objectType + ']');
                return null;
            }

            MetadataService.AssignmentRules rules = (MetadataService.AssignmentRules) records[0];
            List<Map<String, Object>> ruleList = new List<Map<String, Object>>();

            if (rules.assignmentRule != null) {
                for (MetadataService.AssignmentRule rule : rules.assignmentRule) {
                    List<Map<String, Object>> entries = new List<Map<String, Object>>();

                    if (rule.ruleEntry != null) {
                        for (MetadataService.RuleEntry entry : rule.ruleEntry) {
                            List<Map<String, Object>> criteriaList = new List<Map<String, Object>>();

                            if (entry.criteriaItems != null) {
                                for (MetadataService.FilterItem item : entry.criteriaItems) {
                                    criteriaList.add(new Map<String, Object>{
                                        'field'     => item.field,
                                        'operation' => item.operation,
                                        'value'     => item.value
                                    });
                                }
                            }

                            entries.add(new Map<String, Object>{
                                'assignedTo'     => entry.assignedTo,
                                'assignedToType' => entry.assignedToType,
                                'formula'        => entry.formula,
                                'criteriaItems'  => criteriaList
                            });
                        }
                    }

                    ruleList.add(new Map<String, Object>{
                        'fullName'    => rule.fullName,
                        'active'      => rule.active,
                        'ruleEntries' => entries
                    });
                }
            }

            if (ruleList.isEmpty()) return null;

            System.debug('getAssignmentRulesState: found ' + ruleList.size() + ' rule(s) for [' + objectType + ']');
            return new Map<String, Object>{
                'objectType' => objectType,
                'rules'      => ruleList
            };

        } catch (Exception e) {
            System.debug('getAssignmentRulesState failed for [' + objectType + ']: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }


    // ─────────────────────────────────────────────────────────────
    // GET NAMED CREDENTIALS STATE
    // Reads all Named Credentials via:
    //   Step 1 — SOQL on NamedCredential to get DeveloperNames
    //   Step 2 — MetadataService.readMetadata() to get full details
    //            (protocol, authProvider, oauthScope, username etc.)
    //
    // Called directly from runOrgCheck() — no LLM tool loop needed.
    // password is NEVER returned by any Salesforce API (stored encrypted).
    // For Password NC updates the ticket MUST supply the password.
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getNamedCredentialsState() {
        try {
            // Step 1 — get DeveloperNames via SOQL (fast, no callout)
            List<String> names = new List<String>();
            for (NamedCredential nc : [
                SELECT DeveloperName FROM NamedCredential ORDER BY DeveloperName
            ]) {
                names.add(nc.DeveloperName);
            }

            if (names.isEmpty()) {
                System.debug('getNamedCredentialsState: no Named Credentials found in org');
                return null;
            }

            System.debug('getNamedCredentialsState: reading ' + names.size() + ' NC(s) via readMetadata: ' + names);

            // Step 2 — read full metadata via SOAP (same pattern as getAssignmentRulesState)
            MetadataService.IReadResult readResult = metaPort.readMetadata(
                'NamedCredential', names
            );
            MetadataService.Metadata[] records = readResult.getRecords();

            if (records == null || records.isEmpty()) {
                System.debug('getNamedCredentialsState: readMetadata returned no records');
                return null;
            }

            List<Map<String, Object>> result = new List<Map<String, Object>>();

            for (MetadataService.Metadata raw : records) {
                if (raw == null) continue;
                MetadataService.NamedCredential nc = (MetadataService.NamedCredential) raw;

                // Build map with fields guaranteed to be in MetadataService stub
                // calloutStatus is always Enabled — not exposed as a field in the stub
                Map<String, Object> ncMap = new Map<String, Object>{
                    'apiName'                     => nc.fullName,
                    'label'                       => nc.label,
                    'endpoint'                    => nc.endpoint,
                    'protocol'                    => nc.protocol,
                    'principalType'               => nc.principalType,
                    'calloutStatus'               => 'Enabled',
                    'generateAuthorizationHeader' => nc.generateAuthorizationHeader,
                    'allowMergeFieldsInBody'      => nc.allowMergeFieldsInBody,
                    'allowMergeFieldsInHeader'    => nc.allowMergeFieldsInHeader
                };

                // OAuth 2.0 specific — only populated when protocol = Oauth
                try { if (nc.authProvider != null) ncMap.put('authProvider', nc.authProvider); } catch (Exception ex) {}
                try { if (nc.oauthScope   != null) ncMap.put('oauthScope',   nc.oauthScope);   } catch (Exception ex) {}

                // Password specific — username returned, password NEVER returned by any API
                try { if (nc.username != null) ncMap.put('username', nc.username); } catch (Exception ex) {}

                result.add(ncMap);
                System.debug('getNamedCredentialsState: read NC [' + nc.fullName
                    + '] protocol=[' + nc.protocol + ']');
            }

            System.debug('getNamedCredentialsState: returning ' + result.size() + ' NC(s)');
            return result;

        } catch (Exception e) {
            System.debug('getNamedCredentialsState failed: ' + e.getMessage());
            //ErrorLogger.log(e);
            return null;
        }
    }


    // ─────────────────────────────────────────────────────────────
    // STAGE 1.5 — PROMPT ROUTER
    // Calls a lightweight LLM to classify the ticket and select
    // relevant prompt sections. Returns the assembled system prompt.
    // ─────────────────────────────────────────────────────────────
    private static String runRouterStage(String summary, String description) {
        try {
            String routerSystemPrompt = PromptService.getRouterSystemPrompt();
            List<String> availableKeys = PromptService.getRoutableFeatureKeys();

            String userMsg = 'Available feature keys: ' + JSON.serialize(availableKeys)
                + '\n\nTicket Summary: ' + summary
                + '\nTicket Description: ' + (String.isBlank(description) ? '(none)' : description)
                + '\n\nReturn ONLY a JSON array of the relevant feature keys from the list above.';

            System.debug('[ROUTER] Available keys count: ' + availableKeys.size());
            System.debug('[ROUTER] Calling Groq for feature classification...');

            List<Map<String, Object>> routerMessages = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'system', 'content' => routerSystemPrompt },
                new Map<String, Object>{ 'role' => 'user',   'content' => userMsg }
            };

            Map<String, Object> routerResponse = callGroq(
                routerMessages, new List<Map<String, Object>>(), null
            );
            if (routerResponse == null || !routerResponse.containsKey('choices')) {
                System.debug('[ROUTER] ERROR — callGroq returned null or missing choices. ' +
                    'Response: ' + routerResponse);
                return buildXmlGenerationSystemPrompt();
            }

            List<Object>        routerChoices  = (List<Object>) routerResponse.get('choices');
            Map<String, Object> routerChoice   = (Map<String, Object>) routerChoices[0];
            Map<String, Object> routerMessage  = (Map<String, Object>) routerChoice.get('message');
            String              routerContent  = cleanJsonResponse((String) routerMessage.get('content'));

            System.debug('[ROUTER] Raw response: ' + routerContent);

            Set<String> selectedKeys = new Set<String>();
            List<Object> keyList = (List<Object>) JSON.deserializeUntyped(routerContent);
            for (Object k : keyList) {
                selectedKeys.add((String) k);
            }

            System.debug('[ROUTER] Selected keys (' + selectedKeys.size() + '): ' + selectedKeys);
            return PromptService.assemblePrompt(selectedKeys);

        } catch (Exception ex) {
            System.debug('[ROUTER] ERROR — ' + ex.getTypeName() + ': ' + ex.getMessage());
            System.debug('[ROUTER] Stack trace: ' + ex.getStackTraceString());
            System.debug('[ROUTER] Falling back to full prompt (all CMT sections).');
            return buildXmlGenerationSystemPrompt();
        }
    }

    private static String runXmlGenerationStage(
        String issueKey,
        String summary,
        String description,
        Map<String, Object> orgState,
        String systemPrompt
    ) {
        List<Map<String, Object>> messages = new List<Map<String, Object>>{
            new Map<String, Object>{
                'role'    => 'system',
                'content' => systemPrompt
            },
            new Map<String, Object>{
                'role'    => 'user',
                'content' => buildXmlGenerationUserPrompt(issueKey, summary, description, orgState)
            }
        };

        // Single call — no tools, pure XML generation
        Map<String, Object> response = callGroq(messages, new List<Map<String, Object>>(), null);
        List<Object> choices         = (List<Object>) response.get('choices');
        Map<String, Object> choice   = (Map<String, Object>) choices[0];
        Map<String, Object> message  = (Map<String, Object>) choice.get('message');
        String content               = (String) message.get('content');

        // ADD THIS — see raw LLM output
        System.debug('=== RAW LLM XML RESPONSE START ===');
        System.debug(content);
        System.debug('=== RAW LLM XML RESPONSE END ===');

        System.debug('── STAGE 2 raw LLM response: ' + content);

        // Parse and process the XML generation response
        return processXmlGenerationResponse(content, issueKey, orgState);
    }

    // ─────────────────────────────────────────────────────────────
    // PROCESS XML GENERATION RESPONSE
    // Parses LLM JSON response, validates XML, feeds to ZipBuilder
    // ─────────────────────────────────────────────────────────────
    private static String processXmlGenerationResponse(
        String llmResponse,
        String issueKey,
        Map<String, Object> orgState
    ) {

        String cleaned = cleanJsonResponse(llmResponse);

        // ADD THIS — see the full cleaned response
        System.debug('=== XML GENERATION RESPONSE START ===');
        System.debug(cleaned);
        System.debug('=== XML GENERATION RESPONSE END ===');

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
        } catch (Exception e) {
            System.debug('processXmlGenerationResponse: JSON parse failed: ' + e.getMessage());
            ErrorLogger.log(e);
            FunctionHelper.hadError = true;
            return 'Error: LLM returned invalid JSON. Raw response: ' + llmResponse;
        }

        // Run clone DML operations first so files[] can layer updates on top of cloned XML.
        List<Object> dmlOps = (List<Object>) parsed.get('dmlOperations');
        List<Object> cloneOps = new List<Object>();
        List<Object> nonCloneOps = new List<Object>();
        if (dmlOps != null && !dmlOps.isEmpty()) {
            for (Object rawOp : dmlOps) {
                Map<String, Object> op = (Map<String, Object>) rawOp;
                String opType = (String) op.get('type');
                if (opType == 'permissionSetClone' || opType == 'profileClone') {
                    cloneOps.add(rawOp);
                } else {
                    nonCloneOps.add(rawOp);
                }
            }
        }
        if (!cloneOps.isEmpty()) {
            System.debug('processXmlGenerationResponse: processing '
                + cloneOps.size() + ' clone DML operation(s) first');
            processDmlOperations(cloneOps);
        }

        // ── Read deployment plan — determines single vs chained deploy ──
        Map<String, Object> deploymentPlan = (Map<String, Object>) parsed.get('deploymentPlan');
        String deployScenario = (deploymentPlan != null && deploymentPlan.get('scenario') != null)
            ? (String) deploymentPlan.get('scenario') : 'single';
        Set<String> zip2FilePaths = new Set<String>();
        if (deployScenario == 'chained' && deploymentPlan != null) {
            List<Object> zip2List = (List<Object>) deploymentPlan.get('zip2Files');
            if (zip2List != null) {
                for (Object p : zip2List) { zip2FilePaths.add((String) p); }
            }
        }
        System.debug('processXmlGenerationResponse: deployScenario=' + deployScenario
            + ', zip2FilePaths=' + zip2FilePaths);
        System.debug('[DEPLOY-TRACE] LLM picked scenario=' + deployScenario
            + ' | zip2FilePaths=' + zip2FilePaths
            + ' | rawDeploymentPlan=' + JSON.serialize(deploymentPlan));


        if (deployScenario == 'chained') {
            Boolean hasNewCustomObject = false;
            Set<String> existingObjs = new Set<String>();
            if (orgState != null && orgState.get('existingObjects') instanceof List<Object>) {
                for (Object o : (List<Object>) orgState.get('existingObjects')) {
                    existingObjs.add(String.valueOf(o));
                }
            }
            List<Object> filesCheck = (List<Object>) parsed.get('files');
            if (filesCheck != null) {
                for (Object rawFile : filesCheck) {
                    Map<String, Object> f = (Map<String, Object>) rawFile;
                    String mt = (String) f.get('metadataType');
                    String mn = (String) f.get('memberName');
                    if (mt == 'CustomObject' && !existingObjs.contains(mn)) {
                        hasNewCustomObject = true;
                        break;
                    }
                }
            }
            if (!hasNewCustomObject) {
                System.debug('[DEPLOY-TRACE] *** SCENARIO OVERRIDE *** LLM chose chained but no new CustomObject — forcing single');
                deployScenario = 'single';
                zip2FilePaths.clear();
            }
        }

        Map<String, String>       zip2Files         = new Map<String, String>();
        Map<String, Set<String>>  zip2MetadataTypes = new Map<String, Set<String>>();

        // ── Process regular files ──────────────────────
        List<Object> files = (List<Object>) parsed.get('files');

        // ── Trigger merge enforcer ─────────────────────────────────────────────────
        // Must run BEFORE the files loop so that when a trigger/handler already
        // exists in the org, the LLM-generated code is merged (not replaced) before
        // it reaches ZipBuilder.
        enforceTriggerMerge(files, orgState);

        // ── Scenario B violation detector ────────────────────────────────────────────
        // If the LLM is emitting a CustomObject/CustomField on an existing object that
        // has layouts in orgState.existingLayouts, files[] MUST also contain a Layout entry
        // for that object. Detect violation up-front and log a loud trace marker.
        detectScenarioBViolation(files, orgState);

        if (files != null && !files.isEmpty()) {
            System.debug('processXmlGenerationResponse: processing ' + files.size() + ' file(s)');

            for (Object rawFile : files) {
                Map<String, Object> file = (Map<String, Object>) rawFile;

                String metadataType = (String) file.get('metadataType');
                String memberName   = (String) file.get('memberName');
                String filePath     = (String) file.get('filePath');
                String xmlContent   = (String) file.get('xmlContent');

                System.debug('processXmlGenerationResponse: processing file ['
                    + filePath + '] type=[' + metadataType + ']');

                // Auto-add required parent-object Read permissions for Permission Set XML
                // to avoid deploy failures on lookup/master-detail dependencies.
                if (metadataType == 'PermissionSet') {
                    xmlContent = PermissionSetHelper.ensureParentReadAccessForXml(xmlContent);
                
                }

                // Rewrite <relationshipName> for every Lookup/MasterDetail field in a CustomObject
                // so names never collide with orphans left by prior partial deploys.
                if (metadataType == 'CustomObject') {
                    String sourceObj = extractSourceObjectFromObjectPath(filePath);
                    xmlContent = rewriteRelationshipNamesInCustomObjectXml(xmlContent, sourceObj);
                }

                // Strip broken <layoutItems> blocks (empty <field>/<behavior>) from any
                // Layout XML. Protects both Scenario A (new object + new layout) and
                // Scenario B (existing object + field + regenerated layout).
                if (metadataType == 'Layout') {
                    xmlContent = sanitizeLayoutXml(xmlContent);
                }

                // Strip non-en_US <labels> blocks from CustomLabels XML and auto-redirect
                // them to translations/{language}.translation so a translation-only ticket
                // never causes "Duplicate name" errors from the Metadata API.
                if (metadataType == 'CustomLabel' || metadataType == 'CustomLabels') {
                    xmlContent = sanitizeCustomLabelsXml(xmlContent);
                }

                // Normalize language codes for Translations files (fr_FR -> fr, de_DE -> de).
                // Salesforce rejects locale variants like fr_FR with
                // "bad value for restricted picklist field".
                if (metadataType == 'Translations' && String.isNotBlank(memberName)) {
                    String normalizedLang = normalizeTranslationLanguageCode(memberName);
                    if (normalizedLang != memberName) {
                        System.debug('[DEPLOY-TRACE] Translations: normalizing lang ['
                            + memberName + '] -> [' + normalizedLang + ']');
                        filePath   = 'translations/' + normalizedLang + '.translation';
                        memberName = normalizedLang;
                    }
                }

                // ── Skip CustomTab for standard objects ───────────────────
                // Standard objects (Account, Case etc.) have built-in tabs.
                // Generating a CustomTab for them causes:
                //   "Master label must be provided for non-custom object tabs"
                //   "no CustomTab named Account found" (in Profile tabVisibilities)
                if (metadataType == 'CustomTab' && !memberName.endsWith('__c')) {
                    System.debug('[DEPLOY-TRACE] skipping CustomTab for standard object ['
                        + memberName + '] — standard objects have built-in tabs');
                    continue;
                }

                // ── Sanitize CustomObject XML for standard objects ─────────
                // Standard objects forbid <nameField>, <pluralLabel>,
                // <deploymentStatus>, <sharingModel> in their XML.
                // These cause: "Cannot specify a name field for a standard object"
                if (metadataType == 'CustomObject'
                        && !memberName.endsWith('__c')
                        && !memberName.endsWith('__mdt')) {
                    xmlContent = sanitizeStandardObjectXml(xmlContent);
                    System.debug('[DEPLOY-TRACE] sanitizeStandardObjectXml applied to ['
                        + filePath + ']');
                    // Auto-inject <businessProcess> for Case/Lead/Opportunity/Solution
                    xmlContent = injectBusinessProcessIfMissing(xmlContent, memberName, orgState);
                }

                // ── Sanitize CustomObject XML for __mdt objects ────────────
                // The LLM occasionally includes <customSettingsType> or
                // <customMetadataType> in __mdt XML — both are illegal.
                // Strip them silently instead of hard-failing.
                if (metadataType == 'CustomObject' && memberName != null
                        && memberName.endsWith('__mdt')) {
                    xmlContent = sanitizeMdtObjectXml(xmlContent);
                    System.debug('[DEPLOY-TRACE] sanitizeMdtObjectXml applied to ['
                        + filePath + ']');
                }

                // ── Strip standard-object tabVisibilities from Profile XML ──
                // Profile <tabVisibilities> must only reference existing CustomTabs.
                // Standard objects (Account, Case etc.) have no CustomTab —
                // referencing them causes: "no CustomTab named X found".
                if (metadataType == 'Profile') {
                    // cloneFrom is not a valid child in deployable Profile XML.
                    xmlContent = sanitizeProfileXml(xmlContent);
                    xmlContent = sanitizeProfileStandardObjectTabs(xmlContent);
                    // Fix bare layout names: "Account Layout" -> "Account-Account Layout"
                    xmlContent = sanitizeProfileLayoutAssignments(xmlContent);
                     xmlContent = sanitizeProfileMasterRecordType(xmlContent);
                }

                if (metadataType == 'AuthProvider') {
                    filePath = 'authproviders/' + memberName + '.authprovider';
                }

                // Strip invalid elements from AuthProvider XML before validation.
                // Removes <developerName>, <fullName>, <urlSuffix> and renames
                // wrong element names like <tokenEndpointUrl> → <tokenUrl> etc.
                if (metadataType == 'AuthProvider') {
                    xmlContent = sanitizeAuthProviderXml(xmlContent);
                    System.debug('[DEPLOY-TRACE] sanitizeAuthProviderXml applied to [' + filePath + ']');
                }

                // ── Phase 3: Apex code files skip XML validation ──────────────
                // ApexClass and ApexTrigger contain Apex source code, not XML.
                // The Metadata API compiles them server-side — we cannot validate
                // Apex syntax in Apex. Companion -meta.xml files ARE XML and are
                // validated normally via the else branch below.
                Boolean isApexCode = (metadataType == 'ApexClass' || metadataType == 'ApexTrigger');
                Boolean isApexMeta = (metadataType == 'ApexClassMeta' || metadataType == 'ApexTriggerMeta');

                // ── LWC file type detection ───────────────────────────────────
                // LwcHtml and LwcJs are source files — skip XML validation.
                // LwcMeta is an XML file — validate normally.
                Boolean isLwcHtml = (metadataType == 'LwcHtml');
                Boolean isLwcJs   = (metadataType == 'LwcJs');
                Boolean isLwcMeta = (metadataType == 'LwcMeta');
                // LwcTest = Jest test file — saved locally, NOT deployed to Salesforce
                Boolean isLwcTest = (metadataType == 'LwcTest');
                Boolean isLwcFile = isLwcHtml || isLwcJs || isLwcMeta; // LwcTest excluded — not a metadata type

                // ── Guard: Apex code file must NOT contain XML meta content ─────────────────
                if ((metadataType == 'ApexClass' || metadataType == 'ApexTrigger')
                        && String.isNotBlank(xmlContent)) {
                    String trimmedContent = xmlContent.trim();
                    if (trimmedContent.startsWith('<?xml')
                            || trimmedContent.startsWith('<ApexClass')
                            || trimmedContent.startsWith('<ApexTrigger')) {
                        System.debug('[DEPLOY-TRACE] *** APEX CODE FILE CONTAINS XML *** file=['
                            + filePath + '] — LLM put meta XML in a code file. Aborting.');
                        return 'Error: LLM generated XML meta content inside Apex code file ['
                            + filePath + ']. The .cls/.trigger file must contain Apex source code, '
                            + 'not XML. Please retry.';
                    }
                }

                // ── Guard: LWC HTML/JS files must NOT contain XML meta content ────────────
                // Catches cases where LLM puts <?xml or <LightningComponentBundle into a .html or .js file.
                if ((isLwcHtml || isLwcJs) && String.isNotBlank(xmlContent)) {
                    String trimmedLwc = xmlContent.trim();
                    if (trimmedLwc.startsWith('<?xml') || trimmedLwc.startsWith('<LightningComponent')) {
                        System.debug('[DEPLOY-TRACE] *** LWC SOURCE FILE CONTAINS XML *** file=['
                            + filePath + '] — LLM put meta XML in a source file. Aborting.');
                        return 'Error: LLM generated XML meta content inside LWC source file ['
                            + filePath + ']. The .html and .js files must contain component source, '
                            + 'not XML. Please retry.';
                    }
                }

                // ── LWC HTML sanitization: strip wire-style .data/.error bindings ──────────
                // LLMs frequently generate {property.data} / {property.error} (Tier 1 wire-result
                // syntax) even when the JS uses imperative .then()/.catch() (Tier 2).
                // Accessing .data on a plain array is undefined at connect phase →
                // "Cannot read properties of undefined (reading 'data')".
                // Fix: if the sibling LwcJs uses imperative pattern → strip .data/.error silently.
                if (isLwcHtml && String.isNotBlank(xmlContent)) {
                    String correspondingJs = null;
                    for (Object f2Raw : files) {
                        Map<String, Object> f2 = (Map<String, Object>) f2Raw;
                        if ('LwcJs'.equals((String) f2.get('metadataType'))
                                && memberName.equals((String) f2.get('memberName'))) {
                            correspondingJs = (String) f2.get('xmlContent');
                            break;
                        }
                    }
                    Boolean jsIsImperative = correspondingJs != null
                        && correspondingJs.contains('.then(');
                    if (jsIsImperative) {
                        String htmlBefore = xmlContent;
                        // {prop.data} → {prop}  (for:each, if:true bindings)
                        xmlContent = xmlContent.replaceAll(
                            '\\{([a-zA-Z][a-zA-Z0-9_]*)\\.data\\}', '{$1}'
                        );
                        // {prop.error} → {error}
                        xmlContent = xmlContent.replaceAll(
                            '\\{([a-zA-Z][a-zA-Z0-9_]*)\\.error\\}', '{error}'
                        );
                        if (!xmlContent.equals(htmlBefore)) {
                            System.debug('[DEPLOY-TRACE] LWC HTML [' + memberName
                                + '] — auto-sanitized wire-style .data/.error bindings'
                                + ' for imperative Tier 2 component');
                        }
                    }
                }

                // Guard: skip spurious classes/XxxTrigger.cls files
                if (metadataType == 'ApexClass'
                        && filePath != null
                        && !filePath.endsWith('-meta.xml')
                        && filePath.toLowerCase().endsWith('trigger.cls')) {
                    System.debug('[DEPLOY-TRACE] SKIPPED [' + filePath
                        + '] — trigger name found in classes/ directory. '
                        + 'Triggers must live in triggers/, not classes/.');
                    continue;
                }

                // ── LwcTest: Jest test file — save to ContentDocument, skip deployment ────────
                // Jest tests are Node.js files. They cannot be deployed to Salesforce.
                // Store in a ContentVersion so a local script can retrieve and run them.
                if (isLwcTest && String.isNotBlank(xmlContent)) {
                    try {
                        ContentVersion cv = new ContentVersion();
                        cv.Title       = 'LwcJest_' + memberName;
                        cv.PathOnClient = memberName + '.test.js';
                        cv.VersionData  = Blob.valueOf(xmlContent);
                        cv.IsMajorVersion = true;
                        insert cv;
                        System.debug('[DEPLOY-TRACE] Jest test saved to ContentDocument title=[LwcJest_'
                            + memberName + '] Id=[' + cv.Id + ']');
                    } catch (Exception e) {
                        System.debug('[DEPLOY-TRACE] Failed to save Jest test: ' + e.getMessage());
                    }
                    continue; // do NOT add to Salesforce deployment ZIP
                }

                // isNonXmlSource = files whose content is NOT XML (Apex source, LWC html, LWC js)
                // These skip XML validation. LwcMeta IS XML and goes through validation.
                Boolean isNonXmlSource = isApexCode || isLwcHtml || isLwcJs || isLwcTest;

                if (!isNonXmlSource) {
                    
                    // ── XML validation — skipped for raw Apex source ──────────
                    // Companion meta files (ApexClassMeta / ApexTriggerMeta) are
                    // tiny XML files and ARE validated here.
                    String validationError = validateXml(
                        isApexMeta ? metadataType.replace('Meta', '') : metadataType,
                        memberName, xmlContent
                    );
                    if (String.isNotBlank(validationError)) {
                        System.debug('processXmlGenerationResponse: XML validation FAILED for ['
                            + filePath + ']: ' + validationError);
                        FunctionHelper.hadError = true;
                        return 'Error: Invalid XML generated for ' + filePath + ': ' + validationError;
                    }
                } else {
                    // Non-XML source file — skip XML validation
                    if (isApexCode) {
                        xmlContent = sanitizeApexRegex(xmlContent);
                    }
                    System.debug('[DEPLOY-TRACE] skipping XML validation for non-XML source file ['
                        + filePath + '] metadataType=[' + metadataType + ']');
                }

                // ── Package.xml registration for Apex types ───────────────────
                // ApexClass  → one member = the class name  (covers both .cls + -meta.xml)
                // ApexTrigger → one member = the trigger name (covers both .trigger + -meta.xml)
                // ApexClassMeta / ApexTriggerMeta share the same memberName as their code file —
                // ZipBuilder.addFile() will register them under the parent type automatically.
                // We normalise the metadataType here so ZipBuilder sees the correct API type.
                String effectiveType = metadataType;
                if (isApexMeta) {
                    // Strip the "Meta" suffix so the package.xml type is correct
                    effectiveType = metadataType.replace('Meta', '');
                    System.debug('[DEPLOY-TRACE] ApexMeta file — normalising metadataType ['
                        + metadataType + '] → [' + effectiveType + '] for package.xml registration');
                }

                // Normalize all three LWC file types to the single package.xml type.
                // ZipBuilder.metadataTypes is Map<String, Set<String>> so the same memberName
                // added three times is deduplicated automatically — no extra logic needed.
                if (isLwcFile) {
                    effectiveType = 'LightningComponentBundle';
                    System.debug('[DEPLOY-TRACE] LWC file — normalising metadataType ['
                        + metadataType + '] → [LightningComponentBundle] for package.xml');
                }

                if (zip2FilePaths.contains(filePath)) {
                    zip2Files.put(filePath, xmlContent);
                    if (!zip2MetadataTypes.containsKey(effectiveType)) {
                        zip2MetadataTypes.put(effectiveType, new Set<String>());
                    }
                    zip2MetadataTypes.get(effectiveType).add(memberName);
                    System.debug('processXmlGenerationResponse: held back [' + filePath + '] for ZIP 2');
                    System.debug('[DEPLOY-TRACE] route ZIP2 <- ' + effectiveType + ' / ' + filePath);
                    continue;
                }

                // Safety net: NEVER deploy Layout files for standard objects.
                // They already exist in every org; deploying an LLM-generated one
                // causes "Layout must contain an item for required layout field".
                if (metadataType == 'Layout' && isStandardObjectLayout(memberName)) {
                    System.debug('[DEPLOY-TRACE] SKIPPED standard-object Layout file ['
                        + filePath + '] — standard layouts must not be deployed.');
                    continue;
                }
                ZipBuilder.addFile(effectiveType, memberName, filePath, xmlContent);

                // Auto-register RecordType members in package.xml
                // The actual definition lives inside the CustomObject file
                if (metadataType == 'CustomObject') {
                    List<String> rtNames = extractRecordTypeNamesFromObjectXml(xmlContent);
                    for (String rtName : rtNames) {
                        ZipBuilder.registerMember('RecordType', memberName + '.' + rtName);
                        System.debug('[DEPLOY-TRACE] registered RecordType member: '
                            + memberName + '.' + rtName);
                    }
                }

                System.debug('processXmlGenerationResponse: added [' + filePath + '] to ZipBuilder');
                System.debug('[DEPLOY-TRACE] route ZIP1 <- ' + effectiveType + ' / ' + filePath);

                System.debug('=== FILE ADDED TO ZIP ===');
                System.debug('Path: ' + filePath);
                System.debug('Type: ' + effectiveType);
                System.debug('Content (first 500 chars): ' + xmlContent.left(500));
                System.debug('========================');
            }
        }

        // ── Scenario A backstop — force layout for any new CustomObject when
        // the LLM forgot to emit one. Adds synthesized Layout entries directly
        // to zip2Files so the staging block below picks them up.
        backstopMissingLayoutsForNewObjects(files, orgState, zip2Files, zip2MetadataTypes);
        backstopMissingFieldsInExistingLayouts(files, orgState, zip2Files, zip2MetadataTypes);

        // ── Process destructive changes ────────────────────────
        List<Object> destructiveFiles = (List<Object>) parsed.get('destructiveFiles');
        if (destructiveFiles != null && !destructiveFiles.isEmpty()) {
            System.debug('processXmlGenerationResponse: processing '
                + destructiveFiles.size() + ' destructive file(s)');

            for (Object rawFile : destructiveFiles) {
                Map<String, Object> file = (Map<String, Object>) rawFile;
                String xmlContent        = (String) file.get('xmlContent');
                if (String.isBlank(xmlContent)) {
                    String metadataType = (String) file.get('metadataType');
                    if (String.isBlank(metadataType)) metadataType = (String) file.get('type');
                    String memberName = (String) file.get('member');
                    if (String.isBlank(memberName)) memberName = (String) file.get('memberName');

                    if (String.isBlank(metadataType) || String.isBlank(memberName)) {
                        FunctionHelper.hadError = true;
                        return 'Error: Invalid destructiveFiles entry. Provide xmlContent OR metadataType/type + member/memberName.';
                    }

                    appendDestructiveMember(metadataType, memberName);
                } else {
                    ZipBuilder.addFile('__destructive__', 'destructive', 'destructiveChangesPost.xml', xmlContent);
                }
            }
        }

        // ── Process DML operations ─────────────────────────────
        // Permission set assignments etc — these are record operations not XML
        if (nonCloneOps != null && !nonCloneOps.isEmpty()) {
            System.debug('processXmlGenerationResponse: processing '
                + nonCloneOps.size() + ' non-clone DML operation(s)');
            processDmlOperations(nonCloneOps);
        }

        // ── Persist zip2 data for chained deploy ──────────────
        if (!zip2Files.isEmpty()) {
            Map<String, Object> zip2Data = new Map<String, Object>{
                'files'             => zip2Files,
                'binaryFiles'       => new Map<String, String>(),
                'metadataTypesJson' => JSON.serialize(zip2MetadataTypes)
            };
            pendingZip2DataJson = JSON.serialize(zip2Data);
            System.debug('processXmlGenerationResponse: zip2 data staged — '
                + zip2Files.size() + ' file(s) for ZIP 2');
            System.debug('[DEPLOY-TRACE] ZIP2 staged | fileCount=' + zip2Files.size()
                + ' | files=' + zip2Files.keySet());
        } else {
            pendingZip2DataJson = null;
            System.debug('[DEPLOY-TRACE] ZIP2 staged | fileCount=0 (single-deploy mode)');
        }

        // ── Return summary ─────────────────────────────────────
        String summary = (String) parsed.get('summary');
        return String.isNotBlank(summary) ? summary : 'Changes staged for deployment.';
    }


    private static List<String> extractRecordTypeNamesFromObjectXml(String xmlContent) {
        List<String> result = new List<String>();
        if (String.isBlank(xmlContent) || !xmlContent.contains('<recordTypes>')) return result;

        Pattern rtBlock = Pattern.compile('(?s)<recordTypes>(.*?)</recordTypes>');
        Matcher m = rtBlock.matcher(xmlContent);
        Pattern fnPat = Pattern.compile('<fullName>([^<]+)</fullName>');

        while (m.find()) {
            Matcher fnm = fnPat.matcher(m.group(1));
            if (fnm.find()) {
                result.add(fnm.group(1));
            }
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // SCENARIO B VIOLATION DETECTOR
    // The LLM is required to emit a Layout file for each existing layout
    // when adding a new CustomField to an object that already has layouts
    // (Scenario B in the system prompt). This method detects when the LLM
    // skipped that requirement and logs a loud trace marker so we can see
    // ─────────────────────────────────────────────────────────────
    // SCENARIO B BACKSTOP
    // When the LLM adds fields to an EXISTING object but forgets to include
    // the matching Layout update, the new fields land in the "fields palette"
    // and never appear on any layout section.
    // This backstop detects that omission and rebuilds the layout XML
    // directly from the orgState sections + appends the new fields.
    // No extra callout is needed — orgState already holds the layout structure
    // from the pre-callout gatherOrgState phase.
    // The rebuilt layout is staged in zip2Files so it deploys AFTER the fields.
    // ─────────────────────────────────────────────────────────────
    private static void backstopMissingFieldsInExistingLayouts(
        List<Object> files,
        Map<String, Object> orgState,
        Map<String, String> zip2Files,
        Map<String, Set<String>> zip2MetadataTypes
    ) {
        if (orgState == null) return;
        Object rawExistingLayouts = orgState.get('existingLayouts');
        if (!(rawExistingLayouts instanceof Map<String, Object>)) return;
        Map<String, Object> existingLayouts = (Map<String, Object>) rawExistingLayouts;
        if (existingLayouts.isEmpty()) return;

        Set<String> existingObjects = new Set<String>();
        Object rawExistingObjects = orgState.get('existingObjects');
        if (rawExistingObjects instanceof List<Object>) {
            for (Object o : (List<Object>) rawExistingObjects) {
                if (o != null) existingObjects.add(String.valueOf(o));
            }
        }

        Map<String, List<String>> newFieldsByObject = new Map<String, List<String>>();
        Set<String> objectsWithLayoutEmitted = new Set<String>();

        if (files != null) {
            for (Object rawFile : files) {
                Map<String, Object> f = (Map<String, Object>) rawFile;
                String mt = (String) f.get('metadataType');
                String mn = (String) f.get('memberName');
                if (String.isBlank(mt) || String.isBlank(mn)) continue;

                if (mt == 'CustomObject' && existingObjects.contains(mn)) {
                    List<Map<String, String>> infos =
                        extractFieldInfosFromObjectXml((String) f.get('xmlContent'));
                    if (!infos.isEmpty()) {
                        if (!newFieldsByObject.containsKey(mn)) {
                            newFieldsByObject.put(mn, new List<String>());
                        }
                        for (Map<String, String> fi : infos) {
                            newFieldsByObject.get(mn).add(fi.get('name'));
                        }
                    }
                } else if (mt == 'CustomField' && mn.contains('.')) {
                    String parentObj  = mn.substringBefore('.');
                    String fieldName  = mn.substringAfter('.');
                    if (existingObjects.contains(parentObj)) {
                        if (!newFieldsByObject.containsKey(parentObj)) {
                            newFieldsByObject.put(parentObj, new List<String>());
                        }
                        newFieldsByObject.get(parentObj).add(fieldName);
                    }
                } else if (mt == 'Layout' && mn.contains('-')) {
                    objectsWithLayoutEmitted.add(mn.substringBefore('-'));
                }
            }
        }

        for (String objName : newFieldsByObject.keySet()) {
            if (!existingLayouts.containsKey(objName)) continue;
            if (objectsWithLayoutEmitted.contains(objName)) {
                System.debug('[DEPLOY-TRACE] backstopB: Layout already emitted for ['
                    + objName + '] — no injection needed');
                continue;
            }

            List<String> newFields = newFieldsByObject.get(objName);
            if (newFields == null || newFields.isEmpty()) continue;

            Object rawLayouts = existingLayouts.get(objName);
            if (!(rawLayouts instanceof List<Object>)) continue;
            List<Object> layouts = (List<Object>) rawLayouts;
            if (layouts.isEmpty()) continue;

            Map<String, Object> firstLayout = (Map<String, Object>) layouts[0];
            String layoutFullName = (String) firstLayout.get('fullName');
            if (String.isBlank(layoutFullName)) continue;

            String layoutPath = 'layouts/' + layoutFullName + '.layout';
            if (zip2Files.containsKey(layoutPath)) {
                System.debug('[DEPLOY-TRACE] backstopB: Layout already in zip2Files for ['
                    + objName + '] — skipping');
                continue;
            }

            String layoutXml = rebuildLayoutXmlWithNewFields(firstLayout, newFields);
            if (String.isBlank(layoutXml)) continue;

            zip2Files.put(layoutPath, layoutXml);
            if (!zip2MetadataTypes.containsKey('Layout')) {
                zip2MetadataTypes.put('Layout', new Set<String>());
            }
            zip2MetadataTypes.get('Layout').add(layoutFullName);

            System.debug('[DEPLOY-TRACE] *** SCENARIO B BACKSTOP FIRED *** object=' + objName
                + ' | LLM omitted Layout — appending ' + newFields.size()
                + ' field(s) to [' + layoutFullName + '] via zip2Files');
        }
    }

    private static String rebuildLayoutXmlWithNewFields(
        Map<String, Object> layoutStructure, List<String> newFields) {

        String fullName = (String) layoutStructure.get('fullName');
        Object rawSections = layoutStructure.get('sections');
        if (!(rawSections instanceof List<Object>)) return null;
        List<Object> sections = (List<Object>) rawSections;

        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';

        Boolean injected = false;
        for (Object rawSec : sections) {
            Map<String, Object> sec = (Map<String, Object>) rawSec;
            String label = (String) sec.get('label');

            List<String> leftFields     = toStringList(sec.get('leftFields'));
            List<String> leftBehaviors  = toStringList(sec.get('leftBehaviors'));
            List<String> rightFields    = toStringList(sec.get('rightFields'));
            List<String> rightBehaviors = toStringList(sec.get('rightBehaviors'));

            if (!injected && label == 'Information') {
                for (String f : newFields) {
                    Integer total = leftFields.size() + rightFields.size();
                    if (Math.mod(total, 2) == 0) {
                        leftFields.add(f);
                        leftBehaviors.add('Edit');
                    } else {
                        rightFields.add(f);
                        rightBehaviors.add('Edit');
                    }
                }
                injected = true;
            }

            xml += '    <layoutSections>\n'
                + '        <customLabel>true</customLabel>\n'
                + '        <detailHeading>true</detailHeading>\n'
                + '        <editHeading>true</editHeading>\n'
                + '        <label>' + label + '</label>\n'
                + '        <layoutColumns>\n';

            for (Integer i = 0; i < leftFields.size(); i++) {
                String beh = (i < leftBehaviors.size()) ? leftBehaviors[i] : 'Edit';
                xml += '            <layoutItems>\n'
                    + '                <behavior>' + beh + '</behavior>\n'
                    + '                <field>' + leftFields[i] + '</field>\n'
                    + '            </layoutItems>\n';
            }

            xml += '        </layoutColumns>\n'
                + '        <layoutColumns>\n';

            for (Integer i = 0; i < rightFields.size(); i++) {
                String beh = (i < rightBehaviors.size()) ? rightBehaviors[i] : 'Edit';
                xml += '            <layoutItems>\n'
                    + '                <behavior>' + beh + '</behavior>\n'
                    + '                <field>' + rightFields[i] + '</field>\n'
                    + '            </layoutItems>\n';
            }

            xml += '        </layoutColumns>\n'
                + '        <style>TwoColumnsTopToBottom</style>\n'
                + '    </layoutSections>\n';
        }

        if (!injected && !newFields.isEmpty()) {
            xml += '    <layoutSections>\n'
                + '        <customLabel>true</customLabel>\n'
                + '        <detailHeading>true</detailHeading>\n'
                + '        <editHeading>true</editHeading>\n'
                + '        <label>Information</label>\n'
                + '        <layoutColumns>\n';
            for (String f : newFields) {
                xml += '            <layoutItems>\n'
                    + '                <behavior>Edit</behavior>\n'
                    + '                <field>' + f + '</field>\n'
                    + '            </layoutItems>\n';
            }
            xml += '        </layoutColumns>\n'
                + '        <layoutColumns/>\n'
                + '        <style>TwoColumnsTopToBottom</style>\n'
                + '    </layoutSections>\n';
        }

        xml += '</Layout>';
        return xml;
    }

    private static List<String> toStringList(Object raw) {
        List<String> result = new List<String>();
        if (!(raw instanceof List<Object>)) return result;
        for (Object o : (List<Object>) raw) {
            if (o != null) result.add(String.valueOf(o));
        }
        return result;
    }

    // it in the deploy log instead of silently shipping a layout-less field.
    // Detection only — no behavior change yet.
    // ─────────────────────────────────────────────────────────────
    private static void detectScenarioBViolation(List<Object> files, Map<String, Object> orgState) {
        if (orgState == null) return;
        Object rawExistingLayouts = orgState.get('existingLayouts');
        if (!(rawExistingLayouts instanceof Map<String, Object>)) return;
        Map<String, Object> existingLayouts = (Map<String, Object>) rawExistingLayouts;
        if (existingLayouts.isEmpty()) return;

        Object rawExistingObjects = orgState.get('existingObjects');
        Set<String> existingObjects = new Set<String>();
        if (rawExistingObjects instanceof List<Object>) {
            for (Object o : (List<Object>) rawExistingObjects) {
                if (o != null) existingObjects.add(String.valueOf(o));
            }
        }

        Set<String> objectsReceivingNewFields = new Set<String>();
        Set<String> objectsWithLayoutEmitted  = new Set<String>();

        if (files != null) {
            for (Object rawFile : files) {
                Map<String, Object> file = (Map<String, Object>) rawFile;
                String metadataType = (String) file.get('metadataType');
                String memberName   = (String) file.get('memberName');
                if (String.isBlank(metadataType) || String.isBlank(memberName)) continue;

                if (metadataType == 'CustomObject' && existingObjects.contains(memberName)) {
                    objectsReceivingNewFields.add(memberName);
                } else if (metadataType == 'CustomField' && memberName.contains('.')) {
                    String parent = memberName.substringBefore('.');
                    if (existingObjects.contains(parent)) objectsReceivingNewFields.add(parent);
                } else if (metadataType == 'Layout' && memberName.contains('-')) {
                    String parent = memberName.substringBefore('-');
                    objectsWithLayoutEmitted.add(parent);
                }
            }
        }

        for (String objName : objectsReceivingNewFields) {
            if (!existingLayouts.containsKey(objName)) continue;
            if (objectsWithLayoutEmitted.contains(objName)) continue;
            Object layoutsRaw = existingLayouts.get(objName);
            Integer layoutCount = (layoutsRaw instanceof List<Object>)
                ? ((List<Object>) layoutsRaw).size() : 0;
            System.debug('[DEPLOY-TRACE] *** SCENARIO B VIOLATION *** object=' + objName
                + ' is in existingObjects with ' + layoutCount + ' existing layout(s),'
                + ' but the LLM emitted a CustomObject/CustomField without a matching Layout file.'
                + ' The new field will land in the palette only and will NOT appear in any layout section.');
        }
    }

    // ─────────────────────────────────────────────────────────────
    // SCENARIO A BACKSTOP
    // The LLM is required to emit a Layout file for every NEW CustomObject
    // and to mark the deployment as "chained". When it forgets (e.g. picks
    // scenario=single with zero layout files), this backstop synthesizes a
    // minimal default Layout from the object's <fields> and force-stages it
    // for ZIP2. Result: chained deploy fires regardless of LLM compliance.
    // ─────────────────────────────────────────────────────────────
    private static void backstopMissingLayoutsForNewObjects(
        List<Object> files,
        Map<String, Object> orgState,
        Map<String, String> zip2Files,
        Map<String, Set<String>> zip2MetadataTypes
    ) {
        if (files == null || files.isEmpty()) return;

        Set<String> existingObjects = new Set<String>();
        if (orgState != null) {
            Object raw = orgState.get('existingObjects');
            if (raw instanceof List<Object>) {
                for (Object o : (List<Object>) raw) {
                    if (o != null) existingObjects.add(String.valueOf(o));
                }
            }
        }

        Map<String, String> newObjectXml = new Map<String, String>();
        Set<String> objectsWithLayout = new Set<String>();

        for (Object rawFile : files) {
            Map<String, Object> file = (Map<String, Object>) rawFile;
            String metadataType = (String) file.get('metadataType');
            String memberName   = (String) file.get('memberName');
            String xmlContent   = (String) file.get('xmlContent');
            if (String.isBlank(metadataType) || String.isBlank(memberName)) continue;
            // Only backstop CUSTOM objects (__c / __mdt).
            // Standard objects (Account, Case, Contact, Lead etc.) are deployed
            // as CustomObject files for record types but they NEVER need a
            // synthesized layout — their layouts already exist in every org.
            // Before this guard, the backstop saw Account in the deploy list,
            // noticed it was not in existingObjects (only custom objects land there),
            // and synthesized a blank layout that failed with:
            //   "Layout must contain an item for required layout field: ParentId"
            Boolean isCustomObj = memberName != null
                && (memberName.endsWith('__c') || memberName.endsWith('__mdt'));
            if (metadataType == 'CustomObject' && isCustomObj && !existingObjects.contains(memberName)) {
                newObjectXml.put(memberName, xmlContent);
            } else if (metadataType == 'Layout' && memberName.contains('-')) {
                objectsWithLayout.add(memberName.substringBefore('-'));
            }
        }

        for (String objApi : newObjectXml.keySet()) {
            if (objectsWithLayout.contains(objApi)) {
                System.debug('[DEPLOY-TRACE] backstop: Layout already present for new object '
                    + objApi + ' — no synthesis needed');
                continue;
            }

            List<Map<String, String>> fieldInfos = extractFieldInfosFromObjectXml(newObjectXml.get(objApi));
            String objLabel    = objApi.endsWith('__c') ? objApi.removeEnd('__c').replace('_', ' ') : objApi;
            String layoutMember = objApi + '-' + objLabel + ' Layout';
            String layoutPath   = 'layouts/' + layoutMember + '.layout';
            String layoutXml    = buildDefaultLayoutXml(fieldInfos);

            zip2Files.put(layoutPath, layoutXml);
            if (!zip2MetadataTypes.containsKey('Layout')) {
                zip2MetadataTypes.put('Layout', new Set<String>());
            }
            zip2MetadataTypes.get('Layout').add(layoutMember);

            System.debug('[DEPLOY-TRACE] *** SCENARIO A BACKSTOP FIRED *** object=' + objApi
                + ' | LLM omitted Layout — synthesized default with ' + fieldInfos.size()
                + ' field(s) | path=' + layoutPath + ' | layoutMember=' + layoutMember);
        }
    }

    private static List<Map<String, String>> extractFieldInfosFromObjectXml(String customObjectXml) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        if (String.isBlank(customObjectXml)) return result;
        Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
        Matcher fbm = fieldsBlock.matcher(customObjectXml);
        Pattern fnPat   = Pattern.compile('<fullName>([^<]+)</fullName>');
        Pattern typePat = Pattern.compile('<type>([^<]+)</type>');
        while (fbm.find()) {
            String block = fbm.group(1);
            Matcher fnm = fnPat.matcher(block);
            if (fnm.find()) {
                Matcher tym = typePat.matcher(block);
                String fieldType = tym.find() ? tym.group(1) : 'Text';
                result.add(new Map<String, String>{ 'name' => fnm.group(1), 'type' => fieldType });
            }
        }
        return result;
    }

    private static String buildDefaultLayoutXml(List<Map<String, String>> fieldInfos) {
        String s = '<?xml version="1.0" encoding="UTF-8"?>\n';
        s += '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';
        s += '    <layoutSections>\n';
        s += '        <customLabel>true</customLabel>\n';
        s += '        <detailHeading>true</detailHeading>\n';
        s += '        <editHeading>true</editHeading>\n';
        s += '        <label>Information</label>\n';
        s += '        <layoutColumns>\n';
        s += '            <layoutItems>\n';
        s += '                <behavior>Required</behavior>\n';
        s += '                <field>Name</field>\n';
        s += '            </layoutItems>\n';
        if (fieldInfos != null) {
            for (Map<String, String> fi : fieldInfos) {
                String f = fi.get('name');
                String t = fi.get('type');
                if (String.isBlank(f)) continue;
                String behavior = (t == 'MasterDetail') ? 'Required' : 'Edit';
                s += '            <layoutItems>\n';
                s += '                <behavior>' + behavior + '</behavior>\n';
                s += '                <field>' + f + '</field>\n';
                s += '            </layoutItems>\n';
            }
        }
        s += '        </layoutColumns>\n';
        s += '        <layoutColumns/>\n';
        s += '        <style>TwoColumnsTopToBottom</style>\n';
        s += '    </layoutSections>\n';
        s += '</Layout>';
        return s;
    }

    // ─────────────────────────────────────────────────────────────
    // PROCESS DML OPERATIONS
    // Handles non-XML operations like permission set user assignments
    // ─────────────────────────────────────────────────────────────
    private static void processDmlOperations(List<Object> dmlOps) {
        for (Object rawOp : dmlOps) {
            Map<String, Object> op = (Map<String, Object>) rawOp;
            String opType          = (String) op.get('type');

            System.debug('processDmlOperations: processing op type=[' + opType + ']');

            if (opType == 'permissionSetAssign') {
                String psName  = (String) op.get('permissionSetName');
                String username = (String) op.get('username');
                SObject assignment = PermissionSetHelper.buildAssignment(
                    new Map<String, Object>{
                        'permissionSetName' => psName,
                        'username'          => username
                    }
                );
                FunctionHelper.recordsToInsert.add(assignment);
                System.debug('processDmlOperations: queued PS assignment ['
                    + psName + '] → [' + username + ']');

            } else if (opType == 'permissionSetRemove') {
                String psName   = (String) op.get('permissionSetName');
                String username = (String) op.get('username');
                SObject assignment = PermissionSetHelper.findAssignment(
                    new Map<String, Object>{
                        'permissionSetName' => psName,
                        'username'          => username
                    }
                );
                FunctionHelper.recordsToDelete.add(assignment);
                System.debug('processDmlOperations: queued PS removal ['
                    + psName + '] → [' + username + ']');
            } else if (opType == 'staticResourceDeploy') {
                String apiName      = (String) op.get('apiName');
                String fileName     = (String) op.get('fileName');
                String cacheControl = (String) op.get('cacheControl');
                StaticResourceHelper.deployStaticResource(new Map<String, Object>{
                    'apiName'      => apiName,
                    'fileName'     => fileName,
                    'cacheControl' => cacheControl != null ? cacheControl : 'Public'
                });
                System.debug('processDmlOperations: static resource staged [' + apiName + ']');

            } else if (opType == 'staticResourceDelete') {
                String apiName = (String) op.get('apiName');
                StaticResourceHelper.deleteStaticResource(new Map<String, Object>{
                    'apiName' => apiName
                });
                System.debug('processDmlOperations: static resource delete queued [' + apiName + ']');
            } else if (opType == 'permissionSetClone') {
                // Clone a PS via SOAP retrieve (Apex-side) — XML too large for LLM to generate
                String sourcePermissionSetName = (String) op.get('sourcePermissionSetName');
                String newApiName              = (String) op.get('newApiName');
                String newLabel                = (String) op.get('newLabel');
                String description             = (String) op.get('description');
                PermissionSetHelper.clonePermissionSet(new Map<String, Object>{
                    'sourcePermissionSetName' => sourcePermissionSetName,
                    'newApiName'              => newApiName,
                    'newLabel'                => newLabel,
                    'description'             => description
                });
                System.debug('processDmlOperations: PS clone staged ['
                    + sourcePermissionSetName + '] → [' + newApiName + ']');
            } else if (
                String.isNotBlank(opType)
                && opType.startsWith('permissionSet')
                && opType != 'permissionSetAssign'
                && opType != 'permissionSetRemove'
                && opType != 'permissionSetClone'
            ) {
                // Clone remains helper/SOAP-based. All other permission-set changes must be XML files.
                // Fail fast so we don't silently ignore unsupported legacy op types.
                FunctionHelper.hadError = true;
                throw new LLMException(
                    'Unsupported dmlOperations type [' + opType + '] for Permission Set. '
                    + 'Use files[] PermissionSet XML for create/update/delete and keep only permissionSetClone in dmlOperations.'
                );

            } else if (opType == 'profileClone') {
                // Clone a Profile via readMetadata (Apex-side) — XML too large for LLM to generate
                String sourceProfileName = (String) op.get('sourceProfileName');
                String newProfileName    = (String) op.get('newProfileName');
                ProfileHelper.cloneProfile(new Map<String, Object>{
                    'sourceProfileName' => sourceProfileName,
                    'newProfileName'    => newProfileName
                });
                System.debug('processDmlOperations: Profile clone staged ['
                    + sourceProfileName + '] → [' + newProfileName + ']');

            } else if (opType == 'csvProcess') {
                String fileName = (String) op.get('fileName');
                String csvType  = (String) op.get('csvType');
                
                System.debug('processDmlOperations: processing CSV [' + fileName + '] type=[' + csvType + ']');
                
                // Step 1 — read and cache rows
                Map<String, Object> readResult = CsvProcessor.readCsv(new Map<String, Object>{
                    'fileName' => fileName
                });
                System.debug('processDmlOperations: CSV read complete — ' + readResult.get('totalRows') + ' rows');
                
                // Step 2 — bulk process
                Map<String, Object> processResult = CsvProcessor.process(new Map<String, Object>{
                    'fileName' => fileName,
                    'type'     => csvType
                });
                System.debug('processDmlOperations: CSV processed — ' + processResult.get('processed') + ' records staged');
            }

        }
    }

    // ─────────────────────────────────────────────────────────────
    // RELATIONSHIP NAME POST-PROCESSING (CustomObject XML)
    //
    // The LLM emits <relationshipName> values like "Reservation_AI_Message"
    // directly in the CustomObject XML. When a prior deploy of the same ticket
    // partially succeeded, that name survives as an orphan on the parent object
    // and every re-deploy fails with "There is already a Child Relationship
    // named X on Y". We rewrite every Lookup/MasterDetail relationshipName to
    // a SHA1-suffixed unique value so:
    //   - same ticket → same name (idempotent across re-runs)
    //   - different {child,field,parent} → different name (no collisions)
    //   - never equals the legacy "{Child}_{Field}" pattern (clears the org)
    // ─────────────────────────────────────────────────────────────
    private static String uniqueRelationshipName(
        String childObjectApiName, String fieldApiName, String parentObjectApiName) {

        String child  = sanitizeRelToken(String.isBlank(childObjectApiName) ? 'Child' : childObjectApiName);
        String field  = sanitizeRelToken(fieldApiName);
        String parent = sanitizeRelToken(parentObjectApiName);

        // Look up names already in use on the parent object (avoids known orphans).
        Set<String> taken = getExistingChildRelationshipNames(parentObjectApiName);

        Integer maxLen = 40;
        String base = child;
        if (String.isNotBlank(field)) base = base + '_' + field;

        // Sanity guard: Salesforce API names ALWAYS start with a letter, so after
        // sanitization `base` is guaranteed to start alpha. We deliberately do NOT
        // prepend any prefix here — earlier versions had a bug where Apex's
        // case-insensitive String == made an "if first char isn't alpha" guard
        // fire spuriously and prefix every name with "R".
        System.debug('uniqueRelationshipName[v2]: child=' + child + ' field=' + field
            + ' parent=' + parent + ' base=' + base);

        // Per-deploy timestamp makes the name NON-deterministic across deploy
        // attempts — essential because soft-deleted (recycle-bin) relationships
        // are not visible to Schema.describe, so a deterministic hash will
        // happily regenerate a name that the deploy validator still considers
        // "taken". A fresh timestamp per call avoids that failure mode entirely.
        String nonce = String.valueOf(DateTime.now().getTime());
        String fallback = null;
        for (Integer salt = 0; salt < 32; salt++) {
            String seed = child + '|' + field + '|' + parent + '|T' + nonce
                + (salt > 0 ? '|S' + String.valueOf(salt) : '');
            String hex    = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA1', Blob.valueOf(seed))).toUpperCase();
            String suffix = hex.substring(0, 6);

            Integer maxBaseLen = Math.max(1, maxLen - (1 + suffix.length()));
            String b = (base.length() > maxBaseLen) ? base.substring(0, maxBaseLen) : base;
            String rel = b + '_' + suffix;

            if (fallback == null) fallback = rel;
            if (!taken.contains(rel)) {
                System.debug('uniqueRelationshipName[v2]: → ' + rel
                    + ' (salt=' + salt + ', collisions checked against '
                    + taken.size() + ' existing rel name(s) on ' + parentObjectApiName + ')');
                return rel;
            }
            System.debug('uniqueRelationshipName[v2]: name [' + rel
                + '] already taken on ' + parentObjectApiName + ', re-hashing (salt=' + (salt + 1) + ')');
        }
        System.debug('uniqueRelationshipName[v2]: exhausted salts, returning fallback ' + fallback);
        return fallback;
    }

    // Returns the set of relationshipName values already in use on the parent's
    // child relationships. This is what the deploy validator checks against.
    // Soft-deleted (recycle-bin) relationships are NOT returned by describe — those
    // can only be cleared by emptying the recycle bin in setup.
    private static Set<String> getExistingChildRelationshipNames(String parentApiName) {
        Set<String> names = new Set<String>();
        if (String.isBlank(parentApiName)) return names;
        try {
            Schema.SObjectType t = Schema.getGlobalDescribe().get(parentApiName);
            if (t == null) return names;
            Schema.DescribeSObjectResult d = t.getDescribe();
            for (Schema.ChildRelationship cr : d.getChildRelationships()) {
                String n = cr.getRelationshipName();
                if (String.isNotBlank(n)) names.add(n);
            }
        } catch (Exception e) {
            System.debug('getExistingChildRelationshipNames failed for ['
                + parentApiName + ']: ' + e.getMessage());
            ErrorLogger.log(e);
        }
        return names;
    }

    private static String sanitizeRelToken(String token) {
        if (String.isBlank(token)) return '';
        String t = token.trim();
        if (t.endsWith('__c'))   t = t.substring(0, t.length() - 3);
        if (t.endsWith('__mdt')) t = t.substring(0, t.length() - 5);
        // Only alphanumeric + underscore
        t = t.replaceAll('[^A-Za-z0-9_]', '_');
        // Collapse multiple underscores
        while (t.contains('__')) t = t.replace('__', '_');
        if (t.startsWith('_')) t = t.substring(1);
        if (t.endsWith('_'))   t = t.substring(0, t.length() - 1);
        return t;
    }

    // Derive "Reservation__c" from "objects/Reservation__c.object".
    private static String extractSourceObjectFromObjectPath(String filePath) {
        if (String.isBlank(filePath)) return '';
        String name = filePath;
        Integer slash = name.lastIndexOf('/');
        if (slash >= 0) name = name.substring(slash + 1);
        if (name.toLowerCase().endsWith('.object')) {
            name = name.substring(0, name.length() - '.object'.length());
        }
        return name;
    }

    // Rewrites <relationshipName>…</relationshipName> inside every <fields> block
    // whose <type> is Lookup or MasterDetail. Injects one if missing.
    private static String rewriteRelationshipNamesInCustomObjectXml(String xmlContent, String sourceObjectApiName) {
        if (String.isBlank(xmlContent) || !xmlContent.contains('<fields>')) return xmlContent;

        Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
        Matcher m = fieldsBlock.matcher(xmlContent);

        List<String> oldBlocks = new List<String>();
        List<String> newBlocks = new List<String>();

        while (m.find()) {
            String fullMatch = m.group(0);
            String inners     = m.group(1);

            String typeVal  = extractFirstTagValue(inners, 'type');
            if (typeVal != 'Lookup' && typeVal != 'MasterDetail') continue;

            String fieldApi = extractFirstTagValue(inners, 'fullName');
            String parent   = extractFirstTagValue(inners, 'referenceTo');
            if (String.isBlank(fieldApi) || String.isBlank(parent)) continue;

            String uniqueName = uniqueRelationshipName(sourceObjectApiName, fieldApi, parent);
            String newInner;

            if (inners.contains('<relationshipName>')) {
                // Replace the first <relationshipName>…</relationshipName>
                newInner = inners.replaceFirst(
                    '<relationshipName>.*?</relationshipName>',
                    '<relationshipName>' + uniqueName + '</relationshipName>');
            } else {
                // Inject right after the <referenceTo>…</referenceTo> tag
                newInner = inners.replaceFirst(
                    '(</referenceTo>)',
                    '$1<relationshipName>' + uniqueName + '</relationshipName>');
            }

            oldBlocks.add(fullMatch);
            newBlocks.add('<fields>' + newInner + '</fields>');

            System.debug('rewriteRelationshipNames: ' + sourceObjectApiName + '.' + fieldApi
                + ' → ' + uniqueName);
        }

        String result = xmlContent;
        for (Integer i = 0; i < oldBlocks.size(); i++) {
            result = result.replace(oldBlocks[i], newBlocks[i]);
        }
        return result;
    }

    // Pulls the text value of the first <tagName>…</tagName> found in xml.
    private static String extractFirstTagValue(String xml, String tagName) {
        if (String.isBlank(xml) || String.isBlank(tagName)) return null;
        Pattern p = Pattern.compile('(?s)<' + tagName + '>(.*?)</' + tagName + '>');
        Matcher m = p.matcher(xml);
        if (m.find()) return m.group(1).trim();
        return null;
    }


    // ─────────────────────────────────────────────────────────────
    // GET AUTH PROVIDERS STATE
    // Reads all Auth Providers via SOQL.
    // ConsumerSecret is NEVER returned by any Salesforce API (encrypted).
    // For create/update, the secret MUST come from the ticket.
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getAuthProvidersState() {
        try {
            List<Map<String, Object>> result = new List<Map<String, Object>>();
 
            for (AuthProvider ap : [
                SELECT DeveloperName, FriendlyName, ProviderType,
                       ConsumerKey, DefaultScopes, AuthorizeUrl,
                       TokenUrl, UserInfoUrl, IconUrl
                FROM AuthProvider
                ORDER BY DeveloperName
            ]) {
                Map<String, Object> apMap = new Map<String, Object>{
                    'developerName' => ap.DeveloperName,
                    'friendlyName'  => ap.FriendlyName,
                    'providerType'  => ap.ProviderType
                };
 
                // Optional fields — only include when non-null
                if (ap.ConsumerKey    != null) apMap.put('consumerKey',    ap.ConsumerKey);
                if (ap.DefaultScopes  != null) apMap.put('defaultScopes',  ap.DefaultScopes);
                if (ap.AuthorizeUrl   != null) apMap.put('authorizeUrl',   ap.AuthorizeUrl);
                if (ap.TokenUrl       != null) apMap.put('tokenUrl',       ap.TokenUrl);
                if (ap.UserInfoUrl    != null) apMap.put('userInfoUrl',    ap.UserInfoUrl);
                if (ap.IconUrl        != null) apMap.put('iconUrl',        ap.IconUrl);
 
                result.add(apMap);
                System.debug('getAuthProvidersState: read AP [' + ap.DeveloperName
                    + '] type=[' + ap.ProviderType + ']');
            }
 
            System.debug('getAuthProvidersState: returning ' + result.size() + ' AP(s)');
            return result.isEmpty() ? null : result;
 
        } catch (Exception e) {
            System.debug('getAuthProvidersState failed: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // GET APEX TRIGGER STATE
    // Checks whether a trigger already exists on a given object.
    // Called directly from runOrgCheck() — same pattern as getNamedCredentialsState().
    // Returns the trigger name + body, and the companion handler class name + body
    // if found. Returns null if no trigger exists on that object.
    //
    // The LLM uses this to decide MERGE vs CREATE:
    //   existingTrigger != null  → merge new events into existing trigger + handler
    //   existingTrigger == null  → create fresh trigger + handler files
    //
    // Uses the Tooling API via MetadataHelper (same path as run_tooling_api_query
    // but called directly from Apex — no LLM tool-calling loop involved).
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getApexTriggerState(String objectApiName) {
        try {
            System.debug('getApexTriggerState: checking for trigger on [' + objectApiName + ']');

            // Query for existing trigger on this object via Tooling API
            String triggerQuery = 'SELECT Id, Name, Body FROM ApexTrigger'
                + ' WHERE TableEnumOrId = \'' + objectApiName + '\''
                + ' AND NamespacePrefix = null'
                + ' LIMIT 1';

            String triggerJson = JSON.serialize(MetadataHelper.runToolingApiQuery(triggerQuery));

            Map<String, Object> triggerResult = (Map<String, Object>) JSON.deserializeUntyped(triggerJson);
            List<Object> triggerRecords = (List<Object>) triggerResult.get('records');

            if (triggerRecords == null || triggerRecords.isEmpty()) {
                System.debug('getApexTriggerState: no trigger found on [' + objectApiName + ']');
                return null;
            }

            // Trigger found — extract name and body
            Map<String, Object> triggerRec = (Map<String, Object>) triggerRecords[0];
            String triggerName = (String) triggerRec.get('Name');
            String triggerBody = (String) triggerRec.get('Body');

            System.debug('getApexTriggerState: found trigger [' + triggerName + '] on [' + objectApiName + ']');

            // Now look for the companion handler class.
            // Strategy 1 — parse the trigger body (inside the braces only) to find
            // the actual class being called, regardless of naming convention.
            // Strategy 2 — fall back to convention-based guessing if parsing finds nothing.
            String baseName = objectApiName.endsWith('__c')
                ? objectApiName.removeEnd('__c')
                : objectApiName;

            Set<String> sfBuiltIns = new Set<String>{
                'Trigger', 'System', 'Schema', 'Database', 'Test', 'UserInfo',
                'Math', 'String', 'Date', 'DateTime', 'Decimal', 'Integer',
                'Boolean', 'List', 'Map', 'Set', 'SObject', 'Id', 'Type',
                'JSON', 'Limits', 'ApexPages', 'PageReference', 'URL', 'Blob',
                'Exception', 'CalloutException', 'DmlException'
            };

            // Only search inside the trigger body — after the opening brace —
            // to avoid matching the object name in the declaration line itself.
            String triggerBodyInner = triggerBody;
            Integer openBrace = triggerBody.indexOf('{');
            if (openBrace >= 0) {
                triggerBodyInner = triggerBody.substring(openBrace + 1);
            }

            String detectedHandlerName = null;
            // Match PascalCase word followed by a dot (static class call pattern)
            Pattern handlerPat = Pattern.compile('([A-Z][A-Za-z0-9_]+)\\.');
            Matcher handlerMatcher = handlerPat.matcher(triggerBodyInner);
            while (handlerMatcher.find()) {
                String candidate = handlerMatcher.group(1);
                if (!sfBuiltIns.contains(candidate)) {
                    detectedHandlerName = candidate;
                    System.debug('getApexTriggerState: detected handler name from trigger body: [' + detectedHandlerName + ']');
                    break;
                }
            }

            String handlerQuery;
            if (String.isNotBlank(detectedHandlerName)) {
                handlerQuery = 'SELECT Id, Name, Body FROM ApexClass'
                    + ' WHERE Name = \'' + detectedHandlerName + '\''
                    + ' AND NamespacePrefix = null'
                    + ' LIMIT 1';
            } else {
                System.debug('getApexTriggerState: body parse found nothing — using convention-based name fallback');
                handlerQuery = 'SELECT Id, Name, Body FROM ApexClass'
                    + ' WHERE Name IN (\''
                    + baseName + 'Handler\', \''
                    + baseName + 'TriggerHandler\', \''
                    + baseName + 'Helper\', \''
                    + baseName + 'Controller\')'
                    + ' AND NamespacePrefix = null'
                    + ' LIMIT 1';
            }

            String handlerJson = JSON.serialize(MetadataHelper.runToolingApiQuery(handlerQuery));

            Map<String, Object> handlerResult = (Map<String, Object>) JSON.deserializeUntyped(handlerJson);
            List<Object> handlerRecords = (List<Object>) handlerResult.get('records');

            Map<String, Object> state = new Map<String, Object>{
                'name' => triggerName,
                'body' => triggerBody
            };

            if (handlerRecords != null && !handlerRecords.isEmpty()) {
                Map<String, Object> handlerRec = (Map<String, Object>) handlerRecords[0];
                String handlerName = (String) handlerRec.get('Name');
                String handlerBody = (String) handlerRec.get('Body');
                state.put('handlerName', handlerName);
                state.put('handlerBody', handlerBody);
                System.debug('getApexTriggerState: found handler [' + handlerName + ']');
            } else {
                System.debug('getApexTriggerState: no handler class found for [' + objectApiName + ']');
            }

            return state;

        } catch (Exception e) {
            System.debug('getApexTriggerState failed for [' + objectApiName + ']: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // GET APEX CLASS STATE
    // Fetches the full body of a named Apex class via Tooling API.
    // Called directly from runOrgCheck() for class create/update/delete tickets.
    // Returns { name, body } map or null if the class does not exist.
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getApexClassState(String className) {
        try {
            System.debug('getApexClassState: fetching class [' + className + ']');

            String classQuery = 'SELECT Id, Name, Body FROM ApexClass'
                + ' WHERE Name = \'' + className + '\''
                + ' AND NamespacePrefix = null'
                + ' LIMIT 1';

            String classJson = JSON.serialize(MetadataHelper.runToolingApiQuery(classQuery));

            Map<String, Object> classResult = (Map<String, Object>) JSON.deserializeUntyped(classJson);
            List<Object> classRecords = (List<Object>) classResult.get('records');

            if (classRecords == null || classRecords.isEmpty()) {
                System.debug('getApexClassState: class [' + className + '] not found in org');
                return null;
            }

            Map<String, Object> rec = (Map<String, Object>) classRecords[0];
            System.debug('getApexClassState: found class [' + className + ']');
            return new Map<String, Object>{
                'name' => rec.get('Name'),
                'body' => rec.get('Body')
            };

        } catch (Exception e) {
            System.debug('getApexClassState failed for [' + className + ']: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // TRIGGER MERGE ENFORCER — entry point
    // ─────────────────────────────────────────────────────────────
    private static void enforceTriggerMerge(List<Object> files, Map<String, Object> orgState) {
        if (orgState == null) return;

        Map<String, Object> existingTrigger = (Map<String, Object>) orgState.get('existingTrigger');
        Map<String, Object> existingHandler = (Map<String, Object>) orgState.get('existingHandlerClass');

        if (existingTrigger == null) return;

        String existingTriggerBody = (String) existingTrigger.get('body');
        String existingHandlerBody = existingHandler != null ? (String) existingHandler.get('body') : null;

        // ── Sanitize the ORG bodies before using them as merge sources ──
        // This ensures that even if old deployed code had AnnualRevenue__c,
        // the injected methods come out with the correct field names.
        existingTriggerBody = sanitizeStandardFieldReferences(existingTriggerBody, orgState);
        if (existingHandlerBody != null) {
            existingHandlerBody = sanitizeStandardFieldReferences(existingHandlerBody, orgState);
        }

        if (files == null) return;

        for (Object rawFile : files) {
            Map<String, Object> file = (Map<String, Object>) rawFile;
            String metadataType  = (String) file.get('metadataType');
            String generatedBody = (String) file.get('xmlContent');
            if (String.isBlank(generatedBody)) continue;

            // ── Sanitize the LLM-generated code too ─────────────────
            // Catches cases where the LLM itself writes AnnualRevenue__c
            // even when orgState.existingFields clearly shows AnnualRevenue.
            generatedBody = sanitizeStandardFieldReferences(generatedBody, orgState);
            file.put('xmlContent', generatedBody);

            if (metadataType == 'ApexTrigger' && String.isNotBlank(existingTriggerBody)) {
                String merged = mergeTriggerEvents(existingTriggerBody, generatedBody);
                if (merged != null) {
                    file.put('xmlContent', merged);
                    System.debug('enforceTriggerMerge: trigger events enforced');
                }
            }

            if (metadataType == 'ApexClass' && String.isNotBlank(existingHandlerBody)) {
                String merged = mergeClassMethods(existingHandlerBody, generatedBody);
                if (merged != null) {
                    file.put('xmlContent', merged);
                    System.debug('enforceTriggerMerge: class methods enforced');
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MERGE TRIGGER EVENTS
    // Computes union of existing and generated event lists,
    // writes them back in canonical Salesforce order.
    // ─────────────────────────────────────────────────────────────
    private static String mergeTriggerEvents(String existingBody, String generatedBody) {
        try {
            Pattern evPat = Pattern.compile('(?i)on\\s+\\w+\\s*\\(([^)]+)\\)');

            Matcher em = evPat.matcher(existingBody);
            Matcher gm = evPat.matcher(generatedBody);
            if (!em.find() || !gm.find()) return null;

            Set<String> allEvents = new Set<String>();
            for (String e : em.group(1).split(',')) allEvents.add(e.trim().toLowerCase());
            for (String e : gm.group(1).split(',')) allEvents.add(e.trim().toLowerCase());

            List<String> canonical = new List<String>{
                'before insert','before update','before delete',
                'after insert','after update','after delete','after undelete'
            };
            List<String> merged = new List<String>();
            for (String ev : canonical) {
                if (allEvents.contains(ev)) merged.add(ev);
            }

            // No new events added — no change needed
            Set<String> existingSet = new Set<String>();
            for (String e : em.group(1).split(',')) existingSet.add(e.trim().toLowerCase()); // re-read since matcher advanced
            if (merged.size() == existingSet.size()) return null;

            // Rewrite the existing trigger body event list
            String mergedStr = String.join(merged, ', ');
            return existingBody.replaceFirst(
                '(?i)(on\\s+\\w+\\s*\\()([^)]+)(\\))',
                '$1' + mergedStr + '$3'
            );
        } catch (Exception e) {
            System.debug('mergeTriggerEvents failed: ' + e.getMessage());
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MERGE CLASS METHODS — no naming convention required
    // Uses brace-depth tracking to extract ALL top-level methods
    // from both existing and generated class bodies, then injects
    // any method present in existing but absent from generated.
    // Works for: dispatch(), run(), execute(), processX(), validateY()
    // — any name, any return type, any parameter signature.
    // ─────────────────────────────────────────────────────────────
    private static String mergeClassMethods(String existingBody, String generatedBody) {
        try {
            Map<String, String> existingMethods  = extractTopLevelMethods(existingBody);
            Map<String, String> generatedMethods = extractTopLevelMethods(generatedBody);

            System.debug('mergeClassMethods: existing methods  = ' + existingMethods.keySet());
            System.debug('mergeClassMethods: generated methods = ' + generatedMethods.keySet());

            // Step 1: find truly new private methods (in generated, not in existing)
            List<String> newMethodBodies = new List<String>();
            for (String name : generatedMethods.keySet()) {
                if (name == 'dispatch') continue; // handle separately
                if (!existingMethods.containsKey(name)) {
                    newMethodBodies.add(generatedMethods.get(name));
                    System.debug('mergeClassMethods: new method to inject [' + name + ']');
                }
            }

            // Step 2: find new dispatch if-blocks to add
            // Extract dispatch bodies
            String existingDispatch  = existingMethods.get('dispatch');
            String generatedDispatch = generatedMethods.get('dispatch');
            
            String newDispatchBlocks = '';
            if (existingDispatch != null && generatedDispatch != null) {
                newDispatchBlocks = extractNewDispatchBlocks(existingDispatch, generatedDispatch);
            }

            // Step 3: if nothing new, return null (no change needed)
            if (newMethodBodies.isEmpty() && String.isBlank(newDispatchBlocks)) {
                System.debug('mergeClassMethods: nothing new to merge');
                return null;
            }

            // Step 4: inject new if-blocks into existing dispatch()
            String result = existingBody;
            
            if (String.isNotBlank(newDispatchBlocks) && existingDispatch != null) {
                // Find the closing brace of the existing dispatch method body
                Integer lastBraceInDispatch = existingDispatch.lastIndexOf('}');
                if (lastBraceInDispatch >= 0) {
                    String updatedDispatch = existingDispatch.substring(0, lastBraceInDispatch)
                        + '\n        // ── Added by automation ──'
                        + newDispatchBlocks
                        + '\n    }';
                    result = result.replace(existingDispatch, updatedDispatch);
                }
            }

            // Step 5: inject new private methods before the final class closing brace
            if (!newMethodBodies.isEmpty()) {
                Integer lastBrace = result.lastIndexOf('}');
                if (lastBrace < 0) return null;
                String injection = '\n\n    // ── Added by automation ──';
                for (String m : newMethodBodies) {
                    injection += '\n    ' + m.trim() + '\n';
                }
                result = result.substring(0, lastBrace) + injection + '\n}';
            }

            System.debug('mergeClassMethods: merge complete');
            return result;

        } catch (Exception e) {
            System.debug('mergeClassMethods failed: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // EXTRACT NEW DISPATCH BLOCKS
    // Compares existing and generated dispatch() bodies.
    // Returns only the if-blocks from generated that handle
    // TriggerOperation values NOT already present in existing.
    // ─────────────────────────────────────────────────────────────
    private static String extractNewDispatchBlocks(String existingDispatch, String generatedDispatch) {
        Pattern opPat = Pattern.compile('System\\.TriggerOperation\\.(\\w+)');

        Set<String> existingOps = new Set<String>();
        Matcher em = opPat.matcher(existingDispatch);
        while (em.find()) existingOps.add(em.group(1));

        Set<String> generatedOps = new Set<String>();
        Matcher gm = opPat.matcher(generatedDispatch);
        while (gm.find()) generatedOps.add(gm.group(1));

        System.debug('extractNewDispatchBlocks: existingOps='  + existingOps);
        System.debug('extractNewDispatchBlocks: generatedOps=' + generatedOps);

        String result = '';
        for (String op : generatedOps) {
            if (existingOps.contains(op)) continue; // already handled

            // Extract the full if-statement line for this op from generated dispatch
            // Pattern: if (op == System.TriggerOperation.BEFORE_DELETE) someMethod(...);
            Pattern linePat = Pattern.compile(
                '[ \\t]*(if\\s*\\([^)]*' + op + '[^)]*\\)\\s*\\w+\\([^)]*\\)\\s*;)'
            );
            Matcher lm = linePat.matcher(generatedDispatch);
            if (lm.find()) {
                result += '\n        ' + lm.group(1).trim();
                System.debug('extractNewDispatchBlocks: adding if-block for op [' + op + ']: ' + lm.group(1).trim());
            }
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // EXTRACT TOP-LEVEL METHODS (brace-depth parser)
    //
    // Scans the class body character by character tracking brace depth.
    // Extracts every method/block that opens at depth 1 (directly inside
    // the class) and closes back to depth 1.
    // Returns Map<lowercaseMethodName, fullMethodText>
    //
    // Handles:
    //   - Any method name (dispatch, run, processX, validate, execute...)
    //   - Any return type (void, String, Map<Id,List<Account>>, custom types)
    //   - Arbitrarily deep nesting inside the method body
    //   - String literals containing { } (skipped correctly)
    //   - Single-line // comments (skipped)
    //   - Multi-line /* */ comments (skipped)
    // ─────────────────────────────────────────────────────────────
    private static Map<String, String> extractTopLevelMethods(String classBody) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(classBody)) return result;

        Integer len = classBody.length();

        // Skip past the class-level opening brace
        Integer classOpen = classBody.indexOf('{');
        if (classOpen < 0) return result;

        Integer i     = classOpen + 1;
        Integer depth = 1;

        Integer sigStart   = -1; // where the current method's signature starts
        Integer braceDepth = -1; // depth at which this block opened

        while (i < len) {
            String ch = classBody.substring(i, i + 1);

            // ── Skip single-line comments ──────────────────────────
            if (ch == '/' && i + 1 < len && classBody.substring(i+1, i+2) == '/') {
                i = classBody.indexOf('\n', i);
                if (i < 0) break;
                i++;
                continue;
            }

            // ── Skip multi-line comments ───────────────────────────
            if (ch == '/' && i + 1 < len && classBody.substring(i+1, i+2) == '*') {
                Integer endComment = classBody.indexOf('*/', i + 2);
                i = (endComment < 0) ? len : endComment + 2;
                continue;
            }

            // ── Skip string literals ───────────────────────────────
            if (ch == '\'') {
                i++;
                while (i < len) {
                    String sc = classBody.substring(i, i+1);
                    if (sc == '\\' && i + 1 < len) { i += 2; continue; }
                    if (sc == '\'') { i++; break; }
                    i++;
                }
                continue;
            }

            // ── Brace tracking ─────────────────────────────────────
            if (ch == '{') {
                if (depth == 1) {
                    // Opening a top-level block (method or static initializer)
                    // Walk backwards from here to find the start of the signature
                    sigStart = findSignatureStart(classBody, i, classOpen);
                }
                depth++;
            } else if (ch == '}') {
                depth--;
                if (depth == 1 && sigStart >= 0) {
                    // Closed a top-level block — extract it
                    String fullBlock = classBody.substring(sigStart, i + 1).trim();
                    String methodName = extractMethodName(fullBlock);
                    if (String.isNotBlank(methodName)) {
                        result.put(methodName.toLowerCase(), fullBlock);
                        System.debug('extractTopLevelMethods: found method [' + methodName + ']');
                    }
                    sigStart = -1;
                }
            }

            i++;
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // FIND SIGNATURE START
    // Walks backwards from the opening brace of a method to find
    // where its signature begins (after the previous ; or } or
    // the class opening brace itself).
    // ─────────────────────────────────────────────────────────────
    private static Integer findSignatureStart(String body, Integer openBracePos, Integer classOpenPos) {
        Integer i = openBracePos - 1;
        while (i > classOpenPos) {
            String ch = body.substring(i, i+1);
            // Signature starts right after the previous statement end or block close
            if (ch == ';' || ch == '}') return i + 1;
            i--;
        }
        return classOpenPos + 1;
    }

    // ─────────────────────────────────────────────────────────────
    // EXTRACT METHOD NAME
    // Given the full text of a method block, finds the method name:
    // the last word followed by '(' before the opening '{', that is
    // not a reserved keyword.
    //
    // Examples handled:
    //   public static void dispatch(...)            → "dispatch"
    //   private static Map<Id,List<Opp>> run(...)   → "run"
    //   global override String execute(...)         → "execute"
    //   public static void processRevenue(...)      → "processRevenue"
    // ─────────────────────────────────────────────────────────────
    private static String extractMethodName(String methodText) {
        // Take only the part before the opening brace to avoid false matches inside body
        Integer bracePos = methodText.indexOf('{');
        String signature = bracePos > 0 ? methodText.substring(0, bracePos) : methodText;

        // Find all word( occurrences in the signature
        Pattern wordParen = Pattern.compile('(\\w+)\\s*\\(');
        Matcher m = wordParen.matcher(signature);

        Set<String> reserved = new Set<String>{
            'if','else','for','while','do','switch','try','catch','finally',
            'new','return','throw','class','interface','enum','extends','implements',
            'public','private','protected','global','static','void','abstract',
            'virtual','override','testMethod','with','sharing','without',
            'String','Integer','Boolean','Long','Decimal','Double','Object',
            'Id','Date','Time','DateTime','Blob','List','Map','Set','Type',
            'System','Schema','Database','Test','Trigger','SObject',
            'insert','update','delete','upsert','merge','undelete'
        };

        String lastCandidate = null;
        while (m.find()) {
            String candidate = m.group(1);
            if (!reserved.contains(candidate)) {
                lastCandidate = candidate;
            }
        }
        return lastCandidate;
    }


    // ─────────────────────────────────────────────────────────────
    // MERGE DISPATCH CALLS
    // Ensures the generated dispatch() method contains all the
    // op == TriggerOperation.XXX branches from the existing one.
    // Called inside mergeClassMethods() after method injection.
    // ─────────────────────────────────────────────────────────────
    private static String mergeDispatchCalls(String existingDispatch, String generatedDispatch) {
        try {
            Pattern opPat = Pattern.compile('System\\.TriggerOperation\\.(\\w+)');

            Set<String> existingOps  = new Set<String>();
            Set<String> generatedOps = new Set<String>();

            Matcher em = opPat.matcher(existingDispatch);
            while (em.find()) existingOps.add(em.group(1));

            Matcher gm = opPat.matcher(generatedDispatch);
            while (gm.find()) generatedOps.add(gm.group(1));

            System.debug('mergeDispatchCalls: existingOps  = ' + existingOps);
            System.debug('mergeDispatchCalls: generatedOps = ' + generatedOps);

            // Find ops that are NEW in generated but not in existing
            // (we want to ADD new op handling, not re-inject old ones)
            List<String> missing = new List<String>();
            for (String op : generatedOps) {
                if (!existingOps.contains(op)) missing.add(op);
            }
            if (missing.isEmpty()) return null;

            // Extract the if-block for each missing op from generated dispatch
            String injectedCalls = '';
            for (String op : missing) {
                Pattern callPat = Pattern.compile(
                    '(?s)(if\\s*\\([^)]*' + op + '[^)]*\\)\\s*[^;{]+[;{][^}]*(?:\\})?)'
                );
                Matcher cm = callPat.matcher(generatedDispatch);
                if (cm.find()) {
                    injectedCalls += '\n        ' + cm.group(1).trim();
                    System.debug('mergeDispatchCalls: injecting op block for [' + op + ']');
                }
            }

            if (String.isBlank(injectedCalls)) return null;

            Integer lastBrace = existingDispatch.lastIndexOf('}');
            if (lastBrace < 0) return null;

            return existingDispatch.substring(0, lastBrace)
                + '\n        // ── New op checks ──'
                + injectedCalls
                + '\n    }';

        } catch (Exception e) {
            System.debug('mergeDispatchCalls failed: ' + e.getMessage());
            return null;
        }
    }



    // ─────────────────────────────────────────────────────────────
    // STANDARD FIELD SANITIZER
    // Strips erroneous __c suffix from standard object field names
    // in Apex code. Runs on both LLM-generated and injected-from-org
    // code before it reaches ZipBuilder.
    //
    // Uses orgState.existingFields which already contains the correct
    // API names for every standard object fetched in runOrgCheck().
    // Example: Account → [AnnualRevenue, Rating, Name, Industry, ...]
    //
    // If LLM (or old org code) wrote AnnualRevenue__c, and
    // existingFields["Account"] contains "AnnualRevenue" (no __c),
    // then AnnualRevenue__c → AnnualRevenue.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeStandardFieldReferences(String apexCode, Map<String, Object> orgState) {
        if (String.isBlank(apexCode) || orgState == null) return apexCode;

        Map<String, Object> existingFields = (Map<String, Object>) orgState.get('existingFields');
        if (existingFields == null || existingFields.isEmpty()) return apexCode;

        String result = apexCode;

        for (String objectName : existingFields.keySet()) {
            // Only process standard objects — custom objects end in __c and
            // their fields legitimately use __c, so we never touch those.
            if (objectName.endsWith('__c') || objectName.endsWith('__mdt')) continue;

            List<Object> rawFields = (List<Object>) existingFields.get(objectName);
            if (rawFields == null) continue;

            for (Object rawField : rawFields) {
                String fieldName = String.valueOf(rawField);

                // Skip if this field itself is a custom field on a standard object
                // (e.g. My_Custom_Field__c on Account — that __c is correct)
                if (fieldName.endsWith('__c')) continue;

                // If the code contains FieldName__c but the real API name is FieldName,
                // replace it. Word boundary (\b) prevents partial matches.
                String wrongName  = fieldName + '__c';
                if (result.containsIgnoreCase(wrongName)) {
                    result = result.replaceAll(
                        '(?i)\\b' + Pattern.quote(wrongName) + '\\b',
                        fieldName
                    );
                    System.debug('sanitizeStandardFieldReferences: replaced ['
                        + wrongName + '] → [' + fieldName + '] on object [' + objectName + ']');
                }
            }
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // LAYOUT XML SANITIZER
    // The LLM occasionally emits non-field placeholder sections in Layout XML
    // (Custom Links, Mobile Cards, etc.) with empty <field></field> and empty
    // <behavior></behavior> tags. The Metadata API rejects these with:
    //   "'' is not a valid value for the enum 'UiBehavior'".
    // This helper strips any <layoutItems>...</layoutItems> block whose <field>
    // or <behavior> tag is empty. It runs unconditionally for every Layout file
    // before it is added to ZipBuilder, so both Scenario A (new object + layout)
    // and Scenario B (existing object + field + layout) are protected.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeLayoutXml(String xml) {
        if (String.isBlank(xml)) return xml;
        if (!xml.contains('<layoutItems>')) return xml;

        String cleaned = xml;
        Integer removed = 0;
        Integer safety  = 500;   // bounded to avoid pathological loops

        while (safety-- > 0) {
            Integer emptyBehaviorIdx = cleaned.indexOf('<behavior></behavior>');
            Integer emptyFieldIdx    = cleaned.indexOf('<field></field>');
            Integer target = -1;
            if (emptyBehaviorIdx >= 0 && (emptyFieldIdx < 0 || emptyBehaviorIdx < emptyFieldIdx)) {
                target = emptyBehaviorIdx;
            } else if (emptyFieldIdx >= 0) {
                target = emptyFieldIdx;
            }
            if (target < 0) break;

            Integer itemStart = cleaned.lastIndexOf('<layoutItems>', target);
            Integer itemEnd   = cleaned.indexOf('</layoutItems>', target);
            if (itemStart < 0 || itemEnd < 0) break;
            itemEnd += '</layoutItems>'.length();

            cleaned = cleaned.substring(0, itemStart) + cleaned.substring(itemEnd);
            removed++;
        }

        if (removed > 0) {
            System.debug('[DEPLOY-TRACE] sanitizeLayoutXml: stripped ' + removed
                + ' broken <layoutItems> block(s) from Layout XML');
        }
        return cleaned;
    }

    // ─────────────────────────────────────────────────────────────
    // NORMALIZE TRANSLATION LANGUAGE CODE
    // Salesforce Translations metadata accepts base language codes
    // (fr, de, ja, es) not locale variants (fr_FR, de_DE).
    // A small set of compound codes IS valid (pt_BR, zh_CN etc.).
    // Strip the country suffix from all others.
    // ─────────────────────────────────────────────────────────────
    private static String normalizeTranslationLanguageCode(String lang) {
        if (String.isBlank(lang)) return lang;
        if (!lang.contains('_')) return lang;
        Set<String> validCompound = new Set<String>{
            'pt_BR', 'zh_CN', 'zh_TW', 'en_US', 'en_GB',
            'nl_BE', 'fr_CA', 'nb_NO', 'en_AU', 'en_IN'
        };
        if (validCompound.contains(lang)) return lang;
        return lang.substringBefore('_');
    }

    // ─────────────────────────────────────────────────────────────
    // SANITIZE CUSTOM LABELS XML
    // Strips any <labels> block whose <language> is not en_US from
    // the CustomLabels file. Non-English entries are auto-redirected
    // to the correct translations/{language}.translation file via
    // ZipBuilder so the translation is still deployed — just in the
    // right place.  Duplicate en_US entries are simply discarded.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeCustomLabelsXml(String xml) {
        if (String.isBlank(xml)) return xml;
        if (!xml.contains('<labels>')) return xml;

        Set<String> seenFullNames = new Set<String>();
        String sanitized = xml;
        Integer redirected = 0;
        Integer dropped    = 0;
        Integer searchFrom = 0;
        Integer safety     = 200;

        while (safety-- > 0) {
            Integer blockStart = sanitized.indexOf('<labels>', searchFrom);
            if (blockStart == -1) break;
            Integer blockEnd = sanitized.indexOf('</labels>', blockStart);
            if (blockEnd == -1) break;
            blockEnd += '</labels>'.length();

            String block = sanitized.substring(blockStart, blockEnd);

            Integer fnStart  = block.indexOf('<fullName>') + '<fullName>'.length();
            Integer fnEnd    = block.indexOf('</fullName>');
            String fullName  = (fnStart >= '<fullName>'.length() && fnEnd >= 0)
                               ? block.substring(fnStart, fnEnd).trim() : '';

            Integer lStart   = block.indexOf('<language>') + '<language>'.length();
            Integer lEnd     = block.indexOf('</language>');
            String language  = (lStart >= '<language>'.length() && lEnd >= 0)
                               ? block.substring(lStart, lEnd).trim() : 'en_US';

            Integer vStart   = block.indexOf('<value>') + '<value>'.length();
            Integer vEnd     = block.indexOf('</value>');
            String value     = (vStart >= '<value>'.length() && vEnd >= 0)
                               ? block.substring(vStart, vEnd).trim() : '';

            Boolean isEnglish   = (language == 'en_US' || language == 'en');
            Boolean isDuplicate = seenFullNames.contains(fullName);

            if (!isEnglish && String.isNotBlank(fullName) && String.isNotBlank(value)) {
                String normalizedLang = normalizeTranslationLanguageCode(language);
                String tFilePath = 'translations/' + normalizedLang + '.translation';
                String existing  = ZipBuilder.files.get(tFilePath);
                String tXml;
                if (String.isNotBlank(existing)) {
                    tXml = existing.replace('</Translations>',
                        '    <customLabels>\n        <label>' + value
                        + '</label>\n        <name>' + fullName
                        + '</name>\n    </customLabels>\n</Translations>');
                } else {
                    tXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                        + '<Translations xmlns="http://soap.sforce.com/2006/04/metadata">\n'
                        + '    <customLabels>\n'
                        + '        <label>' + value + '</label>\n'
                        + '        <name>' + fullName + '</name>\n'
                        + '    </customLabels>\n'
                        + '</Translations>';
                }
                ZipBuilder.addFile('Translations', normalizedLang, tFilePath, tXml);
                System.debug('[SANITIZE] sanitizeCustomLabelsXml: redirected label ['
                    + fullName + '] lang=[' + language + '] -> ' + tFilePath);
                redirected++;
                sanitized = sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
                // searchFrom stays at blockStart — block was removed, next block now starts there
            } else if (isDuplicate) {
                System.debug('[SANITIZE] sanitizeCustomLabelsXml: dropped duplicate label ['
                    + fullName + '] lang=[' + language + ']');
                dropped++;
                sanitized = sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
                // searchFrom stays at blockStart
            } else {
                if (String.isNotBlank(fullName)) seenFullNames.add(fullName);
                searchFrom = blockEnd; // advance past this valid block
            }
        }

        if (redirected > 0 || dropped > 0) {
            System.debug('[SANITIZE] sanitizeCustomLabelsXml: redirected=' + redirected
                + ' dropped=' + dropped + ' seenNames=' + seenFullNames);
        }
        return sanitized;
    }

    private static String sanitizeApexRegex(String apexCode) {
        if (String.isBlank(apexCode)) return apexCode;

        // Fix illegal escape sequences
        apexCode = apexCode.replace('\\+', '[+]');
        apexCode = apexCode.replace('\\d', '[0-9]');
        apexCode = apexCode.replace('\\s', '[ \\t\\n\\r]');
        apexCode = apexCode.replace('\\w', '[a-zA-Z0-9_]');
        apexCode = apexCode.replace('\\.', '[.]');

        // Fix Pattern.matches(regex, input) → Pattern.compile(regex).matcher(input).matches()
        Pattern pmPat = Pattern.compile('Pattern[.]matches[(]([^,]+),\\s*([^)]+)[)]');
        Matcher pmMatcher = pmPat.matcher(apexCode);
        apexCode = pmMatcher.replaceAll('Pattern.compile($1).matcher($2).matches()');

        return apexCode;
    }

    // ─────────────────────────────────────────────────────────────
    // XML VALIDATION
    // Validates LLM-generated XML before passing to ZipBuilder
    // ─────────────────────────────────────────────────────────────
    private static String validateXml(String metadataType, String memberName, String xmlContent) {

        if (String.isBlank(xmlContent)) {
            return 'xmlContent is empty';
        }

        // ── Check 1: Valid XML structure ───────────────────────
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(xmlContent);
        } catch (Exception e) {
            ErrorLogger.log(e);
            return 'Malformed XML: ' + e.getMessage();
        }

        // ── Check 2: Type-specific required elements ───────────
        if (metadataType == 'CustomObject') {
            // ── Standard object guard ──────────────────────────────────
            // Standard objects forbid <nameField>, <sharingModel>, <pluralLabel>,
            // <deploymentStatus>. They should have already been stripped by
            // sanitizeStandardObjectXml, but if something slips through, reject early.
            if (!memberName.endsWith('__c') && !memberName.endsWith('__mdt')) {
                if (xmlContent.contains('<nameField>')) {
                    return 'Standard object [' + memberName + '] must not contain <nameField>';
                }
                if (xmlContent.contains('<sharingModel>')) {
                    return 'Standard object [' + memberName + '] must not contain <sharingModel>';
                }
                if (xmlContent.contains('<pluralLabel>')) {
                    return 'Standard object [' + memberName + '] must not contain <pluralLabel>';
                }
                // Standard objects only need the <CustomObject> wrapper — no further required elements.
                return null;
            }

            // Check __mdt FIRST — before any content checks
            if (memberName != null && memberName.endsWith('__mdt')) {
                // Reject invalid tags LLM might hallucinate
                if (xmlContent.contains('<customMetadataType>')) {
                    return 'Invalid element <customMetadataType> — this tag does not exist in Salesforce Metadata API';
                }
                if (xmlContent.contains('<customSettingsType>')) {
                    return 'Custom Metadata Type cannot contain <customSettingsType>';
                }
                return validateRequiredElements(xmlContent,
                    new List<String>{ '<label>', '<pluralLabel>' });
            }
            // Custom Setting
            if (xmlContent.contains('<customSettingsType>')) {
                return validateRequiredElements(xmlContent,
                    new List<String>{ '<label>', '<customSettingsType>' });
            }
            // Regular Custom Object
            return validateRequiredElements(xmlContent,
                new List<String>{ '<label>', '<pluralLabel>', '<nameField>', '<sharingModel>' });
        }

        if (metadataType == 'CustomField' || xmlContent.contains('<fields>')) {
            return validateRequiredElements(xmlContent,
                new List<String>{ '<fullName>', '<label>', '<type>' });
        }

        if (metadataType == 'PermissionSet') {
            return validateRequiredElements(xmlContent,
                new List<String>{ '<label>' });
        }

        if (metadataType == 'Profile') {
            // Profile XML is valid as long as it parses
            return null;
        }

        if (metadataType == 'ValidationRule') {
            return validateRequiredElements(xmlContent,
                new List<String>{ '<fullName>', '<active>', '<errorConditionFormula>', '<errorMessage>' });
        }

        if (metadataType == 'CustomLabel' || metadataType == 'CustomLabels') {
            String baseError = validateRequiredElements(xmlContent,
                new List<String>{ '<fullName>', '<value>' });
            if (String.isNotBlank(baseError)) return baseError;
            Set<String> seenNames = new Set<String>();
            Integer searchFrom = 0;
            while (true) {
                Integer fnStart = xmlContent.indexOf('<fullName>', searchFrom);
                if (fnStart == -1) break;
                Integer fnEnd = xmlContent.indexOf('</fullName>', fnStart);
                if (fnEnd == -1) break;
                String labelName = xmlContent.substring(fnStart + '<fullName>'.length(), fnEnd).trim();
                if (seenNames.contains(labelName)) {
                    return 'Duplicate <fullName> "' + labelName + '" found in CustomLabels XML — each label must appear only once. '
                        + 'For translations use translations/{language}.translation instead.';
                }
                seenNames.add(labelName);
                searchFrom = fnEnd + '</fullName>'.length();
            }
            return null;
        }

        if (metadataType == 'NamedCredential') {
            // Always required
            String baseError = validateRequiredElements(xmlContent,
                new List<String>{ '<label>', '<endpoint>', '<protocol>', '<principalType>' });
            if (String.isNotBlank(baseError)) return baseError;

            // Reject old incorrect patterns
            if (xmlContent.contains('<principalType>Anonymous</principalType>')) {
                return 'Invalid principalType — Named Principal credentials must use NamedUser, not Anonymous';
            }
            if (xmlContent.contains('<developerName>')) {
                return 'Invalid element <developerName> inside AuthProvider XML — remove it, '
                    + 'the file name IS the developerName identity';
            }

            // Protocol-specific required fields
            if (xmlContent.contains('<protocol>Oauth</protocol>')) {
                return validateRequiredElements(xmlContent,
                    new List<String>{ '<authProvider>', '<oauthScope>' });
            }
            if (xmlContent.contains('<protocol>Password</protocol>')) {
                return validateRequiredElements(xmlContent,
                    new List<String>{ '<username>', '<password>' });
            }

            return null;
        }

        if (metadataType == 'AuthProvider') {
            // Always required
            String baseError = validateRequiredElements(xmlContent,
                new List<String>{ '<friendlyName>', '<providerType>' });
            if (String.isNotBlank(baseError)) return baseError;

            // Reject identity fields — file name IS the identity
            if (xmlContent.contains('<fullName>')) {
                return 'Invalid element <fullName> inside AuthProvider XML — remove it, the file name is the identity';
            }
            if (xmlContent.contains('<developerName>')) {
                return 'Invalid element <developerName> inside AuthProvider XML — remove it, the file name IS the developerName';
            }

            // Reject wrong element names LLM commonly hallucinates
            if (xmlContent.contains('<tokenEndpointUrl>')) {
                return 'Invalid element <tokenEndpointUrl> — correct element name is <tokenUrl>';
            }
            if (xmlContent.contains('<authorizeEndpointUrl>')) {
                return 'Invalid element <authorizeEndpointUrl> — correct element name is <authorizeUrl>';
            }
            if (xmlContent.contains('<scope>')) {
                return 'Invalid element <scope> — correct element name is <defaultScopes>';
            }
            if (xmlContent.contains('<urlSuffix>')) {
                return 'Invalid element <urlSuffix> — this element does not exist in AuthProvider metadata XML';
            }

            // Validate providerType enum value
            Set<String> validTypes = new Set<String>{
                'Apple', 'Bitbucket', 'Confluence3LO', 'Facebook', 'GitHub',
                'Google', 'Janrain', 'LinkedIn', 'Microsoft', 'MicrosoftACS',
                'MuleSoft', 'OpenIdConnect', 'Salesforce', 'Slack', 'Twitter'
            };
            Pattern ptPat = Pattern.compile('<providerType>([^<]+)</providerType>');
            Matcher ptMat = ptPat.matcher(xmlContent);
            if (ptMat.find()) {
                String pt = ptMat.group(1).trim();
                if (!validTypes.contains(pt)) {
                    return 'Invalid providerType [' + pt + ']. Valid values: '
                        + String.join(new List<String>(validTypes), ', ');
                }
                if ((pt == 'OpenIdConnect' || pt == 'MicrosoftACS')
                    && !xmlContent.contains('<authorizeUrl>')) {
                    return 'providerType ' + pt + ' requires <authorizeUrl> and <tokenUrl>';
                }
            }
            return null;
        }

        return null; // Valid
    }

    // ─────────────────────────────────────────────────────────────
    // AUTH PROVIDER XML SANITIZER
    // The LLM occasionally injects invalid identity elements like
    // <developerName>, <fullName>, or wrong element names like
    // <tokenEndpointUrl>, <authorizeEndpointUrl>, <scope>, <urlSuffix>.
    // Strip them before validation so the deploy proceeds cleanly.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeAuthProviderXml(String xml) {
        if (String.isBlank(xml)) return xml;

        // Remove entire tags that must never appear in AuthProvider XML
        List<String> forbiddenTags = new List<String>{
            'developerName', 'fullName', 'urlSuffix'
        };
        for (String tag : forbiddenTags) {
            xml = xml.replaceAll('(?i)\\s*<' + tag + '>[^<]*</' + tag + '>', '');
        }

        // Rename wrong element names to correct ones
       
        xml = xml.replace('<tokenEndpointUrl>',    '<tokenUrl>')
                .replace('</tokenEndpointUrl>',   '</tokenUrl>')
                .replace('<authorizeEndpointUrl>', '<authorizeUrl>')
                .replace('</authorizeEndpointUrl>','</authorizeUrl>')
                .replace('<scope>',               '<defaultScopes>')
                .replace('</scope>',              '</defaultScopes>');

        // LLM sometimes uses <name> instead of <friendlyName>
        // In AuthProvider XML there is no <name> element — safe to rename
        if (!xml.contains('<friendlyName>') && xml.contains('<name>')) {
            xml = xml.replace('<name>', '<friendlyName>')
                    .replace('</name>', '</friendlyName>');
        }

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // STANDARD OBJECT XML SANITIZER
    // The LLM occasionally emits elements that are only valid on custom
    // objects inside the CustomObject wrapper for standard objects like
    // Account, Case, Contact, Lead, Opportunity etc.
    //
    // Salesforce rejects these with errors like:
    //   "Cannot specify a name field for a standard object"
    //
    // Strips: <nameField>, <pluralLabel>, <deploymentStatus>, <sharingModel>
    // Safe to run on all non-__c non-__mdt CustomObject files.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeStandardObjectXml(String xml) {
        if (String.isBlank(xml)) return xml;

        Integer removedCount = 0;
        List<String> forbiddenBlocks = new List<String>{
            'nameField', 'pluralLabel', 'deploymentStatus', 'sharingModel'
        };

        for (String tag : forbiddenBlocks) {
            Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
            Matcher m = p.matcher(xml);
            String cleaned = m.replaceAll('');
            if (cleaned != xml) {
                removedCount++;
                xml = cleaned;
            }
        }

        if (removedCount > 0) {
            System.debug('[DEPLOY-TRACE] sanitizeStandardObjectXml: removed '
                + removedCount + ' forbidden element(s) from standard object XML');
        }
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // CUSTOM METADATA TYPE SANITIZER
    // The LLM occasionally adds <customSettingsType> (belongs to Custom
    // Settings only) or the non-existent <customMetadataType> tag inside
    // __mdt object XML.  Salesforce rejects these with:
    //   "Custom Metadata Type cannot contain <customSettingsType>"
    //
    // Strips: <customSettingsType>, <customMetadataType>
    // Safe to run on all __mdt CustomObject files.
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeMdtObjectXml(String xml) {
        if (String.isBlank(xml)) return xml;

        Integer removedCount = 0;
        List<String> forbiddenTags = new List<String>{
            'customSettingsType', 'customMetadataType'
        };

        for (String tag : forbiddenTags) {
            Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
            Matcher m = p.matcher(xml);
            String cleaned = m.replaceAll('');
            if (cleaned != xml) {
                removedCount++;
                xml = cleaned;
            }
        }

        if (removedCount > 0) {
            System.debug('[DEPLOY-TRACE] sanitizeMdtObjectXml: removed '
                + removedCount + ' forbidden element(s) from __mdt object XML');
        }
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE STANDARD-OBJECT TAB SANITIZER
    // The LLM occasionally adds <tabVisibilities> blocks for standard
    // objects (Account, Case, Contact etc.) in Profile XML.
    //
    // Salesforce rejects these with:
    //   "no CustomTab named Account found"
    // because standard objects use built-in tabs, not CustomTabs.
    //
    // Strips any <tabVisibilities> block whose <tab> value does NOT
    // end with __c (i.e. is a standard-object tab reference).
    // ─────────────────────────────────────────────────────────────
    private static String sanitizeProfileStandardObjectTabs(String xml) {
        if (String.isBlank(xml) || !xml.contains('<tabVisibilities>')) return xml;

        // Match full <tabVisibilities>…</tabVisibilities> blocks
        Pattern tvPat = Pattern.compile(
            '(?s)\\s*<tabVisibilities>\\s*<tab>([^<]+)</tab>.*?</tabVisibilities>'
        );
        Matcher m = tvPat.matcher(xml);

        List<String> toRemove = new List<String>();
        while (m.find()) {
            String tabName = m.group(1).trim();
            if (!tabName.endsWith('__c')) {
                toRemove.add(m.group(0));
                System.debug('[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: '
                    + 'removing tabVisibilities for standard object tab [' + tabName + ']');
            }
        }

        for (String block : toRemove) {
            xml = xml.replace(block, '');
        }

        if (!toRemove.isEmpty()) {
            System.debug('[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: removed '
                + toRemove.size() + ' standard-object tabVisibilities block(s)');
        }
        return xml;
    }

    // Remove unsupported Profile elements that LLM may emit.
    // Example: <cloneFrom> is not valid in Profile metadata source format.
    private static String sanitizeProfileXml(String xml) {
        if (String.isBlank(xml)) return xml;
        if (!xml.contains('<cloneFrom>')) return xml;
        String cleaned = xml.replaceAll('(?s)\\s*<cloneFrom>.*?</cloneFrom>', '');
        System.debug('[DEPLOY-TRACE] sanitizeProfileXml: removed unsupported <cloneFrom> element');
        return cleaned;
    }

    // ── FIX: AUTO-INJECT <businessProcess> FOR PROCESS-DRIVEN OBJECTS ─────────
    // Case, Lead, Opportunity and Solution record types REQUIRE <businessProcess>.
    // If the LLM omits it → "Required field is missing: businessProcess"
    // This injects the first available process from orgState after <active>.
    private static final Map<String, String> PROCESS_DRIVEN_OBJECTS = new Map<String, String>{
        'Case' => 'Case', 'Lead' => 'Lead', 'Opportunity' => 'Opportunity', 'Solution' => 'Solution'
    };

    private static String injectBusinessProcessIfMissing(
        String xml, String memberName, Map<String, Object> orgState
    ) {
        if (String.isBlank(xml) || !xml.contains('<recordTypes>')) return xml;
        if (!PROCESS_DRIVEN_OBJECTS.containsKey(memberName)) return xml;
        String tableEnumOrId = PROCESS_DRIVEN_OBJECTS.get(memberName);

        String bpName = null;
        Object rawBps = orgState != null ? orgState.get('existingBusinessProcesses') : null;
        if (rawBps != null) {
            try {
                Map<String, Object> bpMap = (Map<String, Object>) JSON.deserializeUntyped(
                    JSON.serialize(rawBps)
                );
                Object bpListRaw = bpMap.get(tableEnumOrId);
                if (bpListRaw instanceof List<Object>) {
                    List<Object> bpList = (List<Object>) bpListRaw;
                    if (!bpList.isEmpty()) bpName = String.valueOf(bpList[0]);
                }
            } catch (Exception e) {
                System.debug('[DEPLOY-TRACE] injectBusinessProcess: failed to parse bps — ' + e.getMessage());
            }
        }

        if (String.isBlank(bpName)) {
            System.debug('[DEPLOY-TRACE] injectBusinessProcess: no Business Process found for ['
                + memberName + '] in orgState — deploy may fail');
            return xml;
        }

        Pattern rtPat = Pattern.compile('(?s)<recordTypes>(.*?)</recordTypes>');
        Matcher rm = rtPat.matcher(xml);
        List<String> origBlocks = new List<String>();
        List<String> fixedBlocks = new List<String>();

        while (rm.find()) {
            String fullBlock = rm.group(0);
            if (fullBlock.contains('<businessProcess>')) continue;
            String fixedBlock = fullBlock.replace(
                '</active>',
                '</active> <businessProcess>' + bpName + '</businessProcess>');
            origBlocks.add(fullBlock);
            fixedBlocks.add(fixedBlock);
            System.debug('[DEPLOY-TRACE] injectBusinessProcess: injected ['
                + bpName + '] into ' + memberName + ' record type');
        }

        for (Integer i = 0; i < origBlocks.size(); i++) {
            xml = xml.replace(origBlocks[i], fixedBlocks[i]);
        }
        return xml;
    }

    // ── FIX: AUTO-PREFIX BARE LAYOUT NAMES IN PROFILE <layoutAssignments> ───────
    // LLM sometimes emits <layout>Account Layout</layout> instead of the required
    // <layout>Account-Account Layout</layout> format, causing:
    //   "In field: layout - no Layout named Account Layout found"
    // This sanitizer infers the ObjectName prefix from the sibling <recordType> tag.
    private static String sanitizeProfileLayoutAssignments(String xml) {
        if (String.isBlank(xml) || !xml.contains('<layoutAssignments>')) return xml;

        // Pass 1: build a map of objName → known layout fullName
        // from blocks that DO have a <recordType> tag (those are reliable)
        Map<String, String> objToLayout = new Map<String, String>();
        Pattern blockPat = Pattern.compile('(?s)<layoutAssignments>(.*?)</layoutAssignments>');
        Matcher bm = blockPat.matcher(xml);
        while (bm.find()) {
            String inner1 = bm.group(1);
            Pattern rtPat = Pattern.compile('<recordType>([^.<]+)[.]([^<]+)</recordType>');
            Matcher rm = rtPat.matcher(inner1);
            if (!rm.find()) continue;
            String objName = rm.group(1).trim();
            Pattern lPat = Pattern.compile('<layout>([^<]+)</layout>');
            Matcher lm = lPat.matcher(inner1);
            if (!lm.find()) continue;
            String layoutVal = lm.group(1).trim();
            // Store the prefixed layout or the object name at minimum
            if (layoutVal.contains('-')) {
                objToLayout.put(objName, layoutVal.substringBefore('-'));
            } else {
                objToLayout.put(objName, objName); // at least we know the object
            }
        }

        // Pass 2: fix all unprefixed layout values
        bm = blockPat.matcher(xml);
        List<String> origBlocks = new List<String>();
        List<String> fixedBlocks = new List<String>();

        while (bm.find()) {
            String fullBlock = bm.group(0);
            String inner1    = bm.group(1);

            Pattern layoutPat = Pattern.compile('<layout>([^<]+)</layout>');
            Matcher lm = layoutPat.matcher(inner1);
            if (!lm.find()) continue;
            String layoutVal = lm.group(1).trim();
            if (layoutVal.contains('-')) continue; // already prefixed

            String objName = null;

            // Try sibling <recordType> first
            Pattern rtPat = Pattern.compile('<recordType>([^.<]+)[.]([^<]+)</recordType>');
            Matcher rm = rtPat.matcher(inner1);
            if (rm.find()) {
                objName = rm.group(1).trim();
            }
            // Try inferring from layout name ("Case Layout" → "Case")
            if (String.isBlank(objName) && layoutVal.contains(' ')) {
                objName = layoutVal.substringBefore(' ').trim();
            }
            // Try inferring from other blocks in the same profile (for bare names like "Default")
            if (String.isBlank(objName) && !objToLayout.isEmpty()) {
                objName = objToLayout.values()[0]; // best guess from same profile
            }

            if (String.isBlank(objName)) continue;

            String fixedLayout = objName + '-' + layoutVal;
            String fixedBlock  = fullBlock.replace(
                '<layout>' + layoutVal + '</layout>',
                '<layout>' + fixedLayout + '</layout>'
            );
            origBlocks.add(fullBlock);
            fixedBlocks.add(fixedBlock);
            System.debug('[DEPLOY-TRACE] sanitizeProfileLayoutAssignments: '
                + layoutVal + ' -> ' + fixedLayout);
        }

        for (Integer i = 0; i < origBlocks.size(); i++) {
            xml = xml.replace(origBlocks[i], fixedBlocks[i]);
        }
        return xml;
    }

    // ── FIX: AUTO-INJECT/CORRECT <--master--> recordTypeVisibilities ──────────
    // Salesforce requires that for every object with recordTypeVisibilities in a
    // profile, exactly one entry has default=true. When the new RT is default=false,
    // the Master entry must be default=true + visible=true.
    // The LLM often omits Master entirely or sets it incorrectly.
    private static String sanitizeProfileMasterRecordType(String xml) {
        if (String.isBlank(xml) || !xml.contains('<recordTypeVisibilities>')) return xml;

        // Step 1: Remove any bogus ObjectName.Master entries — these don't exist in Salesforce
        Pattern masterEntryPat = Pattern.compile(
            '(?s)\\s*<recordTypeVisibilities>\\s*<recordType>[^<]+\\.Master</recordType>.*?</recordTypeVisibilities>'
        );
        Matcher mm = masterEntryPat.matcher(xml);
        while (mm.find()) {
            System.debug('[DEPLOY-TRACE] sanitizeProfileMasterRecordType: removing bogus Master entry: ' + mm.group(0));
            xml = xml.replace(mm.group(0), '');
            mm = masterEntryPat.matcher(xml); // re-match after replace
        }

        // Step 2: Per object, ensure at least one recordTypeVisibility has default=true
        // Collect objects and whether any RT has default=true
        Map<String, Boolean> objHasDefault = new Map<String, Boolean>();
        Map<String, String>  objFirstBlock  = new Map<String, String>();  // first RT block per object

        Pattern blockPat = Pattern.compile('(?s)<recordTypeVisibilities>(.*?)</recordTypeVisibilities>');
        Matcher bm = blockPat.matcher(xml);
        while (bm.find()) {
            String inner2 = bm.group(1);
            Pattern rtPat = Pattern.compile('<recordType>([^.<]+)[.]([^<]+)</recordType>');
            Matcher rm = rtPat.matcher(inner2);
            if (!rm.find()) continue;
            String objName   = rm.group(1).trim();
            Boolean isDef    = inner2.contains('<default>true</default>');
            if (!objHasDefault.containsKey(objName)) {
                objHasDefault.put(objName, false);
                objFirstBlock.put(objName, bm.group(0)); // remember full first block
            }
            if (isDef) objHasDefault.put(objName, true);
        }

        // Step 3: For any object with no default=true RT, promote the first RT to default=true
        for (String objName : objHasDefault.keySet()) {
            if (!objHasDefault.get(objName)) {
                String firstBlock = objFirstBlock.get(objName);
                String fixedBlock = firstBlock.replace(
                    '<default>false</default>',
                    '<default>true</default>'
                );
                xml = xml.replace(firstBlock, fixedBlock);
                System.debug('[DEPLOY-TRACE] sanitizeProfileMasterRecordType: promoted ['
                    + objName + '] first RT to default=true (no default existed)');
            }
        }

        return xml;
    }

    // ── FIX: SAFETY NET — NEVER DEPLOY LAYOUT FILES FOR STANDARD OBJECTS ─────
    // Standard object layouts (Account, Case, Contact, Lead, Opportunity …)
    // already exist in every org and MUST NOT be deployed via the Metadata API.
    // Deploying them causes "Layout must contain an item for required layout field"
    // because the LLM-generated XML is always incomplete.
    // This guard drops any Layout file whose memberName starts with a known
    // standard-object name, before the file ever reaches the ZIP.
    private static final Set<String> STANDARD_OBJECTS = new Set<String>{
        'Account','Case','Contact','Lead','Opportunity','Task','Event',
        'Campaign','Order','Contract','Asset','Solution','Product2','Pricebook2',
        'User','UserRole','Group','Territory','Forecast','ForecastingItem'
    };
    private static Boolean isStandardObjectLayout(String memberName) {
        if (String.isBlank(memberName) || !memberName.contains('-')) return false;
        String objPart = memberName.substringBefore('-');
        return STANDARD_OBJECTS.contains(objPart);
    }

    // Adds a single destructive member entry to destructiveChangesPost.xml,
    // creating or merging the file as needed.
    private static void appendDestructiveMember(String metadataType, String memberName) {
        String typeEsc   = escapeXmlValue(metadataType);
        String memberEsc = escapeXmlValue(memberName);
        String existing  = ZipBuilder.files.get('destructiveChangesPost.xml');

        String typeBlock = '\n    <types>'
            + '\n        <members>' + memberEsc + '</members>'
            + '\n        <name>' + typeEsc + '</name>'
            + '\n    </types>';

        String xml;
        if (String.isBlank(existing)) {
            xml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                + typeBlock
                + '\n    <version>61.0</version>'
                + '\n</Package>';
        } else if (existing.contains('<version>')) {
            xml = existing.replace('<version>', typeBlock + '\n    <version>');
        } else if (existing.contains('</Package>')) {
            xml = existing.replace('</Package>', typeBlock + '\n</Package>');
        } else {
            xml = existing + typeBlock;
        }

        ZipBuilder.addFile('__destructive__', memberName, 'destructiveChangesPost.xml', xml);
    }

    private static String escapeXmlValue(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

    // ─────────────────────────────────────────────────────────────
    // EXTRACT LWC COMPONENT NAME FROM TICKET TEXT
    // Tries four regex patterns in priority order.
    // Returns the camelCase/lowercase component name or null if not found.
    // Priority 1: explicit — "called myComponent", "named myComponent"
    // Priority 2: "the myComponent component/lwc"
    // Priority 3: "lwc/component myComponent"
    // Priority 4: "update/modify/fix the myComponent"
    // If none match → returns null and LLM names the component itself.
    // ─────────────────────────────────────────────────────────────
    private static String extractLwcComponentName(String ticketText) {
        if (String.isBlank(ticketText)) return null;

        // Priority 1: explicit "called myComponent" or "named myComponent"
        Pattern p1 = Pattern.compile('(?i)(?:called|named)\\s+([a-z][A-Za-z0-9]+)');
        Matcher m1 = p1.matcher(ticketText);
        if (m1.find()) {
            System.debug('extractLwcComponentName: matched P1 → ' + m1.group(1));
            return m1.group(1);
        }

        // Priority 2: "the myComponent component" or "the myComponent lwc"
        Pattern p2 = Pattern.compile(
            '(?i)(?:the\\s+)?([a-z][A-Za-z0-9]+)\\s+(?:lwc|component|lightning web component|lightning component)'
        );
        Matcher m2 = p2.matcher(ticketText);
        if (m2.find()) {
            System.debug('extractLwcComponentName: matched P2 → ' + m2.group(1));
            return m2.group(1);
        }

        // Priority 3: "lwc myComponent" or "component myComponent"
        Pattern p3 = Pattern.compile('(?i)(?:lwc|component)\\s+([a-z][A-Za-z0-9]+)');
        Matcher m3 = p3.matcher(ticketText);
        if (m3.find()) {
            System.debug('extractLwcComponentName: matched P3 → ' + m3.group(1));
            return m3.group(1);
        }

        // Priority 4: "update/modify/edit/fix the myComponent"
        Pattern p4 = Pattern.compile(
            '(?i)(?:update|modify|edit|fix|change)\\s+(?:the\\s+)?([a-z][A-Za-z0-9]+)'
        );
        Matcher m4 = p4.matcher(ticketText);
        if (m4.find()) {
            System.debug('extractLwcComponentName: matched P4 → ' + m4.group(1));
            return m4.group(1);
        }

        System.debug('extractLwcComponentName: no match — LLM will name the component');
        return null;
    }

    // ─────────────────────────────────────────────────────────────
    // GET LWC COMPONENT STATE
    // Reads an existing LWC bundle from the org via Tooling API.
    // Two queries:
    //   Step 1: LightningComponentBundle → get Id by DeveloperName
    //   Step 2: LightningComponentResource → get html, js, meta sources
    //
    // Returns null if the component does not exist (= create mode).
    // Returns a map with keys: developerName, html, js, metaXml (= merge mode).
    // Called directly from runOrgCheck() — no LLM tool loop involved.
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getLwcComponentState(String developerName) {
        try {
            System.debug('getLwcComponentState: checking for LWC [' + developerName + ']');

            // Step 1 — find the bundle Id
            String bundleQuery = 'SELECT Id, DeveloperName FROM LightningComponentBundle'
                + ' WHERE DeveloperName = \'' + developerName + '\''
                + ' AND NamespacePrefix = null'
                + ' LIMIT 1';

            Map<String, Object> bundleResult = MetadataHelper.runToolingApiQuery(bundleQuery);
            List<Object> bundleRecords = (List<Object>) bundleResult.get('records');

            if (bundleRecords == null || bundleRecords.isEmpty()) {
                System.debug('getLwcComponentState: no bundle found for [' + developerName + '] — create mode');
                return null;
            }

            Map<String, Object> bundleRec = (Map<String, Object>) bundleRecords[0];
            String bundleId = (String) bundleRec.get('Id');
            System.debug('getLwcComponentState: found bundle id=' + bundleId);

            // Step 2 — fetch the component resource files
            String resourceQuery = 'SELECT FilePath, Source FROM LightningComponentResource'
                + ' WHERE LightningComponentBundleId = \'' + bundleId + '\''
                + ' LIMIT 10';

            Map<String, Object> resourceResult = MetadataHelper.runToolingApiQuery(resourceQuery);
            List<Object> resourceRecords = (List<Object>) resourceResult.get('records');

            if (resourceRecords == null || resourceRecords.isEmpty()) {
                System.debug('getLwcComponentState: bundle exists but no resources returned — treating as create mode');
                return null;
            }

            String htmlSource = null;
            String jsSource   = null;
            String metaXml    = null;

            for (Object raw : resourceRecords) {
                Map<String, Object> rec = (Map<String, Object>) raw;
                String filePath = (String) rec.get('FilePath');
                String source   = (String) rec.get('Source');
                if (String.isBlank(filePath)) continue;

                // FilePath pattern: lwc/componentName/componentName.html
                if (filePath.endsWith('.html'))         htmlSource = source;
                else if (filePath.endsWith('-meta.xml')) metaXml   = source;
                else if (filePath.endsWith('.js'))       jsSource   = source;
            }

            System.debug('getLwcComponentState: resolved'
                + ' html=' + (htmlSource != null)
                + ' js='   + (jsSource   != null)
                + ' meta=' + (metaXml    != null));

            return new Map<String, Object>{
                'developerName' => developerName,
                'html'          => htmlSource,
                'js'            => jsSource,
                'metaXml'       => metaXml
            };

        } catch (Exception e) {
            System.debug('getLwcComponentState failed for [' + developerName + ']: ' + e.getMessage());
            ErrorLogger.log(e);
            return null;
        }
    }

    private static String validateRequiredElements(String xml, List<String> requiredElements) {
        for (String element : requiredElements) {
            if (!xml.contains(element)) {
                return 'Missing required element: ' + element;
            }
        }
        return null;
    }

    // ─────────────────────────────────────────────────────────────
    // CALL GROQ API
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> callGroq(
        List<Map<String, Object>> messages,
        List<Map<String, Object>> tools,
        String toolChoice              // 'auto', 'none', or null
    ) {
        HttpRequest req = new HttpRequest();

        apiCallCount++;
        System.debug('── GROQ API CALL #' + apiCallCount);

        req.setEndpoint(GROQ_BASE_URL + '/chat/completions');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + GROQ_API_KEY);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);

        Map<String, Object> body = new Map<String, Object>{
            'model'      => GROQ_MODEL,
            'messages'   => messages,
            'max_tokens' => 4096
        };

        if (tools != null && !tools.isEmpty()) {
            body.put('tools', tools);
            // Use provided toolChoice, default to 'auto'
            body.put('tool_choice', String.isNotBlank(toolChoice) ? toolChoice : 'auto');
        }

        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        System.debug('Groq HTTP Status: ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            System.debug('Groq API Error: ' + res.getBody());
            throw new LLMException('Groq API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        


        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        Map<String, Object> usage = (Map<String, Object>) response.get('usage');
        if (usage != null) {
            Integer prompt     = (Integer) usage.get('prompt_tokens');
            Integer completion = (Integer) usage.get('completion_tokens');
            Integer total      = (Integer) usage.get('total_tokens');

            totalPromptTokens     += prompt;
            totalCompletionTokens += completion;
            totalTokens           += total;

            System.debug('TOKENS [call #' + apiCallCount + '] >> '
                + 'prompt=' + prompt
                + ' completion=' + completion
                + ' total=' + total);
        }

        return response;
    }


    // -----------------------------------------------------------------
    // SYSTEM PROMPT (content moved to LLM_Prompt__mdt CMT records)
    // -----------------------------------------------------------------

    private static String buildXmlGenerationSystemPrompt() {
        return PromptService.assemblePrompt(
            new Set<String>(PromptService.getRoutableFeatureKeys())
        );
    }


    // ─────────────────────────────────────────────────────────────
    // USER PROMPTS
    // ─────────────────────────────────────────────────────────────

    private static String buildXmlGenerationUserPrompt(
        String issueKey,
        String summary,
        String description,
        Map<String, Object> orgState
    ) {
        String prompt = 'Jira Issue: ' + issueKey
            + '\nSummary: ' + summary
            + '\nDescription: ' + (String.isBlank(description) ? '(no description)' : description);

            if (!StaticResourceHelper.currentAttachments.isEmpty()) {
                prompt += '\n\nATTACHMENTS ON THIS TICKET:';
                for (String fileName : StaticResourceHelper.currentAttachments.keySet()) {
                    String mime = StaticResourceHelper.currentAttachments.get(fileName).get('mimeType');
                    prompt += '\n- ' + fileName + ' (' + mime + ')';
                    if (fileName.toLowerCase().endsWith('.csv')) {
                        prompt += '\n  → CSV file — use dmlOperations csvProcess, do NOT read content yourself';
                    }
                }
            }


        if (orgState.containsKey('csvFiles')) {
            prompt += '\n\nCSV FILES HAVE BEEN PRE-READ BY APEX (rows are cached server-side).'
                + '\nColumn names and row counts are in org state under "csvFiles".'
                + '\nFor each CSV file — use dmlOperations with type csvProcess.'
                + '\nIdentify the csvType from the column names in org state.'
                + '\nDo NOT generate XML for CSV data. Apex handles it via csvProcess.';
        }

        prompt += '\n\nCURRENT ORG STATE (from pre-checks):\n' + JSON.serialize(orgState);
        prompt += '\n\nGenerate the Salesforce Metadata XML files needed to implement this ticket. '
               + 'Return ONLY the JSON object as specified in the system prompt.';

        return prompt;
    }

    // ─────────────────────────────────────────────────────────────
    // UTILITY — Clean JSON response from LLM
    // Strips markdown code fences if present
    // ─────────────────────────────────────────────────────────────
    private static String cleanJsonResponse(String response) {
        if (String.isBlank(response)) return '{}';

        String cleaned = response.trim();

        // Strip ```json ... ``` fences
        if (cleaned.startsWith('```json')) {
            cleaned = cleaned.substring(7);
        } else if (cleaned.startsWith('```')) {
            cleaned = cleaned.substring(3);
        }

        if (cleaned.endsWith('```')) {
            cleaned = cleaned.substring(0, cleaned.length() - 3);
        }

        cleaned = cleaned.trim();

        // Remove trailing commas before } and ] — common LLM JSON generation defect.
        // e.g. { "key": "value", }  →  { "key": "value" }
        cleaned = cleaned.replaceAll(',\\s*\\}', '}');
        cleaned = cleaned.replaceAll(',\\s*\\]', ']');

        return cleaned;
    }

    // ─────────────────────────────────────────────────────────────
    // METADATA SESSION ID
    // Uses VF page trick to get a full session ID that works with
    // the Metadata API SOAP endpoint (same pattern as ProfileHelper).
    // Falls back to UserInfo.getSessionId() in tests or on error.
    // ─────────────────────────────────────────────────────────────
    private static String getMetadataSessionId() {
        if (Test.isRunningTest()) return UserInfo.getSessionId();
        try {
            PageReference vfPage = Page.SessionId;
            String content = vfPage.getContent().toString();
            Integer s = content.indexOf('Start_Of_Session_Id') + 'Start_Of_Session_Id'.length();
            Integer e = content.indexOf('End_Of_Session_Id');
            return content.substring(s, e);
        } catch (Exception ex) {
            ErrorLogger.log(ex);
            return UserInfo.getSessionId();
        }
    }

    public class LLMException extends Exception {}
}