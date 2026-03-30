public class LLMService {

    private static final String GROQ_BASE_URL = App_Config__c.getOrgDefaults().Groq_Base_URL__c;
    private static final String GROQ_API_KEY  = App_Config__c.getOrgDefaults().Groq_API_Key__c;
    private static final String GROQ_MODEL    = App_Config__c.getOrgDefaults().Groq_Model__c;

    private static final Integer MAX_ITERATIONS = 10;

    // ─────────────────────────────────────────────────────────────
    // ENTRY POINT — called from JiraInboundController
    // ─────────────────────────────────────────────────────────────
    public static String processJiraTicket(String issueKey, String summary, String description) {

        System.debug('');
        System.debug('╔══════════════════════════════════════════════════════╗');
        System.debug('║           JIRA AI ASSISTANT — NEW REQUEST            ║');
        System.debug('╚══════════════════════════════════════════════════════╝');
        System.debug('► Issue Key  : ' + issueKey);
        System.debug('► Summary    : ' + summary);
        System.debug('► Description: ' + description);

        List<Map<String, Object>> messages = new List<Map<String, Object>>{
            new Map<String, Object>{ 'role' => 'system', 'content' => buildSystemPrompt() },
            new Map<String, Object>{ 'role' => 'user',   'content' => buildUserPrompt(issueKey, summary, description) }
        };

        System.debug('');
        System.debug('── STEP 1: Messages built. Sending to Groq with ' + ToolDefinitions.getAllTools().size() + ' tools available.');

        String result = runToolCallingLoop(messages, ToolDefinitions.getAllTools());

        // ── FLUSH DML QUEUES ─────────────────────────────────
        // Step 1 — Insert new records (permission set assignments)
        if (!FunctionHelper.recordsToInsert.isEmpty()) {
            System.debug('LLMService: inserting ' + FunctionHelper.recordsToInsert.size() + ' queued record(s)');
            insert FunctionHelper.recordsToInsert;
            FunctionHelper.recordsToInsert.clear();
            System.debug('LLMService: insert complete');
        }

        // Step 2 — Delete records (assignments must go before permission set delete)
        if (!FunctionHelper.recordsToDelete.isEmpty()) {
            System.debug('LLMService: deleting ' + FunctionHelper.recordsToDelete.size() + ' queued record(s)');
            delete FunctionHelper.recordsToDelete;
            FunctionHelper.recordsToDelete.clear();
            System.debug('LLMService: delete complete');
        }

        // Step 3 — Add destructive XML for permission set deletes to ZipBuilder
        // Assignments are now gone — safe to add destructive deploy
        if (!FunctionHelper.permissionSetsToDelete.isEmpty()) {
            for (String psName : FunctionHelper.permissionSetsToDelete) {
                PermissionSetHelper.addDestructiveXml(psName);
            }
            FunctionHelper.permissionSetsToDelete.clear();
        }

        // ── ZIP DEPLOY (async) ────────────────────────────────
        // ZIP build + MetadataAPI deploy moved to a Queueable.
        // Reason: Zippex CRC32 on large binary files exceeds the 10s synchronous
        // CPU limit. The Queueable gets 60s CPU in its own transaction.
        if (ZipBuilder.hasFiles()) {
            System.debug('LLMService: ZipBuilder has ' + ZipBuilder.files.size()
                + ' file(s) — enqueuing ZipDeployQueueable for issue [' + issueKey + ']');
            System.enqueueJob(new ZipDeployQueueable(issueKey));
            ZipBuilder.clear();  // clear static state — Queueable already captured a snapshot
            return result + '\n⏳ Deploying to Salesforce asynchronously — DeployPoller will post the result to Jira when done.';
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // TOOL CALLING LOOP
    // ─────────────────────────────────────────────────────────────
    private static String runToolCallingLoop(List<Map<String, Object>> messages, List<Map<String, Object>> tools) {
        Integer iterations = 0;

        while (iterations < MAX_ITERATIONS) {
            iterations++;

            System.debug('');
            System.debug('┌─────────────────────────────────────────────────────┐');
            System.debug('│  LOOP ITERATION ' + iterations + ' of max ' + MAX_ITERATIONS);
            System.debug('│  Messages in conversation so far: ' + messages.size());
            System.debug('└─────────────────────────────────────────────────────┘');

            // ── STEP 2: Call Groq
            System.debug('── STEP 2: Calling Groq API (model: ' + GROQ_MODEL + ')...');
            Map<String, Object> response = callGroq(messages, tools);

            List<Object> choices       = (List<Object>) response.get('choices');
            Map<String, Object> choice = (Map<String, Object>) choices[0];
            Map<String, Object> message = (Map<String, Object>) choice.get('message');
            String finishReason        = (String) choice.get('finish_reason');

            System.debug('── STEP 3: Groq responded. finish_reason = [' + finishReason + ']');

            // ── TOOL CALL — LLM wants to execute something
            if (finishReason == 'tool_calls') {
                List<Object> toolCalls = (List<Object>) message.get('tool_calls');

                System.debug('');
                System.debug('   ✦ LLM decided to call ' + toolCalls.size() + ' tool(s) this iteration');

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

                    System.debug('');
                    System.debug('   ┌── TOOL CALL ──────────────────────────────────────');
                    System.debug('   │  Tool ID     : ' + toolCallId);
                    System.debug('   │  Tool Name   : ' + functionName);
                    System.debug('   │  Arguments   : ' + argumentsJson);
                    System.debug('   │');

                    // ── STEP 4: Execute the tool
                    System.debug('   │  ── STEP 4: Routing to FunctionRouter...');
                    String toolResult = executeFunction(functionName, argumentsJson);

                    System.debug('   │  ── STEP 5: Tool execution complete.');
                    System.debug('   │  Result      : ' + toolResult);
                    System.debug('   └───────────────────────────────────────────────────');

                    // Feed result back into conversation
                    messages.add(new Map<String, Object>{
                        'role'         => 'tool',
                        'tool_call_id' => toolCallId,
                        'content'      => toolResult
                    });
                }

                System.debug('');
                System.debug('   ↻ Tool results added to conversation. Looping back to Groq...');

            // ── STOP — LLM is done
            } else if (finishReason == 'stop') {
                String finalResponse = (String) message.get('content');

                System.debug('');
                System.debug('╔══════════════════════════════════════════════════════╗');
                System.debug('║                  AI FINISHED                         ║');
                System.debug('╚══════════════════════════════════════════════════════╝');
                System.debug('► Total iterations used: ' + iterations);
                System.debug('► Final response:');
                System.debug(finalResponse);

                return finalResponse;

            } else {
                System.debug('✖ Unexpected finish_reason: ' + finishReason);
                return 'Unexpected response from AI: ' + finishReason;
            }
        }

        System.debug('✖ Max iterations (' + MAX_ITERATIONS + ') reached without completion.');
        return 'Could not complete after ' + MAX_ITERATIONS + ' steps. Please simplify the Jira story.';
    }

    // ─────────────────────────────────────────────────────────────
    // CALL GROQ API
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> callGroq(List<Map<String, Object>> messages, List<Map<String, Object>> tools) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GROQ_BASE_URL + '/chat/completions');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + GROQ_API_KEY);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'model'       => GROQ_MODEL,
            'messages'    => messages,
            'tools'       => tools,
            'tool_choice' => 'auto',
            'max_tokens'  => 512
        }));

        HttpResponse res = new Http().send(req);

        System.debug('   Groq HTTP Status: ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            System.debug('✖ Groq API Error: ' + res.getBody());
            throw new LLMException('Groq API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        // ── TOKEN LOGGING ──────────────────────────────────────────
        Map<String, Object> usage = (Map<String, Object>) response.get('usage');
        if (usage != null) {
            System.debug('📊 TOKENS >> prompt=' + usage.get('prompt_tokens')
                + ' | completion=' + usage.get('completion_tokens')
                + ' | total=' + usage.get('total_tokens'));
        }
        // ──────────────────────────────────────────────────────────

        return response;
    }

    // ─────────────────────────────────────────────────────────────
    // EXECUTE A TOOL CALL
    // ─────────────────────────────────────────────────────────────
    private static String executeFunction(String functionName, String argumentsJson) {
        Map<String, Object> arguments = new Map<String, Object>();
        if (String.isNotBlank(argumentsJson)) {
            arguments = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
        }
        try {
            return FunctionRouter.execute(functionName, arguments);
        } catch (Exception e) {
            System.debug('✖ Tool execution failed: ' + e.getMessage());
            return JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => e.getMessage()
            });
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PROMPTS
    // ─────────────────────────────────────────────────────────────
    private static String buildSystemPrompt() {
    return 'You are a Salesforce Admin AI. Execute Jira stories as Salesforce metadata changes using the provided tools.'
        + '\nTools STAGE changes — not live until deployed. Never verify staged changes with describe/list calls.'
        + '\nComplete ALL tasks before returning your final response. Never stop mid-way.'
        + '\nIf a tool returns status=queued_for_deploy, treat it as done and move to the next task.'

        + '\n\n== RULES =='
        + '\n1. Execute ALL tasks. Do not stop until every task is done. Do not ask questions.'
        + '\n2. Use only provided tools. Do not invent tool names.'
        //+ '\n3. BEFORE creating a field: call sobject_fields_list to check if it exists. If yes, use sobject_field_update.'
        //+ '\n4. BEFORE creating an object: call sobjects_list to check if it exists.'
        + '\n5. Never verify staged changes. Never call the same create tool twice for the same field or object.'
        //+ '\n6. sobject_create auto-creates a Tab — do NOT call tab_create after it.'
        + '\n7. Field type and API name cannot be changed. If asked, suggest delete + recreate.'
        + '\n8. Lookup/MasterDetail: set referenceTo=parent object API name. relationshipName is auto-generated — do not send it.'
        //+ '\n9. Permission set: call permission_set_list first. Profile: call profile_list first.'
        + '\n10. Use permission_set_grant_all_fields_access — never loop fields individually.'
        + '\n11. permission_set_assign_to_user and permission_set_remove_from_user must be the LAST tool call.'
        + '\n12. BEFORE deleting an object: delete ALL custom fields (especially Lookup/MasterDetail) first.'
        + '\n13. Validation rule formula: plain Salesforce syntax. Use AND(), OR(), NOT() — never as keywords. Use ISBLANK() — never = "". Use ISPICKVAL() for picklists. Formula returns TRUE when record is BLOCKED.'
        //+ '\n14. BEFORE update/delete: call list tool first — validation_rule_list, custom_label_list, custom_setting_list, named_credential_list, page_layout_list.'
        + '\n15. Custom Label = translatable text ($Label.Name). Custom Setting = config object (getInstance()). Never mix them up.'
        + '\n16. Custom setting type defaults to Hierarchy if not specified.'
        + '\n17. Named Credentials are anonymous (NoAuthentication) — endpoint URL only.'
        + '\n18. Translations: call translation_list_languages first. translationType must be: field, picklist, label, validationRule, or object.'
        + '\n19. Custom Metadata: call custom_metadata_type_list before add/delete. Call custom_metadata_record_list before upsert/delete. custom_metadata_record_upsert handles create+update — never call twice.'
        + '\n20. fieldValues in custom_metadata_record_upsert must be valid JSON e.g. {"Field__c": "value"}.'
        + '\n21. Page layout: call page_layout_assign after create. sections and fields params must be valid JSON array strings.'
        + '\n22. Static resources: call static_resource_list first. static_resource_deploy handles create+update — never call twice. apiName = alphanumeric+underscores only, no file extension.'

        + '\n\nOrg: ' + UserInfo.getOrganizationName()
        + '\nUser: ' + UserInfo.getUserName();
}

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

        prompt += '\n\nExecute the required Salesforce action now.';
        return prompt;
    }

    public class LLMException extends Exception {}
}