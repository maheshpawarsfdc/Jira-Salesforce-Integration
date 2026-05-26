public class LLMRelationshipHelper {
  // ─────────────────────────────────────────────────────────────
  // UNIQUE RELATIONSHIP NAME
  //
  //   - random 6-char hex suffix per deployment → ghost-proof
  //   - deleted objects leave their relationship names in Salesforce's
  //     internal registry (Recycle Bin) so a deterministic hash would
  //     collide on re-creation; a random suffix guarantees freshness
  //   - different {child,field,parent} → different base → no collisions
  //   - never equals the legacy "{Child}_{Field}" pattern (clears the org)
  // ─────────────────────────────────────────────────────────────
  public static String uniqueRelationshipName(
    String childObjectApiName,
    String fieldApiName,
    String parentObjectApiName
  ) {
    String child = sanitizeRelToken(
      String.isBlank(childObjectApiName) ? 'Child' : childObjectApiName
    );
    String field = sanitizeRelToken(
      String.isBlank(fieldApiName) ? 'Field' : fieldApiName
    );
    String parent = sanitizeRelToken(
      String.isBlank(parentObjectApiName) ? 'Parent' : parentObjectApiName
    );

    // Random 6-char hex suffix — different on every deployment.
    // This is intentionally non-deterministic: a SHA-1 hash based on
    // the object/field/parent would produce the same name each time,
    // which collides with the ghost relationship left in Salesforce's
    // internal registry when the child object is deleted to the Recycle
    // Bin and then recreated.  Schema.getChildRelationships() does NOT
    // surface those ghost names, so pre-flight collision detection alone
    // cannot save us — a fresh random name per deploy is the only
    // reliable guard.
    String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128))
      .substring(0, 6)
      .toUpperCase();

    // Max 40 chars total — Salesforce RelationshipName limit
    String base = child + '_' + field;
    if (base.length() > 33)
      base = base.substring(0, 33);

    String name = base + '_' + suffix;

    // Ensure it does not start with a digit or underscore
    if (name.substring(0, 1).isNumeric() || name.startsWith('_')) {
      name = 'R' + name;
    }

    System.debug(
      'uniqueRelationshipName: ' +
        childObjectApiName +
        '.' +
        fieldApiName +
        ' → ' +
        parentObjectApiName +
        ' => ' +
        name
    );

    return name;
  }

  public static String sanitizeRelToken(String token) {
    if (String.isBlank(token)) {
      return '';
    }
    String t = token.trim();
    if (t.endsWith('__c')) {
      t = t.substring(0, t.length() - 3);
    }
    if (t.endsWith('__mdt')) {
      t = t.substring(0, t.length() - 5);
    }
    t = t.replaceAll('[^A-Za-z0-9_]', '_');
    while (t.contains('__')) {
      t = t.replace('__', '_');
    }
    if (t.startsWith('_')) {
      t = t.substring(1);
    }
    if (t.endsWith('_')) {
      t = t.substring(0, t.length() - 1);
    }
    return t;
  }

  // ─────────────────────────────────────────────────────────────
  // GET EXISTING CHILD RELATIONSHIP NAMES
  // Returns all child relationship names already registered on a
  // parent object via Schema describe. Used to avoid collisions.
  // ─────────────────────────────────────────────────────────────
  public static Set<String> getExistingChildRelationshipNames(
    String parentApiName
  ) {
    Set<String> names = new Set<String>();
    if (String.isBlank(parentApiName)) {
      return names;
    }
    try {
      Schema.SObjectType objType = Schema.getGlobalDescribe()
        .get(parentApiName);
      if (objType == null) {
        return names;
      }
      for (
        Schema.ChildRelationship cr : objType.getDescribe()
          .getChildRelationships()
      ) {
        String relName = cr.getRelationshipName();
        if (String.isNotBlank(relName)) {
          names.add(relName.toLowerCase());
        }
      }
    } catch (Exception e) {
      System.debug(
        'getExistingChildRelationshipNames failed for [' +
          parentApiName +
          ']: ' +
          e.getMessage()
      );
    }
    return names;
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT SOURCE OBJECT FROM OBJECT FILE PATH
  // Derives "Reservation__c" from "objects/Reservation__c.object"
  // ─────────────────────────────────────────────────────────────
  public static String extractSourceObjectFromObjectPath(String filePath) {
    if (String.isBlank(filePath)) {
      return '';
    }
    String name = filePath;
    Integer slash = name.lastIndexOf('/');
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    if (name.toLowerCase().endsWith('.object')) {
      name = name.substring(0, name.length() - '.object'.length());
    }
    return name;
  }

  // ─────────────────────────────────────────────────────────────
  // REWRITE RELATIONSHIP NAMES IN CUSTOM OBJECT XML
  // Rewrites <relationshipName>…</relationshipName> inside every
  // <fields> block whose <type> is Lookup or MasterDetail.
  // Injects one if missing.
  // ─────────────────────────────────────────────────────────────
  public static String rewriteRelationshipNamesInCustomObjectXml(
    String xmlContent,
    String sourceObjectApiName
  ) {
    if (String.isBlank(xmlContent) || !xmlContent.contains('<fields>')) {
      return xmlContent;
    }

    Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Matcher m = fieldsBlock.matcher(xmlContent);

    List<String> oldBlocks = new List<String>();
    List<String> newBlocks = new List<String>();

    while (m.find()) {
      String fullMatch = m.group(0);
      String inners = m.group(1);

      String typeVal = extractFirstTagValue(inners, 'type');
      if (typeVal != 'Lookup' && typeVal != 'MasterDetail') {
        continue;
      }

      String fieldApi = extractFirstTagValue(inners, 'fullName');
      String parent = extractFirstTagValue(inners, 'referenceTo');
      if (String.isBlank(fieldApi) || String.isBlank(parent)) {
        continue;
      }

      String uniqueName = uniqueRelationshipName(
        sourceObjectApiName,
        fieldApi,
        parent
      );

      Set<String> existingRelNames = getExistingChildRelationshipNames(parent);
      if (existingRelNames.contains(uniqueName.toLowerCase())) {
        String baseName = uniqueName.length() > 36
          ? uniqueName.substring(0, 36)
          : uniqueName;
        Integer counter = 2;
        while (
          existingRelNames.contains((baseName + '_' + counter).toLowerCase()) &&
          counter < 20
        ) {
          counter++;
        }
        String deduped = baseName + '_' + counter;
        System.debug(
          'rewriteRelationshipNames: collision on [' +
            uniqueName +
            '] for parent [' +
            parent +
            '] — using [' +
            deduped +
            ']'
        );
        uniqueName = deduped;
      }

      String newInner;
      if (inners.contains('<relationshipName>')) {
        newInner = inners.replaceFirst(
          '<relationshipName>.*?</relationshipName>',
          '<relationshipName>' + uniqueName + '</relationshipName>'
        );
      } else {
        newInner = inners.replaceFirst(
          '(</referenceTo>)',
          '$1<relationshipName>' + uniqueName + '</relationshipName>'
        );
      }

      oldBlocks.add(fullMatch);
      newBlocks.add('<fields>' + newInner + '</fields>');

      System.debug(
        'rewriteRelationshipNames: ' +
          sourceObjectApiName +
          '.' +
          fieldApi +
          ' → ' +
          uniqueName
      );
    }

    String result = xmlContent;
    for (Integer i = 0; i < oldBlocks.size(); i++) {
      result = result.replace(oldBlocks[i], newBlocks[i]);
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT FIRST TAG VALUE
  // Pulls the text value of the first <tagName>…</tagName> found.
  // ─────────────────────────────────────────────────────────────
  public static String extractFirstTagValue(String xml, String tagName) {
    if (String.isBlank(xml) || String.isBlank(tagName)) {
      return null;
    }
    Pattern p = Pattern.compile('(?s)<' + tagName + '>(.*?)</' + tagName + '>');
    Matcher m = p.matcher(xml);
    if (m.find()) {
      return m.group(1).trim();
    }
    return null;
  }
}
