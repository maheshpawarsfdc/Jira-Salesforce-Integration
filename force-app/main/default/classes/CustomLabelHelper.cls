/**
 * CustomLabelHelper.cls
 *
 * Handles Custom Label operations via ZIP deploy.
 * All labels live in one file: labels/CustomLabels.labels
 *
 * Package.xml type: CustomLabel, member: LabelName
 * Destructive delete: type CustomLabel, member: LabelName
 *
 * ── FIELD MAPPING (confirmed from both sources) ──────────────────
 *
 *   Tooling API (ExternalString)  │  Metadata XML element
 *   ──────────────────────────────│──────────────────────
 *   Name                          │  <fullName>
 *   Language                      │  <language>
 *   IsProtected                   │  <protected>
 *   MasterLabel                   │  <shortDescription>   ← DIFFERENT NAMES!
 *   Value                         │  <value>
 *
 * ── CORRECT XML ELEMENT ORDER (verified from VS Code) ────────────
 *
 *   <labels>
 *       <fullName>...</fullName>
 *       <language>...</language>
 *       <protected>...</protected>
 *       <shortDescription>...</shortDescription>   ← optional
 *       <value>...</value>
 *   </labels>
 *
 * There is NO <masterLabel> or <categories> element in the metadata XML.
 * shortDescription in XML = MasterLabel in Tooling API.
 */
public class CustomLabelHelper {

