/**
 * ToolDefinitions.cls
 *
 * Defines the tools (functions) that the LLM is allowed to call.
 * This is the "menu" we send to Groq along with every request.
 *
 * Each tool has:
 *   name        — function name the LLM will use
 *   description — tells the LLM when and why to use this tool
 *   parameters  — what arguments the LLM must provide
 *
 * These map directly to methods in FunctionRouter → FunctionHelper → MetadataHelper
 */
public class ToolDefinitions {

    // Returns all tools as a list ready to send to Groq
    public static List<Map<String, Object>> getAllTools() {
        List<Map<String, Object>> tools = new List<Map<String, Object>>();
        tools.addAll(getSObjectTools());
        tools.addAll(getFieldTools());
        tools.addAll(getPermissionSetTools());
        tools.addAll(getProfileTools());
        tools.addAll(getValidationRuleTools());
        tools.addAll(getTranslationTools());
        tools.addAll(getCustomLabelTools());
        tools.addAll(getCustomSettingTools());
        tools.addAll(getNamedCredentialTools());
        tools.addAll(getCustomMetadataTools());
        tools.add(getQueryTool());
        return tools;
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getSObjectTools() {
        return new List<Map<String, Object>>{

            buildTool(
                'sobjects_list',
                'List all Salesforce objects in the org. Use customObjectsOnly=true to show only custom objects.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('customObjectsOnly', 'Set to true to return only custom objects')
                    },
                    new List<String>{}  // no required params
                )
            ),

            buildTool(
                'sobject_describe',
                'Get details about a specific Salesforce object including all its fields.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object e.g. Account or Reservation__c')
                    },
                    new List<String>{ 'sObjectName' }
                )
            ),

            buildTool(
                'sobject_create',
                'Create a new custom Salesforce object. Always provide nameFieldType and nameFieldLabel.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',        'API name without __c e.g. Reservation'),
                        strProp('label',          'Singular label e.g. Reservation'),
                        strProp('pluralLabel',    'Plural label e.g. Reservations'),
                        enumProp('nameFieldType', 'Type of the Name field', new List<String>{ 'Text', 'AutoNumber' }),
                        strProp('nameFieldLabel', 'Label for the Name field e.g. Reservation Name'),
                        enumProp('sharingModel',  'Sharing model for the object', new List<String>{ 'ReadWrite', 'Read', 'Private' }),
                        strProp('description',    'Optional description of the object')
                    },
                    new List<String>{ 'apiName', 'label', 'pluralLabel', 'nameFieldType', 'nameFieldLabel' }
                )
            ),

            buildTool(
                'sobject_update',
                'Update properties of an existing custom object such as label or description.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName',  'API name of the object e.g. Reservation__c'),
                        strProp('label',        'New singular label'),
                        strProp('pluralLabel',  'New plural label'),
                        strProp('description',  'New description')
                    },
                    new List<String>{ 'sObjectName' }
                )
            ),

            buildTool(
                'sobject_delete',
                'Delete a custom object and all its data. Use with caution.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object to delete e.g. Reservation__c')
                    },
                    new List<String>{ 'sObjectName' }
                )
            ),

            buildTool(
                'tab_create',
                'Create a Tab for an existing custom object so it appears in the App navigation. '
                + 'Use this if a custom object exists but has no tab yet. '
                + 'Note: sobject_create automatically creates a tab — only use this for objects that already exist without a tab.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object e.g. Car__c'),
                        strProp('motif',       'Optional icon motif (default: Custom58: Handsaw)')
                    },
                    new List<String>{ 'sObjectName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getFieldTools() {
        return new List<Map<String, Object>>{

            buildTool(
                'sobject_fields_list',
                'List all fields on a Salesforce object.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object e.g. Account')
                    },
                    new List<String>{ 'sObjectName' }
                )
            ),

            buildTool(
                'sobject_field_describe',
                'Get details about a specific field on an object.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object e.g. Account'),
                        strProp('fieldName',   'API name of the field e.g. Phone__c')
                    },
                    new List<String>{ 'sObjectName', 'fieldName' }
                )
            ),

            buildTool(
                'sobject_field_create',
                'Create a brand NEW custom field on a Salesforce object. '
                + 'DO NOT use this to rename or update an existing field — use sobject_field_update for that. '
                + 'Always call sobject_fields_list first to confirm the field does not already exist in the org. '
                + 'Only include parameters relevant to the field type. Omit unused parameters entirely. '
                + 'For Text: include length. For Number/Currency/Percent: include precision and scale. '
                + 'For Picklist: include picklistValues. For Lookup/MasterDetail: include referenceTo and relationshipName.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName',      'API name of the object e.g. Account'),
                        strProp('apiName',          'Field API name without __c e.g. Phone_Number'),
                        strProp('label',            'Field label e.g. Phone Number'),
                        enumProp('type',            'Field data type. Text=short text, LongTextArea=rich text area, Lookup=child-parent optional, MasterDetail=child-parent required (cascades delete)',
                            new List<String>{
                                'Text', 'Number', 'Date', 'DateTime', 'Phone',
                                'Email', 'Checkbox', 'Currency', 'Percent',
                                'Url', 'TextArea', 'LongTextArea',
                                'Picklist', 'MultiselectPicklist',
                                'Lookup', 'MasterDetail'
                            }
                        ),
                        nullableStrProp('required',         'Set to true if field is required. Otherwise send null.'),
                        nullableStrProp('length',           'For Text fields only: max character length. Send null for other types.'),
                        nullableStrProp('precision',        'For Number/Currency/Percent only: total digits. Send null for other types.'),
                        nullableStrProp('scale',            'For Number/Currency/Percent only: decimal places. Send null for other types.'),
                        nullableStrProp('picklistValues',   'For Picklist or MultiselectPicklist only: comma-separated values e.g. "Open,Closed,Pending". Send null for other types.'),
                        nullableStrProp('referenceTo',      'For Lookup/MasterDetail only: parent object API name. Send null for other types.'),
                        nullableStrProp('relationshipName', 'For Lookup/MasterDetail only: relationship name. Send null for other types.'),
                        nullableStrProp('description',      'Optional description. Send null if not needed.'),
                        nullableStrProp('helpText',         'Optional help text. Send null if not needed.')
                    },
                    new List<String>{ 'sObjectName', 'apiName', 'label', 'type' }
                )
            ),

            buildTool(
                'sobject_field_update',
                'Update an existing custom field — use this to RENAME a field label or change its description, helpText, or required flag. IMPORTANT: Only include parameters you actually want to change — omit any parameters you are not changing (do NOT pass empty strings). '
                + 'USE THIS (not sobject_field_create) when the story says: rename, update, change label of an existing field. '
                + 'Example: "rename LastName to Surname" → fieldName=LastName__c, label=Surname. '
                + 'IMPORTANT: Field API name and type CANNOT be changed — only the label and metadata shown here. '
                + 'Only include parameters you want to change. Omit unused parameters entirely.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName',  'API name of the object e.g. Reservation__c'),
                        strProp('fieldName',    'Current API name of the field to update e.g. LastName__c'),
                        strProp('label',        'New display label e.g. Car Color. Only include if renaming the label.'),
                        strProp('description',  'New description. Only include if changing the description.'),
                        strProp('helpText',     'New help text. Only include if changing help text.'),
                        strProp('required',     'New required flag: true or false. Only include if changing.')
                    },
                    new List<String>{ 'sObjectName', 'fieldName' }
                )
            ),

            buildTool(
                'sobject_field_delete',
                'Delete a custom field from an object.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sObjectName', 'API name of the object e.g. Account'),
                        strProp('fieldName',   'API name of the field to delete e.g. Phone__c')
                    },
                    new List<String>{ 'sObjectName', 'fieldName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // QUERY TOOL
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> getQueryTool() {
        return buildTool(
            'run_tooling_api_query',
            'Run a SOQL query using the Salesforce Tooling API. Useful for reading metadata.',
            buildParams(
                new List<Map<String, Object>>{
                    strProp('query', 'SOQL query to run e.g. SELECT Id, DeveloperName FROM CustomObject__c')
                },
                new List<String>{ 'query' }
            )
        );
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getPermissionSetTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'permission_set_list',
                'List all permission sets in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'permission_set_create',
                'Create a new permission set. '
                + 'Only include description parameter if you have a meaningful description to add. '
                + 'Do NOT send null for unused parameters — omit them entirely.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',     'API name for the permission set e.g. Sales_Team_Access'),
                        strProp('label',       'Label for the permission set e.g. Sales Team Access'),
                        strProp('description', 'Only include if you have a meaningful description to add.')
                    },
                    new List<String>{ 'apiName', 'label' }
                )
            ),
            buildTool(
                'permission_set_delete',
                'Delete a permission set permanently. '
                + 'Always call permission_set_list first to confirm the permission set exists.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set to delete e.g. Sales_Team_Access')
                    },
                    new List<String>{ 'permissionSetName' }
                )
            ),
            buildTool(
                'permission_set_grant_object_access',
                'Grant object level access to a permission set. '
                + 'Always call permission_set_list first to confirm the permission set exists. '
                + 'Only include access flags you want to set to true.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set e.g. Sales_Team_Access'),
                        strProp('objectName',        'API name of the object e.g. Reservation__c'),
                        strProp('allowRead',         'Grant read access. Use true or false.'),
                        strProp('allowCreate',       'Grant create access. Use true or false.'),
                        strProp('allowEdit',         'Grant edit access. Use true or false.'),
                        strProp('allowDelete',       'Grant delete access. Use true or false.'),
                        strProp('viewAllRecords',    'Grant view all records. Use true or false.'),
                        strProp('modifyAllRecords',  'Grant modify all records. Use true or false.')
                    },
                    new List<String>{ 'permissionSetName', 'objectName' }
                )
            ),
            buildTool(
                'permission_set_grant_field_access',
                'Grant access to a specific field on a permission set.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set'),
                        strProp('objectName',        'API name of the object e.g. Reservation__c'),
                        strProp('fieldName',         'API name of the field e.g. TotalAmount__c'),
                        strProp('readable',          'Grant read access to field. Use true or false.'),
                        strProp('editable',          'Grant edit access to field. Use true or false.')
                    },
                    new List<String>{ 'permissionSetName', 'objectName', 'fieldName' }
                )
            ),
            buildTool(
                'permission_set_grant_all_fields_access',
                'Grant access to ALL custom fields on an object in one call. '
                + 'Use this instead of calling permission_set_grant_field_access for each field individually.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set'),
                        strProp('objectName',        'API name of the object e.g. Reservation__c'),
                        strProp('readable',          'Grant read access to all fields. Use true or false.'),
                        strProp('editable',          'Grant edit access to all fields. Use true or false.')
                    },
                    new List<String>{ 'permissionSetName', 'objectName' }
                )
            ),
            buildTool(
                'permission_set_assign_to_user',
                'Assign a permission set to a user.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set'),
                        strProp('username',          'Username or full name of the user to assign to')
                    },
                    new List<String>{ 'permissionSetName', 'username' }
                )
            ),
            buildTool(
                'permission_set_remove_from_user',
                'Remove a specific permission set from a user. '
                + 'Always specify both permissionSetName and username.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('permissionSetName', 'API name of the permission set to remove'),
                        strProp('username',          'Username or full name of the user')
                    },
                    new List<String>{ 'permissionSetName', 'username' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getProfileTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'profile_list',
                'List all profiles in the org. Call this first before any profile operation to confirm the exact profile name.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'profile_clone',
                'Clone an existing profile to create a new one. '
                + 'This is the only supported way to create a new profile — you cannot create one from scratch. '
                + 'Always call profile_list first to get the exact source profile name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('sourceProfileName', 'API name of the existing profile to copy from'),
                        strProp('newProfileName',    'API name for the new profile (no spaces, no __c)')
                    },
                    new List<String>{ 'sourceProfileName', 'newProfileName' }
                )
            ),
            buildTool(
                'profile_delete',
                'Delete a custom profile from the org via destructive deploy. '
                + 'Cannot delete standard Salesforce profiles (System Administrator, Standard User, etc.).',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName', 'API name of the profile to delete')
                    },
                    new List<String>{ 'profileName' }
                )
            ),
            buildTool(
                'profile_grant_object_access',
                'Grant object-level permissions to a profile. '
                + 'Always call profile_list first to confirm the exact profile name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName',       'API name of the profile'),
                        strProp('objectName',        'API name of the object (e.g. Car__c)'),
                        strProp('allowRead',         'true or false — allow read access'),
                        strProp('allowCreate',       'true or false — allow create access'),
                        strProp('allowEdit',         'true or false — allow edit access'),
                        strProp('allowDelete',       'true or false — allow delete access'),
                        strProp('viewAllRecords',    'true or false — allow view all records'),
                        strProp('modifyAllRecords',  'true or false — allow modify all records')
                    },
                    new List<String>{ 'profileName', 'objectName' }
                )
            ),
            buildTool(
                'profile_revoke_object_access',
                'Remove all object-level permissions from a profile for a specific object. '
                + 'Always call profile_list first to confirm the exact profile name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName', 'API name of the profile'),
                        strProp('objectName',  'API name of the object (e.g. Car__c)')
                    },
                    new List<String>{ 'profileName', 'objectName' }
                )
            ),
            buildTool(
                'profile_grant_field_access',
                'Grant field-level access to a specific field on a profile. '
                + 'Always call profile_list first to confirm the exact profile name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName', 'API name of the profile'),
                        strProp('objectName',  'API name of the object (e.g. Car__c)'),
                        strProp('fieldName',   'API name of the field (e.g. Price__c)'),
                        strProp('readable',    'true or false — allow read access to the field'),
                        strProp('editable',    'true or false — allow edit access to the field')
                    },
                    new List<String>{ 'profileName', 'objectName', 'fieldName' }
                )
            ),
            buildTool(
                'profile_revoke_field_access',
                'Remove field-level access (set readable=false, editable=false) for a specific field on a profile. '
                + 'Always call profile_list first to confirm the exact profile name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName', 'API name of the profile'),
                        strProp('objectName',  'API name of the object (e.g. Car__c)'),
                        strProp('fieldName',   'API name of the field (e.g. Price__c)')
                    },
                    new List<String>{ 'profileName', 'objectName', 'fieldName' }
                )
            ),
            buildTool(
                'profile_grant_all_fields_access',
                'Grant field-level access to ALL custom fields on an object for a profile. '
                + 'Use this instead of calling profile_grant_field_access for each field individually.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('profileName', 'API name of the profile'),
                        strProp('objectName',  'API name of the object (e.g. Car__c)'),
                        strProp('readable',    'true or false — allow read access to all fields'),
                        strProp('editable',    'true or false — allow edit access to all fields')
                    },
                    new List<String>{ 'profileName', 'objectName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // VALIDATION RULE TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getValidationRuleTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'validation_rule_list',
                'List all validation rules on a given object. Call this before update/delete to confirm the rule name exists.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('objectName', 'API name of the object (e.g. Car__c)')
                    },
                    new List<String>{ 'objectName' }
                )
            ),
            buildTool(
                'validation_rule_create',
                'Create a new validation rule on a custom object. '
                + 'The errorConditionFormula must be a valid Salesforce formula that evaluates to TRUE when the record should be blocked. '
                + 'CRITICAL formula syntax: (1) Use AND(), OR(), NOT() as functions — never as keywords. '
                + '(2) Use ISBLANK(field) — never = "". '
                + '(3) For picklist fields always use ISPICKVAL(Field__c, "Value") — never = or !=. '
                + 'Example: AND(IsAvailable__c = true, ISPICKVAL(Status__c, "Active"), OR(ISBLANK(Price__c), Price__c < 500)) '
                + 'Do NOT XML-escape the formula — the system handles escaping automatically.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('objectName',             'API name of the object (e.g. Car__c)'),
                        strProp('ruleName',               'API name for the rule — no spaces, no __c (e.g. PriceMustBePositive)'),
                        strProp('errorConditionFormula',  'Salesforce formula that returns TRUE when the record should be blocked (e.g. Price__c <= 0)'),
                        strProp('errorMessage',           'Error message shown to the user when the rule fires'),
                        strProp('description',            'Optional description of the rule'),
                        strProp('errorDisplayField',      'Optional API name of the field to highlight when error fires'),
                        strProp('active',                 'true or false — whether the rule is active (default true)')
                    },
                    new List<String>{ 'objectName', 'ruleName', 'errorConditionFormula', 'errorMessage' }
                )
            ),
            buildTool(
                'validation_rule_update',
                'Update an existing validation rule — change its formula, error message, or description. '
                + 'Only include parameters you want to change — omit any you are not changing. '
                + 'Always call validation_rule_list first to confirm the rule name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('objectName',             'API name of the object (e.g. Car__c)'),
                        strProp('ruleName',               'API name of the existing rule (e.g. PriceMustBePositive)'),
                        strProp('errorConditionFormula',  'New Salesforce formula — only include if changing'),
                        strProp('errorMessage',           'New error message — only include if changing'),
                        strProp('description',            'New description — only include if changing'),
                        strProp('errorDisplayField',      'New field to highlight — only include if changing')
                    },
                    new List<String>{ 'objectName', 'ruleName' }
                )
            ),
            buildTool(
                'validation_rule_set_active',
                'Activate or deactivate a validation rule without changing its formula or message. '
                + 'Always call validation_rule_list first to confirm the rule name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('objectName', 'API name of the object (e.g. Car__c)'),
                        strProp('ruleName',   'API name of the rule (e.g. PriceMustBePositive)'),
                        strProp('active',     'true to activate, false to deactivate')
                    },
                    new List<String>{ 'objectName', 'ruleName', 'active' }
                )
            ),
            buildTool(
                'validation_rule_delete',
                'Delete a validation rule from an object permanently via destructive deploy. '
                + 'Always call validation_rule_list first to confirm the rule name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('objectName', 'API name of the object (e.g. Car__c)'),
                        strProp('ruleName',   'API name of the rule to delete (e.g. PriceMustBePositive)')
                    },
                    new List<String>{ 'objectName', 'ruleName' }
                )
            )
        };
    }



    // ─────────────────────────────────────────────────────────────
    // TRANSLATION TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getTranslationTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'translation_list_languages',
                'List all active languages enabled in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'translation_upsert',
                'Create or update a translation for a field label, picklist value, custom label, validation rule error message, or custom object label. '
                + 'Always call translation_list_languages first to confirm the language code is enabled. '
                + 'The translationType parameter controls what is being translated: '
                + '"field" = custom field label (needs objectName, fieldName, translation). '
                + '"picklist" = picklist value (needs objectName, fieldName, masterLabel, translation). '
                + '"label" = custom label value (needs labelName, translation). '
                + '"validationRule" = validation rule error message (needs objectName, ruleName, translation). '
                + '"object" = custom object label (needs objectName, translation). '
                + 'Existing translations for the language are preserved — only the specified entry is added/updated.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('language',       'Language ISO code (e.g. fr, de, ja, zh_CN, pt_BR)'),
                        strProp('translationType','What to translate: field, picklist, label, validationRule, object'),
                        strProp('objectName',     'API name of the object (e.g. Car__c) — required for field, picklist, validationRule, object types'),
                        strProp('fieldName',      'API name of the field (e.g. Price__c) — required for field and picklist types'),
                        strProp('masterLabel',    'The original English picklist value (e.g. Active) — required for picklist type'),
                        strProp('labelName',      'API name of the custom label (e.g. Welcome_Message) — required for label type'),
                        strProp('ruleName',       'API name of the validation rule (e.g. PriceMustBePositive) — required for validationRule type'),
                        strProp('translation',    'The translated text in the target language')
                    },
                    new List<String>{ 'language', 'translationType', 'translation' }
                )
            ),
            buildTool(
                'translation_delete',
                'Delete a specific custom label translation using the Tooling API. '
                + 'Always call custom_label_list first to confirm the label name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('language',  'Language ISO code (e.g. fr, de, ja)'),
                        strProp('labelName', 'API name of the custom label (e.g. Welcome_Message)')
                    },
                    new List<String>{ 'language', 'labelName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // CUSTOM LABEL TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getCustomLabelTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'custom_label_list',
                'List all custom labels in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'custom_label_create',
                'Create a new custom label. '
                + 'Custom labels are org-wide text values referenced in Apex, Visualforce, and Lightning components using $Label.Name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('name',             'API name for the label — no spaces (e.g. Welcome_Message)'),
                        strProp('value',            'The text value of the label (e.g. Welcome to our app!)'),
                        strProp('language',         'Language code (default: en_US)'),
                        strProp('shortDescription', 'Optional short description of what this label is used for'),
                        strProp('protected',        'true or false — whether label is protected (default false)')
                    },
                    new List<String>{ 'name', 'value' }
                )
            ),
            buildTool(
                'custom_label_update',
                'Update an existing custom label — change its value, description, or other properties. '
                + 'Always call custom_label_list first to confirm the exact label name. '
                + 'Only include parameters you want to change.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('name',             'API name of the existing label (e.g. Welcome_Message)'),
                        strProp('value',            'New text value — only include if changing'),
                        strProp('shortDescription', 'New short description — only include if changing'),
                        strProp('language',         'New language code — only include if changing')
                    },
                    new List<String>{ 'name' }
                )
            ),
            buildTool(
                'custom_label_delete',
                'Delete a custom label permanently via destructive deploy. '
                + 'Always call custom_label_list first to confirm the exact label name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('name', 'API name of the label to delete (e.g. Welcome_Message)')
                    },
                    new List<String>{ 'name' }
                )
            )
        };
    }


    // ─────────────────────────────────────────────────────────────
    // CUSTOM SETTING TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getCustomSettingTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'custom_setting_list',
                'List all custom settings in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'custom_setting_create',
                'Create a new custom setting (Hierarchy or List type). '
                + 'Custom settings are org-wide configuration objects accessible in Apex via CustomSettingName__c.getInstance(). '
                + 'Always add fields separately with custom_setting_add_field after creating.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',     'API name for the setting (e.g. MyConfig). __c will be added automatically.'),
                        strProp('label',       'Human-readable label (e.g. My Config)'),
                        strProp('type',        'Hierarchy (default) or List'),
                        strProp('visibility',  'Public (default) or Protected'),
                        strProp('description', 'Optional description of what this setting is used for')
                    },
                    new List<String>{ 'apiName', 'label' }
                )
            ),
            buildTool(
                'custom_setting_add_field',
                'Add a new field to an existing custom setting. '
                + 'Always call custom_setting_list first to confirm the exact setting API name. '
                + 'Supported field types: Checkbox, Currency, Date, DateTime, Email, Number, Percent, Phone, Text, TextArea, Url. DO NOT use LongTextArea, Picklist, Lookup or any other type.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',     'API name of the existing setting (e.g. MyConfig__c)'),
                        strProp('fieldName',   'API name for the new field (e.g. IsEnabled). __c added automatically.'),
                        strProp('fieldLabel',  'Human-readable label for the field'),
                        strProp('fieldType',   'Must be one of: Checkbox, Currency, Date, DateTime, Email, Number, Percent, Phone, Text, TextArea, Url'),
                        strProp('length',      'For Text/TextArea: max length (default 255). For LongTextArea: default 32768.'),
                        strProp('precision',   'For Number/Currency/Percent: total digits (default 18)'),
                        strProp('scale',       'For Number/Currency/Percent: decimal places (default 0)'),
                        strProp('required',    'true or false (default false)')
                    },
                    new List<String>{ 'apiName', 'fieldName', 'fieldLabel', 'fieldType' }
                )
            ),
            buildTool(
                'custom_setting_update_field',
                'Update an existing field on a custom setting — change its label, length, or other properties. '
                + 'Always call custom_setting_list first to confirm the exact setting and field names. '
                + 'Only include the parameters you want to change.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',    'API name of the setting (e.g. MyConfig__c)'),
                        strProp('fieldName',  'API name of the field to update (e.g. IsEnabled__c)'),
                        strProp('fieldLabel', 'New label — only include if changing'),
                        strProp('length',     'New length — only include if changing'),
                        strProp('required',   'true or false — only include if changing')
                    },
                    new List<String>{ 'apiName', 'fieldName' }
                )
            ),
            buildTool(
                'custom_setting_delete_field',
                'Delete a field from a custom setting via destructive deploy. '
                + 'Always call custom_setting_list first to confirm the exact setting and field names.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',   'API name of the setting (e.g. MyConfig__c)'),
                        strProp('fieldName', 'API name of the field to delete (e.g. IsEnabled__c)')
                    },
                    new List<String>{ 'apiName', 'fieldName' }
                )
            ),
            buildTool(
                'custom_setting_delete',
                'Delete an entire custom setting and all its fields via destructive deploy. '
                + 'Always call custom_setting_list first to confirm the exact setting name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName', 'API name of the setting to delete (e.g. MyConfig__c)')
                    },
                    new List<String>{ 'apiName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // NAMED CREDENTIAL TOOLS
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> getNamedCredentialTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'named_credential_list',
                'List all Named Credentials in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'named_credential_create',
                'Create a new anonymous Named Credential with a label and endpoint URL. '
                + 'No authentication is configured — suitable for public APIs or internal endpoints.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',  'API name for the credential — no spaces, no __c (e.g. My_API)'),
                        strProp('label',   'Human-readable label (e.g. My API)'),
                        strProp('endpoint','Full endpoint URL (e.g. https://api.example.com)'),
                        strProp('allowMergeFieldsInBody',      'true or false — allow merge fields in body (default false)'),
                        strProp('allowMergeFieldsInHeader',    'true or false — allow merge fields in header (default false)'),
                        strProp('generateAuthorizationHeader', 'true or false — generate auth header (default false)')
                    },
                    new List<String>{ 'apiName', 'label', 'endpoint' }
                )
            ),
            buildTool(
                'named_credential_update',
                'Update an existing Named Credential — change its label or endpoint URL. '
                + 'Always call named_credential_list first to confirm the exact API name. '
                + 'Only include parameters you want to change.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',  'API name of the existing credential (e.g. My_API)'),
                        strProp('label',   'New label — only include if changing'),
                        strProp('endpoint','New endpoint URL — only include if changing'),
                        strProp('allowMergeFieldsInBody',      'true or false — allow merge fields in body (default false)'),
                        strProp('allowMergeFieldsInHeader',    'true or false — allow merge fields in header (default false)'),
                        strProp('generateAuthorizationHeader', 'true or false — generate auth header (default false)')
                    },
                    new List<String>{ 'apiName' }
                )
            ),
            buildTool(
                'named_credential_delete',
                'Delete a Named Credential permanently via destructive deploy. '
                + 'Always call named_credential_list first to confirm the exact API name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName', 'API name of the credential to delete (e.g. My_API)')
                    },
                    new List<String>{ 'apiName' }
                )
            )
        };
    }


    // ─────────────────────────────────────────────────────────────
    // CUSTOM METADATA TYPE TOOLS
    // ─────────────────────────────────────────────────────────────

    private static List<Map<String, Object>> getCustomMetadataTools() {
        return new List<Map<String, Object>>{
            buildTool(
                'custom_metadata_type_list',
                'List all Custom Metadata Types in the org.',
                buildParams(new List<Map<String, Object>>{}, new List<String>{})
            ),
            buildTool(
                'custom_metadata_type_create',
                'Create a new Custom Metadata Type. After creating, add fields with custom_metadata_type_add_field.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',      'API name without __mdt (e.g. My_Config)'),
                        strProp('label',        'Singular label (e.g. My Config)'),
                        strProp('pluralLabel',  'Plural label (e.g. My Configs)'),
                        strProp('description',  'Optional description'),
                        enumProp('visibility',  'Visibility setting',
                            new List<String>{ 'Public', 'Protected', 'PackageProtected' })
                    },
                    new List<String>{ 'apiName', 'label', 'pluralLabel' }
                )
            ),
            buildTool(
                'custom_metadata_type_add_field',
                'Add a field to an existing Custom Metadata Type. '
                + 'Always call custom_metadata_type_list first to confirm the type exists. '
                + 'Supported types: Checkbox, Date, DateTime, Email, Number, Percent, Phone, Picklist, Text, TextArea, LongTextArea, Url.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',        'API name of the type with __mdt (e.g. My_Config__mdt)'),
                        strProp('fieldName',      'Field API name without __c (e.g. Timeout_Seconds)'),
                        strProp('fieldLabel',     'Field label (e.g. Timeout Seconds)'),
                        strProp('fieldType',      'Field type: Checkbox, Date, DateTime, Email, Number, Percent, Phone, Picklist, Text, TextArea, LongTextArea, Url'),
                        strProp('length',         'For Text/TextArea: max length (default 255)'),
                        strProp('precision',      'For Number/Percent: total digits (default 18)'),
                        strProp('scale',          'For Number/Percent: decimal places (default 0)'),
                        strProp('picklistValues', 'For Picklist: comma-separated values (e.g. "Active,Inactive,Pending")'),
                        strProp('required',       'true or false (default false)'),
                        strProp('defaultValue',   'For Checkbox only: true or false (default false)')
                    },
                    new List<String>{ 'apiName', 'fieldName', 'fieldLabel', 'fieldType' }
                )
            ),
            buildTool(
                'custom_metadata_type_delete',
                'Delete a Custom Metadata Type and all its records via destructive deploy. '
                + 'Always call custom_metadata_type_list first to confirm the exact API name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName', 'API name of the type with __mdt (e.g. My_Config__mdt)')
                    },
                    new List<String>{ 'apiName' }
                )
            ),
            buildTool(
                'custom_metadata_record_list',
                'List all records of a Custom Metadata Type including their field values. '
                + 'Always call this before upsert or delete to confirm record names.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName', 'API name of the type with __mdt (e.g. My_Config__mdt)')
                    },
                    new List<String>{ 'apiName' }
                )
            ),
            buildTool(
                'custom_metadata_record_upsert',
                'Create or update a Custom Metadata record. '
                + 'Always call custom_metadata_record_list first to check if the record already exists. '
                + 'fieldValues must be a JSON object mapping field API names to values '
                + 'e.g. {"Timeout_Seconds__c": 30, "Is_Active__c": true, "Label__c": "Default"}.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',      'API name of the type with __mdt (e.g. My_Config__mdt)'),
                        strProp('recordName',   'Developer name of the record (e.g. Default) — no spaces'),
                        strProp('label',        'Label for the record (e.g. Default Config)'),
                        strProp('fieldValues',  'JSON object of field API names to values e.g. {"Field__c": "value"}'),
                        strProp('protected',    'true or false — whether record is protected (default false)')
                    },
                    new List<String>{ 'apiName', 'recordName' }
                )
            ),
            buildTool(
                'custom_metadata_record_delete',
                'Delete a Custom Metadata record via destructive deploy. '
                + 'Always call custom_metadata_record_list first to confirm the exact record name.',
                buildParams(
                    new List<Map<String, Object>>{
                        strProp('apiName',    'API name of the type with __mdt (e.g. My_Config__mdt)'),
                        strProp('recordName', 'Developer name of the record to delete (e.g. Default)')
                    },
                    new List<String>{ 'apiName', 'recordName' }
                )
            )
        };
    }

    // ─────────────────────────────────────────────────────────────
    // BUILDER HELPERS
    // These make it clean to define tools above
    // ─────────────────────────────────────────────────────────────

    // Wraps a tool into the format Groq expects
    private static Map<String, Object> buildTool(
        String name,
        String description,
        Map<String, Object> parameters
    ) {
        return new Map<String, Object>{
            'type' => 'function',
            'function' => new Map<String, Object>{
                'name'        => name,
                'description' => description,
                'parameters'  => parameters
            }
        };
    }

    // Builds the parameters object with properties and required list
    private static Map<String, Object> buildParams(
        List<Map<String, Object>> properties,
        List<String> required
    ) {
        Map<String, Object> propsMap = new Map<String, Object>();
        for (Map<String, Object> prop : properties) {
            String propName = (String) prop.get('_name');
            prop.remove('_name');
            propsMap.put(propName, prop);
        }
        return new Map<String, Object>{
            'type'       => 'object',
            'properties' => propsMap,
            'required'   => required
        };
    }

    // String property (required)
    private static Map<String, Object> strProp(String name, String description) {
        return new Map<String, Object>{
            '_name'       => name,
            'type'        => 'string',
            'description' => description
        };
    }

    // Nullable string property (optional — LLM may send null, must be accepted)
    private static Map<String, Object> nullableStrProp(String name, String description) {
        return new Map<String, Object>{
            '_name'       => name,
            'type'        => 'string',
            'description' => description,
            'nullable'    => true
        };
    }

    // Boolean property
    private static Map<String, Object> boolProp(String name, String description) {
        return new Map<String, Object>{
            '_name'       => name,
            'type'        => 'boolean',
            'description' => description
        };
    }

    // Enum property (string with fixed allowed values)
    private static Map<String, Object> enumProp(
        String name,
        String description,
        List<String> values
    ) {
        return new Map<String, Object>{
            '_name'       => name,
            'type'        => 'string',
            'description' => description,
            'enum'        => values
        };
    }
}