/**
 * CustomMetadataHelper.cls
 *
 * Handles Custom Metadata Type and Record operations via ZIP deploy.
 *
 * MDAPI facts:
 * - Type definition:  objects/{ApiName}__mdt.object          (type: CustomObject)
 * - Field on type:    objects/{ApiName}__mdt.object           (embedded <fields> blocks)
 * - Record:           customMetadata/{ApiName}__mdt.{RecordName}.md  (type: CustomMetadata)
 *
 * xsi:type mappings for record values:
 *   Text/TextArea/LongTextArea/Email/Phone/URL/Picklist → xsd:string
 *   Number/Percent/Currency                             → xsd:double
 *   Checkbox                                            → xsd:boolean
 *   Date                                                → xsd:date
 *   DateTime                                            → xsd:dateTime
 */
public class CustomMetadataHelper {

    private static final String NAMESPACE     = 'http://soap.sforce.com/2006/04/metadata';
    private static final String NAMESPACE_XSI = 'http://www.w3.org/2001/XMLSchema-instance';
    private static final String NAMESPACE_XSD = 'http://www.w3.org/2001/XMLSchema';


    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Metadata port
    // ─────────────────────────────────────────────────────────────
    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('CustomMetadataHelper: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('CustomMetadataHelper: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // LIST TYPES
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listCustomMetadataTypes(Map<String, Object> args) {
        System.debug('CustomMetadataHelper.listCustomMetadataTypes() called');

        String query = 'SELECT QualifiedApiName, Label, PluralLabel, Description '
            + 'FROM EntityDefinition WHERE IsCustomizable = true '
            + 'AND QualifiedApiName LIKE \'%__mdt\' ORDER BY QualifiedApiName';

        String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CustomMetadataException('Failed to list Custom Metadata Types. Status: '
                + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                result.add(new Map<String, Object>{
                    'apiName'     => r.get('QualifiedApiName'),
                    'label'       => r.get('Label'),
                    'pluralLabel' => r.get('PluralLabel'),
                    'description' => r.get('Description')
                });
            }
        }

        System.debug('CustomMetadataHelper.listCustomMetadataTypes(): found ' + result.size());
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE TYPE
    // ─────────────────────────────────────────────────────────────
    public static void createCustomMetadataType(Map<String, Object> args) {
        String apiName     = getRequired(args, 'apiName');
        String label       = getRequired(args, 'label');
        String pluralLabel = getRequired(args, 'pluralLabel');
        String description = getOptional(args, 'description', '');
        String visibility  = getOptional(args, 'visibility', 'Public');

        // Ensure __mdt suffix
        String fullApiName = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';

        System.debug('CustomMetadataHelper.createCustomMetadataType(): ' + fullApiName);

        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomObject xmlns="' + NAMESPACE + '">'
            + '<label>'       + escapeXml(label)       + '</label>'
            + '<pluralLabel>' + escapeXml(pluralLabel) + '</pluralLabel>'
            + (String.isNotBlank(description) ? '<description>' + escapeXml(description) + '</description>' : '')
            + '<visibility>'  + escapeXml(visibility)  + '</visibility>'
            + '</CustomObject>';

        String filePath = 'objects/' + fullApiName + '.object';
        ZipBuilder.addFile('CustomObject', fullApiName, filePath, xml);

        System.debug('CustomMetadataHelper: type [' + fullApiName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // ADD FIELD TO TYPE
    // Same ZipBuilder-first pattern as CustomSettingHelper
    // ─────────────────────────────────────────────────────────────
    public static void addFieldToCustomMetadataType(Map<String, Object> args) {
        String apiName    = getRequired(args, 'apiName');
        String fieldName  = getRequired(args, 'fieldName');
        String fieldLabel = getRequired(args, 'fieldLabel');
        String fieldType  = getRequired(args, 'fieldType');

        // Ensure __mdt suffix
        String fullApiName = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';
        String fullField   = fieldName.endsWith('__c') ? fieldName : fieldName + '__c';

        System.debug('CustomMetadataHelper.addFieldToCustomMetadataType(): ' + fullApiName + '.' + fullField);

        String filePath  = 'objects/' + fullApiName + '.object';
        String stagedXml = ZipBuilder.files.get(filePath);

        List<String> existingFieldBlocks;
        if (String.isNotBlank(stagedXml)) {
            existingFieldBlocks = extractFieldBlocksFromXml(stagedXml);
        } else {
            existingFieldBlocks = readExistingFieldBlocks(fullApiName);
        }

        // Build new field block
        String newFieldBlock = buildFieldBlock(fullField, fieldLabel, fieldType, args);

        // Rebuild object XML with all fields
        String objectXml;
        if (String.isNotBlank(stagedXml)) {
            // Inject new field before closing tag
            objectXml = stagedXml.replace('</CustomObject>', newFieldBlock + '</CustomObject>');
        } else {
            // Read existing object metadata
            String existingObjectXml = readExistingObjectXml(fullApiName);
            if (String.isNotBlank(existingObjectXml)) {
                objectXml = existingObjectXml.replace('</CustomObject>', newFieldBlock + '</CustomObject>');
            } else {
                // Type doesn't exist yet or can't be read — build minimal wrapper
                objectXml = '<?xml version="1.0" encoding="UTF-8"?>'
                    + '<CustomObject xmlns="' + NAMESPACE + '">'
                    + newFieldBlock
                    + '</CustomObject>';
            }
        }

        ZipBuilder.addFile('CustomObject', fullApiName, filePath, objectXml);
        System.debug('CustomMetadataHelper: field [' + fullField + '] staged on [' + fullApiName + ']');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE TYPE
    // ─────────────────────────────────────────────────────────────
    public static void deleteCustomMetadataType(Map<String, Object> args) {
        String apiName = getRequired(args, 'apiName');
        String fullApiName = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';

        System.debug('CustomMetadataHelper.deleteCustomMetadataType(): ' + fullApiName);

        addDestructiveXml('CustomObject', fullApiName);
        System.debug('CustomMetadataHelper: type [' + fullApiName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // LIST RECORDS
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listCustomMetadataRecords(Map<String, Object> args) {
        String apiName     = getRequired(args, 'apiName');
        String fullApiName = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';

        System.debug('CustomMetadataHelper.listCustomMetadataRecords(): ' + fullApiName);

        // Get field names first
        List<String> fieldNames = getCustomFieldNames(fullApiName);

        // Build dynamic SOQL
        String fieldList = 'Id, DeveloperName, Label';
        if (!fieldNames.isEmpty()) {
            fieldList += ', ' + String.join(fieldNames, ', ');
        }

        String query = 'SELECT ' + fieldList + ' FROM ' + fullApiName + ' ORDER BY DeveloperName';
        String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new CustomMetadataException('Failed to list records for ' + fullApiName
                + '. Status: ' + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                Map<String, Object> row = new Map<String, Object>{
                    'developerName' => r.get('DeveloperName'),
                    'label'         => r.get('Label')
                };
                // Include field values
                for (String f : fieldNames) {
                    row.put(f, r.get(f));
                }
                result.add(row);
            }
        }

        System.debug('CustomMetadataHelper.listCustomMetadataRecords(): found ' + result.size());
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // UPSERT RECORD (create or update)
    // ─────────────────────────────────────────────────────────────
    public static void upsertCustomMetadataRecord(Map<String, Object> args) {
        String apiName      = getRequired(args, 'apiName');
        String recordName   = getRequired(args, 'recordName');
        String label        = getOptional(args, 'label', recordName);
        String isProtected  = getOptional(args, 'protected', 'false');

        String fullApiName  = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';
        String cleanRecord  = recordName.replaceAll('[^a-zA-Z0-9_]', '_');

        System.debug('CustomMetadataHelper.upsertCustomMetadataRecord(): ' + fullApiName + '.' + cleanRecord);

        // fieldValues is a JSON string like {"Field1__c": "value1", "Field2__c": 42}
        String fieldValuesJson = getOptional(args, 'fieldValues', '{}');
        Map<String, Object> fieldValues = new Map<String, Object>();
        if (String.isNotBlank(fieldValuesJson) && fieldValuesJson != '{}') {
            fieldValues = (Map<String, Object>) JSON.deserializeUntyped(fieldValuesJson);
        }

        // Get field type info to determine xsi:type
        Map<String, String> fieldTypes = getFieldTypeMap(fullApiName);

        // Build XML
        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomMetadata xmlns="'     + NAMESPACE     + '"'
            + ' xmlns:xsi="'               + NAMESPACE_XSI + '"'
            + ' xmlns:xsd="'               + NAMESPACE_XSD + '">'
            + '<label>'                    + escapeXml(label)       + '</label>'
            + '<protected>'                + isProtected            + '</protected>';

        for (String fieldApiName : fieldValues.keySet()) {
            Object val = fieldValues.get(fieldApiName);
            String xsiType = getXsiType(fieldApiName, fieldTypes);
            String strVal  = val != null ? String.valueOf(val) : '';

            xml += '<values>'
                + '<field>'  + escapeXml(fieldApiName) + '</field>'
                + '<value xsi:type="' + xsiType + '">' + escapeXml(strVal) + '</value>'
                + '</values>';
        }

        xml += '</CustomMetadata>';

        String filePath = 'customMetadata/' + fullApiName + '.' + cleanRecord + '.md';
        ZipBuilder.addFile('CustomMetadata', fullApiName + '.' + cleanRecord, filePath, xml);

        System.debug('CustomMetadataHelper: record [' + cleanRecord + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE RECORD
    // ─────────────────────────────────────────────────────────────
    public static void deleteCustomMetadataRecord(Map<String, Object> args) {
        String apiName    = getRequired(args, 'apiName');
        String recordName = getRequired(args, 'recordName');

        String fullApiName = apiName.endsWith('__mdt') ? apiName : apiName + '__mdt';
        String member      = fullApiName + '.' + recordName;

        System.debug('CustomMetadataHelper.deleteCustomMetadataRecord(): ' + member);

        addDestructiveXml('CustomMetadata', member);
        System.debug('CustomMetadataHelper: record [' + member + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build field XML block
    // ─────────────────────────────────────────────────────────────
    private static String buildFieldBlock(String fieldName, String fieldLabel,
        String fieldType, Map<String, Object> args) {

        String safeType = fieldType.capitalize();
        String xml = '<fields>'
            + '<fullName>'  + escapeXml(fieldName)  + '</fullName>'
            + '<label>'     + escapeXml(fieldLabel)  + '</label>'
            + '<type>'      + escapeXml(safeType)    + '</type>';

        if (safeType == 'Checkbox') {
            xml += '<defaultValue>' + getOptional(args, 'defaultValue', 'false') + '</defaultValue>';
        } else if (safeType == 'Text' || safeType == 'Textarea') {
            Integer len = Integer.valueOf(getOptional(args, 'length', '255'));
            xml += '<length>' + len + '</length>';
        } else if (safeType == 'Longtextarea') {
            Integer len = Integer.valueOf(getOptional(args, 'length', '32768'));
            xml += '<length>'      + len + '</length>'
                + '<visibleLines>3</visibleLines>';
        } else if (safeType == 'Number' || safeType == 'Percent') {
            Integer precision = Integer.valueOf(getOptional(args, 'precision', '18'));
            Integer scale     = Integer.valueOf(getOptional(args, 'scale', '0'));
            xml += '<precision>' + precision + '</precision>'
                + '<scale>'     + scale     + '</scale>';
        } else if (safeType == 'Picklist') {
            String picklistValues = getOptional(args, 'picklistValues', '');
            if (String.isNotBlank(picklistValues)) {
                xml += '<valueSet><valueSetDefinition>';
                for (String pv : picklistValues.split(',')) {
                    String trimmed = pv.trim();
                    xml += '<value>'
                        + '<fullName>' + escapeXml(trimmed) + '</fullName>'
                        + '<default>false</default>'
                        + '<label>'    + escapeXml(trimmed) + '</label>'
                        + '</value>';
                }
                xml += '</valueSetDefinition></valueSet>';
            }
        }

        String required = getOptional(args, 'required', 'false');
        if (safeType != 'Checkbox') {
            xml += '<required>' + required + '</required>';
        }

        xml += '</fields>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get xsi:type for a field
    // ─────────────────────────────────────────────────────────────
    private static String getXsiType(String fieldApiName, Map<String, String> fieldTypes) {
        String fieldType = fieldTypes.get(fieldApiName);
        if (fieldType == null) return 'xsd:string';

        String ft = fieldType.toLowerCase();

        if (ft == 'checkbox')                return 'xsd:boolean';
        if (ft.startsWith('number')
            || ft.startsWith('currency')
            || ft.startsWith('percent'))     return 'xsd:double';
        if (ft == 'date')                    return 'xsd:date';
        if (ft == 'date/time'
            || ft == 'datetime')             return 'xsd:dateTime';
        return 'xsd:string';
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get field type map from org via Tooling API
    // ─────────────────────────────────────────────────────────────
    private static Map<String, String> getFieldTypeMap(String fullApiName) {
        Map<String, String> result = new Map<String, String>();
        try {
            String query = 'SELECT QualifiedApiName, DataType FROM FieldDefinition '
                + 'WHERE EntityDefinition.QualifiedApiName = \'' + fullApiName + '\'';
            String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
                + '/services/data/v61.0/tooling/query?q='
                + EncodingUtil.urlEncode(query, 'UTF-8');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setTimeout(30000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> records = (List<Object>) resp.get('records');
                if (records != null) {
                    for (Object rec : records) {
                        Map<String, Object> r = (Map<String, Object>) rec;
                        result.put((String) r.get('QualifiedApiName'), (String) r.get('DataType'));
                    }
                }
            }
        } catch (Exception e) {
            System.debug('CustomMetadataHelper.getFieldTypeMap() failed: ' + e.getMessage());
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get custom field names for dynamic SOQL
    // ─────────────────────────────────────────────────────────────
    private static List<String> getCustomFieldNames(String fullApiName) {
        List<String> result = new List<String>();
        try {
            Map<String, String> typeMap = getFieldTypeMap(fullApiName);
            result.addAll(typeMap.keySet());
        } catch (Exception e) {
            System.debug('CustomMetadataHelper.getCustomFieldNames() failed: ' + e.getMessage());
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Read existing field blocks from staged XML
    // ─────────────────────────────────────────────────────────────
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
    // PRIVATE — Read existing field blocks from org
    // ─────────────────────────────────────────────────────────────
    private static List<String> readExistingFieldBlocks(String fullApiName) {
        List<String> blocks = new List<String>();
        String xml = readExistingObjectXml(fullApiName);
        if (String.isNotBlank(xml)) {
            blocks = extractFieldBlocksFromXml(xml);
        }
        return blocks;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Read existing object XML from org via Metadata API
    // ─────────────────────────────────────────────────────────────
    private static String readExistingObjectXml(String fullApiName) {
        try {
            MetadataService.IReadResult readResult = port.readMetadata('CustomObject',
                new List<String>{ fullApiName });

            if (readResult == null || readResult.getRecords() == null 
                || readResult.getRecords().isEmpty() || readResult.getRecords()[0] == null) {
                return '';
            }

            MetadataService.CustomObject obj = 
                (MetadataService.CustomObject) readResult.getRecords()[0];

            String label       = String.isNotBlank(obj.label)       ? obj.label       : fullApiName.replace('__mdt', '');
            String pluralLabel = String.isNotBlank(obj.pluralLabel) ? obj.pluralLabel : label + 's';
            String description = String.isNotBlank(obj.description) ? obj.description : null;

            return '<?xml version="1.0" encoding="UTF-8"?>'
                + '<CustomObject xmlns="' + NAMESPACE + '">'
                + '<label>'       + escapeXml(label)       + '</label>'
                + '<pluralLabel>' + escapeXml(pluralLabel) + '</pluralLabel>'
                + (String.isNotBlank(description)
                    ? '<description>' + escapeXml(description) + '</description>' : '')
                + '</CustomObject>';

        } catch (Exception e) {
            System.debug('CustomMetadataHelper.readExistingObjectXml() failed: ' + e.getMessage());
        }
        return '';
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Destructive XML helper
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String metaType, String member) {
        String nameTag  = '<' + 'name>' + metaType + '</' + 'name>';
        String existing = ZipBuilder.files.get('destructiveChangesPost.xml');
        String xml;

        if (existing != null && existing.contains(nameTag)) {
            xml = existing.replace(nameTag, '<members>' + member + '</members>' + nameTag);
        } else if (existing != null) {
            xml = existing.replace('</Package>',
                '<types><members>' + member + '</members>' + nameTag + '</types></Package>');
        } else {
            xml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="' + NAMESPACE + '">'
                + '<types>'
                + '<members>' + member + '</members>'
                + nameTag
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
            throw new CustomMetadataException('Required parameter missing: ' + key);
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

    public class CustomMetadataException extends Exception {}
}