/**
 * TranslationHelper.cls
 *
 * Handles Translation operations via ZIP deploy.
 *
 * MDAPI facts:
 * - Translations file:          translations/{lang}.translation       (type: Translations)
 * - Object translations file:   objectTranslations/{Object}-{lang}.objectTranslation (type: CustomObjectTranslation)
 *
 * KEY ARCHITECTURE:
 * - Custom Labels, (future: app/tab)  → Translations type, file: translations/{lang}.translation
 * - Field labels, Picklist values, Validation Rule messages, Object labels
 *   → CustomObjectTranslation type, file: objectTranslations/{Object}-{lang}.objectTranslation
 *
 * MetadataService field name mapping (from MetadataService.cls):
 *   CustomLabelTranslation:    .name (label API name),  .label (translated text)
 *   CustomFieldTranslation:    .name (field API name),  .label (translated label), .picklistValues[]
 *   PicklistValueTranslation:  .masterLabel,            .translation
 *   ValidationRuleTranslation: .name (rule API name),   .errorMessage
 *   CustomObjectTranslation:   .fullName = "ObjectName-lang", .nameFieldLabel, .fields[], .validationRules[]
 */
public class TranslationHelper {

    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    private static MetadataPort getPort() {
        MetadataPort port = new MetadataPort();
        port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/Soap/m/61.0';
        port.SessionHeader = new MetadataService.SessionHeader_element();
        port.SessionHeader.sessionId = UserInfo.getSessionId();
        return port;
    }


    // ─────────────────────────────────────────────────────────────
    // LIST SUPPORTED LANGUAGES
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listSupportedLanguages(Map<String, Object> args) {
        System.debug('TranslationHelper.listSupportedLanguages() called');

        // Use SOQL on Organization supported language picklist
        String query = 'SELECT IsoCode, IsActive, IsDefault FROM LanguageLocaleKey WHERE IsActive = true ORDER BY IsoCode';
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

        if (res.getStatusCode() == 200) {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> records = (List<Object>) response.get('records');
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            if (records != null) {
                for (Object rec : records) {
                    Map<String, Object> r = (Map<String, Object>) rec;
                    result.add(new Map<String, Object>{
                        'isoCode'   => r.get('IsoCode'),
                        'isDefault' => r.get('IsDefault')
                    });
                }
            }
            if (!result.isEmpty()) {
                System.debug('TranslationHelper.listSupportedLanguages(): found ' + result.size());
                return result;
            }
        }

        // Fallback: return org default language
        System.debug('TranslationHelper: SOQL fallback, returning org default language');
        return new List<Map<String, Object>>{
            new Map<String, Object>{ 'isoCode' => UserInfo.getLanguage(), 'isDefault' => true }
        };
    }

