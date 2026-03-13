/**
 * NamedCredentialHelper.cls
 *
 * Handles Named Credential operations via ZIP deploy.
 *
 * MDAPI facts:
 * - File path:    namedCredentials/{Name}.namedCredential
 * - Package type: NamedCredential
 * - Member name:  API name (no __c suffix)
 * - Protocol:     NoAuthentication (anonymous — no auth headers)
 */
public class NamedCredentialHelper {

    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    // ─────────────────────────────────────────────────────────────
    // LIST
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listNamedCredentials(Map<String, Object> args) {
        System.debug('NamedCredentialHelper.listNamedCredentials() called');

        String query = 'SELECT Id, DeveloperName, MasterLabel, Endpoint FROM NamedCredential ORDER BY DeveloperName';
        String endpointUrl = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/tooling/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpointUrl);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new NamedCredentialException('Failed to list Named Credentials. Status: '
                + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                result.add(new Map<String, Object>{
                    'apiName'  => r.get('DeveloperName'),
                    'label'    => r.get('MasterLabel'),
                    'endpoint' => r.get('Endpoint')
                });
            }
        }

        System.debug('NamedCredentialHelper.listNamedCredentials(): found ' + result.size());
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE
    // ─────────────────────────────────────────────────────────────
    public static void createNamedCredential(Map<String, Object> args) {
        String apiName     = getRequired(args, 'apiName');
        String label       = getRequired(args, 'label');
        String endpointUrl = getRequired(args, 'endpoint');

        System.debug('NamedCredentialHelper.createNamedCredential(): ' + apiName);

        String xml      = buildXml(apiName, label, endpointUrl);
        String filePath = 'namedCredentials/' + apiName + '.namedCredential';
        ZipBuilder.addFile('NamedCredential', apiName, filePath, xml);

        System.debug('NamedCredentialHelper: [' + apiName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // UPDATE
    // Reads current values from org, applies only the changed fields
    // ─────────────────────────────────────────────────────────────
    public static void updateNamedCredential(Map<String, Object> args) {
        String apiName = getRequired(args, 'apiName');

        System.debug('NamedCredentialHelper.updateNamedCredential(): ' + apiName);

        // Read current values from org via Tooling API
        String query = 'SELECT DeveloperName, MasterLabel, Endpoint FROM NamedCredential '
            + 'WHERE DeveloperName = \'' + apiName + '\'';
        String endpointUrl = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/tooling/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpointUrl);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new NamedCredentialException('Failed to read Named Credential. Status: '
                + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        if (records == null || records.isEmpty()) {
            throw new NamedCredentialException('Named Credential not found: ' + apiName
                + '. Call named_credential_list first to confirm the exact API name.');
        }

        Map<String, Object> existing = (Map<String, Object>) records[0];
        String currentLabel          = (String) existing.get('MasterLabel');
        String currentEndpoint       = (String) existing.get('Endpoint');

        // Apply only the parameters that were passed in
        String newLabel    = getOptional(args, 'label',    currentLabel);
        String newEndpoint = getOptional(args, 'endpoint', currentEndpoint);

        String xml      = buildXml(apiName, newLabel, newEndpoint);
        String filePath = 'namedCredentials/' + apiName + '.namedCredential';
        ZipBuilder.addFile('NamedCredential', apiName, filePath, xml);

        System.debug('NamedCredentialHelper: [' + apiName + '] update staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE
    // ─────────────────────────────────────────────────────────────
    public static void deleteNamedCredential(Map<String, Object> args) {
        String apiName = getRequired(args, 'apiName');

        System.debug('NamedCredentialHelper.deleteNamedCredential(): ' + apiName);

        String nameTag  = '<' + 'name>NamedCredential</' + 'name>';
        String existing = ZipBuilder.files.get('destructiveChangesPost.xml');
        String xml;

        if (existing != null && existing.contains(nameTag)) {
            xml = existing.replace(nameTag, '<members>' + apiName + '</members>' + nameTag);
        } else if (existing != null) {
            xml = existing.replace('</Package>',
                '<types><members>' + apiName + '</members>' + nameTag + '</types></Package>');
        } else {
            xml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="' + NAMESPACE + '">'
                + '<types>'
                + '<members>' + apiName + '</members>'
                + nameTag
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', apiName, 'destructiveChangesPost.xml', xml);
        System.debug('NamedCredentialHelper: [' + apiName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — XML builder
    // ─────────────────────────────────────────────────────────────
    private static String buildXml(String apiName, String label, String endpointUrl) {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<NamedCredential xmlns="' + NAMESPACE + '">'
            + '<fullName>'    + escapeXml(apiName)     + '</fullName>'
            + '<label>'       + escapeXml(label)       + '</label>'
            + '<protocol>NoAuthentication</protocol>'
            + '<endpoint>'    + escapeXml(endpointUrl) + '</endpoint>'
            + '<principalType>Anonymous</principalType>'
            + '<allowMergeFieldsInBody>false</allowMergeFieldsInBody>'
            + '<allowMergeFieldsInHeader>false</allowMergeFieldsInHeader>'
            + '<generateAuthorizationHeader>false</generateAuthorizationHeader>'
            + '</NamedCredential>';
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
            throw new NamedCredentialException('Required parameter missing: ' + key);
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

    public class NamedCredentialException extends Exception {}
}