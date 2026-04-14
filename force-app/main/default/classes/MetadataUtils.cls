/**
 * MetadataUtils.cls
 *
 * Shared utility methods used across all Metadata helper classes.
 *
 * Previously these were copy-pasted as private methods into every helper:
 *   escapeXml, getRequired, getOptional, addSuffix, getSessionId
 *
 * Single source of truth — fix here and all helpers benefit automatically.
 */
public class MetadataUtils {

    // ─────────────────────────────────────────────────────────────
    // XML ESCAPING
    // ─────────────────────────────────────────────────────────────
    public static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&',  '&amp;')
                  .replace('<',  '&lt;')
                  .replace('>',  '&gt;')
                  .replace('"',  '&quot;')
                  .replace('\'', '&apos;');
    }

    // ─────────────────────────────────────────────────────────────
    // SUFFIX HELPERS
    // ─────────────────────────────────────────────────────────────

    /** Appends __c if not already present. Used for custom objects and fields. */
    public static String addSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }

    /** Appends __mdt if not already present. */
    public static String addMdtSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__mdt') ? name : name + '__mdt';
    }

    // ─────────────────────────────────────────────────────────────
    // PARAMETER EXTRACTION
    // ─────────────────────────────────────────────────────────────

    /**
     * Returns the String value for a required argument key.
     * Throws UtilException if the key is absent or blank.
     */
    public static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new UtilException('Required parameter missing: ' + key);
        }
        return String.valueOf(val).trim();
    }

    /**
     * Returns the String value for an optional argument key,
     * falling back to defaultValue when absent, blank, or the literal string "null".
     */
    public static String getOptional(Map<String, Object> args, String key, String defaultValue) {
        Object val = args?.get(key);
        if (val == null) return defaultValue;
        String strVal = String.valueOf(val).trim();
        if (String.isBlank(strVal) || strVal == 'null') return defaultValue;
        return strVal;
    }

    // ─────────────────────────────────────────────────────────────
    // SESSION ID
    //
    // UserInfo.getSessionId() returns null in async (Queueable/Scheduled)
    // contexts when the session has no associated UI request.
    // The Visualforce page workaround retrieves a token that remains
    // valid in those contexts.
    //
    // Falls back to UserInfo.getSessionId() when the VF page is
    // unavailable (e.g. in test execution).
    // ─────────────────────────────────────────────────────────────
    public static String getSessionId() {
        if (Test.isRunningTest()) return UserInfo.getSessionId();
        try {
            PageReference vfPage = Page.SessionId;
            String content = vfPage.getContent().toString();
            Integer s = content.indexOf('Start_Of_Session_Id') + 'Start_Of_Session_Id'.length();
            Integer e = content.indexOf('End_Of_Session_Id');
            return content.substring(s, e);
        } catch (Exception ex) {
            return UserInfo.getSessionId();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // EXCEPTION
    // ─────────────────────────────────────────────────────────────
    public class UtilException extends Exception {}
}