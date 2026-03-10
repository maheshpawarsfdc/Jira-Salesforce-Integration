public class FunctionRouter {

    public static String execute(String functionName, Map<String, Object> args) {

        System.debug('');
        System.debug('      ── FunctionRouter: routing [' + functionName + ']');

        String result;

        // ── SOBJECT OPERATIONS ────────────────────────────────
        if      (functionName == 'sobjects_list')          result = FunctionHelper.callListSObjects(args);
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
        else if (functionName == 'permission_set_list')                  result = FunctionHelper.callListPermissionSets(args);
        else if (functionName == 'permission_set_create')                result = FunctionHelper.callCreatePermissionSet(args);
        else if (functionName == 'permission_set_grant_object_access')   result = FunctionHelper.callGrantObjectAccess(args);
        else if (functionName == 'permission_set_grant_field_access')    result = FunctionHelper.callGrantFieldAccess(args);
        else if (functionName == 'permission_set_grant_all_fields_access') result = FunctionHelper.callGrantAllFieldsAccess(args);
        else if (functionName == 'permission_set_delete')                    return FunctionHelper.callDeletePermissionSet(args);
        else if (functionName == 'permission_set_assign_to_user')          return FunctionHelper.callAssignPermissionSetToUser(args);
        else if (functionName == 'permission_set_remove_from_user')         return FunctionHelper.callRemovePermissionSetFromUser(args);

        // ── PROFILE OPERATIONS ───────────────────────────────────
        else if (functionName == 'profile_list')                     return FunctionHelper.callListProfiles(args);
        else if (functionName == 'profile_clone')                    return FunctionHelper.callProfileClone(args);
        else if (functionName == 'profile_delete')                   return FunctionHelper.callProfileDelete(args);
        else if (functionName == 'profile_grant_object_access')      return FunctionHelper.callProfileGrantObjectAccess(args);
        else if (functionName == 'profile_revoke_object_access')     return FunctionHelper.callProfileRevokeObjectAccess(args);
        else if (functionName == 'profile_grant_field_access')       return FunctionHelper.callProfileGrantFieldAccess(args);
        else if (functionName == 'profile_revoke_field_access')      return FunctionHelper.callProfileRevokeFieldAccess(args);
        else if (functionName == 'profile_grant_all_fields_access')  return FunctionHelper.callProfileGrantAllFieldsAccess(args);

        // ── VALIDATION RULE OPERATIONS ───────────────────────────
        else if (functionName == 'validation_rule_list')       result = FunctionHelper.callListValidationRules(args);
        else if (functionName == 'validation_rule_create')     result = FunctionHelper.callCreateValidationRule(args);
        else if (functionName == 'validation_rule_update')     result = FunctionHelper.callUpdateValidationRule(args);
        else if (functionName == 'validation_rule_set_active') result = FunctionHelper.callSetValidationRuleActive(args);
        else if (functionName == 'validation_rule_delete')     result = FunctionHelper.callDeleteValidationRule(args);

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