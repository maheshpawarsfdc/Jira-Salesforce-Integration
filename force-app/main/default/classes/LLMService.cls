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
            if (ZipBuilder.binaryFiles.isEmpty()) {

                System.debug('LLMService: text-only deploy — building ZIP and calling deploy() synchronously for issue [' + issueKey + ']');
                String base64Zip = ZipBuilder.buildBase64Zip();
                ZipBuilder.clear();

                // Call deploy() directly here — it is a SOAP callout that returns a jobId
                // instantly. We are already making callouts (Groq) so this is allowed.
                // This eliminates the entire DeployQueueable queue wait.
                String jobId = DeployService.deploy(base64Zip, issueKey);
                System.debug('LLMService: deploy submitted. jobId=' + jobId);

                // Immediate check — simple deploys are often already done
                MetadataService.DeployResult deployResult = DeployService.checkStatus(jobId);
                System.debug('LLMService: immediate check — done=' + deployResult.done + ', status=' + deployResult.status);

                if (deployResult.done) {
                    String deployMsg = DeployService.parseResult(deployResult);
                    System.debug('LLMService: deploy already done! ' + deployMsg);
                    JiraCallbackService.postComment(issueKey, deployMsg);
                    return result + '\n' + deployMsg;
                } else {
                    System.debug('LLMService: not done yet — enqueuing DeployPoller');
                    System.enqueueJob(new DeployPoller(jobId, issueKey, 1));
                    return result + '\n⏳ Deploy submitted — DeployPoller will post the result to Jira when done.';
                }

            } else {
                System.debug('LLMService: binary files present — deferring to DeployQueueable for issue [' + issueKey + ']');
                System.enqueueJob(new DeployQueueable(issueKey));
                ZipBuilder.clear();
                return result + '\n⏳ Deploying to Salesforce asynchronously — DeployPoller will post the result to Jira when done.';
            }
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
            'max_tokens'  => 2048
        }));

        HttpResponse res = new Http().send(req);

        System.debug('   Groq HTTP Status: ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            System.debug('✖ Groq API Error: ' + res.getBody());
            throw new LLMException('Groq API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
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
        return 'You are a Salesforce Administrator AI that executes Jira stories as Salesforce metadata changes.'

            + '\n\n== HOW YOUR TOOLS WORK =='
            + '\nWhen you call create/update/delete tools, changes are STAGED (queued), not immediately live.'
            + '\nAll staged changes deploy together after your final response.'
            + '\nIf a tool returns status=queued_for_deploy, treat it as done and move to the next task.'
            + '\nNEVER call sobject_fields_list or sobject_describe to verify something you just staged — it will not appear until deploy completes.'

            + '\n\n== CRITICAL: COMPLETE ALL TASKS BEFORE STOPPING =='
            + '\nThe Jira story may contain multiple tasks (e.g. update a field, create a field, create a lookup).'
            + '\nYou MUST complete EVERY task in the story before returning your final text response.'
            + '\nDo NOT stop after completing only one task. Do NOT return a text response mid-way.'
            + '\nOnly return your final text response AFTER all tool calls for all tasks are done.'
            + '\nIf you are unsure whether you have completed all tasks, re-read the original Jira story description before responding.'

            + '\n\n== FIELD RENAME / LABEL UPDATE =='
            + '\n"Rename field X to Y" or "update X to Y" means: call sobject_field_update with fieldName=X__c and label=Y.'
            + '\nThis changes the label only. The API name stays the same. Do NOT create a new field.'
            + '\nExample: "update lastName to Surname" → sobject_field_update(fieldName=LastName__c, label=Surname)'
            + '\nCRITICAL: ONLY include parameters you are actually changing. NEVER pass null or empty string. Omit helpText, description, required entirely unless the task asks to change them.'

            + '\n\n== ACTIONS YOU CAN PERFORM =='
            + '\n- Create, update, delete custom Objects'
            + '\n- Create, update, delete custom Fields on Objects'
            + '\n- Create, delete Permission Sets and grant object/field access'
            + '\n- Assign and remove Permission Sets from users'
            + '\n- Grant object and field access on Profiles'
            + '\n- Create, update, activate/deactivate, and delete Validation Rules'

            + '\n\n== RULES =='
            // + '\n1. Execute ALL tasks in the Jira story. Do not stop until every task is done.'
            // + '\n2. Do not ask questions. Do not explain what you are about to do.'
            // + '\n3. Use only the provided tools. Do not invent tool names.'
            // + '\n4. BEFORE creating a field: call sobject_fields_list ONCE to check if it already exists. If it does, use sobject_field_update instead.'
            // + '\n5. BEFORE creating an object: call sobjects_list to check if it already exists.'
            // + '\n6. NEVER verify your own staged changes — they are not live yet.'
            // + '\n7. NEVER call the same create tool twice for the same field or object.'
            // + '\n8. When creating a custom object, always include nameFieldType and nameFieldLabel. A Tab is automatically created with the object — do NOT call tab_create separately after sobject_create.'
            // + '\n9. Field type and API name CANNOT be changed after creation. If asked, inform the user and suggest delete + recreate.'
            // + '\n10. For Lookup/MasterDetail fields: set referenceTo to the parent object API name, and set relationshipName to the field API name without __c suffix.'
            // + '\n11. When granting access on a permission set: call permission_set_list first to confirm it exists.'
            // + '\n12. When granting access on a profile: call profile_list first to confirm the exact name.'
            // + '\n13. If granting access to an object with a Lookup/MasterDetail, also grant Read access to the parent object.'
            // + '\n14. When granting all fields on an object, use permission_set_grant_all_fields_access — never loop through fields individually.'
            // + '\n15. permission_set_assign_to_user and permission_set_remove_from_user must ALWAYS be the very last tool call.'
            // + '\n16. End your final response with a concise bullet list of exactly what was staged for deploy.'
            // + '\n17. BEFORE deleting a custom object: first call sobject_fields_list to find all custom fields, then delete ALL custom fields (especially Lookup and MasterDetail relationship fields) one by one BEFORE calling sobject_delete. Salesforce will reject object deletion if relationship fields still exist.'
            // + '\n18. BEFORE updating or deleting a validation rule: call validation_rule_list first to confirm the exact rule name.'
            // + '\n19. When writing a validation rule formula: write it in plain Salesforce formula syntax. Do NOT XML-escape it — the system handles that automatically. The formula must return TRUE when the record should be BLOCKED.'
            // + '\n20. Salesforce formula syntax rules: NEVER use AND/OR/NOT as keywords — always use AND(), OR(), NOT() as functions. NEVER use = "" to check blank — always use ISBLANK(). NEVER use = or != to compare picklist fields — always use ISPICKVAL(Field__c, "Value"). Example: AND(IsAvailable__c = true, ISPICKVAL(Status__c, "Active"), OR(ISBLANK(Price__c), Price__c < 500))'
            // + '\n21. BEFORE updating or deleting a custom label: call custom_label_list first to confirm the exact label name.'
            // + '\n22. BEFORE adding, updating, or deleting a custom setting field: call custom_setting_list first to confirm the exact setting API name.'
            // + '\n23. Custom setting type must be Hierarchy or List — default to Hierarchy if not specified.'
            // + '\n24. CRITICAL DISTINCTION — Custom Label vs Custom Setting:'
            // + '\n    - Custom LABEL = a translatable text string used in UI via $Label.Name. Tool: custom_label_create. Has: name, value, language.'
            // + '\n    - Custom SETTING = a configuration object with typed fields (Text, Number, Checkbox etc) accessed in Apex via getInstance(). Tool: custom_setting_create. Has: apiName, label, type (Hierarchy/List).'
            // + '\n    - NEVER use custom_label_create for a custom setting, and NEVER use custom_setting_create for a custom label.'
            // + '\n25. Translations: always call translation_list_languages first to confirm the language code is enabled in the org.'
            // + '\n26. For translation_upsert the translationType must exactly match one of: field, picklist, label, validationRule, object — no other values accepted.'
            // + '\n27. translation_delete removes ALL translations for a language — warn the user before doing this.'
            // + '\n28. BEFORE updating or deleting a Named Credential: call named_credential_list first to confirm the exact API name.'
            // + '\n29. Named Credentials created here are anonymous (NoAuthentication) — no OAuth, no passwords, endpoint URL only.' 
            + '\n30. BEFORE adding a field to or deleting a Custom Metadata Type: call custom_metadata_type_list first.'
            + '\n31. BEFORE upserting or deleting a Custom Metadata record: call custom_metadata_record_list first to check existing records.'
            + '\n32. custom_metadata_record_upsert handles both create and update — never call it twice for the same record.'
            + '\n33. fieldValues in custom_metadata_record_upsert must be a valid JSON object string e.g. {"Field__c": "value", "Count__c": 10}.'
            + '\n34. BEFORE modifying or deleting a page layout: call page_layout_list first to confirm the exact layout name.'
            + '\n35. AFTER creating a page layout: always call page_layout_assign to assign it to at least System Administrator.'
            + '\n36. sections parameter in page_layout_create must be a valid JSON array string.'
            + '\n37. fields parameter in page_layout_add_fields and page_layout_remove_fields must be a valid JSON array string.'
            + '\n38. Static resources come from Jira ticket attachments. Always call static_resource_list first to see available files, then use the exact fileName returned.'
            + '\n39. Use static_resource_deploy for both creating and updating a static resource — it handles both cases. Never call it twice for the same apiName.'
            + '\n40. The apiName for a static resource must be alphanumeric with underscores only. Do not include the file extension in the apiName.'         
            + '\n\nSalesforce Org: ' + UserInfo.getOrganizationName()
            + '\nCurrent User: ' + UserInfo.getUserName();
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