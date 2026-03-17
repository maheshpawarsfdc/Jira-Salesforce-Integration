/**
 * StaticResourceHelper.cls
 *
 * Handles Static Resource operations via ZIP deploy.
 *
 * MDAPI facts:
 * - Content file:  staticresources/{ApiName}                    (binary, no extension)
 * - Metadata file: staticresources/{ApiName}.resource-meta.xml  (text XML)
 * - Package type:  StaticResource
 * - Member name:   ApiName (no __c, no extension)
 *
 * Files come from Jira ticket attachments.
 * currentAttachments is populated by JiraInboundController
 * before LLMService runs.
 *
 * ── TOOL MAPPING ──────────────────────────────────────────────
 *   static_resource_list   → listStaticResources()
 *   static_resource_deploy → deployStaticResource()   (create + update)
 *   static_resource_delete → deleteStaticResource()
 */
public class StaticResourceHelper {

    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    // ─────────────────────────────────────────────────────────────
    // ATTACHMENTS
    // Populated by JiraInboundController before LLMService runs.
    // Key   = fileName  (e.g. logo.png)
    // Value = { base64Content, mimeType }
    // ─────────────────────────────────────────────────────────────
    public static Map<String, Map<String, String>> currentAttachments
        = new Map<String, Map<String, String>>();

    // ─────────────────────────────────────────────────────────────
    // LIST
    // Returns all attachments available on the current Jira ticket.
    // The LLM calls this first to see what files are available
    // before deciding which one to deploy.
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listStaticResources(Map<String, Object> args) {
        System.debug('StaticResourceHelper.listStaticResources() called');

        List<Map<String, Object>> result = new List<Map<String, Object>>();

        for (String fileName : currentAttachments.keySet()) {
            Map<String, String> att = currentAttachments.get(fileName);
            result.add(new Map<String, Object>{
                'fileName' => fileName,
                'mimeType' => att.get('mimeType')
            });
        }

        System.debug('StaticResourceHelper.listStaticResources(): ' + result.size() + ' attachment(s) available');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // DEPLOY (create or update)
    // Stages both the binary content file and the metadata XML sidecar
    // into ZipBuilder for a single deploy.
    // ─────────────────────────────────────────────────────────────
    public static void deployStaticResource(Map<String, Object> args) {
        String apiName      = getRequired(args, 'apiName');
        String fileName     = getRequired(args, 'fileName');
        String cacheControl = getOptional(args, 'cacheControl', 'Public');

        System.debug('StaticResourceHelper.deployStaticResource() called');
        System.debug('apiName=' + apiName + ' fileName=' + fileName + ' cacheControl=' + cacheControl);

        // Look up attachment from current ticket
        Map<String, String> att = currentAttachments.get(fileName);
        if (att == null) {
            throw new StaticResourceException(
                'Attachment not found: ' + fileName
                + '. Call static_resource_list first to see available files.'
            );
        }

        String mimeType   = att.get('mimeType');
        String base64Data = att.get('base64Content');

        // 1 — Binary content file (no extension in path)
        ZipBuilder.addBinaryFile('StaticResource', apiName,
            'staticresources/' + apiName + '.resource', base64Data);

        // 2 — Metadata XML sidecar
        String metaXml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<StaticResource xmlns="' + NAMESPACE + '">'
            + '<cacheControl>' + cacheControl + '</cacheControl>'
            + '<contentType>' + escapeXml(mimeType) + '</contentType>'
            + '</StaticResource>';

        ZipBuilder.addFile('StaticResource', apiName,
            'staticresources/' + apiName + '.resource-meta.xml', metaXml);

        System.debug('StaticResourceHelper.deployStaticResource(): [' + apiName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE
    // Adds the static resource to destructiveChangesPost.xml.
    // Follows the same pattern as CustomLabelHelper, NamedCredentialHelper etc.
    // ─────────────────────────────────────────────────────────────
    public static void deleteStaticResource(Map<String, Object> args) {
        String apiName = getRequired(args, 'apiName');

        System.debug('StaticResourceHelper.deleteStaticResource() called: apiName=' + apiName);

        String nameTag  = '<name>StaticResource</name>';
        String existing = ZipBuilder.files.get('destructiveChangesPost.xml');
        String xml;

        if (existing != null && existing.contains(nameTag)) {
            xml = existing.replace(nameTag,
                '<members>' + apiName + '</members>' + nameTag);
        } else if (existing != null) {
            xml = existing.replace('</Package>',
                '<types><members>' + apiName + '</members>'
                + nameTag + '</types></Package>');
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

        ZipBuilder.addFile('__destructive__', apiName,
            'destructiveChangesPost.xml', xml);

        System.debug('StaticResourceHelper.deleteStaticResource(): [' + apiName + '] queued for destructive deploy');
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

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new StaticResourceException('Required parameter missing: ' + key);
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

    public class StaticResourceException extends Exception {}
}