    // ─────────────────────────────────────────────────────────────
    // UPSERT TRANSLATION
    // Routes to the correct file type based on translationType
    // ─────────────────────────────────────────────────────────────
    public static void upsertTranslation(Map<String, Object> args) {
        String language        = getRequired(args, 'language');
        String translationType = getRequired(args, 'translationType');

        System.debug('TranslationHelper.upsertTranslation(): language=' + language + ' type=' + translationType);

        if (translationType == 'label') {
            upsertLabelTranslation(language, args);
        } else if (translationType == 'field' || translationType == 'picklist'
                || translationType == 'validationRule' || translationType == 'object') {
            upsertObjectTranslation(language, translationType, args);
        } else {
            throw new TranslationException('Unknown translationType: ' + translationType
                + '. Must be: field, picklist, label, validationRule, object');
        }
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE TRANSLATION (entire language file)
    // ─────────────────────────────────────────────────────────────
    public static void deleteTranslation(Map<String, Object> args) {
        String language  = getRequired(args, 'language');
        String labelName = getRequired(args, 'labelName');

        System.debug('TranslationHelper.deleteTranslation(): ' + labelName + ' / ' + language);

        // Step 1 — Find the translation record ID
        String query = 'SELECT Id FROM ExternalStringLocalization '
        + 'WHERE ExternalString.Name = \'' + labelName + '\' '
        + 'AND Language = \'' + language + '\'';

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
            throw new TranslationException('Failed to query translation. Status: '
                + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        if (records == null || records.isEmpty()) {
            throw new TranslationException('No ' + language + ' translation found for label: ' + labelName);
        }

        // Step 2 — DELETE each record found
        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            String recordId = (String) r.get('Id');

            HttpRequest delReq = new HttpRequest();
            delReq.setEndpoint('https://' + DomainCreator.getOrgMyDomainHostname()
                + '/services/data/v61.0/tooling/sobjects/ExternalStringLocalization/' + recordId);
            delReq.setMethod('DELETE');
            delReq.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            delReq.setTimeout(30000);

            HttpResponse delRes = new Http().send(delReq);
            if (delRes.getStatusCode() != 204) {
                throw new TranslationException('Failed to delete translation ID ' + recordId
                    + '. Status: ' + delRes.getStatusCode() + ' Body: ' + delRes.getBody());
            }

            System.debug('TranslationHelper.deleteTranslation(): deleted ID ' + recordId);
        }

        System.debug('TranslationHelper.deleteTranslation(): [' + labelName + '/' + language + '] deleted successfully');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Custom Label translation → translations/{lang}.translation
    // ─────────────────────────────────────────────────────────────
    private static void upsertLabelTranslation(String language, Map<String, Object> args) {
        String labelName   = getRequired(args, 'labelName');
        String translation = getRequired(args, 'translation');

        // Read existing Translations file
        MetadataPort port = getPort();
        MetadataService.IReadResult readResult = port.readMetadata('Translations', new List<String>{ language });

        // Build in-memory map of existing label translations
        Map<String, String> labelMap = new Map<String, String>();

        if (readResult != null) {
            MetadataService.Metadata[] records = readResult.getRecords();
            if (records != null && !records.isEmpty() && records[0] != null) {
                MetadataService.Translations trans = (MetadataService.Translations) records[0];
                if (trans.customLabels != null) {
                    for (MetadataService.CustomLabelTranslation clt : trans.customLabels) {
                        if (clt != null && String.isNotBlank(clt.name)) {
                            labelMap.put(clt.name, clt.label != null ? clt.label : '');
                        }
                    }
                }
            }
        }

        // Upsert
        labelMap.put(labelName, translation);

        // Build XML
        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<Translations xmlns="' + NAMESPACE + '">';

        for (String lName : labelMap.keySet()) {
            xml += '<customLabels>'
                + '<label>' + escapeXml(labelMap.get(lName)) + '</label>'
                + '<name>'  + escapeXml(lName)               + '</name>'
                + '</customLabels>';
        }

        xml += '</Translations>';

        String filePath = 'translations/' + language + '.translation';
        ZipBuilder.addFile('Translations', language, filePath, xml);
        System.debug('TranslationHelper: label translation [' + labelName + '] queued for ' + language);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Object translation → objectTranslations/{Object}-{lang}.objectTranslation
    // Covers: field, picklist, validationRule, object (label)
    // ─────────────────────────────────────────────────────────────
    private static void upsertObjectTranslation(String language, String translationType, Map<String, Object> args) {
        String objectName = getRequired(args, 'objectName');
        String member     = objectName + '-' + language; // e.g. Car__c-fr

        // Read existing CustomObjectTranslation
        MetadataPort port = getPort();
        MetadataService.IReadResult readResult = port.readMetadata('CustomObjectTranslation', new List<String>{ member });

        // In-memory state
        String              objectLabel     = null;
        Map<String, String> fieldLabels     = new Map<String, String>(); // fieldName → label
        Map<String, Map<String, String>> picklistMap = new Map<String, Map<String, String>>(); // fieldName → {masterLabel → translation}
        Map<String, String> validationRules = new Map<String, String>(); // ruleName → errorMessage

        // Populate from existing
        if (readResult != null) {
            MetadataService.Metadata[] records = readResult.getRecords();
            if (records != null && !records.isEmpty() && records[0] != null) {
                MetadataService.CustomObjectTranslation cot = (MetadataService.CustomObjectTranslation) records[0];

                if (String.isNotBlank(cot.nameFieldLabel)) objectLabel = cot.nameFieldLabel;

                if (cot.fields != null) {
                    for (MetadataService.CustomFieldTranslation cft : cot.fields) {
                        if (cft == null || String.isBlank(cft.name)) continue;
                        if (String.isNotBlank(cft.label)) fieldLabels.put(cft.name, cft.label);
                        if (cft.picklistValues != null) {
                            Map<String, String> pvMap = new Map<String, String>();
                            for (MetadataService.PicklistValueTranslation pvt : cft.picklistValues) {
                                if (pvt != null && String.isNotBlank(pvt.masterLabel)) {
                                    pvMap.put(pvt.masterLabel, pvt.translation != null ? pvt.translation : '');
                                }
                            }
                            if (!pvMap.isEmpty()) picklistMap.put(cft.name, pvMap);
                        }
                    }
                }

                if (cot.validationRules != null) {
                    for (MetadataService.ValidationRuleTranslation vrt : cot.validationRules) {
                        if (vrt != null && String.isNotBlank(vrt.name) && String.isNotBlank(vrt.errorMessage)) {
                            validationRules.put(vrt.name, vrt.errorMessage);
                        }
                    }
                }
            }
        }

        // Apply the new translation
        if (translationType == 'object') {
            objectLabel = getRequired(args, 'translation');

        } else if (translationType == 'field') {
            String fieldName   = getRequired(args, 'fieldName');
            String translation = getRequired(args, 'translation');
            fieldLabels.put(fieldName, translation);

        } else if (translationType == 'picklist') {
            String fieldName   = getRequired(args, 'fieldName');
            String masterLabel = getRequired(args, 'masterLabel');
            String translation = getRequired(args, 'translation');
            if (!picklistMap.containsKey(fieldName)) picklistMap.put(fieldName, new Map<String, String>());
            picklistMap.get(fieldName).put(masterLabel, translation);

        } else if (translationType == 'validationRule') {
            String ruleName    = getRequired(args, 'ruleName');
            String translation = getRequired(args, 'translation');
            validationRules.put(ruleName, translation);
        }

        // Build XML
        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomObjectTranslation xmlns="' + NAMESPACE + '">';

        if (String.isNotBlank(objectLabel)) {
            xml += '<nameFieldLabel>' + escapeXml(objectLabel) + '</nameFieldLabel>';
        }

        // Collect all field names
        Set<String> allFields = new Set<String>();
        allFields.addAll(fieldLabels.keySet());
        allFields.addAll(picklistMap.keySet());

        for (String fieldName : allFields) {
            xml += '<fields>'
                + '<name>' + escapeXml(fieldName) + '</name>';

            if (fieldLabels.containsKey(fieldName)) {
                xml += '<label>' + escapeXml(fieldLabels.get(fieldName)) + '</label>';
            }

            if (picklistMap.containsKey(fieldName)) {
                Map<String, String> pvMap = picklistMap.get(fieldName);
                for (String masterLabel : pvMap.keySet()) {
                    xml += '<picklistValues>'
                        + '<masterLabel>'  + escapeXml(masterLabel)          + '</masterLabel>'
                        + '<translation>'  + escapeXml(pvMap.get(masterLabel)) + '</translation>'
                        + '</picklistValues>';
                }
            }

            xml += '</fields>';
        }

        for (String ruleName : validationRules.keySet()) {
            xml += '<validationRules>'
                + '<errorMessage>' + escapeXml(validationRules.get(ruleName)) + '</errorMessage>'
                + '<name>'         + escapeXml(ruleName)                      + '</name>'
                + '</validationRules>';
        }

        xml += '</CustomObjectTranslation>';

        String filePath = 'objectTranslations/' + member + '.objectTranslation';
        ZipBuilder.addFile('CustomObjectTranslation', member, filePath, xml);
        System.debug('TranslationHelper: object translation [' + member + '] queued for deploy');
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
            throw new TranslationException('Required parameter missing: ' + key);
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

    public class TranslationException extends Exception {}
}