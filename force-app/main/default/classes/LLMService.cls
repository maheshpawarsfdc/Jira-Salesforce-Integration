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

        // Ambient ticket context so any ErrorLogger.log() in deep helpers tags this key.
        ErrorLogger.currentJiraKey = issueKey;

        System.debug('JIRA AI ASSISTANT — NEW REQUEST');
        System.debug('► Issue Key  : ' + issueKey);
        System.debug('► Summary    : ' + summary);
        System.debug('► Description: ' + description);

        // ── STAGE 1: Read org state ────────────────────────────
        // runOrgCheck  — pure Apex, no LLM call, always runs.
        //                Covers: existing fields/objects, sharing models,
        //                        layout structure, CSV pre-read.
        // runReadStage — LLM tool-calling loop, only when the ticket
        //                needs dynamic lookups Apex can't predict:
        //                e.g. apex class names, existing PS/profile details,
        //                permission set membership, custom label values, etc.
        System.debug('── STAGE 1: Reading org state...');
        Map<String, Object> orgState = runOrgCheck(summary, description);

        if (needsReadStage(summary, description)) {
            System.debug('── STAGE 1b: Ticket needs dynamic org lookups — running LLM read stage...');
            Map<String, Object> readState = runReadStage(issueKey, summary, description);
            orgState.putAll(readState);
            System.debug('── STAGE 1b complete. Merged org state.');
        }

        System.debug('── Org check complete. orgState: ' + JSON.serialize(orgState));

        // ── STAGE 2: Generate XML files ────────────────────────
        // LLM generates all XML based on ticket + org state
        System.debug('── STAGE 2: Generating XML...');
        String result = runXmlGenerationStage(issueKey, summary, description, orgState);
        System.debug('── STAGE 2 complete.');


    // ── ZIP DEPLOY (async) ─────────────────────────────────────
    // Flush DML first — enqueue follows immediately, no callout after
    if (ZipBuilder.hasFiles()) {
        flushDmlQueues();
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
                        ErrorLogger.log(e);
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
                            ErrorLogger.log(e);
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
            ErrorLogger.log(e);
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
    // NEEDS READ STAGE?
    // Determines whether the ticket requires a full LLM read stage
    // (tool-calling loop) on top of the lean Apex-only runOrgCheck.
    //
    // Triggers when the ticket involves lookups that Apex cannot
    // cheaply predict from the ticket text alone:
    //   - Apex class/page access grants (need full class list)
    //   - Profile/PS updates (need existing permission details)
    //   - Custom label reads/updates (need existing label values)
    //   - Tooling API queries for metadata not in Schema describe
    //
    // Keep this list tight — every true result costs one extra
    // LLM tool-calling loop before XML generation.
    // ─────────────────────────────────────────────────────────────
    private static Boolean needsReadStage(String summary, String description) {
        String t = (summary + ' ' + description).toLowerCase();

        // NOTE: 'named credential' intentionally removed — NC state is now fetched
        // directly in runOrgCheck() via getNamedCredentialsState() (Metadata SOAP),
        // so no LLM tool-calling loop is needed for NC tickets.
        return t.contains('apex class')
            || t.contains('class access')
            || t.contains('apex classes')
            || t.contains('visualforce')
            || t.contains('page access')
            || t.contains('custom label')
            || t.contains('update label');
    }

    // ─────────────────────────────────────────────────────────────
    // STAGE 1 — READ ORG STATE (LLM tool-calling loop)
    // LLM uses read-only tools to understand current org state
    // Returns a map of what it found
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> runReadStage(String issueKey, String summary, String description) {

        List<Map<String, Object>> messages = new List<Map<String, Object>>{
            new Map<String, Object>{
                'role'    => 'system',
                'content' => buildReadStageSystemPrompt()
            },
            new Map<String, Object>{
                'role'    => 'user',
                'content' => buildUserPrompt(issueKey, summary, description)
            }
        };

        // Run tool calling loop with READ-ONLY tools
        String orgStateJson = runToolCallingLoop(messages, getReadOnlyTools());

        System.debug('── STAGE 1 raw response: ' + orgStateJson);

        // Parse the JSON response from LLM
        try {
            // Strip markdown code fences if present
            String cleaned = cleanJsonResponse(orgStateJson);
            Map<String, Object> orgState = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            System.debug('── STAGE 1 parsed orgState successfully');
            return orgState;
        } catch (Exception e) {
            System.debug('── STAGE 1 JSON parse failed: ' + e.getMessage() + ' — using empty state');
            ErrorLogger.log(e);
            return new Map<String, Object>{ 'rawResponse' => orgStateJson };
        }
    }

    // ─────────────────────────────────────────────────────────────
    // STAGE 2 — XML GENERATION
    // LLM generates all XML files needed for the deployment
    // ─────────────────────────────────────────────────────────────
    private static String runXmlGenerationStage(
        String issueKey,
        String summary,
        String description,
        Map<String, Object> orgState
    ) {
        List<Map<String, Object>> messages = new List<Map<String, Object>>{
            new Map<String, Object>{
                'role'    => 'system',
                'content' => buildXmlGenerationSystemPrompt()
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

                // ── Strip standard-object tabVisibilities from Profile XML ──
                // Profile <tabVisibilities> must only reference existing CustomTabs.
                // Standard objects (Account, Case etc.) have no CustomTab —
                // referencing them causes: "no CustomTab named X found".
                if (metadataType == 'Profile') {
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

                // Validate XML before adding to ZipBuilder
                String validationError = validateXml(metadataType, memberName, xmlContent);
                if (String.isNotBlank(validationError)) {
                    System.debug('processXmlGenerationResponse: XML validation FAILED for ['
                        + filePath + ']: ' + validationError);
                    FunctionHelper.hadError = true;
                    return 'Error: Invalid XML generated for ' + filePath + ': ' + validationError;
                }

                if (zip2FilePaths.contains(filePath)) {
                    zip2Files.put(filePath, xmlContent);
                    if (!zip2MetadataTypes.containsKey(metadataType)) {
                        zip2MetadataTypes.put(metadataType, new Set<String>());
                    }
                    zip2MetadataTypes.get(metadataType).add(memberName);
                    System.debug('processXmlGenerationResponse: held back [' + filePath + '] for ZIP 2');
                    System.debug('[DEPLOY-TRACE] route ZIP2 <- ' + metadataType + ' / ' + filePath);
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
                ZipBuilder.addFile(metadataType, memberName, filePath, xmlContent);

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
                System.debug('[DEPLOY-TRACE] route ZIP1 <- ' + metadataType + ' / ' + filePath);

                // ADD THIS — see exactly what XML is going into the ZIP
                System.debug('=== FILE ADDED TO ZIP ===');
                System.debug('Path: ' + filePath);
                System.debug('Type: ' + metadataType);
                System.debug('XML: ' + xmlContent);
                System.debug('========================');
            }
        }

        // ── Scenario A backstop — force layout for any new CustomObject when
        // the LLM forgot to emit one. Adds synthesized Layout entries directly
        // to zip2Files so the staging block below picks them up.
        backstopMissingLayoutsForNewObjects(files, orgState, zip2Files, zip2MetadataTypes);

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

            List<String> fieldNames = extractFieldFullNamesFromObjectXml(newObjectXml.get(objApi));
            String objLabel    = objApi.endsWith('__c') ? objApi.removeEnd('__c').replace('_', ' ') : objApi;
            String layoutMember = objApi + '-' + objLabel + ' Layout';
            String layoutPath   = 'layouts/' + layoutMember + '.layout';
            String layoutXml    = buildDefaultLayoutXml(fieldNames);

            zip2Files.put(layoutPath, layoutXml);
            if (!zip2MetadataTypes.containsKey('Layout')) {
                zip2MetadataTypes.put('Layout', new Set<String>());
            }
            zip2MetadataTypes.get('Layout').add(layoutMember);

            System.debug('[DEPLOY-TRACE] *** SCENARIO A BACKSTOP FIRED *** object=' + objApi
                + ' | LLM omitted Layout — synthesized default with ' + fieldNames.size()
                + ' field(s) | path=' + layoutPath + ' | layoutMember=' + layoutMember);
        }
    }

    private static List<String> extractFieldFullNamesFromObjectXml(String customObjectXml) {
        List<String> result = new List<String>();
        if (String.isBlank(customObjectXml)) return result;
        Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
        Matcher fbm = fieldsBlock.matcher(customObjectXml);
        Pattern fnPat = Pattern.compile('<fullName>([^<]+)</fullName>');
        while (fbm.find()) {
            Matcher fnm = fnPat.matcher(fbm.group(1));
            if (fnm.find()) result.add(fnm.group(1));
        }
        return result;
    }

    private static String buildDefaultLayoutXml(List<String> fieldNames) {
        String s = '<?xml version="1.0" encoding="UTF-8"?>\n';
        s += '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';
        s += '    <layoutSections>\n';
        s += '        <editHeading>true</editHeading>\n';
        s += '        <label>Information</label>\n';
        s += '        <layoutColumns>\n';
        s += '            <layoutItems>\n';
        s += '                <behavior>Required</behavior>\n';
        s += '                <field>Name</field>\n';
        s += '            </layoutItems>\n';
        if (fieldNames != null) {
            for (String f : fieldNames) {
                if (String.isBlank(f)) continue;
                s += '            <layoutItems>\n';
                s += '                <behavior>Edit</behavior>\n';
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

        if (metadataType == 'CustomLabel') {
            return validateRequiredElements(xmlContent,
                new List<String>{ '<fullName>', '<value>' });
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

    private static String validateRequiredElements(String xml, List<String> requiredElements) {
        for (String element : requiredElements) {
            if (!xml.contains(element)) {
                return 'Missing required element: ' + element;
            }
        }
        return null;
    }

    // ─────────────────────────────────────────────────────────────
    // TOOL CALLING LOOP — used in Stage 1 (read stage) only
    // ─────────────────────────────────────────────────────────────
    private static String runToolCallingLoop(
        List<Map<String, Object>> messages,
        List<Map<String, Object>> tools
    ) {
        Integer iterations = 0;

        while (iterations < MAX_ITERATIONS) {
            iterations++;
            System.debug('READ STAGE LOOP ITERATION ' + iterations);

            Map<String, Object> response;
            try {
                response = callGroq(messages, tools, 'auto');
            } catch (Exception e) {
                System.debug('runToolCallingLoop: read stage call failed, falling back: ' + e.getMessage());
                // Do NOT call ErrorLogger.log(e) here — it does DML which breaks
                // the subsequent Stage 2 Groq callout with "uncommitted work pending"
                return '{}';
            }
            List<Object> choices         = (List<Object>) response.get('choices');
            Map<String, Object> choice   = (Map<String, Object>) choices[0];
            Map<String, Object> message  = (Map<String, Object>) choice.get('message');
            String finishReason          = (String) choice.get('finish_reason');

            System.debug('Read stage finish_reason = [' + finishReason + ']');

            if (finishReason == 'tool_calls') {
                List<Object> toolCalls = (List<Object>) message.get('tool_calls');

                messages.add(new Map<String, Object>{
                    'role'       => 'assistant',
                    'content'    => '',
                    'tool_calls' => toolCalls
                });

                for (Object rawCall : toolCalls) {
                    Map<String, Object> toolCall = (Map<String, Object>) rawCall;
                    String toolCallId            = (String) toolCall.get('id');
                    Map<String, Object> func     = (Map<String, Object>) toolCall.get('function');
                    String functionName          = (String) func.get('name');
                    String argumentsJson         = (String) func.get('arguments');

                    System.debug('Read stage tool call: [' + functionName + '] args: ' + argumentsJson);

                    String toolResult = executeReadFunction(functionName, argumentsJson);

                    System.debug('Read stage tool result: ' + toolResult);

                    messages.add(new Map<String, Object>{
                        'role'         => 'tool',
                        'tool_call_id' => toolCallId,
                        'content'      => toolResult
                    });
                }

            } else if (finishReason == 'stop') {

                // LLM finished tool calls and produced a text response — use it directly.
                // Do NOT make a second call with tool_choice=none — Groq 400s when the
                // tools array is present alongside tool_choice=none on long conversations
                // because it attempts function generation internally and fails mid-JSON.
                String content = (String) message.get('content');
                System.debug('Read stage complete. Summary: ' + content);
                return String.isNotBlank(content) ? content : '{}';

            } else {
                return '{}'; // Empty org state on unexpected finish
            }
        }

        return '{}';
    }

    // ─────────────────────────────────────────────────────────────
    // EXECUTE READ-ONLY FUNCTION
    // Only allows read operations — no writes during Stage 1
    // ─────────────────────────────────────────────────────────────
    private static String executeReadFunction(String functionName, String argumentsJson) {
        Map<String, Object> arguments = new Map<String, Object>();
        if (String.isNotBlank(argumentsJson)) {
            arguments = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
        }

        // Whitelist of read-only functions allowed in Stage 1
        Set<String> allowedFunctions = new Set<String>{
            'sobjects_list',
            'sobject_describe',
            'sobject_fields_list',
            'sobject_field_describe',
            'permission_set_list',
            'profile_list',
            'validation_rule_list',
            'custom_label_list',
            'custom_setting_list',
            'named_credential_list',
            'custom_metadata_type_list',
            'custom_metadata_record_list',
            'page_layout_list',
            'static_resource_list',
            'translation_list_languages',
            'run_tooling_api_query'
        };

        if (!allowedFunctions.contains(functionName)) {
            System.debug('executeReadFunction: BLOCKED write function [' + functionName + '] in read stage');
            return JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => 'Function ' + functionName + ' is not allowed in read stage'
            });
        }

        try {
            return FunctionRouter.execute(functionName, arguments);
        } catch (Exception e) {
            System.debug('executeReadFunction: failed: ' + e.getMessage());
            ErrorLogger.log(e);
            return JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => e.getMessage()
            });
        }
    }

    // ─────────────────────────────────────────────────────────────
    // READ-ONLY TOOLS — sent to LLM in Stage 1
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getReadOnlyTools() {
        List<Map<String, Object>> allTools = ToolDefinitions.getAllTools();
        List<Map<String, Object>> readOnly = new List<Map<String, Object>>();

        Set<String> readOnlyNames = new Set<String>{
            'sobjects_list',
            'sobject_describe',
            'sobject_fields_list',
            'sobject_field_describe',
            'permission_set_list',
            'profile_list',
            'validation_rule_list',
            'custom_label_list',
            'custom_setting_list',
            'named_credential_list',
            'custom_metadata_type_list',
            'custom_metadata_record_list',
            'page_layout_list',
            'static_resource_list',
            'translation_list_languages',
            'run_tooling_api_query'
        };

        for (Map<String, Object> tool : allTools) {
            Map<String, Object> func = (Map<String, Object>) tool.get('function');
            String name              = (String) func.get('name');
            if (readOnlyNames.contains(name)) {
                readOnly.add(tool);
            }
        }

        return readOnly;
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

    private static String buildAuthProviderPromptSection() {
        return
 
            // ── HEADER ─────────────────────────────────────────────────────────
            '\n\n== AUTH PROVIDER XML FORMAT =='
            + '\nFile path: authproviders/DeveloperName.authprovider'
            + '\nmetadataType: AuthProvider'
            + '\nmemberName: DeveloperName  (no spaces, no __c — e.g. My_Google_Provider)'
            + '\n'
            + '\nCRITICAL — ELEMENT ORDER: elements MUST appear in STRICT ALPHABETICAL ORDER.'
            + '\nSalesforce rejects AuthProvider XML with wrong element order.'
            + '\nDo NOT include <fullName> inside the XML body — the file name is the identity.'
            + '\n'
            + '\nALL PROVIDERS share these optional trailing elements (include only if needed):'
            + '\n  <customErrorUrl>   — Custom Error URL (optional)'
            + '\n  <customLogoutUrl>  — Custom Logout URL (optional)'
            + '\n  <iconUrl>          — Icon URL (optional)'
            + '\n  <registrationHandler>ApexClassName</registrationHandler> (optional — Apex class name only, no quotes)'
            + '\n  <requireMfa>false</requireMfa> — defaults to false; set true only when ticket requests Salesforce MFA'
            + '\n'
            + '\nCONSUMER SECRET RULE:'
            + '\n  consumerSecret is NEVER returned by any Salesforce API (stored encrypted).'
            + '\n  For CREATE or UPDATE: consumerSecret MUST come from the ticket.'
            + '\n  If the ticket does not provide it → return error in summary, do NOT deploy.'
            + '\n'
 
            // ── PROVIDER 1: Salesforce ─────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Salesforce --'
            + '\nUse when: ticket says "Salesforce OAuth", "Salesforce Auth Provider", "Salesforce SSO"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\nPre-filled URLs (use exactly as shown — do NOT override unless ticket says sandbox):'
            + '\n  Prod: https://login.salesforce.com/...'
            + '\n  Sandbox: https://test.salesforce.com/...'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://login.salesforce.com/services/oauth2/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>api refresh_token</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <includeOrgIdInIdentifier>false</includeOrgIdInIdentifier>'
            + '\n    <isPkceEnabled>true</isPkceEnabled>'
            + '\n    <providerType>Salesforce</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendAccessTokenInHeader>false</sendAccessTokenInHeader>'
            + '\n    <sendClientCredentialsInHeader>false</sendClientCredentialsInHeader>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://login.salesforce.com/services/oauth2/token</tokenUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 2: Google ─────────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Google --'
            + '\nUse when: ticket says "Google OAuth", "Google Auth Provider", "Google SSO", "Google Workspace"'
            + '\nRequired from ticket: consumerKey (Client ID), consumerSecret (Client Secret)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://accounts.google.com/o/oauth2/auth</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>openid email profile</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <isPkceEnabled>true</isPkceEnabled>'
            + '\n    <providerType>Google</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://accounts.google.com/o/oauth2/token</tokenUrl>'
            + '\n    <userInfoUrl>https://www.googleapis.com/oauth2/v3/userinfo</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 3: Microsoft ──────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Microsoft --'
            + '\nUse when: ticket says "Microsoft OAuth", "Azure AD", "Microsoft Entra", "Microsoft SSO", "Azure OAuth"'
            + '\nRequired from ticket: consumerKey (Application/Client ID), consumerSecret (Client Secret)'
            + '\nOptional from ticket: tokenIssuer (e.g. https://login.microsoftonline.com/{tenant_id}/v2.0)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://login.microsoftonline.com/common/oauth2/v2.0/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>openid email profile</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <isPkceEnabled>true</isPkceEnabled>'
            + '\n    <providerType>Microsoft</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <!-- Include tokenIssuer ONLY when ticket provides a tenant-specific issuer -->'
            + '\n    <!-- <tokenIssuer>https://login.microsoftonline.com/{tenantId}/v2.0</tokenIssuer> -->'
            + '\n    <tokenUrl>https://login.microsoftonline.com/common/oauth2/v2.0/token</tokenUrl>'
            + '\n    <userInfoUrl>https://graph.microsoft.com/oidc/userinfo</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\nNOTE: tokenIssuer goes between sendSecretInApis and tokenUrl (alphabetical). Include only if ticket specifies a tenant.'
            + '\n'
 
            // ── PROVIDER 4: Open ID Connect ────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: OpenIdConnect --'
            + '\nUse when: ticket says "Open ID Connect", "OpenID Connect", "OIDC", "Custom OAuth 2.0"'
            + '\nRequired from ticket: consumerKey, consumerSecret, authorizeUrl, tokenUrl'
            + '\nOptional from ticket: userInfoUrl, defaultScopes, tokenIssuer'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>FROM_TICKET</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>openid email profile</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <isPkceEnabled>true</isPkceEnabled>'
            + '\n    <providerType>OpenIdConnect</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendAccessTokenInHeader>true</sendAccessTokenInHeader>'
            + '\n    <sendClientCredentialsInHeader>false</sendClientCredentialsInHeader>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <!-- Include tokenIssuer ONLY if ticket provides one -->'
            + '\n    <!-- <tokenIssuer>https://issuer.example.com</tokenIssuer> -->'
            + '\n    <tokenUrl>FROM_TICKET</tokenUrl>'
            + '\n    <!-- Include userInfoUrl ONLY if ticket provides one -->'
            + '\n    <!-- <userInfoUrl>FROM_TICKET</userInfoUrl> -->'
            + '\n</AuthProvider>'
            + '\nNOTE: tokenIssuer goes between sendSecretInApis and tokenUrl (alphabetical).'
            + '\nNOTE: userInfoUrl goes after tokenUrl (alphabetical).'
            + '\n'
 
            // ── PROVIDER 5: Facebook ───────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Facebook --'
            + '\nUse when: ticket says "Facebook OAuth", "Facebook Login", "Meta OAuth"'
            + '\nRequired from ticket: consumerKey (App ID), consumerSecret (App Secret)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://www.facebook.com/dialog/oauth</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>email</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <isPkceEnabled>true</isPkceEnabled>'
            + '\n    <providerType>Facebook</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://graph.facebook.com/oauth/access_token</tokenUrl>'
            + '\n    <userInfoUrl>https://graph.facebook.com/me</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 6: GitHub ─────────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: GitHub --'
            + '\nUse when: ticket says "GitHub OAuth", "GitHub Auth Provider"'
            + '\nRequired from ticket: consumerKey (Client ID), consumerSecret (Client Secret)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://github.com/login/oauth/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>user</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>GitHub</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://github.com/login/oauth/access_token</tokenUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 7: LinkedIn ───────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: LinkedIn --'
            + '\nUse when: ticket says "LinkedIn OAuth", "LinkedIn Auth Provider"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://www.linkedin.com/oauth/v2/authorization</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>r_liteprofile r_emailaddress</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>LinkedIn</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://www.linkedin.com/oauth/v2/accessToken</tokenUrl>'
            + '\n    <userInfoUrl>https://api.linkedin.com/v2/userinfo</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 8: Slack ──────────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Slack --'
            + '\nUse when: ticket says "Slack OAuth", "Slack Auth Provider", "Slack SSO"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://slack.com/openid/connect/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>openid email profile</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>Slack</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://slack.com/api/openid.connect.token</tokenUrl>'
            + '\n    <userInfoUrl>https://slack.com/api/openid.connect.userInfo</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 9: Bitbucket ──────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Bitbucket --'
            + '\nUse when: ticket says "Bitbucket OAuth", "Bitbucket Auth Provider", "Atlassian Bitbucket"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://bitbucket.org/site/oauth2/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>Bitbucket</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://bitbucket.org/site/oauth2/access_token</tokenUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 10: Confluence 3LO ────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Confluence3LO --'
            + '\nUse when: ticket says "Confluence OAuth", "Atlassian Confluence", "Confluence 3LO"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://auth.atlassian.com/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>Confluence3LO</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://auth.atlassian.com/oauth/token</tokenUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 11: MuleSoft ──────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: MuleSoft --'
            + '\nUse when: ticket says "MuleSoft OAuth", "Anypoint Auth Provider", "MuleSoft SSO"'
            + '\nRequired from ticket: consumerKey, consumerSecret'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>https://anypoint.mulesoft.com/accounts/api/v2/oauth2/authorize</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <defaultScopes>offline_access</defaultScopes>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>MuleSoft</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>https://anypoint.mulesoft.com/accounts/api/v2/oauth2/token</tokenUrl>'
            + '\n    <userInfoUrl>https://anypoint.mulesoft.com/accounts/api/v2/oauth2/userinfo</userInfoUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 12: Microsoft Access Control Service ──────────────────
            + '\n\n-- PROVIDER TYPE: MicrosoftACS --'
            + '\nUse when: ticket says "Microsoft Access Control Service", "Azure ACS", "Microsoft ACS"'
            + '\nRequired from ticket: consumerKey, consumerSecret, authorizeUrl, tokenUrl'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <authorizeUrl>FROM_TICKET</authorizeUrl>'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>MicrosoftACS</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n    <tokenUrl>FROM_TICKET</tokenUrl>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 13: Twitter ───────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Twitter --'
            + '\nUse when: ticket says "Twitter OAuth", "Twitter Auth Provider", "X OAuth"'
            + '\nRequired from ticket: consumerKey (API Key), consumerSecret (API Secret)'
            + '\nNote: Twitter uses OAuth 1.0a — no authorizeUrl/tokenUrl needed in XML'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <consumerKey>FROM_TICKET</consumerKey>'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>Twitter</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 14: Janrain ───────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Janrain --'
            + '\nUse when: ticket says "Janrain Auth Provider", "Janrain Identity"'
            + '\nNote: Janrain uses only consumerSecret (no consumerKey)'
            + '\nRequired from ticket: consumerSecret only'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <consumerSecret>FROM_TICKET</consumerSecret>'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <providerType>Janrain</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <sendSecretInApis>true</sendSecretInApis>'
            + '\n</AuthProvider>'
            + '\n'
 
            // ── PROVIDER 15: Apple ─────────────────────────────────────────────
            + '\n\n-- PROVIDER TYPE: Apple --'
            + '\nUse when: ticket says "Apple OAuth", "Sign in with Apple", "Apple Auth Provider"'
            + '\nRequired from ticket: teamId, servicesId, keyId'
            + '\nNote: Apple uses JWT / private key authentication — NOT consumerKey/consumerSecret.'
            + '\nNote: The private key file CANNOT be embedded in metadata XML.'
            + '\n      It must be uploaded manually via Setup → Auth Providers → Apple → Edit → Key.'
            + '\n      Generate the XML below for all text fields, then inform the user in summary'
            + '\n      that the private key file must be uploaded manually after deployment.'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AuthProvider xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <friendlyName>FROM_TICKET</friendlyName>'
            + '\n    <keyId>FROM_TICKET</keyId>'
            + '\n    <providerType>Apple</providerType>'
            + '\n    <requireMfa>false</requireMfa>'
            + '\n    <servicesId>FROM_TICKET</servicesId>'
            + '\n    <teamId>FROM_TICKET</teamId>'
            + '\n</AuthProvider>'
            + '\nAfter deploying Apple AuthProvider XML, the summary MUST include:'
            + '\n"⚠️ Apple private key file must be manually uploaded via Setup → Auth Providers → [Name] → Edit → Key."'
            + '\n'
 
            // ── COMMON RULES ───────────────────────────────────────────────────
            + '\n\n== AUTH PROVIDER RULES =='
            + '\n'
            + '\n-- URL SUFFIX = DEVELOPER NAME --'
            + '\nWhen the ticket provides a "URL Suffix" field:'
            + '\n  - Use the URL Suffix value as the DeveloperName → memberName AND file name'
            + '\n  - Use the "Name" field value as <friendlyName> inside the XML'
            + '\n  - NEVER use the Name/friendlyName value as the memberName'
            + '\n  - NEVER use the URL Suffix as a <urlSuffix> XML element (that element does not exist)'
  
            +'\n    Example:'
            + '\n      Ticket:  Name = "Salesforce_Test", URL Suffix = "Salesforce_OAuth"'
            + '\n      CORRECT: memberName = "Salesforce_OAuth", filePath = "authproviders/Salesforce_OAuth.authprovider"'
            + '\n              <friendlyName>Salesforce_Test</friendlyName>'
            + '\n      WRONG:   memberName = "Salesforce_Test", filePath = "authproviders/Salesforce_Test.authprovider"'
            + '\n'
            + '\n-- ELEMENT ORDER --'
            + '\nElements MUST be in STRICT ALPHABETICAL ORDER. This is identical to Named Credentials.'
            + '\nProviderType-specific reference orders:'
            + '\n  Salesforce: authorizeUrl, consumerKey, consumerSecret, defaultScopes, friendlyName,'
            + '\n              includeOrgIdInIdentifier, isPkceEnabled, providerType, requireMfa,'
            + '\n              sendAccessTokenInHeader, sendClientCredentialsInHeader, sendSecretInApis, tokenUrl'
            + '\n  Google/Facebook/LinkedIn/Slack/MuleSoft: authorizeUrl, consumerKey, consumerSecret,'
            + '\n              defaultScopes, friendlyName, [isPkceEnabled,] providerType, requireMfa,'
            + '\n              sendSecretInApis, tokenUrl, userInfoUrl'
            + '\n  GitHub/Bitbucket/Confluence3LO/Twitter/Janrain/MicrosoftACS: fewer fields, same alpha order'
            + '\n  Microsoft/OpenIdConnect: same as Google but may include tokenIssuer (between sendSecretInApis and tokenUrl)'
            + '\n'
            + '\n-- FIELD NAMING --'
            + '\n  friendlyName = "Name" field in the Salesforce UI'
            + '\n  urlSuffix    = "URL Suffix" field (include only when ticket specifies one)'
            + '\n  sendSecretInApis = "Include Consumer Secret in SOAP API Responses" checkbox'
            + '\n  isPkceEnabled    = "Use Proof Key for Code Exchange (PKCE) Extension" checkbox'
            + '\n  requireMfa       = "Use Salesforce MFA for this SSO Provider" checkbox'
            + '\n  sendAccessTokenInHeader     = "Send access token in header" (OpenIdConnect only)'
            + '\n  sendClientCredentialsInHeader = "Send client credentials in header" (OpenIdConnect only)'
            + '\n  includeOrgIdInIdentifier    = Salesforce provider specific'
            + '\n  tokenIssuer  = "Token Issuer" field (Microsoft + OpenIdConnect only)'
            + '\n'
            + '\n-- CREATE --'
            + '\n1. Identify the correct providerType from the ticket'
            + '\n2. Use the matching template above with pre-filled URLs'
            + '\n3. Replace all FROM_TICKET placeholders with values from the ticket'
            + '\n4. consumerSecret MUST come from the ticket — if missing, return error in summary'
            + '\n5. memberName = DeveloperName (no spaces, no __c) — e.g. My_Google_Provider'
            + '\n6. deploymentPlan.scenario = "single" (no chaining needed for AuthProvider alone)'
            + '\n'
            + '\n-- UPDATE --'
            + '\n1. Find the AP in existingAuthProviders in orgState by developerName'
            + '\n2. If NOT found in orgState → return error in summary, do NOT generate files'
            + '\n3. Regenerate COMPLETE XML using ALL existing values from orgState'
            + '\n4. Only change the specific field(s) the ticket requests'
            + '\n5. consumerSecret is NEVER in orgState (stored encrypted by Salesforce).'
            + '\n6. - If the ticket provides a new consumerSecret → include it in the XML.'
            + '\n   - If the ticket does NOT provide consumerSecret → OMIT <consumerSecret> entirely'
            + '\n       Salesforce preserves the existing encrypted value automatically'
            + '\n6. Use same metadataType=AuthProvider, memberName=developerName (URL Suffix),'
            + '\n   filePath=authproviders/{developerName}.authprovider'
            + '\n'
            + '\n-- UPDATE: PRIORITY RULE --'
            + '\nWhen updating an Auth Provider, the correct priority is:'
            + '\n'
            + '\n  TICKET VALUE  →  always wins over orgState'
            + '\n  ORGSTATE VALUE →  only used when ticket does NOT mention that field'
            + '\n'

            + '\nStep by step:'
            + '\n1. Start with ALL values from orgState as the base'
            + '\n2. For every field the ticket explicitly provides → OVERRIDE with ticket value'
            + '\n3. For every field the ticket does NOT mention → keep orgState value as-is'
            + '\n4. consumerSecret: if ticket provides it → include it. If not → OMIT entirely.'
            + '\n5. providerType is IMMUTABLE — never change it even if ticket mentions it'
            + '\nEXAMPLE for your case:'
            + '\n  Ticket provides: authorizeUrl, tokenUrl, defaultScopes'
            + '\n  → Use ticket values for all three'
            + '\n  orgState has: consumerKey, consumerSecret (not in ticket)'
            + '\n  → Keep consumerKey from orgState, OMIT consumerSecret'

            + '\n  NEVER let orgState overwrite a value that the ticket explicitly provides.'
            + '\n'
            + '\n-- DELETE --'
            + '\n1. Confirm the developerName exists in existingAuthProviders in orgState'
            + '\n2. If NOT found → return error in summary, do NOT generate destructiveFiles'
            + '\n3. Use the shorthand destructiveFiles entry (Apex builds destructiveChangesPost.xml):'
            + '\n   {'
            + '\n     "metadataType": "AuthProvider",'
            + '\n     "member": "DeveloperName"'
            + '\n   }'
            + '\n4. Do NOT generate any files[] entry for delete'
            + '\n'
            + '\n'
            + '\n-- NEVER --'
            + '\n- Never include <fullName> or <developerName> inside AuthProvider XML body — the file name IS the identity'
            + '\n- Never fabricate consumerKey, consumerSecret, teamId, servicesId, keyId'
            + '\n- Never change providerType during an update (providerType is immutable after creation)'
            + '\n- Never mix up consumerKey/consumerSecret with tokenIssuer'
            + '\n- Never use <tokenEndpointUrl> — the correct element is <tokenUrl>'
            + '\n- Never use <authorizeEndpointUrl> — the correct element is <authorizeUrl>'
            + '\n- Never use <scope> — the correct element is <defaultScopes>'
            + '\n- Never include <developerName> or <fullName> inside AuthProvider XML body'
            + '\n- Never use <name> — the correct element for the display name is <friendlyName>'
            + '\n- Never use the "Name" field value as the memberName — URL Suffix IS the DeveloperName'
            + '\n- Never use the "friendlyName" value as the file name or package.xml member'
            + '\n- Never include <urlSuffix> — this element does not exist in AuthProvider metadata';
    }

    // ─────────────────────────────────────────────────────────────
    // SYSTEM PROMPTS
    // ─────────────────────────────────────────────────────────────

    private static String buildReadStageSystemPrompt() {
        return 'You are a Salesforce org reader. Your job is to check the current state of the org '
            + 'before any changes are made.'
            + '\n\nUsing the available tools, check what already exists in the org that is relevant '
            + 'to the Jira ticket provided.'
            + '\n\nFor example:'
            + '\n- If the ticket creates a field, call sobject_fields_list to check if it already exists'
            + '\n- If the ticket creates an object, call sobjects_list to check if it already exists'
            + '\n- If the ticket creates a permission set, call permission_set_list to check'
            + '\n- If the ticket grants apex class access to a profile, call run_tooling_api_query with:'
            + '\n  SELECT Name FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name'
            + '\n  and include the result as apexClasses in your JSON summary'
            + '\n- If the ticket grants Visualforce page access, query: SELECT Name FROM ApexPage WHERE NamespacePrefix = null ORDER BY Name'
            + '\n- If the ticket updates or deletes something, find its current state'
            + '\n\nAfter checking, return a JSON object summarising what you found. Example:'
            + '\n{'
            + '\n  "existingObjects": ["Car__c", "Driver__c"],'
            + '\n  "existingFields": {"Car__c": ["Name", "Price__c", "Status__c"]},'
            + '\n  "existingPermissionSets": ["Sales_Team_Access"],'
            + '\n  "apexClasses": ["AccountController", "CarService", "ReservationHelper"],'
            + '\n  "notes": "Car__c exists with 5 fields. Status__c does not exist yet."'
            + '\n}'
            + '\n\nReturn ONLY valid JSON. No explanation, no markdown, just the JSON object.'
            + '\n\nSalesforce Org: ' + UserInfo.getOrganizationName()
            + '\nCurrent User: ' + UserInfo.getUserName();
    }

    private static String buildXmlGenerationSystemPrompt() {
        return 'You are a Salesforce Metadata XML generator. '
            + 'You receive a Jira ticket and org state, and return a JSON object containing '
            + 'all the Salesforce Metadata API XML files needed to implement the ticket.'
            + '\n\nYou MUST return ONLY a valid JSON object in this exact structure:'
            + '\n{'
            + '\n  "files": ['
            + '\n    {'
            + '\n      "metadataType": "CustomObject",'
            + '\n      "memberName": "Reservation__c",'
            + '\n      "filePath": "objects/Reservation__c.object",'
            + '\n      "xmlContent": "<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>..."'
            + '\n    }'
            + '\n  ],'
            + '\n  "destructiveFiles": ['
            + '\n    {'
            + '\n      "xmlContent": "<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>..."'
            + '\n    }'
            + '\n  ],'
            + '\n  "dmlOperations": ['
            + '\n    {'
            + '\n      "type": "permissionSetAssign",'
            + '\n      "permissionSetName": "Sales_Team",'
            + '\n      "username": "john@example.com"'
            + '\n    }'
            + '\n  ],'
            + '\n  "deploymentPlan": { "scenario": "single" },'
            + '\n  "summary": "Created Reservation__c object with Status__c field"'
            + '\n}'

            // ── GENERAL RULES ──────────────────────────────────
            + '\n\n== GENERAL RULES =='
            + '\n1. Always use API version 61.0'
            + '\n2. Always include xmlns="http://soap.sforce.com/2006/04/metadata" on root elements'
            + '\n3. Always XML-escape special characters in values: & → &amp; < → &lt; > → &gt; " → &quot; \' → &apos;'
            + '\n4. All custom API names end with __c (fields, objects). Custom metadata types end with __mdt.'
            + '\n5. If multiple fields belong to the same object, merge ALL <fields> blocks into ONE CustomObject file'
            + '\n6. filePath format: objects/ObjectName__c.object (no -meta.xml suffix needed for ZIP deploy)'

            // ── CUSTOM OBJECT XML ──────────────────────────────
            + '\n\n== CUSTOM OBJECT XML FORMAT =='
            + '\nFile path: objects/ObjectName__c.object'
            + '\nmetadataType: CustomObject'
            + '\nmemberName: ObjectName__c'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>Object Label</label>'
            + '\n    <pluralLabel>Object Labels</pluralLabel>'
            + '\n    <description>Optional description</description>'
            + '\n    <nameField>'
            + '\n        <label>Name Field Label</label>'
            + '\n        <type>Text</type>  <!-- Text or AutoNumber -->'
            + '\n        <!-- if AutoNumber: <displayFormat>RES-{0000}</displayFormat> -->'
            + '\n    </nameField>'
            + '\n    <deploymentStatus>Deployed</deploymentStatus>'
            + '\n    <sharingModel>ReadWrite</sharingModel>  <!-- NEW objects with no MasterDetail: ReadWrite. Objects with MasterDetail: MUST be ControlledByParent -->'
            + '\n</CustomObject>'
            + '\nRULE: When creating an object, you MUST also generate:'
            + '\n  - A CustomTab file (see Tab format below)'
            + '\n  - A Profile file for Admin tab visibility (see Profile format below)'

            // ── CUSTOM TAB XML ─────────────────────────────────
            + '\n\n== CUSTOM TAB XML FORMAT =='
            + '\nFile path: tabs/ObjectName__c.tab'
            + '\nmetadataType: CustomTab'
            + '\nmemberName: ObjectName__c'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <customObject>true</customObject>'
            + '\n    <motif>Custom18: Form</motif>'
            + '\n</CustomTab>'

            // ── PROFILE TAB VISIBILITY XML ─────────────────────
            + '\n\n== PROFILE TAB VISIBILITY XML FORMAT =='
            + '\nFile path: profiles/Admin.profile'
            + '\nmetadataType: Profile'
            + '\nmemberName: Admin'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <tabVisibilities>'
            + '\n        <tab>ObjectName__c</tab>'
            + '\n        <visibility>DefaultOn</visibility>'
            + '\n    </tabVisibilities>'
            + '\n</Profile>'

            // ── CUSTOM FIELD XML ───────────────────────────────
            + '\n\n== CUSTOM FIELD XML FORMAT =='
            + '\nIMPORTANT: Fields are EMBEDDED inside the CustomObject XML, not separate files.'
            + '\nWhen adding fields to an existing object, the file must include the full CustomObject wrapper:'
            + '\nFile path: objects/ObjectName__c.object'
            + '\nmetadataType: CustomObject'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>Existing Object Label</label>  <!-- MUST match existing label from org state -->'
            + '\n    <pluralLabel>Existing Plural Label</pluralLabel>'
            + '\n    <nameField>'
            + '\n        <label>Existing Name Field Label</label>'
            + '\n        <type>Text</type>'
            + '\n    </nameField>'
            + '\n    <deploymentStatus>Deployed</deploymentStatus>'
            + '\n    <sharingModel>ControlledByParent</sharingModel>'
            + '\n    <!-- fields go here -->'
            + '\n    <fields>...</fields>'
            + '\n    <fields>...</fields>'
            + '\n</CustomObject>'

            // ── FIELD TYPES ────────────────────────────────────
            + '\n\n== FIELD TYPE FORMATS =='

            + '\n-- Text --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Text</type>'
            + '\n    <length>255</length>'
            + '\n    <required>false</required>'
            + '\n</fields>'

            + '\n-- Number / Currency / Percent --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Number</type>'
            + '\n    <precision>18</precision>'
            + '\n    <scale>2</scale>'
            + '\n    <required>false</required>'
            + '\n</fields>'

            + '\n-- Checkbox --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Checkbox</type>'
            + '\n    <defaultValue>false</defaultValue>'
            + '\n</fields>'

            + '\n-- Date / DateTime / Phone / Email / Url --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Date</type>'
            + '\n    <required>false</required>'
            + '\n</fields>'

            + '\n-- TextArea --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>TextArea</type>'
            + '\n    <length>255</length>'
            + '\n</fields>'

            + '\n-- LongTextArea --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>LongTextArea</type>'
            + '\n    <length>32768</length>'
            + '\n    <visibleLines>5</visibleLines>'
            + '\n</fields>'
            + '\nCRITICAL: <visibleLines> is MANDATORY for LongTextArea — Salesforce will reject the deploy without it.'
            + '\nAlways include <visibleLines> on every LongTextArea field, no exceptions.'

            + '\n-- Picklist --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Picklist</type>'
            + '\n    <valueSet>'
            + '\n        <restricted>false</restricted>'
            + '\n        <valueSetDefinition>'
            + '\n            <sorted>false</sorted>'
            + '\n            <value>'
            + '\n                <fullName>Value1</fullName>'
            + '\n                <default>false</default>'
            + '\n                <label>Value1</label>'
            + '\n            </value>'
            + '\n            <value>'
            + '\n                <fullName>Value2</fullName>'
            + '\n                <default>false</default>'
            + '\n                <label>Value2</label>'
            + '\n            </value>'
            + '\n        </valueSetDefinition>'
            + '\n    </valueSet>'
            + '\n</fields>'

            + '\n-- MultiselectPicklist --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>MultiselectPicklist</type>'
            + '\n    <visibleLines>4</visibleLines>'
            + '\n    <valueSet>'
            + '\n        <restricted>false</restricted>'
            + '\n        <valueSetDefinition>'
            + '\n            <sorted>false</sorted>'
            + '\n            <value>'
            + '\n                <fullName>Value1</fullName>'
            + '\n                <default>false</default>'
            + '\n                <label>Value1</label>'
            + '\n            </value>'
            + '\n        </valueSetDefinition>'
            + '\n    </valueSet>'
            + '\n</fields>'

            + '\n-- Lookup --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>Lookup</type>'
            + '\n    <referenceTo>ParentObject__c</referenceTo>'
            + '\n    <relationshipName>ChildObject_FieldName</relationshipName>'
            + '\n</fields>'

            + '\n-- MasterDetail --'
            + '\n<fields>'
            + '\n    <fullName>FieldName__c</fullName>'
            + '\n    <label>Field Label</label>'
            + '\n    <type>MasterDetail</type>'
            + '\n    <referenceTo>ParentObject__c</referenceTo>'
            + '\n    <relationshipName>ChildObject_FieldName</relationshipName>'
            + '\n    <reparentableMasterDetail>false</reparentableMasterDetail>'
            + '\n    <writeRequiresMasterRead>false</writeRequiresMasterRead>'
            + '\n</fields>'

            + '\n-- RELATIONSHIP NAME RULES --'
            + '\n<relationshipName> is REQUIRED on every Lookup / MasterDetail field.'
            + '\nYou MUST include the <relationshipName> tag. A reasonable default is {ChildObjectWithout__c}_{FieldNameWithout__c}.'
            + '\nApex will AUTOMATICALLY rewrite the <relationshipName> value to a unique hash-suffixed name'
            + '\n(e.g. Reservation_AI_Message_7A3F2C) before the XML is deployed. This prevents collisions'
            + '\nwith orphan child relationships left in the org from prior failed deploys.'
            + '\nDo NOT worry about uniqueness — just emit the simple {Child}_{Field} form and Apex handles the rest.'

            + '\nCRITICAL RULE: When a MasterDetail field exists, the object sharingModel MUST be ControlledByParent'

            // ── CUSTOM LABEL XML ───────────────────────────────────────
            + '\n\n== CUSTOM LABEL XML FORMAT =='
            + '\nFile path: labels/CustomLabels.labels'
            + '\nmetadataType: CustomLabel'
            + '\nmemberName: LabelName (the API name of the label)'
            + '\nIMPORTANT: ALL labels go into ONE file — labels/CustomLabels.labels'
            + '\nIf multiple labels are created/updated, merge ALL <labels> blocks into ONE file.'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomLabels xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <labels>'
            + '\n        <fullName>Label_API_Name</fullName>'
            + '\n        <language>en_US</language>'
            + '\n        <protected>false</protected>'
            + '\n        <shortDescription>Label_API_Name</shortDescription>'
            + '\n        <value>The label text value</value>'
            + '\n    </labels>'
            + '\n</CustomLabels>'
            + '\nRULES:'
            + '\n- Element order MUST be: fullName, language, protected, shortDescription, value'
            + '\n- shortDescription is REQUIRED — if not provided in the ticket, use the fullName value as default'
            + '\n- NEVER omit shortDescription — Salesforce will reject the deploy without it'
            + '\n- There is NO <masterLabel> element — do not include it'
            + '\n- language defaults to en_US if not specified'
            + '\n- protected defaults to false if not specified'
            + '\n- For DELETING a label, use destructiveFiles with type CustomLabel and member = label API name'
            + '\n- For UPDATING a label, generate the full <labels> block with all values'
            + '\n  (use existing values from org state for fields not being changed)'

            // ── NAMED CREDENTIAL XML ───────────────────────────────────
            + '\n\n== NAMED CREDENTIAL XML FORMAT =='
            + '\nFile path: namedCredentials/ApiName.namedCredential'
            + '\nmetadataType: NamedCredential'
            + '\nmemberName: ApiName (no __c suffix)'
            + '\n'
            + '\nIDENTITY TYPE is always Named Principal → principalType = NamedUser'
            + '\nPick the correct protocol template based on what the ticket specifies.'
            + '\n'
            + '\nCRITICAL — ELEMENT ORDER: elements MUST appear in strict alphabetical order.'
            + '\nSalesforce rejects Named Credential XML with wrong element order.'
            + '\nDo NOT include <fullName> inside the XML body — the file name is the identity.'
            + '\n'

            // ── PROTOCOL 1: No Authentication ──────────────────
            + '\n-- PROTOCOL: No Authentication --'
            + '\nUse when ticket says: "No Authentication", "No Auth", "anonymous"'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<NamedCredential xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <allowMergeFieldsInBody>false</allowMergeFieldsInBody>'
            + '\n    <allowMergeFieldsInHeader>false</allowMergeFieldsInHeader>'
            + '\n    <calloutStatus>Enabled</calloutStatus>'
            + '\n    <endpoint>https://api.example.com</endpoint>'
            + '\n    <generateAuthorizationHeader>true</generateAuthorizationHeader>'
            + '\n    <label>Label</label>'
            + '\n    <principalType>NamedUser</principalType>'
            + '\n    <protocol>NoAuthentication</protocol>'
            + '\n</NamedCredential>'
            + '\n'

            // ── PROTOCOL 2: OAuth 2.0 ──────────────────────────
            + '\n-- PROTOCOL: OAuth 2.0 --'
            + '\nUse when ticket says: "OAuth 2.0", "OAuth"'
            + '\nRequired from ticket: Authentication Provider name + Scope'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<NamedCredential xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <allowMergeFieldsInBody>false</allowMergeFieldsInBody>'
            + '\n    <allowMergeFieldsInHeader>false</allowMergeFieldsInHeader>'
            + '\n    <authProvider>AuthProviderDeveloperName</authProvider>'
            + '\n    <calloutStatus>Enabled</calloutStatus>'
            + '\n    <endpoint>https://api.example.com</endpoint>'
            + '\n    <generateAuthorizationHeader>true</generateAuthorizationHeader>'
            + '\n    <label>Label</label>'
            + '\n    <oauthScope>api refresh_token</oauthScope>'
            + '\n    <principalType>NamedUser</principalType>'
            + '\n    <protocol>Oauth</protocol>'
            + '\n</NamedCredential>'
            + '\n'

            // ── PROTOCOL 3: Password Authentication ────────────
            + '\n-- PROTOCOL: Password Authentication --'
            + '\nUse when ticket says: "Password Authentication", "Password Auth", "Basic Auth"'
            + '\nRequired from ticket: Username + Password'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<NamedCredential xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <allowMergeFieldsInBody>false</allowMergeFieldsInBody>'
            + '\n    <allowMergeFieldsInHeader>false</allowMergeFieldsInHeader>'
            + '\n    <calloutStatus>Enabled</calloutStatus>'
            + '\n    <endpoint>https://api.example.com</endpoint>'
            + '\n    <generateAuthorizationHeader>true</generateAuthorizationHeader>'
            + '\n    <label>Label</label>'
            + '\n    <password>thepassword</password>'
            + '\n    <principalType>NamedUser</principalType>'
            + '\n    <protocol>Password</protocol>'
            + '\n    <username>user@example.com</username>'
            + '\n</NamedCredential>'
            + '\n'

            // ── NAMED CREDENTIAL RULES ─────────────────────────
            + '\nRULES:'
            + '\n- principalType is ALWAYS NamedUser — never Anonymous'
            + '\n- calloutStatus is ALWAYS Enabled'
            + '\n- generateAuthorizationHeader is ALWAYS true'
            + '\n- allowMergeFieldsInBody and allowMergeFieldsInHeader default to false unless ticket says otherwise'
            + '\n- Element order MUST be strictly alphabetical — any deviation causes deploy failure'
            + '\n- Do NOT include <fullName> inside the XML body'
            + '\n- For OAuth 2.0: authProvider value = the DeveloperName of the Auth Provider stated in the ticket'
            + '\n- For OAuth 2.0: oauthScope value = scope string stated in the ticket (e.g. "api refresh_token")'
            + '\n- For Password: username and password come directly from the ticket'
            + '\n- NEVER invent or guess authProvider, username, or password — use only what the ticket provides'
            + '\n- Each Named Credential is its own separate file — do NOT merge into one file'
            + '\n'
            + '\n-- UPDATE --'
            + '\nThe current state of all Named Credentials is in orgState.existingNamedCredentials.'
            + '\nEach entry contains: apiName, label, endpoint, protocol, principalType, calloutStatus,'
            + '\ngenerateAuthorizationHeader, allowMergeFieldsInBody, allowMergeFieldsInHeader,'
            + '\nand protocol-specific fields: authProvider + oauthScope (OAuth), username (Password).'
            + '\n'
            + '\nTo UPDATE a Named Credential:'
            + '\n1. Find the NC in existingNamedCredentials by apiName'
            + '\n2. If NOT found in orgState → return an error in summary, do NOT generate any files'
            + '\n3. Regenerate the COMPLETE XML using ALL existing values from orgState'
            + '\n4. Only change the specific field(s) the ticket requests'
            + '\n5. Preserve protocol — do NOT change protocol unless ticket explicitly requests it'
            + '\n6. For Password protocol: username comes from orgState (already known).'
            + '\n   password is NEVER returned by any API — it MUST come from the ticket.'
            + '\n   If the ticket does not provide a password → return error in summary, do NOT deploy'
            + '\n7. Use metadataType=NamedCredential, memberName=apiName, filePath=namedCredentials/{apiName}.namedCredential'
            + '\n'
            + '\nEXAMPLE — update endpoint only (protocol=Password, username from orgState):'
            + '\n{'
            + '\n  "metadataType": "NamedCredential",'
            + '\n  "memberName": "My_API",'
            + '\n  "filePath": "namedCredentials/My_API.namedCredential",'
            + '\n  "xmlContent": "<?xml ...><NamedCredential>...<endpoint>https://new.example.com</endpoint>...<password>FROM_TICKET</password>...<username>FROM_ORG_STATE</username>...</NamedCredential>"'
            + '\n}'
            + '\n'
            + '\n-- DELETE --'
            + '\nTo DELETE a Named Credential:'
            + '\n1. Confirm the apiName exists in existingNamedCredentials in orgState'
            + '\n2. If NOT found → return error in summary, do NOT generate destructiveFiles'
            + '\n3. Use the shorthand destructiveFiles entry (no xmlContent needed — Apex builds it):'
            + '\n   {'
            + '\n     "metadataType": "NamedCredential",'
            + '\n     "member": "My_API"'
            + '\n   }'
            + '\n4. Do NOT generate any files[] entry for delete'
            + '\n5. Do NOT generate xmlContent — Apex builds destructiveChangesPost.xml automatically'

            // ── TRANSLATION XML ────────────────────────────────────────
            + '\n\n== TRANSLATION XML FORMAT =='
            + '\nThere are TWO types of translation files:'
            + '\n'
            + '\n-- TYPE 1: Custom Label Translation --'
            + '\nFile path: translations/{language}.translation'
            + '\nmetadataType: Translations'
            + '\nmemberName: {language} (e.g. fr, de, ja)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Translations xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <customLabels>'
            + '\n        <label>Translated text here</label>'
            + '\n        <name>Label_API_Name</name>'
            + '\n    </customLabels>'
            + '\n</Translations>'
            + '\nRULE: Multiple label translations for same language = ONE file with multiple <customLabels> blocks'
            + '\n'
            + '\n-- TYPE 2: Object Translation (fields, picklist values, validation rules, object label) --'
            + '\nFile path: objectTranslations/{ObjectName}-{language}.objectTranslation'
            + '\nmetadataType: CustomObjectTranslation'
            + '\nmemberName: {ObjectName}-{language} (e.g. Car__c-fr)'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObjectTranslation xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <!-- Object label translation (optional) -->'
            + '\n    <nameFieldLabel>Translated object name</nameFieldLabel>'
            + '\n    <!-- Field label translation -->'
            + '\n    <fields>'
            + '\n        <name>FieldName__c</name>'
            + '\n        <label>Translated field label</label>'
            + '\n    </fields>'
            + '\n    <!-- Picklist value translation -->'
            + '\n    <fields>'
            + '\n        <name>PicklistField__c</name>'
            + '\n        <picklistValues>'
            + '\n            <masterLabel>Original English Value</masterLabel>'
            + '\n            <translation>Translated Value</translation>'
            + '\n        </picklistValues>'
            + '\n    </fields>'
            + '\n    <!-- Validation rule error message translation -->'
            + '\n    <validationRules>'
            + '\n        <errorMessage>Translated error message</errorMessage>'
            + '\n        <name>RuleName</name>'
            + '\n    </validationRules>'
            + '\n</CustomObjectTranslation>'
            + '\nRULES:'
            + '\n- Custom Label translations → translations/{lang}.translation (Translations type)'
            + '\n- Field/Picklist/ValidationRule/Object translations → objectTranslations/{Object}-{lang}.objectTranslation (CustomObjectTranslation type)'
            + '\n- Multiple fields for same object+language = ONE objectTranslation file with multiple <fields> blocks'
            + '\n- nameFieldLabel is optional — only include if translating the object label itself'
            + '\n- For DELETING a translation, use destructiveFiles with the appropriate type and member'
            + '\n- Always include ALL existing translations from org state when updating — do not drop existing ones'

            // ── VALIDATION RULE XML ────────────────────────────────────
            + '\n\n== VALIDATION RULE XML FORMAT =='
            + '\nValidation Rules are EMBEDDED inside the CustomObject XML, not separate files.'
            + '\nFile path: objects/ObjectName__c.object'
            + '\nmetadataType: CustomObject'
            + '\nmemberName: ObjectName__c'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>Existing Object Label</label>'
            + '\n    <pluralLabel>Existing Plural Label</pluralLabel>'
            + '\n    <nameField>'
            + '\n        <label>Existing Name Field Label</label>'
            + '\n        <type>Text</type>'
            + '\n    </nameField>'
            + '\n    <deploymentStatus>Deployed</deploymentStatus>'
            + '\n    <sharingModel>ReadWrite</sharingModel>'
            + '\n    <validationRules>'
            + '\n        <fullName>RuleName</fullName>'
            + '\n        <active>true</active>'
            + '\n        <description>Optional description</description>'
            + '\n        <errorConditionFormula>Price__c &lt;= 0</errorConditionFormula>'
            + '\n        <errorDisplayField>Price__c</errorDisplayField>'
            + '\n        <errorMessage>Price must be greater than zero.</errorMessage>'
            + '\n    </validationRules>'
            + '\n</CustomObject>'
            + '\nRULES:'
            + '\n- Element order MUST be: fullName, active, description (optional), errorConditionFormula, errorDisplayField (optional), errorMessage'
            + '\n- description is optional — omit entirely if not provided'
            + '\n- errorDisplayField is optional — omit entirely if not provided'
            + '\n- active defaults to true if not specified'
            + '\n- ALWAYS XML-escape formula characters: < → &lt; > → &gt; & → &amp;'
            + '\n- Formula syntax: use AND(), OR(), NOT() as functions never as keywords'
            + '\n- Formula syntax: use ISBLANK(field) never = ""'
            + '\n- Formula syntax: for picklist fields use ISPICKVAL(Field__c, "Value") never = or !='
            + '\n- Multiple validation rules on same object = ONE object XML file with multiple <validationRules> blocks'
            + '\n- When adding a validation rule to existing object: use sharingModel from org state'
            + '\n- For DELETING a validation rule, use destructiveFiles with type ValidationRule'
            + '\n  and member = ObjectName__c.RuleName (e.g. Car__c.PriceMustBePositive)'
            + '\n- CRITICAL: When updating/creating a rule on an existing object, preserve ALL other'
            + '\n  existing validation rules from org state in the same XML file — do not drop them'

            // ── CUSTOM SETTING XML ─────────────────────────────────────
            + '\n\n== CUSTOM SETTING XML FORMAT =='
            + '\nFile path: objects/SettingName__c.object'
            + '\nmetadataType: CustomObject'
            + '\nmemberName: SettingName__c'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <customSettingsType>Hierarchy</customSettingsType>'
            + '\n    <description>Optional description</description>'
            + '\n    <enableFeeds>false</enableFeeds>'
            + '\n    <label>Setting Label</label>'
            + '\n    <fields>'
            + '\n        <fullName>FieldName__c</fullName>'
            + '\n        <label>Field Label</label>'
            + '\n        <type>Text</type>'
            + '\n        <length>255</length>'
            + '\n        <required>false</required>'
            + '\n    </fields>'
            + '\n</CustomObject>'
            + '\nRULES:'
            + '\n- customSettingsType is Hierarchy (default) or List'
            + '\n- description is optional — omit entirely if not provided'
            + '\n- enableFeeds is always false'
            + '\n- DO NOT include <customSettingsVisibility> — not valid in API v61.0'
            + '\n- DO NOT include <sharingModel>, <nameField>, <pluralLabel>, <deploymentStatus>'
            + '\n  — these are NOT valid in Custom Setting XML'
            + '\n- Supported field types: Checkbox, Currency, Date, DateTime, Email, Number, Percent, Phone, Text, TextArea, Url'
            + '\n- DO NOT use LongTextArea, Picklist, Lookup or MasterDetail in Custom Settings'
            + '\n- Checkbox fields: use <defaultValue>false</defaultValue> instead of <required>'
            + '\n- Text fields: always include <length>255</length>'
            + '\n- Number/Currency/Percent fields: include <precision>18</precision> and <scale>0</scale>'
            + '\n- Multiple fields = ONE object file with multiple <fields> blocks'
            + '\n- Element order inside <fields>: fullName, then type-specific elements, then label, then required/defaultValue, then type'
            + '\n- For ADDING fields to existing setting: include ALL existing fields from org state plus the new one'
            + '\n- For DELETING a field: use destructiveFiles with type CustomField, member = SettingName__c.FieldName__c'
            + '\n- For DELETING the entire setting: use destructiveFiles with type CustomObject, member = SettingName__c'

            // ── CUSTOM METADATA TYPE XML ───────────────────────────────
            + '\n\n== CUSTOM METADATA TYPE XML FORMAT =='
            + '\n\n-- TYPE DEFINITION --'
            + '\nFile path: objects/ApiName__mdt.object'
            + '\nmetadataType: CustomObject'
            + '\nmemberName: ApiName__mdt'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>Type Label</label>'
            + '\n    <pluralLabel>Type Labels</pluralLabel>'
            + '\n    <description>Optional description</description>'
            + '\n    <visibility>Public</visibility>'
            + '\n    <fields>'
            + '\n        <fullName>FieldName__c</fullName>'
            + '\n        <label>Field Label</label>'
            + '\n        <type>Text</type>'
            + '\n        <length>255</length>'
            + '\n        <required>false</required>'
            + '\n    </fields>'
            + '\n</CustomObject>'
            + '\nRULES FOR TYPE DEFINITION:'
            + '\n- API name always ends with __mdt (e.g. My_Config__mdt)'
            + '\n- visibility is Public (default), Protected, or PackageProtected'
            + '\n- description is optional — omit entirely if not provided'
            + '\n- Fields are embedded inside the same CustomObject XML'
            + '\n- Supported field types: Checkbox, Date, DateTime, Email, Number, Percent, Phone, Picklist, Text, TextArea, LongTextArea, Url'
            + '\n- Checkbox fields: use <defaultValue>false</defaultValue> instead of <required>'
            + '\n- Text/TextArea fields: include <length>255</length>'
            + '\n- LongTextArea fields: include <length>32768</length> and <visibleLines>3</visibleLines>'
            + '\n- Number/Percent fields: include <precision>18</precision> and <scale>0</scale>'
            + '\n- Multiple fields = ONE object file with multiple <fields> blocks'
            + '\n- For DELETING a type: use destructiveFiles with type CustomObject, member = ApiName__mdt'
            + '\n\n-- RECORD --'
            + '\nFile path: customMetadata/ApiName__mdt.RecordName.md'
            + '\nmetadataType: CustomMetadata'
            + '\nmemberName: ApiName__mdt.RecordName'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"'
            + '\n    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
            + '\n    xmlns:xsd="http://www.w3.org/2001/XMLSchema">'
            + '\n    <label>Record Label</label>'
            + '\n    <protected>false</protected>'
            + '\n    <values>'
            + '\n        <field>FieldName__c</field>'
            + '\n        <value xsi:type="xsd:string">field value</value>'
            + '\n    </values>'
            + '\n</CustomMetadata>'
            + '\nRULES FOR RECORDS:'
            + '\n- RecordName must be alphanumeric and underscores only, no spaces'
            + '\n- Each field value needs correct xsi:type:'
            + '\n  Text/TextArea/LongTextArea/Email/Phone/Url/Picklist → xsi:type="xsd:string"'
            + '\n  Number/Percent/Currency                             → xsi:type="xsd:double"'
            + '\n  Checkbox                                            → xsi:type="xsd:boolean"'
            + '\n  Date                                                → xsi:type="xsd:date"'
            + '\n  DateTime                                            → xsi:type="xsd:dateTime"'
            + '\n- protected defaults to false'
            + '\n- Each record is its own separate file'
            + '\n- For DELETING a record: use destructiveFiles with type CustomMetadata, member = ApiName__mdt.RecordName'

            // ── STATIC RESOURCE XML ────────────────────────────
            + '\n\n== STATIC RESOURCE FORMAT =='
            + '\nStatic Resources involve binary files from Jira attachments.'
            + '\nDo NOT generate XML for static resources.'
            + '\nInstead use dmlOperations with type staticResourceDeploy or staticResourceDelete:'
            + '\n'
            + '\n-- DEPLOY (create or update) --'
            + '\n{'
            + '\n  "type": "staticResourceDeploy",'
            + '\n  "apiName": "my_logo",'
            + '\n  "fileName": "logo.png",'
            + '\n  "cacheControl": "Public"'
            + '\n}'
            + '\n'
            + '\n-- DELETE --'
            + '\n{'
            + '\n  "type": "staticResourceDelete",'
            + '\n  "apiName": "my_logo"'
            + '\n}'
            + '\nRULES:'
            + '\n- apiName: alphanumeric and underscores only, no file extension'
            + '\n- fileName: exact fileName from the attachments listed in the ticket'
            + '\n- cacheControl: Public (default) or Private'
            + '\n- ALWAYS check attachments section of the ticket for the exact fileName'

            // ── PAGE LAYOUT XML ────────────────────────────────────────
            + '\n\n== PAGE LAYOUT XML FORMAT =='
            + '\nFile path: layouts/{ObjectName}-{LayoutName}.layout'
            + '\nmetadataType: Layout'
            + '\nmemberName: {ObjectName}-{LayoutName}  (e.g. Car__c-Car Layout)'
            + '\n'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Layout xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <fullName>ObjectName__c-Layout Name</fullName>'
            + '\n    <layoutSections>'
            + '\n        <customLabel>true</customLabel>'
            + '\n        <detailHeading>true</detailHeading>'
            + '\n        <editHeading>true</editHeading>'
            + '\n        <label>Section Label</label>'
            + '\n        <layoutColumns>'
            + '\n            <!-- LEFT COLUMN items (even-indexed fields: 0, 2, 4...) -->'
            + '\n            <layoutItems>'
            + '\n                <behavior>Required</behavior>'
            + '\n                <field>Name</field>'
            + '\n            </layoutItems>'
            + '\n            <layoutItems>'
            + '\n                <behavior>Edit</behavior>'
            + '\n                <field>Status__c</field>'
            + '\n            </layoutItems>'
            + '\n        </layoutColumns>'
            + '\n        <layoutColumns>'
            + '\n            <!-- RIGHT COLUMN items (odd-indexed fields: 1, 3, 5...) -->'
            + '\n            <layoutItems>'
            + '\n                <behavior>Edit</behavior>'
            + '\n                <field>Price__c</field>'
            + '\n            </layoutItems>'
            + '\n        </layoutColumns>'
            + '\n        <style>TwoColumnsTopToBottom</style>'
            + '\n    </layoutSections>'
            + '\n    <!-- Add more <layoutSections> blocks for additional sections -->'
            + '\n</Layout>'

            + '\n\n== LAYOUT RULES =='
            + '\n1. fullName MUST exactly match memberName: {ObjectName}-{LayoutName}'
            + '\n2. Always exactly TWO <layoutColumns> blocks per section: first = left, second = right'
            + '\n3. Field distribution across columns:'
            + '\n   - Given an ordered field list [F0, F1, F2, F3, F4...]'
            + '\n   - Left column  gets: F0, F2, F4... (even positions)'
            + '\n   - Right column gets: F1, F3, F5... (odd positions)'
            + '\n   - This must be preserved when modifying existing layouts'
            + '\n4. behavior values — CRITICAL for reliable deploys:'
            + '\n   a) If the field is ALREADY PRESENT in an existing layout in org state:'
            + '\n      USE THE EXACT BEHAVIOR FROM ORG STATE — do NOT re-derive it.'
            + '\n      Read it from existingLayouts[ObjectName][n].sections[s].leftBehaviors[i]'
            + '\n      or .rightBehaviors[i] (parallel to leftFields / rightFields at the same index).'
            + '\n      This is MANDATORY. Changing an existing field\'s behavior will fail with errors like'
            + '\n      "Field:Name must be Readonly" (happens when Name is an AutoNumber field).'
            + '\n   b) If the field is NEW (being added in this ticket) — apply these defaults:'
            + '\n      - "Readonly" → system fields: Id, OwnerId, CreatedById, CreatedDate,'
            + '\n                     LastModifiedById, LastModifiedDate, SystemModstamp, IsDeleted,'
            + '\n                     AND any AutoNumber field (including Name when Name is AutoNumber)'
            + '\n      - "Required" → required custom fields and the Name field ONLY when Name is a'
            + '\n                     standard Text-type name (i.e. Name is NOT AutoNumber)'
            + '\n      - "Edit"     → all other custom fields'
            + '\n   RULE OF THUMB: if existingLayouts shows Name with behavior Readonly for an object,'
            + '\n   that object has an AutoNumber Name — always emit <behavior>Readonly</behavior> for Name.'
            + '\n5. style is always TwoColumnsTopToBottom'
            + '\n6. customLabel, detailHeading, editHeading are always true'
            + '\n7. Multiple sections → multiple <layoutSections> blocks in the same Layout XML'
            + '\n8. Each section has its own pair of <layoutColumns> following the same left/right rule'

            + '\n\n== LAYOUT SCENARIOS =='

            + '\n\n*** MANDATORY PRE-FLIGHT (run BEFORE choosing any scenario) ***'
            + '\nFor every CustomField you are about to emit on an existing object, run this check:'
            + '\n  IF the field\'s parent object is in orgState.existingObjects'
            + '\n  AND orgState.existingLayouts contains one or more layouts for that object'
            + '\n  THEN Scenario B FIRES — you MUST also emit a Layout file entry for EACH layout'
            + '\n  of that object listed in existingLayouts. This is non-negotiable.'
            + '\nThis rule fires even when the ticket text never mentions "layout", "section", or "page".'
            + '\nA response that adds a CustomField on an existing object listed in existingLayouts'
            + '\nbut omits the corresponding Layout file is INCORRECT and will be rejected.'
            + '\nReason: without the Layout file the new field lands only in the field palette and'
            + '\nis never placed in any section, so admins/users cannot see it on records.'

            + '\n\n-- SCENARIO A: Create brand new layout from scratch --'
            + '\nUse when: the ticket creates a brand-new custom object (present in files[] but NOT in existingObjects).'
            + '\nAction: You MUST emit a complete Layout XML alongside the CustomObject XML —'
            + '\n  even if the ticket does not mention "layout" or "page layout". Creating a new object'
            + '\n  without a layout leaves admins without a way to see the new fields in the UI.'
            + '\nNaming: For a new object, default layout name = "{ObjectLabel} Layout"'
            + '\n        e.g. Car__c (label "Car") → memberName = Car__c-Car Layout, filePath = layouts/Car__c-Car Layout.layout'
            + '\nSections: If the ticket specifies sections, use those. Otherwise use:'
            + '\n  - Section 1 "Information": Name + all required fields + main custom fields'
            + '\n  - Section 2 "Additional Information": remaining custom fields'
            + '\nFORBIDDEN: Do NOT include "Custom Links", "Mobile Cards", related-list placeholder'
            + '\n  sections, or any <layoutSections> block that contains <layoutItems> with empty'
            + '\n  <field></field> or empty <behavior></behavior> tags. The Metadata API rejects'
            + '\n  these with "\'\' is not a valid value for the enum \'UiBehavior\'".'
            + '\n  EVERY <layoutItems> you emit MUST have a non-empty <field>API_Name</field>'
            + '\n  and a non-empty <behavior>Edit|Required|Readonly</behavior>.'
            + '\nDEPLOYMENT PLAN: whenever Scenario A fires, you MUST set deploymentPlan.scenario = "chained".'
            + '\n  zip1Files = object + tab + profile + permissionSet + etc. (everything EXCEPT the layout)'
            + '\n  zip2Files = the layout file for the new object'
            + '\n  Reason: the Layout XML references field API names that only exist after the object deploys.'
            + '\n  Single-deploy scenarios would fail with "Invalid field ..." errors.'

            + '\n\n-- SCENARIO B: Add fields to an existing layout --'
            + '\nUse when ANY of the following is true:'
            + '\n  (1) ticket says "add field to layout", "show X on layout", "add to page layout", OR'
            + '\n  (2) the ticket creates one or more new custom fields on an EXISTING object that has'
            + '\n      layouts in existingLayouts — EVEN IF the ticket does not mention "layout".'
            + '\nRULE: whenever you emit a new CustomField on an existing object, you MUST ALSO emit a'
            + '\nLayout file for EACH existing layout of that object in existingLayouts, appending the'
            + '\nnew field(s) to the "Information" section (or the first section if no "Information"'
            + '\nexists). This is the default behavior — creating fields without updating the layout is'
            + '\nconsidered incomplete.'
            + '\nAction: Regenerate the COMPLETE Layout XML including ALL existing sections and fields'
            + '\n  PLUS the new fields added to the specified section (or "Information" if not specified)'
            + '\nHow to reconstruct from org state:'
            + '\n  existingLayouts[ObjectName][n].sections gives you sections with four parallel arrays:'
            + '\n    leftFields, leftBehaviors, rightFields, rightBehaviors'
            + '\n  For each section: interleave the fields AND their behaviors into an ordered pair list:'
            + '\n    ordered = [(left[0], leftBeh[0]), (right[0], rightBeh[0]),'
            + '\n               (left[1], leftBeh[1]), (right[1], rightBeh[1]), ...]'
            + '\n  PRESERVE each existing field\'s behavior EXACTLY — do NOT change Readonly to Required'
            + '\n  or vice versa (doing so breaks AutoNumber Name fields with "must be Readonly" errors).'
            + '\n  Append the NEW fields to the end of the ordered list with their own computed behaviors'
            + '\n  (Edit by default; Readonly for system/AutoNumber fields).'
            + '\nCRITICAL: Never drop existing fields AND never change existing behaviors —'
            + '\n  include ALL fields from org state with their ORIGINAL behaviors plus the new ones.'

            + '\n\n-- SCENARIO C: Remove fields from an existing layout --'
            + '\nUse when: ticket says "remove field from layout", "hide X from layout"'
            + '\nAction: Regenerate the COMPLETE Layout XML omitting only the specified fields'
            + '\nHow: Same reconstruction as Scenario B, but filter out the removed field(s)'
            + '\nCRITICAL: Preserve all other fields and sections exactly as in org state'

            + '\n\n-- SCENARIO D: Add a new section to an existing layout --'
            + '\nUse when: ticket says "add section", "new section on layout", "create section"'
            + '\nAction: Regenerate the COMPLETE Layout XML with all existing sections preserved,'
            + '\n  then append the new <layoutSections> block at the end'
            + '\nIf fields for the new section are specified, include them. Otherwise leave both columns empty:'
            + '\n    <layoutColumns></layoutColumns>'
            + '\n    <layoutColumns></layoutColumns>'

            + '\n\n-- SCENARIO E: Rename or reorder sections --'
            + '\nUse when: ticket says "rename section", "reorder layout", "move field"'
            + '\nAction: Reconstruct the full Layout XML applying the requested change'
            + '\n  For field moves: remove field from its current position, insert in new position'
            + '\n  Re-apply the even/odd left-right distribution after reordering'

            + '\n\n-- SCENARIO F: Delete a layout --'
            + '\nUse when: ticket says "delete layout", "remove layout"'
            + '\nAction: Use destructiveFiles with:'
            + '\n  type = Layout'
            + '\n  member = {ObjectName}-{LayoutName}  (e.g. Car__c-Car Layout)'
            + '\nDo NOT generate a Layout file entry — only a destructiveFiles entry'

            // ── PROFILE WITH LAYOUT ASSIGNMENT ────────────────────────
            + '\n\n== PROFILE LAYOUT ASSIGNMENT =='
            + '\nLayout assignment to a profile is done via a Profile XML file, NOT a separate tool.'
            + '\nWhen creating a new object OR when a ticket asks to assign a layout:'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <layoutAssignments>'
            + '\n        <layout>ObjectName__c-Layout Name</layout>'
            + '\n    </layoutAssignments>'
            + '\n    <tabVisibilities>'
            + '\n        <tab>ObjectName__c</tab>'
            + '\n        <visibility>DefaultOn</visibility>'
            + '\n    </tabVisibilities>'
            + '\n</Profile>'
            + '\nRULES:'
            + '\n- NEVER emit two file entries with the same filePath (e.g. profiles/Admin.profile)'
            + '\n  If a Profile entry already exists in files[] for tab visibility, ADD <layoutAssignments>'
            + '\n  into that SAME entry — merge them into one'
            + '\n- One Profile file can contain multiple <layoutAssignments> and multiple <tabVisibilities>'
            + '\n- For a specific record type assignment, add <recordType> inside the block:'
            + '\n    <layoutAssignments>'
            + '\n        <layout>ObjectName__c-Layout Name</layout>'
            + '\n        <recordType>ObjectName__c.RecordTypeName</recordType>'
            + '\n    </layoutAssignments>'
            + '\n- When creating a new object, ALWAYS assign the layout to Admin profile'
            + '\n  by including <layoutAssignments> in the Admin Profile file alongside tab visibility'
            + '\n- To assign to multiple profiles: generate one Profile file entry per profile'
            + '\n  e.g. profiles/Admin.profile, profiles/Sales_User.profile'

            + '\n\n== CSV BULK PROCESSING =='
            + '\nWhen a ticket has CSV file attachments, use dmlOperations with type csvProcess:'
            + '\n{'
            + '\n  "type": "csvProcess",'
            + '\n  "fileName": "exact_filename.csv",'
            + '\n  "csvType": "translation"'
            + '\n}'
            + '\nSupported csvType values:'
            + '\n- translation          → columns: language, labelName, translation'
            + '\n- custom_label         → columns: name, value (optional: language, shortDescription, protected)'
            + '\n- custom_metadata      → columns: apiName, recordName, label, [field columns]'
            + '\n- custom_metadata_type → columns: apiName, label, pluralLabel, fieldName, fieldLabel, fieldType'
            + '\n- validation_rule      → columns: objectName, ruleName, errorConditionFormula, errorMessage'
            + '\n- custom_setting_field → columns: apiName, fieldName, fieldLabel, fieldType'
            + '\n- custom_setting       → columns: apiName, label, settingType, fieldName, fieldLabel, fieldType'
            + '\n- group_member         → columns: groupDeveloperName, username'
            + '\n                          Adds users to existing Public Groups via DML (not metadata XML).'
            + '\n                          groupDeveloperName = the DeveloperName (API name) of the group,'
            + '\n                          username = the Salesforce username (email format) of the user.'
            + '\n                          Existing members are preserved — only net-new rows are inserted.'
            + '\n                          Do NOT generate any Group XML files when using this csvType.'
            + '\nRULES:'
            + '\n- ALWAYS use dmlOperations for CSV files — never try to read CSV content yourself'
            + '\n- Identify csvType from the attachment filename or ticket description'
            + '\n- fileName must exactly match the attachment name from the ticket'
            + '\n- Generate NO files array entries for CSV operations'

            // ── PERMISSION SET XML ─────────────────────────────────────
            + '\n\n== PERMISSION SET RULES =='
            + '\nPermission Sets have TWO different paths depending on the operation.'
            + '\n'
            + '\n-- PATH 1: CLONE (use dmlOperations — NEVER generate XML yourself) --'
            + '\nCloning copies ALL existing objectPermissions + fieldPermissions from the source.'
            + '\nThe XML is too large for the LLM to generate reliably. Apex retrieves it via SOAP.'
            + '\nUse this for: "clone permission set", "copy permission set", "duplicate permission set"'
            + '\n{'
            + '\n  "type": "permissionSetClone",'
            + '\n  "sourcePermissionSetName": "Existing_PS_API_Name",'
            + '\n  "newApiName": "New_PS_API_Name",'
            + '\n  "newLabel": "New PS Label",'
            + '\n  "description": "Optional description"'
            + '\n}'
            + '\nRULES for clone:'
            + '\n- sourcePermissionSetName: the API name of the existing PS to copy from'
            + '\n- newApiName: API name of the new PS (no __c suffix — PS API names do not use __c)'
            + '\n- newLabel: human-readable label for the new PS'
            + '\n- description: optional — if not specified, defaults to "Cloned from {source}"'
            + '\n- Do NOT generate any files[] entry for this — Apex handles everything'
            + '\n- EXCEPTION: if the ticket asks to clone AND then add/remove permissions, include permissionSetClone in dmlOperations'
            + '\n  AND also include ONE PermissionSet XML entry in files[] for newApiName with the requested final changes'
            + '\n'
            + '\n-- PATH 2: ALL OTHER OPERATIONS (generate XML in files[]) --'
            + '\nFor create, grant/revoke object access, grant/revoke field access, delete:'
            + '\nGenerate the Permission Set XML directly in the files[] array.'
            + '\nFile path: permissionsets/ApiName.permissionset-meta.xml'
            + '\nmetadataType: PermissionSet'
            + '\nmemberName: ApiName'
            + '\n'
            + '\nCreate (blank PS):'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>PS Label</label>'
            + '\n    <description>Optional description</description>'
            + '\n</PermissionSet>'
            + '\n'
            + '\nWith object + field permissions:'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <label>PS Label</label>'
            + '\n    <objectPermissions>'
            + '\n        <allowCreate>true</allowCreate>'
            + '\n        <allowDelete>false</allowDelete>'
            + '\n        <allowEdit>true</allowEdit>'
            + '\n        <allowRead>true</allowRead>'
            + '\n        <modifyAllRecords>false</modifyAllRecords>'
            + '\n        <object>MyObject__c</object>'
            + '\n        <viewAllRecords>false</viewAllRecords>'
            + '\n    </objectPermissions>'
            + '\n    <fieldPermissions>'
            + '\n        <editable>true</editable>'
            + '\n        <field>MyObject__c.MyField__c</field>'
            + '\n        <readable>true</readable>'
            + '\n    </fieldPermissions>'
            + '\n</PermissionSet>'
            + '\nRULES for non-clone PS operations:'
            + '\n- Every objectPermissions block needs ALL six boolean children: allowCreate, allowDelete, allowEdit, allowRead, modifyAllRecords, viewAllRecords'
            + '\n- fieldPermissions: editable and readable are the only children needed'
            + '\n- If granting field access, always also include an objectPermissions block with at least allowRead=true'
            + '\n- For DELETE: use destructiveFiles with metadataType PermissionSet and member = API name'
            + '\n- Do NOT use dmlOperations for Permission Set create/update/delete — dmlOperations is only for permissionSetClone'

            // ── PROFILE XML ────────────────────────────────────────────
            + '\n\n== PROFILE RULES =='
            + '\nProfiles have TWO paths depending on the operation.'
            + '\n'
            + '\n-- PATH 1: CLONE (use dmlOperations — NEVER generate XML yourself) --'
            + '\nCloning reads the full profile via SOAP readMetadata. XML is too large for the LLM.'
            + '\nUse this for: "clone profile", "copy profile", "duplicate profile", "create profile based on X"'
            + '\n{'
            + '\n  "type": "profileClone",'
            + '\n  "sourceProfileName": "Source Profile Name or API name",'
            + '\n  "newProfileName": "New_Profile_API_Name"'
            + '\n}'
            + '\nRULES for clone:'
            + '\n- sourceProfileName: the display name OR API name of the source (e.g. "System Administrator" or "Admin")'
            + '\n- newProfileName: the API name of the new profile (no spaces — use underscores)'
            + '\n- Do NOT generate any files[] entry for this — Apex handles everything'
            + '\n'
            + '\n-- PATH 2: UPDATE OPERATIONS (generate XML in files[]) --'
            + '\nSalesforce merges Profile XML additively — include ONLY the sections the ticket explicitly asks to change.'
            + '\nFile path: profiles/ProfileApiName.profile'
            + '\nmetadataType: Profile'
            + '\nmemberName: ProfileApiName'
            + '\n'
            + '\nStandard profile API name mappings:'
            + '\n  "System Administrator" → Admin'
            + '\n  "Standard User"        → Standard'
            + '\n  "Standard Platform User" → StandardAul'
            + '\nFor custom profiles: use the profile API name directly (no spaces — e.g. Reservation_Manager_Profile).'
            + '\n'
            + '\n-- OBJECT ACCESS --'
            + '\nUse when ticket says: grant/revoke read, create, edit, delete, view all, modify all on an object.'
            + '\n<objectPermissions>'
            + '\n    <allowCreate>true</allowCreate>'
            + '\n    <allowDelete>false</allowDelete>'
            + '\n    <allowEdit>true</allowEdit>'
            + '\n    <allowRead>true</allowRead>'
            + '\n    <modifyAllRecords>false</modifyAllRecords>'
            + '\n    <object>MyObject__c</object>'
            + '\n    <viewAllRecords>false</viewAllRecords>'
            + '\n</objectPermissions>'
            + '\nRULES:'
            + '\n- ALL six boolean children are required in every objectPermissions block'
            + '\n- "Read access" → allowRead=true, all others false (unless ticket says otherwise)'
            + '\n- "Read, Create, Edit" → allowRead=true, allowCreate=true, allowEdit=true, others false'
            + '\n- Multiple objects = multiple <objectPermissions> blocks in ONE profile file'
            + '\n'
            + '\n-- FIELD ACCESS --'
            + '\nUse when ticket says: grant/revoke field-level access on specific fields.'
            + '\n<fieldPermissions>'
            + '\n    <editable>true</editable>'
            + '\n    <field>MyObject__c.MyField__c</field>'
            + '\n    <readable>true</readable>'
            + '\n</fieldPermissions>'
            + '\n'
            + '\n-- APEX CLASS ACCESS --'
            + '\nUse when ticket says: "give access to apex classes", "grant apex class access", "all apex classes".'
            + '\nQuery org state to find class names. If ticket says "all apex classes", include all classes from org state.'
            + '\n<classAccesses>'
            + '\n    <apexClass>MyClassName</apexClass>'
            + '\n    <enabled>true</enabled>'
            + '\n</classAccesses>'
            + '\nRULES:'
            + '\n- apexClass value is the class API name (no namespace prefix unless the class is in a managed package)'
            + '\n- enabled=true to grant, enabled=false to revoke'
            + '\n- Multiple classes = multiple <classAccesses> blocks in ONE profile file'
            + '\n- NEVER use <classAccesses> for Visualforce pages — use <pageAccesses> instead'
            + '\n- The org state "apexClasses" key contains the full list of class names — use those exact names'
            + '\n- If "all apex classes" is requested, generate a <classAccesses> block for every name in apexClasses'
            + '\n'
            + '\n-- TAB VISIBILITY --'
            + '\nUse ONLY when the ticket explicitly asks to show/hide a tab for the profile.'
            + '\nDO NOT add tabVisibilities just because you are granting object access — they are separate.'
            + '\nThe <tab> value must exactly match a CustomTab that already exists in the org OR is being'
            + '\ncreated in the same deploy (in the files[] array as a CustomTab entry).'
            + '\nIf you are unsure whether a CustomTab exists for an object, DO NOT generate tabVisibilities.'
            + '\n<tabVisibilities>'
            + '\n    <tab>ObjectName__c</tab>'
            + '\n    <visibility>DefaultOn</visibility>'
            + '\n</tabVisibilities>'
            + '\nvisibility values: DefaultOn, DefaultOff, Hidden'
            + '\n'
            + '\n-- FULL EXAMPLE: object access + apex class access in one profile file --'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <classAccesses>'
            + '\n        <apexClass>ReservationController</apexClass>'
            + '\n        <enabled>true</enabled>'
            + '\n    </classAccesses>'
            + '\n    <classAccesses>'
            + '\n        <apexClass>CarService</apexClass>'
            + '\n        <enabled>true</enabled>'
            + '\n    </classAccesses>'
            + '\n    <objectPermissions>'
            + '\n        <allowCreate>true</allowCreate>'
            + '\n        <allowDelete>false</allowDelete>'
            + '\n        <allowEdit>true</allowEdit>'
            + '\n        <allowRead>true</allowRead>'
            + '\n        <modifyAllRecords>false</modifyAllRecords>'
            + '\n        <object>Reservation__c</object>'
            + '\n        <viewAllRecords>false</viewAllRecords>'
            + '\n    </objectPermissions>'
            + '\n    <objectPermissions>'
            + '\n        <allowCreate>false</allowCreate>'
            + '\n        <allowDelete>false</allowDelete>'
            + '\n        <allowEdit>false</allowEdit>'
            + '\n        <allowRead>true</allowRead>'
            + '\n        <modifyAllRecords>false</modifyAllRecords>'
            + '\n        <object>Car__c</object>'
            + '\n        <viewAllRecords>false</viewAllRecords>'
            + '\n    </objectPermissions>'
            + '\n</Profile>'
            + '\n'
            + '\nCRITICAL PROFILE RULES:'
            + '\n1. NEVER add <tabVisibilities> unless the ticket explicitly asks to show/hide a tab'
            + '\n2. NEVER reference a CustomTab that does not exist — it will cause a deploy failure'
            + '\n3. Only include profile sections that match what the ticket asks for'
            + '\n4. For DELETE: use destructiveFiles with metadataType Profile and member = profile API name'
            + '\n5. Standard/system profiles (Admin, Standard, StandardAul, MarketingProfile etc.) CANNOT be deleted'
            + '\n6. The org state classAccesses section lists existing Apex class names — use those exact names'


            + '\n\n== QUEUE RULES =='
            + '\nFile path: queues/QueueApiName.queue'
            + '\nmetadataType: Queue'
            + '\nmemberName: QueueApiName'
            + '\n'
            + '\nCRITICAL — ELEMENT ORDER (Salesforce rejects wrong order):'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Queue xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <doesSendEmailToMembers>false</doesSendEmailToMembers>'
            + '\n    <!-- email: include ONLY when explicitly provided -->'
            + '\n    <email>queue@example.com</email>'
            + '\n    <name>Queue Display Name</name>'
            + '\n    <queueMembers>'
            + '\n        <!-- Include <users> only when explicit real usernames are provided in ticket -->'       
            + '\n    </queueMembers>'
            + '\n    <queueRoutingConfig>RoutingConfigApiName</queueRoutingConfig>'
            + '\n    <queueSobject>'
            + '\n        <sobjectType>Case</sobjectType>'
            + '\n    </queueSobject>'
            + '\n    <queueSobject>'
            + '\n        <sobjectType>MyObject__c</sobjectType>'
            + '\n    </queueSobject>'
            + '\n</Queue>'
            + '\n'
            + '\n\nCRITICAL — QUEUE MEMBER RULE:'
            + '\nThe usernames in the example above (user1@example.com, user2@example.com) are PLACEHOLDERS only.'
            + '\n<user> tags MUST only contain usernames explicitly stated in the ticket in email format.'
            + '\nIf the ticket says "Sales Users", "Support Users", "Team Members" or any non-email description:'
            + '\n  → These are group/role descriptions, NOT usernames'
            + '\n  → NEVER convert them to email format'
            + '\n  → OMIT the <users> block entirely'
            + '\n  → If a matching public group exists in org state existingGroups, use <publicGroups> instead'
            + '\nOnly put values inside <user> tags that look exactly like: firstname.lastname@company.com'
            + '\nMANDATORY ELEMENT ORDER (must follow exactly):'
            + '\n  1. doesSendEmailToMembers'
            + '\n  2. email              (optional — omit entirely if not provided)'
            + '\n  3. name'
            + '\n  4. queueMembers       (optional — omit entirely if no members)'
            + '\n  5. queueRoutingConfig (optional — omit entirely if not provided)'
            + '\n  6. queueSobject       (one block per object — at least one required)'
            + '\nAny other order will cause a deploy failure.'
            + '\n'
            + '\n-- CREATE --'
            + '\nGenerate full Queue XML with all fields specified in the ticket.'
            + '\nDo NOT include <email> unless a valid email address is explicitly provided.'
            + '\n'
            + '\n-- UPDATE --'
            + '\nGenerate the complete final desired Queue XML.'
            + '\nStart from existingQueues in org state — preserve ALL existing values unless ticket says to change them:'
            + '\n  - Keep all existing sobjectTypes unless ticket removes one'
            + '\n  - Keep all existing members unless ticket removes one'
            + '\n  - Keep existing email, routingConfig unless ticket changes them'
            + '\n  - Only modify what the ticket explicitly asks to change'
            + '\nCRITICAL: Never drop existing sobjectTypes or members — always merge old + new.'
            + '\n'
            + '\n-- DELETE --'
            + '\nUse destructiveFiles with metadataType Queue and member = Queue API name (DeveloperName).'
            + '\n'
            + '\nOTHER RULES:'
            + '\n- <name> is the display label'
            + '\n- Queue API name (DeveloperName) has no spaces — use underscores'
            + '\n- One <queueSobject> block per object type'
            + '\n- ONE <queueMembers> block maximum — nest all member types inside it'
            + '\n- Inside queueMembers: <users> for users, <publicGroups> for groups, <roles> for roles'
            + '\n- <doesIncludeBosses> is NOT a valid Queue element — do not include it'
            + '\n- NEVER fabricate usernames. If the ticket says "Sales Users" or "Support Users" without'
            + '\n  explicit email addresses, use <publicGroups> with the matching group DeveloperName instead,'
            + '\n  or omit <queueMembers> entirely. Only put real email addresses inside <user> tags.'
            + '\n\nCRITICAL — QUEUE MEMBERS RULE:'
            + '\nOnly add <queueMembers> if the ticket provides REAL, explicit usernames.'
            + '\n"Sales Users", "Support Users", "Team Members" etc. are role descriptions — NOT usernames.'
            + '\nIf member names are vague, descriptive, or not in email format → OMIT <queueMembers> entirely.'
            + '\nNEVER fabricate or guess usernames. A missing queueMembers block is safe; a fake username breaks the deploy.'

            + '\n\n== PUBLIC GROUP RULES =='
            + '\nFile path: groups/GroupApiName.group'
            + '\nmetadataType: Group'
            + '\nmemberName: GroupApiName'
            + '\n'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Group xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <name>Group Display Name</name>'
            + '\n    <doesIncludeBosses>false</doesIncludeBosses>'
            + '\n    <members>'
            + '\n        <members>username@example.com</members>'
            + '\n        <type>User</type>'
            + '\n    </members>'
            + '\n    <members>'
            + '\n        <members>CEO</members>'
            + '\n        <type>Role</type>'
            + '\n    </members>'
            + '\n</Group>'
            + '\n'
            + '\nMANDATORY ELEMENT ORDER:'
            + '\n  1. name               (required — display label, spaces allowed)'
            + '\n  2. doesIncludeBosses  (optional — defaults to false)'
            + '\n  3. members            (optional — one block per member, repeating)'
            + '\n'
            + '\nVALID ELEMENTS — ONLY these three exist on Group metadata:'
            + '\n  <name>, <doesIncludeBosses>, <members>'
            + '\n  NOTHING ELSE. Do not add any other elements.'
            + '\n'
            + '\nSTRICTLY FORBIDDEN — these do NOT exist on Group and will cause deploy failure:'
            + '\n  <doesSendEmailToMembers>  ← Queue-only, NOT valid on Group'
            + '\n  <type>Regular</type>      ← NOT a valid Group element'
            + '\n  <sharedTo>                ← does not exist in Group metadata'
            + '\n'
            + '\nMEMBER TYPES — <type> value inside each <members> block:'
            + '\n  User                → <members> = username (email address)'
            + '\n  Role                → <members> = exact role name (e.g. CEO)'
            + '\n  RoleAndSubordinates → <members> = role name, includes all subordinates'
            + '\n  Group               → <members> = DeveloperName of another public group'
            + '\n  AllInternalUsers    → <members> = AllInternalUsers'
            + '\n'
            + '\nRULES:'
            + '\n- GroupApiName (DeveloperName) has no spaces — use underscores'
            + '\n- For UPDATES: regenerate complete XML preserving existing members, only change what ticket asks'
            + '\n- For DELETE: use destructiveFiles with metadataType Group and member = GroupApiName'
            + '\n- Never use Group metadata for Queues — Queues have their own metadata type'


            // ── ASSIGNMENT RULES XML ───────────────────────────────────────
            + '\n\n== ASSIGNMENT RULES XML FORMAT =='
            + '\nThere are TWO assignment rule files — one per object:'
            + '\n  Lead rules → assignmentRules/Lead.assignmentRules  (memberName: Lead)'
            + '\n  Case rules → assignmentRules/Case.assignmentRules  (memberName: Case)'
            + '\nmetadataType: AssignmentRules'
            + '\nALL rules for the same object go into ONE file — never split them.'
            + '\n'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<AssignmentRules xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <assignmentRule>'
            + '\n        <fullName>RuleName</fullName>'
            + '\n        <active>true</active>'
            + '\n        <!-- ruleEntry with criteria -->'
            + '\n        <ruleEntry>'
            + '\n            <assignedTo>john.doe@company.com</assignedTo>'
            + '\n            <assignedToType>User</assignedToType>'
            + '\n            <criteriaItems>'
            + '\n                <field>Lead.Country</field>'
            + '\n                <operation>equals</operation>'
            + '\n                <value>US,USA,United States</value>'
            + '\n            </criteriaItems>'
            + '\n            <criteriaItems>'
            + '\n                <field>Lead.Industry</field>'
            + '\n                <operation>contains</operation>'
            + '\n                <value>Technology</value>'
            + '\n            </criteriaItems>'
            + '\n        </ruleEntry>'
            + '\n        <!-- ruleEntry with formula -->'
            + '\n        <ruleEntry>'
            + '\n            <assignedTo>Lead_Queue</assignedTo>'
            + '\n            <assignedToType>Queue</assignedToType>'
            + '\n            <formula>ISBLANK( Email )</formula>'
            + '\n        </ruleEntry>'
            + '\n    </assignmentRule>'
            + '\n</AssignmentRules>'
            + '\n'
            + '\n== ASSIGNMENT RULES RULES =='
            + '\n'
            + '\n-- STRUCTURE --'
            + '\n- Dont add user unless it is explicitly provided in the ticket — never fabricate usernames'
            + '\n- One file per object: Lead or Case — NEVER combine Lead and Case in same file'
            + '\n- ALL rules for the same object go in ONE file with multiple <assignmentRule> blocks'
            + '\n- Each <assignmentRule> has <fullName>, <active>, and one or more <ruleEntry> blocks'
            + '\n- Each <ruleEntry> has <assignedTo>, <assignedToType>, then EITHER <criteriaItems> OR <formula>'
            + '\n- <criteriaItems> and <formula> are mutually exclusive per ruleEntry — never use both'
            + '\n- Multiple <criteriaItems> in one ruleEntry = AND logic between them'
            + '\n'
            + '\n-- ACTIVE RULE --'
            + '\n- Only ONE rule per object can be active=true at a time'
            + '\n- If ticket says "activate" a rule, set that rule active=true and ALL other rules active=false'
            + '\n- If ticket says "deactivate" a rule, set active=false — do not change other rules'
            + '\n- If creating a new rule and ticket says it should be active, set active=true and set ALL'
            + '\n  existing rules from org state to active=false in the same file'
            + '\n- If ticket does not mention active/inactive, default new rules to active=false'
            + '\n'
            + '\n-- ASSIGNED TO --'
            + '\n- assignedToType: User or Queue'
            + '\n- If User: assignedTo = exact username (email format) — NEVER fabricate usernames'
            + '\n- If Queue: assignedTo = Queue DeveloperName (e.g. Lead_Queue, Support_Queue)'
            + '\n- If ticket says "assign to Sales Queue", use the matching DeveloperName from existingQueues in org state'
            + '\n- If no real username provided and assignedToType would be User → omit the ruleEntry entirely'
            + '\n'
            + '\n-- CRITERIA ITEMS --'
            + '\n- field format: ObjectName.FieldApiName (e.g. Lead.Country, Case.Status, Lead.Industry)'
            + '\n- operation values: equals, notEqual, contains, notContain, startsWith, greaterThan,'
            + '\n                    greaterOrEqual, lessThan, lessOrEqual, isNull'
            + '\n- value: comma-separated for multiple values (e.g. "US,USA,United States")'
            + '\n- Multiple <criteriaItems> in same ruleEntry = AND logic'
            + '\n- For OR logic: use separate <ruleEntry> blocks'
            + '\n'
            + '\n-- FORMULA --'
            + '\n- Use <formula> instead of <criteriaItems> when ticket says "formula" or gives a formula expression'
            + '\n- Formula syntax: same as Salesforce formula fields'
            + '\n- ALWAYS XML-escape formula characters: < → &lt; > → &gt; & → &amp;'
            + '\n- Example: ISBLANK( Email ), NOT(ISBLANK( Country__c )), Country = "US"'
            + '\n'
            + '\n-- CREATE --'
            + '\n- Generate the complete AssignmentRules XML for that object'
            + '\n- If org state has existingAssignmentRules for that object, include ALL existing rules'
            + '\n  plus the new one — never drop existing rules'
            + '\n- New rule goes at the end of the file'
            + '\n'
            + '\n-- UPDATE (add/remove rule entries, change criteria) --'
            + '\n- Regenerate the COMPLETE file preserving all existing rules'
            + '\n- Only modify the specific rule and entries the ticket asks to change'
            + '\n'
            + '\n-- ACTIVATE / DEACTIVATE --'
            + '\n- Regenerate the COMPLETE file with active flags updated as requested'
            + '\n- CRITICAL: Only one rule can be active=true — enforce this always'
            + '\n'
            + '\n-- DELETE a specific rule --'
            + '\n- Regenerate the COMPLETE AssignmentRules file for that object'
            + '\n- Include ALL existing rules from existingAssignmentRules in org state EXCEPT the deleted one'
            + '\n- Do NOT use destructiveFiles for individual rules — always regenerate the whole file'
            + '\n- Example: if Lead has rules [A, B, C] and ticket says delete B → regenerate file with only [A, C]'
            + '\n'
            + '\n-- DELETE ALL rules (wipe entire object) --'
            + '\n- Salesforce does NOT support deleting AssignmentRules via destructiveFiles — never use that path'
            + '\n- Instead: deploy an EMPTY AssignmentRules file (no <assignmentRule> elements inside)'
            + '\n- Use files[] with metadataType AssignmentRules, memberName Lead or Case,'
            + '\n  filePath assignmentRules/Lead.assignmentRules (or Case.assignmentRules)'
            + '\n- Empty file format:'
            + '\n  <?xml version="1.0" encoding="UTF-8"?>'
            + '\n  <AssignmentRules xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n  </AssignmentRules>'
            + '\n- Only use this when the ticket says to delete ALL rules or the entire assignment rule configuration'

            + '\n\n== RECORD TYPE RULES =='
            + '\nRecord Types are embedded inside the CustomObject XML as <recordTypes> blocks.'
            + '\nFile path: objects/ObjectName.object  (standard objects e.g. Case, Account)'
            + '\n           objects/ObjectName__c.object (custom objects e.g. MyObject__c)'
            + '\nmetadataType: CustomObject'
            + '\nmemberName: ObjectName or ObjectName__c'
            + '\n'
            + '\nCRITICAL: Standard objects use NO __c suffix:'
            + '\n  Correct:   Case, Account, Contact, Lead, Opportunity'
            + '\n  Incorrect: Case__c, Account__c'
            + '\n'
            + '\n== STANDARD OBJECT RECORD TYPES — ABSOLUTE RULES =='
            + '\nWhen the object is a STANDARD object (Account, Case, Contact, Lead, Opportunity, etc.):'
            + '\n'
            + '\n1. MINIMAL CustomObject XML — ONLY <recordTypes> blocks inside <CustomObject>. NOTHING else.'
            + '\n   The ONLY valid format for a standard object CustomObject file is:'
            + '\n   <?xml version=\"1.0\" encoding=\"UTF-8\"?>'
            + '\n   <CustomObject xmlns=\"http://soap.sforce.com/2006/04/metadata\">'
            + '\n       <recordTypes>'
            + '\n           <fullName>Record_Type_API_Name</fullName>'
            + '\n           <active>true</active>'
            + '\n           <description>Optional description</description>'
            + '\n           <label>Record Type Label</label>'
            + '\n       </recordTypes>'
            + '\n   </CustomObject>'
            + '\n'
            + '\n   FORBIDDEN in standard object CustomObject XML (causes deploy failure):'
            + '\n   - <label> at the object level     [Master label must be provided error]'
            + '\n   - <pluralLabel>'
            + '\n   - <nameField>                      [Cannot specify a name field for a standard object]'
            + '\n   - <sharingModel>'
            + '\n   - <deploymentStatus>'
            + '\n'
            + '\n2. NEVER generate a CustomTab file for a standard object.'
            + '\n   Account, Case, Contact, Lead etc. already have built-in tabs.'
            + '\n   Emitting a CustomTab for them causes [Master label must be provided] error.'
            + '\n'
            + '\n3. NEVER add <tabVisibilities> in any Profile XML for a standard object.'
            + '\n   Standard objects have built-in tabs. They are NOT CustomTabs.'
            + '\n   <tabVisibilities><tab>Account</tab> causes [no CustomTab named Account found].'
            + '\n'
            + '\n4. NEVER generate a Layout file for a standard object.'
            + '\n   Standard object layouts already exist in the org. Only reference them'
            + '\n   by name inside Profile <layoutAssignments>. Never emit a Layout file.'
            + '\n'
            + '\nQUICK REFERENCE for a standard-object record type ticket (e.g. Account):'
            + '\n  File 1: objects/Account.object  — CustomObject with ONLY <recordTypes> block(s)'
            + '\n  File 2: profiles/Admin.profile  — Profile with <layoutAssignments> + <recordTypeVisibilities>'
            + '\n  NO CustomTab file. NO <tabVisibilities>. NO Layout file. Ever.'
            + '\n'
            + '\nrecordType reference format is ALWAYS: ObjectName.DeveloperName'
            + '\n  Custom:   MyObject__c.My_Record_Type'
            + '\n  Standard: Case.My_Record_Type'
            + '\n'
            + '\n-- RECORD TYPE XML STRUCTURE --'
            + '\nEmbedded inside <CustomObject>:'
            + '\n<recordTypes>'
            + '\n    <fullName>Record_Type_API_Name</fullName>'
            + '\n    <active>true</active>'
            + '\n    <description>Optional description</description>'
            + '\n    <label>Record Type Label</label>'
            + '\n    <picklistValues>'
            + '\n        <picklist>Status__c</picklist>'
            + '\n        <values>'
            + '\n            <fullName>Active</fullName>'
            + '\n            <default>false</default>'
            + '\n        </values>'
            + '\n        <values>'
            + '\n            <fullName>Inactive</fullName>'
            + '\n            <default>true</default>'
            + '\n        </values>'
            + '\n    </picklistValues>'
            + '\n</recordTypes>'
            + '\n'
            + '\nCRITICAL: Inside <values>, ONLY two elements are allowed:'
            + '\n  1. <fullName>  — the picklist value API name'
            + '\n  2. <default>   — true or false'
            + '\nNEVER include <label> inside <values> — it does not exist and will break the deploy.'
            + '\nELEMENT ORDER inside <recordTypes> MUST be:'
            + '\n  1. fullName'
            + '\n  2. active'
            + '\n  3. businessProcess  ← ONLY for Case/Lead/Opportunity/Solution (see below)'
            + '\n  4. description (optional — omit entirely if not provided)'
            + '\n  5. label'
            + '\n  6. picklistValues (optional — one block per picklist field)'
            + '\n'
            + '\n== PROCESS-DRIVEN OBJECTS — CRITICAL =='
            + '\nCase, Lead, Opportunity, and Solution record types REQUIRE a <businessProcess>'
            + '\nelement. Omitting it causes: "Required field is missing: businessProcess"'
            + '\n'
            + '\nObject → Business Process type:'
            + '\n  Case        → Support Process  (TableEnumOrId = Case)'
            + '\n  Lead        → Lead Process      (TableEnumOrId = Lead)'
            + '\n  Opportunity → Sales Process     (TableEnumOrId = Opportunity)'
            + '\n  Solution    → Solution Process  (TableEnumOrId = Solution)'
            + '\n'
            + '\nThe available Business Process names are in orgState.existingBusinessProcesses:'
            + '\n  { "Case": ["Basic Support Process", ...], "Lead": ["Standard Lead Process"], ... }'
            + '\nALWAYS use the first entry for the relevant object:'
            + '\n  existingBusinessProcesses["Case"][0]     → for Case record types'
            + '\n  existingBusinessProcesses["Lead"][0]     → for Lead record types'
            + '\n  existingBusinessProcesses["Opportunity"][0] → for Opportunity record types'
            + '\n'
            + '\nCORRECT XML for a Case record type:'
            + '\n<recordTypes>'
            + '\n    <fullName>Technical_Support</fullName>'
            + '\n    <active>true</active>'
            + '\n    <businessProcess>Basic Support Process</businessProcess>'
            + '\n    <description>Record type for technical support cases</description>'
            + '\n    <label>Technical Support</label>'
            + '\n</recordTypes>'
            + '\n'
            + '\nIf existingBusinessProcesses is empty or missing the object key:'
            + '\n  → Return an error in summary: "No active Business Process found for [Object].'
            + '\n    Please create a Support/Sales/Lead Process first in Salesforce Setup."'
            + '\n  → Do NOT generate any files — the deploy will fail without a valid process.'
            + '\n'
            + '\nFor Account, Contact, and all other standard/custom objects:'
            + '\n  → NEVER include <businessProcess> — it does not exist on those objects.'
            + '\n'
            + '\n-- CREATE --'
            + '\n1. Embed <recordTypes> block inside the CustomObject XML'
            + '\n2. For EXISTING objects:'
            + '\n   - Use full CustomObject wrapper with label/pluralLabel/nameField/sharingModel from orgState'
            + '\n   - Preserve ALL existing record types from existingRecordTypes in orgState'
            + '\n   - Add the new <recordTypes> block alongside existing ones'
            + '\n3. For NEW objects:'
            + '\n   - Include <recordTypes> block inside the new object definition'
            + '\n4. Always generate a Profile file for each profile mentioned in the ticket:'
            + '\n   - <layoutAssignments> with <layout> AND <recordType>'
            + '\n   - <recordTypeVisibilities> with <visible> and <default>'
            + '\n5. If ticket does not specify a layout:'
            + '\n   - Use the first layout from existingLayouts for that object in orgState'
            + '\n6. If ticket does not specify default → set default=false'
            + '\n7. deploymentPlan:'
            + '\n   - New object with record type → chained (object first, layout+profile second)'
            + '\n   - Existing object with record type → single'
            + '\n8. NEVER generate a Layout XML file for standard objects — standard object'
            + '\n   layouts already exist. Only reference them in Profile <layoutAssignments>.'
            + '\n9. NEVER add tabVisibilities to Profile for standard objects.'
            + '\n'
            + '\n-- PICKLIST VALUES --'
            + '\n1. Only include <picklistValues> if ticket specifies which values to assign'
            + '\n2. If ticket says "all values" → include ALL picklist values from existingFields in orgState'
            + '\n3. If ticket specifies a subset → include ONLY those values'
            + '\n4. If ticket does not mention picklist values → OMIT <picklistValues> entirely'
            + '\n5. Each <picklistValues> block covers ONE picklist field'
            + '\n6. NEVER fabricate picklist values — only use values that exist in orgState existingFields'
            + '\n'
            + '\n-- PICKLIST VALUES XML STRUCTURE --'
            + '\n<picklistValues>'
            + '\n    <picklist>FieldApiName__c</picklist>'
            + '\n    <values>'
            + '\n        <fullName>PicklistValue</fullName>'
            + '\n        <default>false</default>'
            +'\n </values>'
            + '\n    </values>'
            + '\n</picklistValues>'
            + '\n'
            + '\n </picklistValues>'
            + '\n'
            + '\n CRITICAL: Inside <values>, ONLY two elements are allowed:'
            + '\n  CRITICAL: For Case profile layoutAssignments, the master layout name is exactly what '
            + '\n  standardObjectLayoutNames["Case"][0] returns. NEVER use "Default" as a layout name.'
            + '\n  Always use the full name from standardObjectLayoutNames.'
            + '\n  1. <fullName>  — the picklist value API name'
            + '\n  2. <default>   — true or false'
            + '\n  NEVER include <label> inside <values> — it does not exist and will break the deploy.'
            + '\n'
            + '\n-- UPDATE --'
            + '\n1. Find the record type in existingRecordTypes by developerName + sobjectType'
            + '\n2. If NOT found in orgState → return error in summary, do NOT generate files'
            + '\n3. Regenerate COMPLETE CustomObject XML:'
            + '\n   - Include ALL existing record types from orgState'
            + '\n   - Only modify the specific record type the ticket mentions'
            + '\n   - Preserve all other record types exactly as they are in orgState'
            + '\n4. Only change what the ticket explicitly requests'
            + '\n5. deploymentPlan: single'
            + '\n'
            + '\n-- DELETE --'
            + '\n1. Confirm the record type exists in existingRecordTypes in orgState'
            + '\n2. If NOT found → return error in summary, do NOT generate files'
            + '\n3. NEVER delete the Master record type — it is a system default'
            + '\n4. Use destructiveFiles shorthand (Apex builds destructiveChangesPost.xml):'
            + '\n   {'
            + '\n     "metadataType": "RecordType",'
            + '\n     "member": "ObjectName.RecordTypeDeveloperName"'
            + '\n   }'
            + '\n5. Do NOT generate any files[] entry for delete'
            + '\n'
            + '\n-- PROFILE ASSIGNMENT --'
            + '\nGenerate one Profile file per profile mentioned in ticket.'
            + '\nFile path: profiles/ProfileApiName.profile'
            + '\nmetadataType: Profile'
            + '\nmemberName: ProfileApiName'
            + '\n'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Profile xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <layoutAssignments>'
            + '\n        <layout>ObjectName-Layout Name</layout>'
            + '\n        <recordType>ObjectName.RecordTypeDeveloperName</recordType>'
            + '\n    </layoutAssignments>'
            + '\n    <recordTypeVisibilities>'
            + '\n        <recordType>ObjectName.RecordTypeDeveloperName</recordType>'
            + '\n        <default>false</default>'
            + '\n        <visible>true</visible>'
            + '\n    </recordTypeVisibilities>'
            + '\n</Profile>'
            + '\n'
            + '\nCRITICAL — LAYOUT REFERENCE FORMAT IN <layoutAssignments>:'
            + '\n  <layout> MUST always be: ObjectName-Layout Name (joined by ONE dash).'
            + '\n  Examples: Account-Account Layout | Case-Case Layout | MyObj__c-My Obj Layout'
            + '\n  NEVER emit a bare name like "Account Layout" — Salesforce will reject it.'
            + '\n'
            + '\nHOW TO FIND THE CORRECT LAYOUT NAME FOR STANDARD OBJECTS:'
            + '\n  Standard object layout names are in orgState.standardObjectLayoutNames.'
            + '\n  Format: { "Account": ["Account-Account Layout", ...], "Case": [...] }'
            + '\n  ALWAYS use the first entry: standardObjectLayoutNames["Account"][0]'
            + '\n  Do NOT guess layout names. Do NOT use existingLayouts for standard objects.'
            + '\n  If standardObjectLayoutNames is missing a key, use "ObjectName-ObjectName Layout"'
            + '\n  as the fallback (e.g. "Account-Account Layout").'
            + '\n'
            + '\nNEVER GENERATE A LAYOUT XML FILE FOR STANDARD OBJECTS.'
            + '\n  Account, Case, Contact, Lead, Opportunity etc. already have layouts in the org.'
            + '\n  Only reference the layout name inside Profile <layoutAssignments>.'
            + '\n  Generating a Layout XML for a standard object causes:'
            + '\n    "Layout must contain an item for required layout field: <field>"'
            + '\n'
            + '\nPROFILE RULES:'
            + '\n1. ONE profile file per profile — merge ALL layoutAssignments + recordTypeVisibilities'
            + '\n   into the SAME profile file if multiple record types are assigned to it'
            + '\n2. default=true means this is the default record type for that profile'
            + '\n3. NEVER set default=true on more than one record type per profile per object'
            + '\n4. visible=true to show, visible=false to hide from profile'
            + '\n5. If ticket says "default record type for Profile X" → default=true, visible=true'
            + '\n6. If ticket says "visible but not default" → default=false, visible=true'
            + '\n7. If ticket says "hide from profile" → default=false, visible=false'
            + '\n8. NEVER add tabVisibilities unless ticket explicitly asks for it'
            + '\nTABVISIBILITIES ABSOLUTE RULES:'
            + '\n- NEVER add <tabVisibilities> for ANY standard object'
            + '\n  (Account, Case, Contact, Lead, Opportunity, Task, Event etc.)'
            + '\n  Standard objects already have built-in tabs — referencing them'
            + '\n  as CustomTab will fail with "no CustomTab named X found"'
            + '\n- ONLY add <tabVisibilities> for custom objects (__c suffix)'
            + '\n  AND only when the ticket explicitly asks to show/hide a tab'
            + '\n- When in doubt → OMIT <tabVisibilities> entirely'
            + '\n- For Record Type tickets on standard objects → NEVER generate'
            + '\n  tabVisibilities under any circumstances'
            + '\n9. layoutAssignments MUST include <recordType> when assigning layout per record type'
            + '\n10. NEVER generate a Layout XML file for standard objects (Account, Case, Contact,'
            + '\n    Lead, Opportunity etc.) — only reference the existing layout name in'
            + '\n    <layoutAssignments>. Standard object layouts already exist in the org.'
            + '\n10. DEFAULT RECORD TYPE RULE — CRITICAL:'
            + '\n    Salesforce requires exactly ONE recordTypeVisibility per object to have default=true.'
            + '\n    - If ticket says Default=true  → set <default>true</default> on that RT'
            + '\n    - If ticket says Default=false → STILL set <default>true</default> on the new RT'
            + '\n      because it is the only record type and must be the default'
            + '\n    - NEVER emit <recordType>ObjectName.Master</recordType> — Master is not a real'
            + '\n      Metadata API record type name and will cause deploy failure'
            + '\n    - NEVER leave all recordTypeVisibilities with default=false'
            + '\n11. NEVER add <tabVisibilities> for standard objects — they already have'
            + '\n    standard tabs. tabVisibilities is only for custom object tabs.'
            + '\n12. NEVER regenerate or emit a Layout file entry just because of a record type'
            + '\n    assignment — only add <layoutAssignments> inside the Profile file.'
            + '\n'
            + '\n-- MULTIPLE RECORD TYPES ON SAME OBJECT --'
            + '\nWhen creating multiple record types in same ticket:'
            + '\n1. All <recordTypes> blocks go into ONE CustomObject file'
            + '\n2. Only ONE record type can be default=true per profile'
            + '\n3. Each record type can have different layout per profile'
            + '\n4. Generate ONE profile file per profile with ALL record type assignments inside it'
            + '\n'
            + '\n-- RULES SUMMARY --'
            + '\n1. ALWAYS preserve ALL existing record types when updating — never drop any'
            + '\n2. NEVER fabricate record type names, picklist values, or layout names'
            + '\n3. Standard objects: no __c suffix in memberName or recordType reference'
            + '\n4. Custom objects: always include __c suffix'
            + '\n5. recordType reference format: ObjectName.DeveloperName (no spaces)'
            + '\n6. DeveloperName: no spaces, no __c suffix, underscores only'
            + '\n7. Master record type cannot be deleted'
            + '\n8. For new object + record type → always chained deployment'
            + '\n9. For existing object + record type → always single deployment'
            + '\n10. NEVER emit two files[] entries with same filePath — merge into one'

            // ── STANDARD OBJECT CUSTOMOBJECT XML RULES ─────────────────
            + '\n\n== STANDARD OBJECT CUSTOMOBJECT XML — STRICT RULES =='
            + '\nWhen generating CustomObject XML for a STANDARD object (Account, Case, Contact,'
            + '\nLead, Opportunity, Task, Event — i.e. any object WITHOUT __c or __mdt suffix):'
            + '\n'
            + '\nFORBIDDEN — Salesforce rejects these on standard objects:'
            + '\n  <nameField>        — causes "Cannot specify a name field for a standard object"'
            + '\n  <pluralLabel>      — not valid on standard objects'
            + '\n  <deploymentStatus> — not valid on standard objects'
            + '\n  <sharingModel>     — not valid on standard objects'
            + '\n'
            + '\nALLOWED in standard object CustomObject XML:'
            + '\n  <label>            — optional'
            + '\n  <recordTypes>      — Record Type definitions'
            + '\n  <fields>           — only when adding custom fields'
            + '\n  <validationRules>  — only when adding validation rules'
            + '\n'
            + '\nMINIMAL CORRECT example (Record Type on Account):'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <recordTypes>'
            + '\n        <fullName>Corporate_Account</fullName>'
            + '\n        <active>true</active>'
            + '\n        <description>Record type for corporate accounts</description>'
            + '\n        <label>Corporate Account</label>'
            + '\n    </recordTypes>'
            + '\n</CustomObject>'
            + '\n'
            + '\nDo NOT add <nameField>, <pluralLabel>, <deploymentStatus>, <sharingModel>.'
            + '\n'
            + '\nSTANDARD OBJECT TAB RULE:'
            + '\n  NEVER generate a CustomTab file for standard objects.'
            + '\n  NEVER add <tabVisibilities> in Profile for standard objects.'
            + '\n  Account, Case, Contact, Lead, Opportunity etc. already have built-in tabs.'
            + '\n  Adding a CustomTab for them causes: "no CustomTab named Account found".'
            + '\n  For Record Type tickets on standard objects → files[] must NOT contain'
            + '\n  any CustomTab entry, and the Profile must NOT contain any tabVisibilities.'

            // ── DESTRUCTIVE CHANGES ────────────────────────────
            + '\n\n== DESTRUCTIVE CHANGES FORMAT =='
            + '\nUse destructiveFiles array for deletes. The xmlContent is a destructiveChangesPost.xml:'
            + '\n<?xml version="1.0" encoding="UTF-8"?>'
            + '\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '\n    <types>'
            + '\n        <members>ObjectName__c.FieldName__c</members>  <!-- for field delete -->'
            + '\n        <members>ObjectName__c</members>               <!-- for object delete -->'
            + '\n        <name>CustomField</name>                       <!-- or CustomObject -->'
            + '\n    </types>'
            + '\n    <version>61.0</version>'
            + '\n</Package>'
            + '\nRULE: For deleting an object, first list all its custom fields as CustomField members, '
            + '\nthen add the object itself as a CustomObject member — Salesforce requires relationship '
            + '\nfields to be deleted before the object.'

            // ── CRITICAL RULES ─────────────────────────────────
            + '\n\n== CRITICAL RULES =='
            + '\n\n== ABSOLUTE CSV RULE — HIGHEST PRIORITY =='
            + '\nIF the ticket has ANY CSV file attachment:'
            + '\n→ You MUST use dmlOperations with type csvProcess'
            + '\n→ You MUST NOT generate any XML files for the CSV data'
            + '\n→ You MUST NOT guess or assume CSV content'
            + '\n→ You MUST NOT read the CSV yourself'
            + '\n→ The files array MUST be empty []'
            + '\nVIOLATING THIS RULE WILL CAUSE THE DEPLOY TO FAIL.'
            + '\n'
            + '\nCORRECT response when CSV attachment exists:'
            + '\n{'
            + '\n  "files": [],'
            + '\n  "destructiveFiles": [],'
            + '\n  "dmlOperations": ['
            + '\n    {'
            + '\n      "type": "csvProcess",'
            + '\n      "fileName": "exact_filename.csv",'
            + '\n      "csvType": "custom_setting"'
            + '\n    }'
            + '\n  ],'
            + '\n  "summary": "Processing CSV file for custom settings"'
            + '\n}'
            + '\n'
            + '\nWRONG — never do this when CSV exists:'
            + '\n  Generating XML from guessed CSV content'
            + '\n  Putting CSV data in the files array'
            + '\n  Assuming what the CSV contains'
            + '\n1. NEVER create a field that already exists (check org state)'
            + '\n2. NEVER create an object that already exists (check org state)'
            + '\n3. For field UPDATES: read the existing field values from org state, '
            + '\n   preserve all unchanged values, only modify what the ticket requests'
            + '\n4. MasterDetail sharingModel rule: If an object HAS or IS GETTING a MasterDetail field,'
            + '\n   ALWAYS set sharingModel=ControlledByParent — even when you are only adding unrelated fields.'
            + '\n   When in doubt about whether a MasterDetail exists, use ControlledByParent.'
            + '\n5. Multiple fields on same object = ONE object XML file with multiple <fields> blocks'
            + '\n6. When adding fields to an existing object: use exact label/pluralLabel/nameField '
            + '\n   from org state in the wrapper — do not invent them'
            + '\n7. Return ONLY the JSON object. No explanation, no markdown code fences, no preamble.'

            + '\n\n== CRITICAL SHARING MODEL RULE =='
            + '\nBefore generating ANY CustomObject XML wrapper, check the org state for existing MasterDetail fields.'
            + '\nIf the object has ANY MasterDetail field (even one you are not creating in this ticket):'
            + '\n  → sharingModel MUST be ControlledByParent'
            + '\n  → This applies even if you are only adding a Text or Date field'
            + '\n  → This applies even if the MasterDetail field is not mentioned in this ticket'
            + '\nIf you are unsure whether a MasterDetail exists on the object, default to ControlledByParent for safety.'
            + '\nNEVER use ReadWrite, Read, or Private on an object that has or may have a MasterDetail field.'
            + '\nCRITICAL: Custom Metadata Types (__mdt) and Custom Settings (__c) are COMPLETELY DIFFERENT:'
            + '\n- Custom Metadata Type: uses <label>, <pluralLabel>, <visibility> — NO <customSettingsType>'
            + '\n- Custom Setting: uses <label>, <customSettingsType> — NO <pluralLabel>, NO <visibility>'
            + '\n- NEVER mix these two XML formats'
            + '\nCRITICAL: There is NO <customMetadataType> XML element. This tag does NOT exist.'
            + '\nDo NOT add any tag to distinguish a Custom Metadata Type from a regular Custom Object.'
            + '\nThe ONLY way Salesforce knows it is a Custom Metadata Type is because the API name ends in __mdt.'
            + '\nThe XML structure is simply <label>, <pluralLabel>, optional <description>, <visibility>, and <fields>.'
            + '\nNever add <customMetadataType>, <customSettingsType>, or any other discriminator tag to __mdt objects.'

            // ── DEPLOYMENT PLAN ────────────────────────────────────────
            + '\n\n== DEPLOYMENT PLAN =='
            + '\nEvery response MUST include a top-level "deploymentPlan" field.'
            + '\n'
            + '\n-- WHEN TO USE "single" --'
            + '\nUse "single" whenever files[] does NOT contain any brand-new CustomObject.'
            + '\nThis covers: adding fields to existing objects (with Scenario B layout updates in zip1),'
            + '\nupdating existing layouts, creating labels, profiles, permission sets, apex, validation rules,'
            + '\nor any other metadata that does not introduce a new custom object.'
            + '\n'
            + '\n-- WHEN TO USE "chained" --'
            + '\nUSE "chained" WHENEVER files[] contains a brand-new CustomObject (a path like'
            + '\n"objects/XYZ__c.object" where XYZ__c is NOT in existingObjects from org state).'
            + '\nThis is MANDATORY for every new-object ticket — Scenario A requires a Layout, and the Layout'
            + '\nreferences field API names that only exist after the object deploys, so the layout MUST be'
            + '\ndeployed in a separate second step after the object succeeds.'
            + '\n'
            + '\n-- FORMAT --'
            + '\nSingle (default — use in almost all cases):'
            + '\n  "deploymentPlan": { "scenario": "single" }'
            + '\n'
            + '\nChained (new object + layout only):'
            + '\n  "deploymentPlan": {'
            + '\n    "scenario": "chained",'
            + '\n    "zip1Files": ['
            + '\n      "objects/MyObject__c.object",'
            + '\n      "tabs/MyObject__c.tab",'
            + '\n      "profiles/Admin.profile"'
            + '\n    ],'
            + '\n    "zip2Files": ['
            + '\n      "layouts/MyObject__c-My Object Layout.layout"'
            + '\n    ]'
            + '\n  }'
            + '\n'
            + '\nRULES:'
            + '\n- zip1Files lists the filePaths of ALL files for the first deploy (object, tab, profile)'
            + '\n- zip2Files lists the filePaths of ALL layout files for the second deploy'
            + '\n- zip1Files + zip2Files MUST together equal ALL filePaths listed in files[]'
            + '\n- If scenario is "single", omit zip1Files and zip2Files entirely'
            + '\n- NEVER use "chained" for an existing object — the object and its fields deploy fine together'

            + '\n\nSalesforce Org: ' + UserInfo.getOrganizationName()
            + '\nCurrent User: ' + UserInfo.getUserName();
    }

    // ─────────────────────────────────────────────────────────────
    // USER PROMPTS
    // ─────────────────────────────────────────────────────────────

    private static String buildUserPrompt(String issueKey, String summary, String description) {
        String prompt = 'Jira Issue: ' + issueKey
            + '\nSummary: ' + summary
            + '\nDescription: ' + (String.isBlank(description) ? '(no description)' : description);

        if (!StaticResourceHelper.currentAttachments.isEmpty()) {
            prompt += '\n\nATTACHMENTS ON THIS TICKET:';
            for (String fileName : StaticResourceHelper.currentAttachments.keySet()) {
                String mime = StaticResourceHelper.currentAttachments.get(fileName).get('mimeType');
                prompt += '\n- ' + fileName + ' (' + mime + ')';
            }
        }

        return prompt;
    }

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

        return cleaned.trim();
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