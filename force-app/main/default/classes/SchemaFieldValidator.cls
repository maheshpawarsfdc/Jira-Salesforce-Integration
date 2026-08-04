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

  // Same key space as pendingFields — whether the pending field's generated
  // XML declared <required>true</required>. Needed because live schema
  // describe can't see requiredness for a field that doesn't exist yet.
  private static Map<String, Boolean> pendingFieldRequired = new Map<String, Boolean>();

  // Same key space as pendingFields — true when the generated field should
  // be readonly on layouts (formula/summary/autonumber/id semantics).
  private static Map<String, Boolean> pendingFieldLayoutReadOnly = new Map<String, Boolean>();

  // ─────────────────────────────────────────────────────────────
  // RESET — call once at the start of processing a fresh LLM response
  // (including each repair-retry attempt), so pending fields from a
  // previous attempt don't leak into the next one.
  // ─────────────────────────────────────────────────────────────
  public static void reset() {
    pendingFields.clear();
    pendingFieldRequired.clear();
    pendingFieldLayoutReadOnly.clear();
  }

  // ─────────────────────────────────────────────────────────────
  // PRE-PASS — scan every CustomObject file (embedded <fields> blocks) and
  // every standalone CustomField file in the response, and register the
  // fields they declare as pending, before any individual file is
  // validated. Safe to call even if fields is null/empty.
  // ─────────────────────────────────────────────────────────────
  public static void registerPendingFieldsFromResponse(List<Object> files) {
    if (files == null) {
      return;
    }

    Pattern fieldBlockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Pattern fullNamePat = Pattern.compile('<fullName>([^<]+)</fullName>');
    Pattern typePat = Pattern.compile('<type>([^<]+)</type>');
    Pattern requiredPat = Pattern.compile('<required>([^<]+)</required>');

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String xmlContent = (String) file.get('xmlContent');

      if (String.isBlank(memberName) || String.isBlank(xmlContent)) {
        continue;
      }

      if (metadataType == 'CustomObject') {
        Matcher blockMatcher = fieldBlockPat.matcher(xmlContent);
        while (blockMatcher.find()) {
          String block = blockMatcher.group(1);
          Matcher nameMatcher = fullNamePat.matcher(block);
          if (!nameMatcher.find()) {
            continue;
          }
          Matcher typeMatcher = typePat.matcher(block);
          Matcher requiredMatcher = requiredPat.matcher(block);
          String declaredType = typeMatcher.find()
            ? typeMatcher.group(1).toUpperCase()
            : '';
          Boolean required =
            requiredMatcher.find() && requiredMatcher.group(1) == 'true';
          Boolean layoutReadOnly = block.contains('<formula>') ||
            declaredType == 'SUMMARY' ||
            declaredType == 'AUTONUMBER';
          registerPendingField(
            memberName,
            nameMatcher.group(1),
            declaredType,
            required,
            layoutReadOnly
          );
        }
      } else if (metadataType == 'CustomField' && memberName.contains('.')) {
        // Standalone decomposed CustomField file — memberName is already
        // qualified as "ObjectApiName.FieldApiName".
        String objectApiName = memberName.substringBefore('.');
        String fieldApiName = memberName.substringAfter('.');
        Matcher typeMatcher = typePat.matcher(xmlContent);
        Matcher requiredMatcher = requiredPat.matcher(xmlContent);
        String declaredType = typeMatcher.find()
          ? typeMatcher.group(1).toUpperCase()
          : '';
        Boolean required =
          requiredMatcher.find() && requiredMatcher.group(1) == 'true';
        Boolean layoutReadOnly = xmlContent.contains('<formula>') ||
          declaredType == 'SUMMARY' ||
          declaredType == 'AUTONUMBER';
        registerPendingField(
          objectApiName,
          fieldApiName,
          declaredType,
          required,
          layoutReadOnly
        );
      }
    }
  }

  public static void registerPendingField(
    String objectApiName,
    String fieldApiName,
    String declaredType,
    Boolean isRequired
  ) {
    registerPendingField(
      objectApiName,
      fieldApiName,
      declaredType,
      isRequired,
      false
    );
  }

  public static void registerPendingField(
    String objectApiName,
    String fieldApiName,
    String declaredType,
    Boolean isRequired,
    Boolean isLayoutReadOnly
  ) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return;
    }
    String key = objectApiName.toLowerCase() + '.' + fieldApiName.toLowerCase();
    pendingFields.put(key, declaredType);
    pendingFieldRequired.put(key, isRequired == true);
    pendingFieldLayoutReadOnly.put(key, isLayoutReadOnly == true);
  }

  // ─────────────────────────────────────────────────────────────
  // LOOKUPS
  // ─────────────────────────────────────────────────────────────
  private static Map<String, Schema.SObjectField> getFieldMap(
    String objectApiName
  ) {
    if (String.isBlank(objectApiName)) {
      return new Map<String, Schema.SObjectField>();
    }
    String cacheKey = objectApiName.toLowerCase();
    if (fieldMapCache.containsKey(cacheKey)) {
      return fieldMapCache.get(cacheKey);
    }

    Map<String, Schema.SObjectField> fieldMap = new Map<String, Schema.SObjectField>();
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

    // Global describe keys are case-sensitive API names (e.g. Contract1__c),
    // while callers may pass mixed/lower case. Resolve case-insensitively.
    String resolvedKey = null;
    if (globalDescribe.containsKey(objectApiName)) {
      resolvedKey = objectApiName;
    } else {
      String target = objectApiName.toLowerCase();
      for (String gdKey : globalDescribe.keySet()) {
        if (gdKey != null && gdKey.toLowerCase() == target) {
          resolvedKey = gdKey;
          break;
        }
      }
    }

    if (resolvedKey != null) {
      fieldMap = globalDescribe.get(resolvedKey).getDescribe().fields.getMap();
    }

    fieldMapCache.put(cacheKey, fieldMap);
    return fieldMap;
  }

  private static Schema.SObjectField getFieldDescribe(
    String objectApiName,
    String fieldApiName
  ) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return null;
    }
    Map<String, Schema.SObjectField> fmap = getFieldMap(objectApiName);
    if (fmap == null || fmap.isEmpty()) {
      return null;
    }

    if (fmap.containsKey(fieldApiName)) {
      return fmap.get(fieldApiName);
    }

    String target = fieldApiName.toLowerCase();
    for (String k : fmap.keySet()) {
      if (k != null && k.toLowerCase() == target) {
        return fmap.get(k);
      }
    }
    return null;
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
    return getFieldDescribe(objectApiName, fieldApiName) != null;
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
    Schema.SObjectField f = getFieldDescribe(objectApiName, fieldApiName);
    if (f == null) {
      return null;
    }
    return String.valueOf(f.getDescribe().getType());
  }

  // Returns true if the field is required. Checks fields newly declared in
  // this response first — their required flag comes straight from the
  // generated XML since live schema can't see them yet — then falls back
  // to a live Schema describe for fields that already exist in the org.
  public static Boolean isFieldRequired(
    String objectApiName,
    String fieldApiName
  ) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return false;
    }
    String key = objectApiName.toLowerCase() + '.' + fieldApiName.toLowerCase();
    if (pendingFieldRequired.containsKey(key)) {
      return pendingFieldRequired.get(key);
    }
    Schema.SObjectField f = getFieldDescribe(objectApiName, fieldApiName);
    if (f == null) {
      return false;
    }
    Schema.DescribeFieldResult d = f.getDescribe();
    // Required in the permission-set sense: not nillable, not
    // auto-populated, not an auto-number, not a formula, and not Id.
    return !d.isNillable() &&
      !d.isDefaultedOnCreate() &&
      !d.isAutoNumber() &&
      !d.isCalculated() &&
      d.getType() != Schema.DisplayType.ID;
  }

  // Returns true for fields that must be Readonly on layouts because the
  // value is system-derived (formula/rollup/autonumber/Id).
  public static Boolean isLayoutReadOnlyField(
    String objectApiName,
    String fieldApiName
  ) {
    if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
      return false;
    }
    String normalizedField = fieldApiName.contains('.')
      ? fieldApiName.substringAfter('.')
      : fieldApiName;
    String key = objectApiName.toLowerCase() + '.' + normalizedField.toLowerCase();
    if (pendingFieldLayoutReadOnly.containsKey(key)) {
      return pendingFieldLayoutReadOnly.get(key);
    }
    Schema.SObjectField f = getFieldDescribe(objectApiName, normalizedField);
    if (f == null) {
      return false;
    }
    Schema.DescribeFieldResult d = f.getDescribe();
    return d.isCalculated() ||
      d.isAutoNumber() ||
      d.getType() == Schema.DisplayType.ID;
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
