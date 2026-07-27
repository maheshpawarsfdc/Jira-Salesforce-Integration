/**
 * SchemaFieldValidator — mechanically verifies that field/object API names
 * referenced in generated content actually exist, instead of relying on the
 * LLM to get them right or on prompt instructions being followed.
 *
 * Checks live org schema (Schema.describe()) first. Also accepts fields that
 * are being newly created in the SAME generation response — those legitimately
 * don't exist in the org yet, so callers must register them (via
 * registerPendingFieldsFromResponse) before validating, or every ticket that
 * creates a field and immediately references it (e.g. a new object + a
 * validation rule on one of its new fields) would be incorrectly rejected.
 */
public class SchemaFieldValidator {
  private static Map<String, Map<String, Schema.SObjectField>> fieldMapCache = new Map<String, Map<String, Schema.SObjectField>>();

  // Fields being newly created in the current generation response, not yet
  // in the org. Key: lowercased "ObjectApiName.FieldApiName", value: the
  // field's declared type from the generated XML (uppercased, e.g. 'DATE'),
  // or blank if the type couldn't be determined.
  private static Map<String, String> pendingFields = new Map<String, String>();

  // ─────────────────────────────────────────────────────────────
  // RESET — call once at the start of processing a fresh LLM response
  // (including each repair-retry attempt), so pending fields from a
  // previous attempt don't leak into the next one.
  // ─────────────────────────────────────────────────────────────
  public static void reset() {
    pendingFields.clear();
  }

  // ─────────────────────────────────────────────────────────────
  // PRE-PASS — scan every CustomObject file in the response for newly
  // declared <fields> blocks and register them as pending, before any
  // individual file is validated. Safe to call even if fields is null/empty.
  // ─────────────────────────────────────────────────────────────
  public static void registerPendingFieldsFromResponse(List<Object> files) {
    if (files == null) {
      return;
    }

    Pattern fieldBlockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Pattern fullNamePat = Pattern.compile('<fullName>([^<]+)</fullName>');
    Pattern typePat = Pattern.compile('<type>([^<]+)</type>');

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String xmlContent = (String) file.get('xmlContent');

      if (
        metadataType != 'CustomObject' ||
        String.isBlank(memberName) ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }

      Matcher blockMatcher = fieldBlockPat.matcher(xmlContent);
      while (blockMatcher.find()) {
        String block = blockMatcher.group(1);
        Matcher nameMatcher = fullNamePat.matcher(block);
        Matcher typeMatcher = typePat.matcher(block);
        if (nameMatcher.find()) {
          String declaredType = typeMatcher.find()
            ? typeMatcher.group(1).toUpperCase()
            : '';
          registerPendingField(memberName, nameMatcher.group(1), declaredType);
        }
      }
    }
  }

  public static void registerPendingField(
    String objectApiName,
    String fieldApiName,
    String declaredType
  ) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return;
    }
    pendingFields.put(
      objectApiName.toLowerCase() + '.' + fieldApiName.toLowerCase(),
      declaredType
    );
  }

  // ─────────────────────────────────────────────────────────────
  // LOOKUPS
  // ─────────────────────────────────────────────────────────────
  private static Map<String, Schema.SObjectField> getFieldMap(
    String objectApiName
  ) {
    String key = objectApiName.toLowerCase();
    if (fieldMapCache.containsKey(key)) {
      return fieldMapCache.get(key);
    }
    Map<String, Schema.SObjectField> fieldMap = new Map<String, Schema.SObjectField>();
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    if (globalDescribe.containsKey(key)) {
      fieldMap = globalDescribe.get(key).getDescribe().fields.getMap();
    }
    fieldMapCache.put(key, fieldMap);
    return fieldMap;
  }

  public static Boolean fieldExists(String objectApiName, String fieldApiName) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return false;
    }
    if (
      pendingFields.containsKey(
        objectApiName.toLowerCase() + '.' + fieldApiName.toLowerCase()
      )
    ) {
      return true;
    }
    return getFieldMap(objectApiName).containsKey(fieldApiName.toLowerCase());
  }

  // Returns the field's real Display Type name (e.g. 'DATE', 'DATETIME'),
  // or null if the field/object doesn't exist and isn't pending either.
  public static String getFieldType(String objectApiName, String fieldApiName) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return null;
    }
    String pendingKey =
      objectApiName.toLowerCase() +
      '.' +
      fieldApiName.toLowerCase();
    if (pendingFields.containsKey(pendingKey)) {
      return pendingFields.get(pendingKey);
    }
    Schema.SObjectField f = getFieldMap(objectApiName)
      .get(fieldApiName.toLowerCase());
    if (f == null) {
      return null;
    }
    return String.valueOf(f.getDescribe().getType());
  }

  // Comma-separated list of the object's actual field API names, for
  // building factual error messages instead of vague ones.
  public static String getKnownFieldNames(String objectApiName) {
    if (String.isBlank(objectApiName)) {
      return '';
    }
    Set<String> names = new Set<String>();
    for (Schema.SObjectField f : getFieldMap(objectApiName).values()) {
      names.add(f.getDescribe().getName());
    }
    String prefix = objectApiName.toLowerCase() + '.';
    for (String key : pendingFields.keySet()) {
      if (key.startsWith(prefix)) {
        names.add(key.substringAfter('.'));
      }
    }
    List<String> sorted = new List<String>(names);
    sorted.sort();
    return String.join(sorted, ', ');
  }
}