    private static final String FILE_PATH = 'labels/CustomLabels.labels';
    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    // ─────────────────────────────────────────────────────────────
    // LIST
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listCustomLabels(Map<String, Object> args) {
        System.debug('CustomLabelHelper.listCustomLabels() called');

        // MasterLabel in Tooling API = shortDescription in metadata XML
        String query = 'SELECT Id, Name, Value, Language, IsProtected, MasterLabel '
            + 'FROM ExternalString '
            + 'WHERE ManageableState = \'unmanaged\' '
            + 'ORDER BY Name';

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
            throw new CustomLabelException('Failed to list custom labels. Status: ' + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            result.add(new Map<String, Object>{
                'name'             => r.get('Name'),
                'shortDescription' => r.get('MasterLabel'),  // MasterLabel in API = shortDescription in XML
                'value'            => r.get('Value'),
                'language'         => r.get('Language'),
                'protected'        => r.get('IsProtected')
            });
        }

        System.debug('CustomLabelHelper.listCustomLabels(): found ' + result.size() + ' labels');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE
    // ─────────────────────────────────────────────────────────────
    public static void createCustomLabel(Map<String, Object> args) {
        String name             = getRequired(args, 'name');
        String shortDescription = getOptional(args, 'shortDescription', null);
        String value            = getRequired(args, 'value');
        String language         = getOptional(args, 'language', 'en_US');
        Boolean isProtected     = Boolean.valueOf(getOptional(args, 'protected', 'false'));

        System.debug('CustomLabelHelper.createCustomLabel() called: name=' + name);

        String labelBlock = buildLabelBlock(name, value, language, shortDescription, isProtected);
        System.debug('CustomLabelHelper.createCustomLabel(): XML block = ' + labelBlock);
        addLabelToZip(name, labelBlock);
        System.debug('CustomLabelHelper.createCustomLabel(): [' + name + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // UPDATE
    // Reads existing label from Tooling API, applies only the
    // provided changes, preserves everything else.
    // ─────────────────────────────────────────────────────────────
    public static void updateCustomLabel(Map<String, Object> args) {
        String name = getRequired(args, 'name');
        System.debug('CustomLabelHelper.updateCustomLabel() called: name=' + name);

        // Read existing label — MasterLabel in Tooling API = shortDescription in metadata XML
        String query = 'SELECT Name, Value, Language, IsProtected, MasterLabel '
            + 'FROM ExternalString WHERE Name = \'' + name + '\' LIMIT 1';

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
        System.debug('CustomLabelHelper.updateCustomLabel(): Tooling API status=' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            throw new CustomLabelException(
                'Tooling API error reading label [' + name + ']. '
                + 'Status: ' + res.getStatusCode() + ' Body: ' + res.getBody()
            );
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        if (records == null || records.isEmpty()) {
            throw new CustomLabelException('Custom Label not found: ' + name);
        }

        Map<String, Object> existing = (Map<String, Object>) records[0];

        // Apply only the changes provided — preserve existing for anything not specified
        // shortDescription in args maps to MasterLabel in Tooling API
        String shortDescription = getOptional(args, 'shortDescription',
            existing.get('MasterLabel') != null ? String.valueOf(existing.get('MasterLabel')) : null);
        String value            = getOptional(args, 'value',
            String.valueOf(existing.get('Value')));
        String language         = getOptional(args, 'language',
            String.valueOf(existing.get('Language')));
        Boolean isProtected     = Boolean.valueOf(getOptional(args, 'protected',
            String.valueOf(existing.get('IsProtected'))));

        String labelBlock = buildLabelBlock(name, value, language, shortDescription, isProtected);
        System.debug('CustomLabelHelper.updateCustomLabel(): XML block being deployed = ' + labelBlock);

        addLabelToZip(name, labelBlock);
        System.debug('CustomLabelHelper.updateCustomLabel(): [' + name + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE
    // ─────────────────────────────────────────────────────────────
    public static void deleteCustomLabel(Map<String, Object> args) {
        String name = getRequired(args, 'name');
        System.debug('CustomLabelHelper.deleteCustomLabel() called: name=' + name);

        addDestructiveXml(name);
        System.debug('CustomLabelHelper.deleteCustomLabel(): [' + name + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build <labels> XML block
    //
    // VERIFIED correct element order from VS Code package retrieve:
    //   1. fullName
    //   2. language
    //   3. protected
    //   4. shortDescription  (optional — only include if not blank)
    //   5. value
    //
    // NOTE: There is NO <masterLabel> element in metadata XML.
    //       shortDescription here = MasterLabel in Tooling API.
    // ─────────────────────────────────────────────────────────────
    private static String buildLabelBlock(
        String name,
        String value,
        String language,
        String shortDescription,
        Boolean isProtected
    ) {
        Boolean safeProtected = (isProtected != null) ? isProtected : false;
        String safeLanguage   = String.isNotBlank(language) ? language : 'en_US';

        String xml = '<labels>'
            + '<fullName>'  + escapeXml(name)        + '</fullName>'
            + '<language>'  + escapeXml(safeLanguage) + '</language>'
            + '<protected>' + safeProtected           + '</protected>';

        // shortDescription is optional — only add if provided
        if (String.isNotBlank(shortDescription)) {
            xml += '<shortDescription>' + escapeXml(shortDescription) + '</shortDescription>';
        }

        xml += '<value>' + escapeXml(value) + '</value>'
            +  '</labels>';

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Add label block to ZIP
    // Removes any existing block for this label name first to prevent
    // duplicate <fullName> errors when create + update run in same session.
    // ─────────────────────────────────────────────────────────────
    private static void addLabelToZip(String labelName, String labelBlock) {
        String existing = ZipBuilder.files.get(FILE_PATH);

        String fileXml;
        if (existing != null) {
            existing = removeLabelBlock(existing, labelName);
            fileXml  = existing.replace('</CustomLabels>', labelBlock + '</CustomLabels>');
        } else {
            fileXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<CustomLabels xmlns="' + NAMESPACE + '">'
                + labelBlock
                + '</CustomLabels>';
        }

        System.debug('CustomLabelHelper.addLabelToZip(): full file XML = ' + fileXml);
        ZipBuilder.addFile('CustomLabel', labelName, FILE_PATH, fileXml);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Remove a <labels> block by fullName from existing XML
    // ─────────────────────────────────────────────────────────────
    private static String removeLabelBlock(String xml, String labelName) {
        String fullNameTag = '<fullName>' + labelName + '</fullName>';
        if (!xml.contains(fullNameTag)) return xml;

        Integer fullNameIdx = xml.indexOf(fullNameTag);
        Integer blockStart  = xml.lastIndexOf('<labels>', fullNameIdx);
        Integer blockEnd    = xml.indexOf('</labels>', fullNameIdx) + '</labels>'.length();

        if (blockStart == -1 || blockEnd < '</labels>'.length()) return xml;

        return xml.substring(0, blockStart) + xml.substring(blockEnd);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Destructive XML for delete
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String labelName) {
        String existingDestructive = ZipBuilder.files.get('destructiveChangesPost.xml');
        String destructiveXml;

        if (existingDestructive != null && existingDestructive.contains('<name>CustomLabel</name>')) {
            destructiveXml = existingDestructive.replace(
                '<name>CustomLabel</name>',
                '<members>' + labelName + '</members><name>CustomLabel</name>'
            );
        } else if (existingDestructive != null) {
            destructiveXml = existingDestructive.replace(
                '</Package>',
                '<types><members>' + labelName + '</members><name>CustomLabel</name></types></Package>'
            );
        } else {
            destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="' + NAMESPACE + '">'
                + '<types>'
                + '<members>' + labelName + '</members>'
                + '<name>CustomLabel</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', labelName, 'destructiveChangesPost.xml', destructiveXml);
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
            throw new CustomLabelException('Required parameter missing: ' + key);
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

    public class CustomLabelException extends Exception {}
}