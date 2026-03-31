public class FunctionRouter {

    public static String execute(String functionName, Map<String, Object> args) {

        System.debug('');
        System.debug('      ── FunctionRouter: routing [' + functionName + ']');

        String result;

        // ── SOBJECT OPERATIONS ────────────────────────────────
        if      (functionName == 'sobjects_list')           result = FunctionHelper.callListSObjects(args);
        else if (functionName == 'sobject_describe')        result = FunctionHelper.callDescribeSObject(args);
        else if (functionName == 'sobject_create')          result = FunctionHelper.callCreateSObject(args);
        else if (functionName == 'sobject_update')          result = FunctionHelper.callUpdateSObject(args);
        else if (functionName == 'sobject_delete')          result = FunctionHelper.callDeleteSObject(args);
        else if (functionName == 'tab_create')              result = FunctionHelper.callCreateTab(args);

        // ── FIELD OPERATIONS ──────────────────────────────────
        else if (functionName == 'sobject_fields_list')     result = FunctionHelper.callListSObjectFields(args);
        else if (functionName == 'sobject_field_describe')  result = FunctionHelper.callDescribeSObjectField(args);
        else if (functionName == 'sobject_field_create')    result = FunctionHelper.callCreateSObjectField(args);
        else if (functionName == 'sobject_field_update')    result = FunctionHelper.callUpdateSObjectField(args);
        else if (functionName == 'sobject_field_delete')    result = FunctionHelper.callDeleteSObjectField(args);

        // ── PERMISSION SET OPERATIONS ─────────────────────────
        else if (functionName == 'permission_set_list')                      result = FunctionHelper.callListPermissionSets(args);
        else if (functionName == 'permission_set_create')                    result = FunctionHelper.callCreatePermissionSet(args);
        else if (functionName == 'permission_set_clone')                     result = FunctionHelper.callClonePermissionSet(args);
        else if (functionName == 'permission_set_grant_object_access')       result = FunctionHelper.callGrantObjectAccess(args);
        else if (functionName == 'permission_set_grant_field_access')        result = FunctionHelper.callGrantFieldAccess(args);
        else if (functionName == 'permission_set_grant_all_fields_access')   result = FunctionHelper.callGrantAllFieldsAccess(args);
        else if (functionName == 'permission_set_delete')                    result = FunctionHelper.callDeletePermissionSet(args);
        else if (functionName == 'permission_set_assign_to_user')            result = FunctionHelper.callAssignPermissionSetToUser(args);
        else if (functionName == 'permission_set_remove_from_user')          result = FunctionHelper.callRemovePermissionSetFromUser(args);

        // ── PROFILE OPERATIONS ───────────────────────────────────
        else if (functionName == 'profile_list')                     result = FunctionHelper.callListProfiles(args);
        else if (functionName == 'profile_clone')                    result = FunctionHelper.callProfileClone(args);
        else if (functionName == 'profile_delete')                   result = FunctionHelper.callProfileDelete(args);
        else if (functionName == 'profile_grant_object_access')      result = FunctionHelper.callProfileGrantObjectAccess(args);
        else if (functionName == 'profile_revoke_object_access')     result = FunctionHelper.callProfileRevokeObjectAccess(args);
        else if (functionName == 'profile_grant_field_access')       result = FunctionHelper.callProfileGrantFieldAccess(args);
        else if (functionName == 'profile_revoke_field_access')      result = FunctionHelper.callProfileRevokeFieldAccess(args);
        else if (functionName == 'profile_grant_all_fields_access')  result = FunctionHelper.callProfileGrantAllFieldsAccess(args);

        // ── VALIDATION RULE OPERATIONS ───────────────────────────
        else if (functionName == 'validation_rule_list')       result = FunctionHelper.callListValidationRules(args);
        else if (functionName == 'validation_rule_create')     result = FunctionHelper.callCreateValidationRule(args);
        else if (functionName == 'validation_rule_update')     result = FunctionHelper.callUpdateValidationRule(args);
        else if (functionName == 'validation_rule_set_active') result = FunctionHelper.callSetValidationRuleActive(args);
        else if (functionName == 'validation_rule_delete')     result = FunctionHelper.callDeleteValidationRule(args);

        // ── CUSTOM LABEL OPERATIONS ──────────────────────────────
        else if (functionName == 'custom_label_list')   result = FunctionHelper.callListCustomLabels(args);
        else if (functionName == 'custom_label_create') result = FunctionHelper.callCreateCustomLabel(args);
        else if (functionName == 'custom_label_update') result = FunctionHelper.callUpdateCustomLabel(args);
        else if (functionName == 'custom_label_delete') result = FunctionHelper.callDeleteCustomLabel(args);

        // ── TRANSLATION OPERATIONS ───────────────────────────────
        else if (functionName == 'translation_list_languages')        result = FunctionHelper.callListSupportedLanguages(args);
        else if (functionName == 'translation_upsert')                result = FunctionHelper.callUpsertTranslation(args);
        else if (functionName == 'translation_delete')                result = FunctionHelper.callDeleteTranslation(args);

        // ── CUSTOM SETTING OPERATIONS ────────────────────────────
        else if (functionName == 'custom_setting_list')               result = FunctionHelper.callListCustomSettings(args);
        else if (functionName == 'custom_setting_create')             result = FunctionHelper.callCreateCustomSetting(args);
        else if (functionName == 'custom_setting_add_field')          result = FunctionHelper.callAddFieldToCustomSetting(args);
        else if (functionName == 'custom_setting_update_field')       result = FunctionHelper.callUpdateCustomSettingField(args);
        else if (functionName == 'custom_setting_delete_field')       result = FunctionHelper.callDeleteCustomSettingField(args);
        else if (functionName == 'custom_setting_delete')             result = FunctionHelper.callDeleteCustomSetting(args);

        // ── NAMED CREDENTIAL OPERATIONS ─────────────────────────────
        else if (functionName == 'named_credential_list')   result = FunctionHelper.callListNamedCredentials(args);
        else if (functionName == 'named_credential_create') result = FunctionHelper.callCreateNamedCredential(args);
        else if (functionName == 'named_credential_update') result = FunctionHelper.callUpdateNamedCredential(args);
        else if (functionName == 'named_credential_delete') result = FunctionHelper.callDeleteNamedCredential(args);

        // ── CUSTOM METADATA TYPE OPERATIONS ─────────────────────────
        else if (functionName == 'custom_metadata_type_list')       result = FunctionHelper.callListCustomMetadataTypes(args);
        else if (functionName == 'custom_metadata_type_create')     result = FunctionHelper.callCreateCustomMetadataType(args);
        else if (functionName == 'custom_metadata_type_add_field')  result = FunctionHelper.callAddFieldToCustomMetadataType(args);
        else if (functionName == 'custom_metadata_type_delete')     result = FunctionHelper.callDeleteCustomMetadataType(args);
        else if (functionName == 'custom_metadata_record_list')     result = FunctionHelper.callListCustomMetadataRecords(args);
        else if (functionName == 'custom_metadata_record_upsert')   result = FunctionHelper.callUpsertCustomMetadataRecord(args);
        else if (functionName == 'custom_metadata_record_delete')   result = FunctionHelper.callDeleteCustomMetadataRecord(args);

        // ── PAGE LAYOUT OPERATIONS ─────────────────────────────
        else if (functionName == 'page_layout_list')          result = FunctionHelper.callListPageLayouts(args);
        else if (functionName == 'page_layout_create')        result = FunctionHelper.callCreatePageLayout(args);
        else if (functionName == 'page_layout_add_fields')    result = FunctionHelper.callAddFieldsToLayout(args);
        else if (functionName == 'page_layout_remove_fields') result = FunctionHelper.callRemoveFieldsFromLayout(args);
        else if (functionName == 'page_layout_delete')        result = FunctionHelper.callDeletePageLayout(args);
        else if (functionName == 'page_layout_assign')        result = FunctionHelper.callAssignPageLayout(args);

        // ── STATIC RESOURCE OPERATIONS ────────────────────────────
        else if (functionName == 'static_resource_list')   result = FunctionHelper.callStaticResourceList(args);
        else if (functionName == 'static_resource_deploy') result = FunctionHelper.callStaticResourceDeploy(args);
        else if (functionName == 'static_resource_delete') result = FunctionHelper.callStaticResourceDelete(args);

        // ── QUERY ─────────────────────────────────────────────
        else if (functionName == 'run_tooling_api_query')   result = FunctionHelper.runToolingApiQuery(args);

        // ── UNKNOWN ───────────────────────────────────────────
        else {
            System.debug('      ✖ FunctionRouter: unknown function [' + functionName + ']');
            result = JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => 'Unknown function: ' + functionName
            });
        }

        System.debug('      ── FunctionRouter: [' + functionName + '] completed successfully');
        return result;
    }
}
