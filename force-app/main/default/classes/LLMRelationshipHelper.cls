public class LLMRelationshipHelper {
  // ─────────────────────────────────────────────────────────────
  // UNIQUE RELATIONSHIP NAME
  //
  //   - same ticket → same name (idempotent across re-runs)
  //   - different {child,field,parent} → different name (no collisions)
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

    String raw = child + '_' + field + '_' + parent;

    // Truncate input to keep the SHA-1 suffix deterministic at 6 chars
    String hashInput = (raw.length() > 200) ? raw.substring(0, 200) : raw;
    String hashHex = EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA1', Blob.valueOf(hashInput))
      )
      .toUpperCase();
    String suffix = hashHex.substring(0, 6);

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
    if (String.isBlank(token))
      return '';
    String t = token.trim();
    if (t.endsWith('__c'))
      t = t.substring(0, t.length() - 3);
    if (t.endsWith('__mdt'))
      t = t.substring(0, t.length() - 5);
    t = t.replaceAll('[^A-Za-z0-9_]', '_');
    while (t.contains('__'))
      t = t.replace('__', '_');
    if (t.startsWith('_'))
      t = t.substring(1);
    if (t.endsWith('_'))
      t = t.substring(0, t.length() - 1);
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
    if (String.isBlank(parentApiName))
      return names;
    try {
      Schema.SObjectType objType = Schema.getGlobalDescribe()
        .get(parentApiName);
      if (objType == null)
        return names;
      for (
        Schema.ChildRelationship cr : objType.getDescribe()
          .getChildRelationships()
      ) {
        String relName = cr.getRelationshipName();
        if (String.isNotBlank(relName))
          names.add(relName.toLowerCase());
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
    if (String.isBlank(filePath))
      return '';
    String name = filePath;
    Integer slash = name.lastIndexOf('/');
    if (slash >= 0)
      name = name.substring(slash + 1);
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
    if (String.isBlank(xmlContent) || !xmlContent.contains('<fields>'))
      return xmlContent;

    Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Matcher m = fieldsBlock.matcher(xmlContent);

    List<String> oldBlocks = new List<String>();
    List<String> newBlocks = new List<String>();

    while (m.find()) {
      String fullMatch = m.group(0);
      String inners = m.group(1);

      String typeVal = extractFirstTagValue(inners, 'type');
      if (typeVal != 'Lookup' && typeVal != 'MasterDetail')
        continue;

      String fieldApi = extractFirstTagValue(inners, 'fullName');
      String parent = extractFirstTagValue(inners, 'referenceTo');
      if (String.isBlank(fieldApi) || String.isBlank(parent))
        continue;

      String uniqueName = uniqueRelationshipName(
        sourceObjectApiName,
        fieldApi,
        parent
      );
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
    if (String.isBlank(xml) || String.isBlank(tagName))
      return null;
    Pattern p = Pattern.compile('(?s)<' + tagName + '>(.*?)</' + tagName + '>');
    Matcher m = p.matcher(xml);
    if (m.find())
      return m.group(1).trim();
    return null;
  }
}
