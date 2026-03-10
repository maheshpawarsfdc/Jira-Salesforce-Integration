/**
 * ValidationRuleHelper.cls
 *
 * Handles Salesforce Validation Rule operations via ZIP deploy.
 * All operations go through ZipBuilder — no direct SOAP/DML.
 *
 * Validation Rule fullName format: ObjectName.RuleName
 * e.g. Car__c.PriceMustBePositive
 *
 * File path in ZIP: objects/Car__c.object (embedded in CustomObject XML)
 * Package.xml type: CustomObject, member: Car__c
 */
public class ValidationRuleHelper {

    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('ValidationRuleHelper: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('ValidationRuleHelper: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // LIST VALIDATION RULES
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listValidationRules(Map<String, Object> args) {
        String objectName = addSuffix(getRequired(args, 'objectName'));
        System.debug('ValidationRuleHelper.listValidationRules() called for [' + objectName + ']');

        String query = 'SELECT Id, ValidationName, Active, Description, ErrorMessage, ErrorDisplayField '
            + 'FROM ValidationRule '
            + 'WHERE EntityDefinition.QualifiedApiName = \'' + objectName + '\' '
            + 'ORDER BY ValidationName';

        String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/tooling/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new ValidationRuleException(
                'Failed to list validation rules. Status: ' + res.getStatusCode() + ' Body: ' + res.getBody()
            );
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            result.add(new Map<String, Object>{
                'name'              => r.get('ValidationName'),
                'active'            => r.get('Active'),
                'description'       => r.get('Description'),
                'errorMessage'      => r.get('ErrorMessage'),
                'errorDisplayField' => r.get('ErrorDisplayField')
            });
        }

        System.debug('ValidationRuleHelper.listValidationRules(): found ' + result.size() + ' rules');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE VALIDATION RULE
    // ─────────────────────────────────────────────────────────────
    public static void createValidationRule(Map<String, Object> args) {
        String objectName   = addSuffix(getRequired(args, 'objectName'));
        String ruleName     = getRequired(args, 'ruleName');
        String formula      = getRequired(args, 'errorConditionFormula');
        String errorMsg     = getRequired(args, 'errorMessage');
        String description  = getOptional(args, 'description', null);
        String displayField = getOptional(args, 'errorDisplayField', null);
        Boolean active      = Boolean.valueOf(getOptional(args, 'active', 'true'));

        System.debug('ValidationRuleHelper.createValidationRule() called');
        System.debug('object=' + objectName + ', rule=' + ruleName);

        String ruleBlock = buildValidationRuleBlock(ruleName, active, formula, errorMsg, description, displayField);
        String objectXml = buildObjectWrapperWithRule(objectName, ruleBlock, ruleName);
        String filePath  = 'objects/' + objectName + '.object';

        ZipBuilder.addFile('CustomObject', objectName, filePath, objectXml);
        System.debug('ValidationRuleHelper.createValidationRule(): [' + objectName + '.' + ruleName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // UPDATE VALIDATION RULE
    // ─────────────────────────────────────────────────────────────
    public static void updateValidationRule(Map<String, Object> args) {
        String objectName = addSuffix(getRequired(args, 'objectName'));
        String ruleName   = getRequired(args, 'ruleName');
        String fullName   = objectName + '.' + ruleName;

        System.debug('ValidationRuleHelper.updateValidationRule() called for [' + fullName + ']');

        MetadataService.IReadResult readResult = port.readMetadata(
            'ValidationRule', new List<String>{ fullName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new ValidationRuleException('Validation Rule not found: ' + fullName);
        }
        MetadataService.ValidationRule existing = (MetadataService.ValidationRule) records[0];

        // Null-safe reads from existing rule
        Boolean existingActive  = (existing.active != null) ? existing.active : false;
        String existingFormula  = String.isNotBlank(existing.errorConditionFormula) ? existing.errorConditionFormula : 'true';
        String existingMsg      = String.isNotBlank(existing.errorMessage)          ? existing.errorMessage          : 'Error';
        String existingDesc     = String.isNotBlank(existing.description)           ? existing.description           : null;
        String existingField    = String.isNotBlank(existing.errorDisplayField)     ? existing.errorDisplayField     : null;

        String formula      = getOptional(args, 'errorConditionFormula', existingFormula);
        String errorMsg     = getOptional(args, 'errorMessage',          existingMsg);
        String description  = getOptional(args, 'description',           existingDesc);
        String displayField = getOptional(args, 'errorDisplayField',     existingField);
        Boolean active      = existingActive;

        String ruleBlock = buildValidationRuleBlock(ruleName, active, formula, errorMsg, description, displayField);
        String objectXml = buildObjectWrapperWithRule(objectName, ruleBlock, ruleName);
        String filePath  = 'objects/' + objectName + '.object';

        ZipBuilder.addFile('CustomObject', objectName, filePath, objectXml);
        System.debug('ValidationRuleHelper.updateValidationRule(): [' + fullName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // ACTIVATE / DEACTIVATE VALIDATION RULE
    // ─────────────────────────────────────────────────────────────
    public static void setValidationRuleActive(Map<String, Object> args) {
        String objectName = addSuffix(getRequired(args, 'objectName'));
        String ruleName   = getRequired(args, 'ruleName');
        Boolean active    = Boolean.valueOf(getRequired(args, 'active'));
        String fullName   = objectName + '.' + ruleName;

        System.debug('ValidationRuleHelper.setValidationRuleActive() called for [' + fullName + '], active=' + active);

        MetadataService.IReadResult readResult = port.readMetadata(
            'ValidationRule', new List<String>{ fullName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new ValidationRuleException('Validation Rule not found: ' + fullName);
        }
        MetadataService.ValidationRule existing = (MetadataService.ValidationRule) records[0];

        // Null-safe reads from existing rule
        String existingFormula = String.isNotBlank(existing.errorConditionFormula) ? existing.errorConditionFormula : 'true';
        String existingMsg     = String.isNotBlank(existing.errorMessage)          ? existing.errorMessage          : 'Error';
        String existingDesc    = String.isNotBlank(existing.description)           ? existing.description           : null;
        String existingField   = String.isNotBlank(existing.errorDisplayField)     ? existing.errorDisplayField     : null;

        String ruleBlock = buildValidationRuleBlock(ruleName, active, existingFormula, existingMsg, existingDesc, existingField);
        String objectXml = buildObjectWrapperWithRule(objectName, ruleBlock, ruleName);
        String filePath  = 'objects/' + objectName + '.object';

        ZipBuilder.addFile('CustomObject', objectName, filePath, objectXml);
        System.debug('ValidationRuleHelper.setValidationRuleActive(): [' + fullName + '] active=' + active + ' queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE VALIDATION RULE
    // ─────────────────────────────────────────────────────────────
    public static void deleteValidationRule(Map<String, Object> args) {
        String objectName = addSuffix(getRequired(args, 'objectName'));
        String ruleName   = getRequired(args, 'ruleName');
        String fullName   = objectName + '.' + ruleName;

        System.debug('ValidationRuleHelper.deleteValidationRule() called for [' + fullName + ']');

        addDestructiveXml(fullName);
        System.debug('ValidationRuleHelper.deleteValidationRule(): [' + fullName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build <validationRules> XML block
    // ─────────────────────────────────────────────────────────────
    private static String buildValidationRuleBlock(
        String ruleName,
        Boolean active,
        String formula,
        String errorMessage,
        String description,
        String errorDisplayField
    ) {
        // Final null safety before writing XML
        Boolean safeActive = (active != null) ? active : false;

        String xml = '<validationRules>'
            + '<fullName>' + escapeXml(ruleName) + '</fullName>'
            + '<active>'   + safeActive          + '</active>';

        if (String.isNotBlank(description)) {
            xml += '<description>' + escapeXml(description) + '</description>';
        }

        xml += '<errorConditionFormula>' + escapeXml(formula) + '</errorConditionFormula>';

        if (String.isNotBlank(errorDisplayField)) {
            xml += '<errorDisplayField>' + escapeXml(errorDisplayField) + '</errorDisplayField>';
        }

        xml += '<errorMessage>' + escapeXml(errorMessage) + '</errorMessage>'
            + '</validationRules>';

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Wrap rule in full CustomObject XML
    // Reads ALL existing rules from org and preserves them
    // ─────────────────────────────────────────────────────────────
    private static String buildObjectWrapperWithRule(String objectName, String newRuleBlock, String newRuleName) {
        System.debug('ValidationRuleHelper: reading object metadata for [' + objectName + ']');

        MetadataService.IReadResult readResult = port.readMetadata(
            'CustomObject', new List<String>{ objectName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();

        String objLabel           = objectName.replace('__c', '');
        String objPluralLabel     = objLabel + 's';
        String sharingModel       = 'ReadWrite';
        String nameFieldLabel     = 'Name';
        String nameFieldType      = 'Text';
        String existingRuleBlocks = '';

        if (records != null && !records.isEmpty() && records[0] != null) {
            MetadataService.CustomObject obj = (MetadataService.CustomObject) records[0];
            if (String.isNotBlank(obj.label))        objLabel       = obj.label;
            if (String.isNotBlank(obj.pluralLabel))  objPluralLabel = obj.pluralLabel;
            if (String.isNotBlank(obj.sharingModel)) sharingModel   = obj.sharingModel;
            if (obj.nameField != null) {
                if (String.isNotBlank(obj.nameField.label))  nameFieldLabel = obj.nameField.label;
                if (String.isNotBlank(obj.nameField.type_x)) nameFieldType  = obj.nameField.type_x;
            }

            // Preserve all existing rules EXCEPT the one being added/updated
            if (obj.validationRules != null) {
                for (MetadataService.ValidationRule vr : obj.validationRules) {
                    if (vr.fullName == newRuleName) continue;
                    // Null-safe all fields
                    Boolean vrActive       = (vr.active != null)                          ? vr.active                      : false;
                    String  vrFormula      = String.isNotBlank(vr.errorConditionFormula)  ? vr.errorConditionFormula        : 'true';
                    String  vrMessage      = String.isNotBlank(vr.errorMessage)           ? vr.errorMessage                 : 'Error';
                    String  vrDescription  = String.isNotBlank(vr.description)            ? vr.description                  : null;
                    String  vrDisplayField = String.isNotBlank(vr.errorDisplayField)      ? vr.errorDisplayField            : null;
                    existingRuleBlocks += buildValidationRuleBlock(
                        vr.fullName, vrActive, vrFormula, vrMessage, vrDescription, vrDisplayField
                    );
                    System.debug('ValidationRuleHelper: preserving existing rule [' + vr.fullName + ']');
                }
            }
        }

        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<label>'       + escapeXml(objLabel)       + '</label>'
            + '<pluralLabel>' + escapeXml(objPluralLabel) + '</pluralLabel>'
            + '<nameField>'
            +     '<label>' + escapeXml(nameFieldLabel) + '</label>'
            +     '<type>'  + nameFieldType             + '</type>'
            + '</nameField>'
            + '<deploymentStatus>Deployed</deploymentStatus>'
            + '<sharingModel>' + sharingModel + '</sharingModel>'
            + existingRuleBlocks
            + newRuleBlock
            + '</CustomObject>';
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Destructive XML for delete
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String fullName) {
        String existingDestructive = ZipBuilder.files.get('destructiveChangesPost.xml');
        String destructiveXml;

        if (existingDestructive != null && existingDestructive.contains('<name>ValidationRule</name>')) {
            destructiveXml = existingDestructive.replace(
                '<name>ValidationRule</name>',
                '<members>' + fullName + '</members><name>ValidationRule</name>'
            );
        } else if (existingDestructive != null) {
            destructiveXml = existingDestructive.replace(
                '</Package>',
                '<types><members>' + fullName + '</members><name>ValidationRule</name></types></Package>'
            );
        } else {
            destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                + '<types>'
                + '<members>' + fullName + '</members>'
                + '<name>ValidationRule</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', fullName, 'destructiveChangesPost.xml', destructiveXml);
        System.debug('ValidationRuleHelper.addDestructiveXml(): [' + fullName + '] added to destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Helpers
    // ─────────────────────────────────────────────────────────────
    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&',  '&amp;')
                  .replace('<',  '&lt;')
                  .replace('>',  '&gt;')
                  .replace('"',  '&quot;')
                  .replace('\'', '&apos;');
    }

    private static String addSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new ValidationRuleException('Required parameter missing: ' + key);
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

    public class ValidationRuleException extends Exception {}
}