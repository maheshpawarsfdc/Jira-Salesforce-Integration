/**
 * CustomSettingHelper.cls
 *
 * Handles Custom Setting operations via ZIP deploy.
 *
 * MDAPI facts:
 * - Type: CustomObject (same as regular objects)
 * - File: objects/MySetting__c.object
 * - Package.xml type: CustomObject, member: MySetting__c
 * - Destructive delete setting: CustomObject, member: MySetting__c
 * - Destructive delete field:   CustomField,  member: MySetting__c.FieldName__c
 *
 * KEY: Custom Settings have <customSettingsType> tag (List or Hierarchy).
 * Fields are preserved on every deploy by reading existing fields first.
 *
 * NOTE: <customSettingsVisibility> was removed in API v61.0 — do NOT include it.
 */
public class CustomSettingHelper {

    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    // ─────────────────────────────────────────────────────────────
    // METADATA PORT — Initialize once, reuse for all MDAPI calls
    // Same pattern as ValidationRuleHelper
    // ─────────────────────────────────────────────────────────────
    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('CustomSettingHelper: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('CustomSettingHelper: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // LIST
    // Uses Schema.getGlobalDescribe() to find all custom settings
    // Tooling API CustomObject doesn't support IsCustomSetting field
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listCustomSettings(Map<String, Object> args) {
        System.debug('CustomSettingHelper.listCustomSettings() called');

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        for (String objName : globalDescribe.keySet()) {
            Schema.DescribeSObjectResult describe = globalDescribe.get(objName).getDescribe();
            
            // Check if it's a custom setting
            if (describe.isCustomSetting()) {
                String apiName = describe.getName();
                String label = describe.getLabel();
                
                // Determine type by reading from Metadata API
                String settingType = 'Hierarchy'; // Default
                try {
                    MetadataService.IReadResult readResult = port.readMetadata('CustomObject', new List<String>{ apiName });
                    if (readResult != null && readResult.getRecords() != null && !readResult.getRecords().isEmpty()) {
                        MetadataService.CustomObject obj = (MetadataService.CustomObject) readResult.getRecords()[0];
                        if (obj != null && String.isNotBlank(obj.customSettingsType)) {
                            settingType = obj.customSettingsType;
                        }
                    }
                } catch (Exception e) {
                    System.debug('Could not read setting type for ' + apiName + ': ' + e.getMessage());
                }
                
                result.add(new Map<String, Object>{
                    'apiName'     => apiName,
                    'label'       => label,
                    'description' => null, // Not easily available
                    'type'        => settingType
                });
            }
        }

        System.debug('CustomSettingHelper.listCustomSettings(): found ' + result.size());
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE SETTING
    // ─────────────────────────────────────────────────────────────
    public static void createCustomSetting(Map<String, Object> args) {
        String apiName     = getRequired(args, 'apiName');
        String label       = getRequired(args, 'label');
        String settingType = getOptional(args, 'type', 'Hierarchy');
        String description = getOptional(args, 'description', null);

        if (!apiName.endsWith('__c')) apiName += '__c';

        System.debug('CustomSettingHelper.createCustomSetting() called: apiName=' + apiName);

        String xml = buildSettingXml(apiName, label, settingType, description, new List<String>());
        String filePath = 'objects/' + apiName + '.object';
        ZipBuilder.addFile('CustomObject', apiName, filePath, xml);

        System.debug('CustomSettingHelper.createCustomSetting(): [' + apiName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // ADD FIELD
    // Reads existing fields from org, preserves them, adds new one
    // ─────────────────────────────────────────────────────────────
    public static void addFieldToCustomSetting(Map<String, Object> args) {
        String apiName    = getRequired(args, 'apiName');
        String fieldName  = getRequired(args, 'fieldName');
        String fieldType  = getRequired(args, 'fieldType');
        String fieldLabel = getRequired(args, 'fieldLabel');

        if (!apiName.endsWith('__c'))   apiName   += '__c';
        if (!fieldName.endsWith('__c')) fieldName += '__c';

        System.debug('CustomSettingHelper.addFieldToCustomSetting(): ' + apiName + '.' + fieldName);

        Map<String, Object> settingMeta         = readSettingMetadata(apiName);

        // Check ZipBuilder first — if Field 1 was already staged this session,
        // read from that instead of the org (org won't have it yet)
        String filePath  = 'objects/' + apiName + '.object';
        String stagedXml = ZipBuilder.files.get(filePath);

        List<String> existingFieldBlocks;
        if (String.isNotBlank(stagedXml)) {
            existingFieldBlocks = extractFieldBlocksFromXml(stagedXml);
        } else {
            existingFieldBlocks = readExistingFieldBlocks(apiName);
        }

        String newFieldBlock = buildFieldBlock(fieldName, fieldLabel, fieldType, args);
        existingFieldBlocks.add(newFieldBlock);

        String xml = buildSettingXml(
            apiName,
            (String) settingMeta.get('label'),
            (String) settingMeta.get('type'),
            (String) settingMeta.get('description'),
            existingFieldBlocks
        );

        ZipBuilder.addFile('CustomObject', apiName, filePath, xml);
        System.debug('CustomSettingHelper.addFieldToCustomSetting(): [' + apiName + '.' + fieldName + '] queued');
    }

    // ─────────────────────────────────────────────────────────────
    // UPDATE FIELD
    // Reads all existing fields, replaces the target field
    // ─────────────────────────────────────────────────────────────
    public static void updateCustomSettingField(Map<String, Object> args) {
        String apiName   = getRequired(args, 'apiName');
        String fieldName = getRequired(args, 'fieldName');

        if (!apiName.endsWith('__c'))   apiName   += '__c';
        if (!fieldName.endsWith('__c')) fieldName += '__c';

        System.debug('CustomSettingHelper.updateCustomSettingField(): ' + apiName + '.' + fieldName);

        Map<String, Object> settingMeta    = readSettingMetadata(apiName);
        Map<String, Object> existingField  = readSingleField(apiName, fieldName);
        List<String>        allFieldBlocks = readExistingFieldBlocks(apiName);

        String newLabel = getOptional(args, 'fieldLabel', (String) existingField.get('label'));
        String newType  = getOptional(args, 'fieldType',  (String) existingField.get('type'));

        Map<String, Object> mergedArgs = new Map<String, Object>(args);
        if (!mergedArgs.containsKey('fieldLabel')) mergedArgs.put('fieldLabel', newLabel);
        if (!mergedArgs.containsKey('fieldType'))  mergedArgs.put('fieldType',  newType);

        String updatedBlock = buildFieldBlock(fieldName, newLabel, newType, mergedArgs);

        List<String> updatedBlocks = new List<String>();
        for (String block : allFieldBlocks) {
            if (block.contains('<fullName>' + fieldName + '</fullName>')) {
                updatedBlocks.add(updatedBlock);
            } else {
                updatedBlocks.add(block);
            }
        }

        String xml = buildSettingXml(
            apiName,
            (String) settingMeta.get('label'),
            (String) settingMeta.get('type'),
            (String) settingMeta.get('description'),
            updatedBlocks
        );

        String filePath = 'objects/' + apiName + '.object';
        ZipBuilder.addFile('CustomObject', apiName, filePath, xml);
        System.debug('CustomSettingHelper.updateCustomSettingField(): [' + apiName + '.' + fieldName + '] queued');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE FIELD
    // ─────────────────────────────────────────────────────────────
    public static void deleteCustomSettingField(Map<String, Object> args) {
        String apiName   = getRequired(args, 'apiName');
        String fieldName = getRequired(args, 'fieldName');

        if (!apiName.endsWith('__c'))   apiName   += '__c';
        if (!fieldName.endsWith('__c')) fieldName += '__c';

        System.debug('CustomSettingHelper.deleteCustomSettingField(): ' + apiName + '.' + fieldName);

        String member = apiName + '.' + fieldName;
        addDestructiveXml('CustomField', member);
        System.debug('CustomSettingHelper.deleteCustomSettingField(): queued destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE SETTING
    // ─────────────────────────────────────────────────────────────
    public static void deleteCustomSetting(Map<String, Object> args) {
        String apiName = getRequired(args, 'apiName');
        if (!apiName.endsWith('__c')) apiName += '__c';

        System.debug('CustomSettingHelper.deleteCustomSetting(): ' + apiName);
        addDestructiveXml('CustomObject', apiName);
        System.debug('CustomSettingHelper.deleteCustomSetting(): queued destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Read setting metadata via Metadata API
    // Tooling API doesn't support querying custom settings properly
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> readSettingMetadata(String apiName) {
        System.debug('CustomSettingHelper.readSettingMetadata(): reading ' + apiName);
        
        MetadataService.IReadResult readResult = port.readMetadata('CustomObject', new List<String>{ apiName });
        
        if (readResult == null || readResult.getRecords() == null || readResult.getRecords().isEmpty()) {
            throw new CustomSettingException('Custom Setting not found: ' + apiName);
        }
        
        MetadataService.CustomObject obj = (MetadataService.CustomObject) readResult.getRecords()[0];
        
        if (obj == null) {
            throw new CustomSettingException('Custom Setting not found: ' + apiName);
        }
        
        String label       = String.isNotBlank(obj.label)              ? obj.label              : apiName.replace('__c', '');
        String settingType = String.isNotBlank(obj.customSettingsType) ? obj.customSettingsType : 'Hierarchy';
        String description = String.isNotBlank(obj.description)        ? obj.description        : null;
        
        return new Map<String, Object>{
            'label'       => label,
            'type'        => settingType,
            'description' => description
        };
    }

    private static List<String> extractFieldBlocksFromXml(String xml) {
        List<String> blocks = new List<String>();
        if (String.isBlank(xml)) return blocks;

        Integer searchFrom = 0;
        while (true) {
            Integer blockStart = xml.indexOf('<fields>', searchFrom);
            if (blockStart == -1) break;
            Integer blockEnd = xml.indexOf('</fields>', blockStart);
            if (blockEnd == -1) break;
            blockEnd += '</fields>'.length();
            blocks.add(xml.substring(blockStart, blockEnd));
            searchFrom = blockEnd;
        }
        return blocks;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Read all existing custom fields as XML blocks
    // ─────────────────────────────────────────────────────────────
    private static List<String> readExistingFieldBlocks(String apiName) {
        // Use the static initialized port (same pattern as ValidationRuleHelper)
        MetadataService.IReadResult readResult = port.readMetadata('CustomObject', new List<String>{ apiName });

        List<String> blocks = new List<String>();
        if (readResult == null) return blocks;

        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) return blocks;

        MetadataService.CustomObject obj = (MetadataService.CustomObject) records[0];
        if (obj.fields == null || obj.fields.isEmpty()) return blocks;

        for (MetadataService.CustomField f : obj.fields) {
            if (f == null || String.isBlank(f.fullName)) continue;
            blocks.add(buildFieldBlockFromMeta(f));
        }

        return blocks;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Read a single field's metadata
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> readSingleField(String apiName, String fieldName) {
        // Use the static initialized port
        MetadataService.IReadResult readResult = port.readMetadata('CustomObject', new List<String>{ apiName });

        if (readResult == null) {
            throw new CustomSettingException('Custom Setting not found: ' + apiName);
        }

        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new CustomSettingException('Custom Setting not found: ' + apiName);
        }

        MetadataService.CustomObject obj = (MetadataService.CustomObject) records[0];
        if (obj.fields != null) {
            for (MetadataService.CustomField f : obj.fields) {
                if (f != null && f.fullName == fieldName) {
                    return new Map<String, Object>{
                        'label' => f.label  != null ? f.label  : fieldName,
                        'type'  => f.type_x != null ? f.type_x : 'Text'
                    };
                }
            }
        }

        throw new CustomSettingException('Field not found: ' + apiName + '.' + fieldName);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build complete CustomObject XML for a Custom Setting
    //
    // ✅ REMOVED <customSettingsVisibility> — not valid in API v61.0
    // ─────────────────────────────────────────────────────────────
    private static String buildSettingXml(
        String apiName,
        String label,
        String settingType,
        String description,
        List<String> fieldBlocks
    ) {
        String safeType  = String.isNotBlank(settingType) ? settingType : 'Hierarchy';
        String safeLabel = String.isNotBlank(label)       ? label       : apiName.replace('__c', '').replace('_', ' ');

        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomObject xmlns="' + NAMESPACE + '">'
            + '<customSettingsType>' + safeType + '</customSettingsType>';

        if (String.isNotBlank(description)) {
            xml += '<description>' + escapeXml(description) + '</description>';
        }

        xml += '<enableFeeds>false</enableFeeds>'
            + '<label>' + escapeXml(safeLabel) + '</label>';

        for (String block : fieldBlocks) {
            xml += block;
        }

        xml += '</CustomObject>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build a <fields> XML block from args
    // Supported types: Checkbox, Currency, Date, DateTime, Email,
    //                  Number, Percent, Phone, Text, TextArea, Url
    // ─────────────────────────────────────────────────────────────
    private static String buildFieldBlock(
        String fieldName,
        String fieldLabel,
        String fieldType,
        Map<String, Object> args
    ) {
        String safeLabel = String.isNotBlank(fieldLabel) ? fieldLabel : fieldName.replace('__c', '').replace('_', ' ');
        String safeType  = String.isNotBlank(fieldType)  ? fieldType  : 'Text';

        String xml = '<fields>'
            + '<fullName>' + escapeXml(fieldName) + '</fullName>';

        if (safeType == 'Checkbox') {
            // Checkbox requires <defaultValue>, not <required>
            xml += '<defaultValue>' + getOptional(args, 'defaultValue', 'false') + '</defaultValue>';
        } else if (safeType == 'Text') {
            Integer len = Integer.valueOf(getOptional(args, 'length', '255'));
            xml += '<length>' + len + '</length>';
        } else if (safeType == 'Number' || safeType == 'Currency' || safeType == 'Percent') {
            Integer precision = Integer.valueOf(getOptional(args, 'precision', '18'));
            Integer scale     = Integer.valueOf(getOptional(args, 'scale', '0'));
            xml += '<precision>' + precision + '</precision>'
                +  '<scale>'     + scale     + '</scale>';
        }
        // Checkbox, Date, DateTime, Email, Phone, TextArea, Url — no extra attributes

        xml += '<label>' + escapeXml(safeLabel) + '</label>';

        // Checkbox fields cannot have <required> — Salesforce will reject the deploy
        if (safeType != 'Checkbox') {
            xml += '<required>' + getOptional(args, 'required', 'false') + '</required>';
        }

        xml += '<type>' + safeType + '</type>'
            + '</fields>';

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Rebuild field XML block from MetadataService object
    // ─────────────────────────────────────────────────────────────
    private static String buildFieldBlockFromMeta(MetadataService.CustomField f) {
        String xml = '<fields>'
            + '<fullName>' + escapeXml(f.fullName) + '</fullName>';

        if (f.length != null && f.length > 0) {
            xml += '<length>' + f.length + '</length>';
        }
        if (f.precision != null && f.precision > 0) {
            xml += '<precision>' + f.precision + '</precision>';
        }
        if (f.scale != null) {
            xml += '<scale>' + f.scale + '</scale>';
        }
        if (f.visibleLines != null && f.visibleLines > 0) {
            xml += '<visibleLines>' + f.visibleLines + '</visibleLines>';
        }

        String  safeLabel = String.isNotBlank(f.label)  ? f.label  : f.fullName;
        Boolean safeReqd  = (f.required != null)        ? f.required : false;
        String  safeType  = String.isNotBlank(f.type_x) ? f.type_x  : 'Text';

        xml += '<label>' + escapeXml(safeLabel) + '</label>';

        if (safeType == 'Checkbox') {
            String defaultVal = (f.defaultValue != null) ? String.valueOf(f.defaultValue) : 'false';
            xml += '<defaultValue>' + defaultVal + '</defaultValue>';
        } 
        else {
            xml += '<required>' + safeReqd + '</required>';
        }

        xml += '<type>' + safeType + '</type>'
            + '</fields>';

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Destructive XML
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String metaType, String member) {
        String existing = ZipBuilder.files.get('destructiveChangesPost.xml');
        String xml;

        String typeTag = '<name>' + metaType + '</name>';

        if (existing != null && existing.contains(typeTag)) {
            xml = existing.replace(typeTag, '<members>' + member + '</members>' + typeTag);
        } else if (existing != null) {
            xml = existing.replace('</Package>',
                '<types><members>' + member + '</members><name>' + metaType + '</name></types></Package>');
        } else {
            xml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="' + NAMESPACE + '">'
                + '<types>'
                + '<members>' + member + '</members>'
                + '<name>' + metaType + '</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', member, 'destructiveChangesPost.xml', xml);
    }


    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Helpers
    // ─────────────────────────────────────────────────────────────
    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new CustomSettingException('Required parameter missing: ' + key);
        }
        return String.valueOf(val).trim();
    }

    private static String getOptional(Map<String, Object> args, String key, String defaultValue) {
        Object val = args?.get(key);
        if (val == null) return defaultValue;
        String strVal = String.valueOf(val).trim();
        if (String.isBlank(strVal) || strVal == 'null') return defaultValue;
        return strVal;
    }

    public class CustomSettingException extends Exception {}
}