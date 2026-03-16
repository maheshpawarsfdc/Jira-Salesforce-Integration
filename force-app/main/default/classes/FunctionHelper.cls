public class FunctionHelper {

    public static final String SUCCESS_RESPONSE = JSON.serialize(
        new Map<String, Object>{
            'success' => true,
            'status'  => 'queued_for_deploy',
            'note'    => 'Change has been staged. All staged changes will be deployed together after this conversation ends. Do NOT call sobject_fields_list to verify — the field will not appear until deploy completes.'
        }
    );

    // Tracks fields/objects queued in this session so LLM knows what's staged
    public static Set<String> queuedFields  = new Set<String>();  // e.g. "Reservation__c.AccountId__c"
    public static Set<String> queuedObjects = new Set<String>();  // e.g. "Reservation__c"

    // ─────────────────────────────────────────────────────────────
    // DML QUEUES
    // Records that need DML are collected here during tool execution.
    // Actual DML is performed AFTER all Groq callouts finish in LLMService.
    // This avoids the Salesforce restriction:
    //   "Cannot make callout after DML in same transaction"
    // ─────────────────────────────────────────────────────────────
    public static List<SObject> recordsToInsert        = new List<SObject>();
    public static List<SObject> recordsToDelete        = new List<SObject>();
    public static List<String>  permissionSetsToDelete = new List<String>();

    public static void clearQueues() {
        recordsToInsert.clear();
        recordsToDelete.clear();
        permissionSetsToDelete.clear();
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListSObjects(Map<String, Object> args) {
        // Safely default to false if not passed
        Object val = args != null ? args.get('customObjectsOnly') : null;
        Boolean customOnly = (val != null && String.valueOf(val) != 'null')
            ? Boolean.valueOf(String.valueOf(val))
            : true;
        
        System.debug('         ── FunctionHelper: listing objects (customOnly=' + customOnly + ')');
        return JSON.serialize(MetadataHelper.getSObjects(customOnly));
    }

    public static String callDescribeSObject(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: describing object [' + objectName + ']');
        return JSON.serialize(MetadataHelper.describeSObject(objectName));
    }

    public static String callCreateSObject(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: creating object [' + objectName + ']');
        System.debug('         ── FunctionHelper: args = ' + args);
        MetadataHelper.createSObject(objectName, args);
        String fullName = objectName.endsWith('__c') ? objectName : objectName + '__c';
        queuedObjects.add(fullName);
        System.debug('         ✔ FunctionHelper: object [' + fullName + '] staged for deploy');
        return JSON.serialize(new Map<String, Object>{
            'success' => true,
            'status'  => 'queued_for_deploy',
            'staged_object' => fullName,
            'note'    => 'Object staged. Do NOT call sobject_describe to verify — it is not live until deploy completes after this conversation.'
        });
    }

    public static String callUpdateSObject(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: updating object [' + objectName + ']');
        System.debug('         ── FunctionHelper: args = ' + args);
        MetadataHelper.updateSObject(objectName, args);
        System.debug('         ✔ FunctionHelper: object [' + objectName + '] updated successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteSObject(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: deleting object [' + objectName + ']');
        MetadataHelper.deleteSObject(objectName);
        System.debug('         ✔ FunctionHelper: object [' + objectName + '] deleted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callCreateTab(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: creating tab for [' + objectName + ']');
        MetadataHelper.createTab(objectName, args);
        System.debug('         ✔ FunctionHelper: tab for [' + objectName + '] staged for deploy');
        return JSON.serialize(new Map<String, Object>{
            'success' => true,
            'status'  => 'queued_for_deploy',
            'staged_tab' => objectName,
            'note'    => 'Tab staged for deploy.'
        });
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListSObjectFields(Map<String, Object> args) {
        String objectName = getObjectName(args);
        System.debug('         ── FunctionHelper: listing fields on [' + objectName + ']');
        List<Map<String, Object>> fields = MetadataHelper.getSObjectFieldsList(objectName);
        System.debug('         ✔ FunctionHelper: found ' + fields.size() + ' fields');
        return JSON.serialize(fields);
    }

    public static String callDescribeSObjectField(Map<String, Object> args) {
        String objectName = getObjectName(args);
        String fieldName  = getFieldName(args);
        System.debug('         ── FunctionHelper: describing field [' + fieldName + '] on [' + objectName + ']');
        return JSON.serialize(MetadataHelper.describeSObjectField(objectName, fieldName));
    }

    public static String callCreateSObjectField(Map<String, Object> args) {
        String objectName = getObjectName(args);
        String fieldName  = getFieldName(args);
        System.debug('         ── FunctionHelper: creating field [' + fieldName + '] on [' + objectName + ']');
        System.debug('         ── FunctionHelper: args = ' + args);
        MetadataHelper.createField(objectName, fieldName, args);
        String fullName = objectName.endsWith('__c') ? objectName : objectName + '__c';
        String fullField = fullName + '.' + (fieldName.endsWith('__c') ? fieldName : fieldName + '__c');
        queuedFields.add(fullField);
        System.debug('         ✔ FunctionHelper: field [' + fullField + '] staged for deploy');
        return JSON.serialize(new Map<String, Object>{
            'success' => true,
            'status'  => 'queued_for_deploy',
            'staged_field' => fullField,
            'note'    => 'Field staged. Do NOT call sobject_fields_list to verify this field — it is not live until deploy completes after this conversation.'
        });
    }

    public static String callUpdateSObjectField(Map<String, Object> args) {
        String objectName = getObjectName(args);
        String fieldName  = getFieldName(args);
        System.debug('         ── FunctionHelper: updating field [' + fieldName + '] on [' + objectName + ']');
        System.debug('         ── FunctionHelper: args = ' + args);
        MetadataHelper.updateField(objectName, fieldName, args);
        System.debug('         ✔ FunctionHelper: field [' + objectName + '.' + fieldName + '] updated successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteSObjectField(Map<String, Object> args) {
        String objectName = getObjectName(args);
        String fieldName  = getFieldName(args);
        System.debug('         ── FunctionHelper: deleting field [' + fieldName + '] on [' + objectName + ']');
        MetadataHelper.deleteField(objectName, fieldName);
        System.debug('         ✔ FunctionHelper: field [' + objectName + '.' + fieldName + '] deleted successfully');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListPermissionSets(Map<String, Object> args) {
        System.debug('FunctionHelper.callListPermissionSets() called');
        return JSON.serialize(PermissionSetHelper.listPermissionSets());
    }

    public static String callCreatePermissionSet(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreatePermissionSet() called');
        System.debug('args = ' + args);
        PermissionSetHelper.createPermissionSet(args);
        System.debug('FunctionHelper: permission set created successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callGrantObjectAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callGrantObjectAccess() called');
        System.debug('args = ' + args);
        PermissionSetHelper.grantObjectAccess(args);
        System.debug('FunctionHelper: object access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callGrantFieldAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callGrantFieldAccess() called');
        System.debug('args = ' + args);
        PermissionSetHelper.grantFieldAccess(args);
        System.debug('FunctionHelper: field access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callGrantAllFieldsAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callGrantAllFieldsAccess() called');
        System.debug('args = ' + args);
        PermissionSetHelper.grantAllFieldsAccess(args);
        System.debug('FunctionHelper: all fields access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callAssignPermissionSetToUser(Map<String, Object> args) {
        System.debug('FunctionHelper.callAssignPermissionSetToUser() called');
        System.debug('args = ' + args);
        SObject assignment = PermissionSetHelper.buildAssignment(args);
        recordsToInsert.add(assignment);
        System.debug('FunctionHelper: assignment queued for insert after callouts finish');
        return SUCCESS_RESPONSE;
    }

    public static String callRemovePermissionSetFromUser(Map<String, Object> args) {
        System.debug('FunctionHelper.callRemovePermissionSetFromUser() called');
        System.debug('args = ' + args);
        SObject assignment = PermissionSetHelper.findAssignment(args);
        recordsToDelete.add(assignment);
        System.debug('FunctionHelper: assignment queued for delete after callouts finish');
        return SUCCESS_RESPONSE;
    }

    public static String callDeletePermissionSet(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeletePermissionSet() called');
        System.debug('args = ' + args);
        // Queue assignments for deletion + permission set name for SOAP delete
        // Both executed in correct order in LLMService after all callouts finish
        PermissionSetHelper.queuePermissionSetDelete(args);
        System.debug('FunctionHelper: permission set delete queued');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListProfiles(Map<String, Object> args) {
        System.debug('FunctionHelper.callListProfiles() called');
        return JSON.serialize(ProfileHelper.listProfiles());
    }

    public static String callProfileGrantObjectAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileGrantObjectAccess() called');
        System.debug('args = ' + args);
        ProfileHelper.grantObjectAccess(args);
        System.debug('FunctionHelper: profile object access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileGrantFieldAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileGrantFieldAccess() called');
        System.debug('args = ' + args);
        ProfileHelper.grantFieldAccess(args);
        System.debug('FunctionHelper: profile field access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileGrantAllFieldsAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileGrantAllFieldsAccess() called');
        System.debug('args = ' + args);
        ProfileHelper.grantAllFieldsAccess(args);
        System.debug('FunctionHelper: profile all fields access granted successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileClone(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileClone() called');
        System.debug('args = ' + args);
        ProfileHelper.cloneProfile(args);
        System.debug('FunctionHelper: profile cloned successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileDelete(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileDelete() called');
        System.debug('args = ' + args);
        ProfileHelper.deleteProfile(args);
        System.debug('FunctionHelper: profile delete queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileRevokeObjectAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileRevokeObjectAccess() called');
        System.debug('args = ' + args);
        ProfileHelper.revokeObjectAccess(args);
        System.debug('FunctionHelper: profile object access revoked successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callProfileRevokeFieldAccess(Map<String, Object> args) {
        System.debug('FunctionHelper.callProfileRevokeFieldAccess() called');
        System.debug('args = ' + args);
        ProfileHelper.revokeFieldAccess(args);
        System.debug('FunctionHelper: profile field access revoked successfully');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // VALIDATION RULE METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListValidationRules(Map<String, Object> args) {
        System.debug('FunctionHelper.callListValidationRules() called');
        return JSON.serialize(ValidationRuleHelper.listValidationRules(args));
    }

    public static String callCreateValidationRule(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreateValidationRule() called');
        System.debug('args = ' + args);
        ValidationRuleHelper.createValidationRule(args);
        System.debug('FunctionHelper: validation rule created successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callUpdateValidationRule(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpdateValidationRule() called');
        System.debug('args = ' + args);
        ValidationRuleHelper.updateValidationRule(args);
        System.debug('FunctionHelper: validation rule updated successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callSetValidationRuleActive(Map<String, Object> args) {
        System.debug('FunctionHelper.callSetValidationRuleActive() called');
        System.debug('args = ' + args);
        ValidationRuleHelper.setValidationRuleActive(args);
        System.debug('FunctionHelper: validation rule active state updated successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteValidationRule(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteValidationRule() called');
        System.debug('args = ' + args);
        ValidationRuleHelper.deleteValidationRule(args);
        System.debug('FunctionHelper: validation rule queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // CUSTOM LABEL METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListCustomLabels(Map<String, Object> args) {
        System.debug('FunctionHelper.callListCustomLabels() called');
        return JSON.serialize(CustomLabelHelper.listCustomLabels(args));
    }

    public static String callCreateCustomLabel(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreateCustomLabel() called');
        System.debug('args = ' + args);
        CustomLabelHelper.createCustomLabel(args);
        System.debug('FunctionHelper: custom label created successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callUpdateCustomLabel(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpdateCustomLabel() called');
        System.debug('args = ' + args);
        CustomLabelHelper.updateCustomLabel(args);
        System.debug('FunctionHelper: custom label updated successfully');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteCustomLabel(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteCustomLabel() called');
        System.debug('args = ' + args);
        CustomLabelHelper.deleteCustomLabel(args);
        System.debug('FunctionHelper: custom label queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }
    
    // ─────────────────────────────────────────────────────────────
    // TRANSLATION METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListSupportedLanguages(Map<String, Object> args) {
        System.debug('FunctionHelper.callListSupportedLanguages() called');
        return JSON.serialize(TranslationHelper.listSupportedLanguages(args));
    }

    public static String callUpsertTranslation(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpsertTranslation() called');
        System.debug('args = ' + args);
        TranslationHelper.upsertTranslation(args);
        System.debug('FunctionHelper: translation queued for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteTranslation(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteTranslation() called');
        System.debug('args = ' + args);
        TranslationHelper.deleteTranslation(args);
        System.debug('FunctionHelper: translation queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }


    // ─────────────────────────────────────────────────────────────
    // CUSTOM SETTING METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListCustomSettings(Map<String, Object> args) {
        System.debug('FunctionHelper.callListCustomSettings() called');
        return JSON.serialize(CustomSettingHelper.listCustomSettings(args));
    }

    public static String callCreateCustomSetting(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreateCustomSetting() called');
        System.debug('args = ' + args);
        CustomSettingHelper.createCustomSetting(args);
        System.debug('FunctionHelper: custom setting queued for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callAddFieldToCustomSetting(Map<String, Object> args) {
        System.debug('FunctionHelper.callAddFieldToCustomSetting() called');
        System.debug('args = ' + args);
        CustomSettingHelper.addFieldToCustomSetting(args);
        System.debug('FunctionHelper: custom setting field queued for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callUpdateCustomSettingField(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpdateCustomSettingField() called');
        System.debug('args = ' + args);
        CustomSettingHelper.updateCustomSettingField(args);
        System.debug('FunctionHelper: custom setting field update queued');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteCustomSettingField(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteCustomSettingField() called');
        System.debug('args = ' + args);
        CustomSettingHelper.deleteCustomSettingField(args);
        System.debug('FunctionHelper: custom setting field queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteCustomSetting(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteCustomSetting() called');
        System.debug('args = ' + args);
        CustomSettingHelper.deleteCustomSetting(args);
        System.debug('FunctionHelper: custom setting queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    public static String runToolingApiQuery(Map<String, Object> args) {
        String query = getRequiredArg(args, new List<String>{ 'query', 'soql' });
        System.debug('         ── FunctionHelper: running Tooling API query: ' + query);
        try {
            Map<String, Object> result = MetadataHelper.runToolingApiQuery(query);
            System.debug('         ✔ FunctionHelper: query returned successfully');
            return JSON.serialize(result);
        } catch (Exception e) {
            System.debug('         ✖ FunctionHelper: query failed: ' + e.getMessage());
            return JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => 'Query failed: ' + e.getMessage()
            });
        }
    }
    // ─────────────────────────────────────────────────────────────
    // NAMED CREDENTIAL METHODS
    // ─────────────────────────────────────────────────────────────
    public static String callListNamedCredentials(Map<String, Object> args) {
        System.debug('FunctionHelper.callListNamedCredentials() called');
        return JSON.serialize(NamedCredentialHelper.listNamedCredentials(args));
    }

    public static String callCreateNamedCredential(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreateNamedCredential() called');
        System.debug('args = ' + args);
        NamedCredentialHelper.createNamedCredential(args);
        System.debug('FunctionHelper: named credential staged for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callUpdateNamedCredential(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpdateNamedCredential() called');
        System.debug('args = ' + args);
        NamedCredentialHelper.updateNamedCredential(args);
        System.debug('FunctionHelper: named credential update staged for deploy');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // CUSTOM METADATA TYPE METHODS
    // ─────────────────────────────────────────────────────────────
    public static String callListCustomMetadataTypes(Map<String, Object> args) {
        System.debug('FunctionHelper.callListCustomMetadataTypes() called');
        return JSON.serialize(CustomMetadataHelper.listCustomMetadataTypes(args));
    }

    public static String callCreateCustomMetadataType(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreateCustomMetadataType() called');
        System.debug('args = ' + args);
        CustomMetadataHelper.createCustomMetadataType(args);
        System.debug('FunctionHelper: custom metadata type staged for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callAddFieldToCustomMetadataType(Map<String, Object> args) {
        System.debug('FunctionHelper.callAddFieldToCustomMetadataType() called');
        System.debug('args = ' + args);
        CustomMetadataHelper.addFieldToCustomMetadataType(args);
        System.debug('FunctionHelper: custom metadata type field staged for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteCustomMetadataType(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteCustomMetadataType() called');
        System.debug('args = ' + args);
        CustomMetadataHelper.deleteCustomMetadataType(args);
        System.debug('FunctionHelper: custom metadata type queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callListCustomMetadataRecords(Map<String, Object> args) {
        System.debug('FunctionHelper.callListCustomMetadataRecords() called');
        return JSON.serialize(CustomMetadataHelper.listCustomMetadataRecords(args));
    }

    public static String callUpsertCustomMetadataRecord(Map<String, Object> args) {
        System.debug('FunctionHelper.callUpsertCustomMetadataRecord() called');
        System.debug('args = ' + args);
        CustomMetadataHelper.upsertCustomMetadataRecord(args);
        System.debug('FunctionHelper: custom metadata record staged for deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteCustomMetadataRecord(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteCustomMetadataRecord() called');
        System.debug('args = ' + args);
        CustomMetadataHelper.deleteCustomMetadataRecord(args);
        System.debug('FunctionHelper: custom metadata record queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    public static String callDeleteNamedCredential(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeleteNamedCredential() called');
        System.debug('args = ' + args);
        NamedCredentialHelper.deleteNamedCredential(args);
        System.debug('FunctionHelper: named credential queued for destructive deploy');
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // PAGE LAYOUT METHODS
    // ─────────────────────────────────────────────────────────────

    public static String callListPageLayouts(Map<String, Object> args) {
        System.debug('FunctionHelper.callListPageLayouts() called');
        return JSON.serialize(PageLayoutHelper.listPageLayouts(args));
    }
    public static String callCreatePageLayout(Map<String, Object> args) {
        System.debug('FunctionHelper.callCreatePageLayout() called');
        System.debug('args = ' + args);
        PageLayoutHelper.createPageLayout(args);
        return SUCCESS_RESPONSE;
    }
    public static String callAddFieldsToLayout(Map<String, Object> args) {
        System.debug('FunctionHelper.callAddFieldsToLayout() called');
        System.debug('args = ' + args);
        PageLayoutHelper.addFieldsToLayout(args);
        return SUCCESS_RESPONSE;
    }
    public static String callRemoveFieldsFromLayout(Map<String, Object> args) {
        System.debug('FunctionHelper.callRemoveFieldsFromLayout() called');
        System.debug('args = ' + args);
        PageLayoutHelper.removeFieldsFromLayout(args);
        return SUCCESS_RESPONSE;
    }
    public static String callDeletePageLayout(Map<String, Object> args) {
        System.debug('FunctionHelper.callDeletePageLayout() called');
        System.debug('args = ' + args);
        PageLayoutHelper.deletePageLayout(args);
        return SUCCESS_RESPONSE;
    }
    public static String callAssignPageLayout(Map<String, Object> args) {
        System.debug('FunctionHelper.callAssignPageLayout() called');
        System.debug('args = ' + args);
        PageLayoutHelper.assignPageLayout(args);
        return SUCCESS_RESPONSE;
    }

    // ─────────────────────────────────────────────────────────────
    // PARAMETER EXTRACTION HELPERS
    // ─────────────────────────────────────────────────────────────

    private static String getObjectName(Map<String, Object> args) {
        return getRequiredArg(args, new List<String>{
            'sObjectName', 'sObject', 'objectName',
            'object', 'apiName', 'sobject_name', 'object_name'
        });
    }

    private static String getFieldName(Map<String, Object> args) {
        return getRequiredArg(args, new List<String>{
            'fieldName', 'field', 'apiName',
            'fieldAPIName', 'field_name', 'sobject_field_name'
        });
    }

    private static String getRequiredArg(Map<String, Object> args, List<String> keys) {
        for (String key : keys) {
            Object val = args.get(key);
            if (val != null && String.isNotBlank(String.valueOf(val))) {
                System.debug('         ── FunctionHelper: found param [' + key + '] = ' + val);
                return String.valueOf(val).trim();
            }
        }
        throw new IllegalArgumentException(
            'Required parameter ' + keys[0] + ' is missing'
        );
    }
}