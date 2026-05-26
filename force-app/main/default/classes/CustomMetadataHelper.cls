/**
 * CustomMetadataHelper.cls
 *
 * Handles Custom Metadata Type and Record operations via ZIP deploy.
 *
 * MDAPI facts:
 * - Type definition:  objects/{ApiName}__mdt.object          (type: CustomObject)
 * - Field on type:    objects/{ApiName}__mdt.object           (embedded <fields> blocks)
 * - Record:           customMetadata/{ApiName}__mdt.{RecordName}.md  (type: CustomMetadata)
 *
 * xsi:type mappings for record values:
 *   Text/TextArea/LongTextArea/Email/Phone/URL/Picklist → xsd:string
 *   Number/Percent/Currency                             → xsd:double
 *   Checkbox                                            → xsd:boolean
 *   Date                                                → xsd:date
 *   DateTime                                            → xsd:dateTime
 */
public class CustomMetadataHelper {
  private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';
  private static final String NAMESPACE_XSI = 'http://www.w3.org/2001/XMLSchema-instance';
  private static final String NAMESPACE_XSD = 'http://www.w3.org/2001/XMLSchema';

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Metadata port
  // ─────────────────────────────────────────────────────────────
  private static MetadataPort port {
    get {
      if (port == null) {
        System.debug('CustomMetadataHelper: initializing MetadataPort...');
        port = new MetadataPort();
        port.endpoint_x =
          'https://' +
          DomainCreator.getOrgMyDomainHostname() +
          '/services/Soap/m/61.0';
        port.SessionHeader = new MetadataService.SessionHeader_element();
        port.SessionHeader.sessionId = UserInfo.getSessionId();
        System.debug('CustomMetadataHelper: MetadataPort ready.');
      }
      return port;
    }
    set;
  }

  // ─────────────────────────────────────────────────────────────
  // CREATE TYPE
  // ─────────────────────────────────────────────────────────────
  public static void createCustomMetadataType(Map<String, Object> args) {
    String apiName = getRequired(args, 'apiName');
    String label = getRequired(args, 'label');
    String pluralLabel = getRequired(args, 'pluralLabel');
    String description = getOptional(args, 'description', '');
    String visibility = getOptional(args, 'visibility', 'Public');

    // Ensure __mdt suffix
    String fullApiName = apiName.endsWith('__mdt')
      ? apiName
      : apiName + '__mdt';

    System.debug(
      'CustomMetadataHelper.createCustomMetadataType(): ' + fullApiName
    );

    String xml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<CustomObject xmlns="' +
      NAMESPACE +
      '">' +
      '<label>' +
      escapeXml(label) +
      '</label>' +
      '<pluralLabel>' +
      escapeXml(pluralLabel) +
      '</pluralLabel>' +
      (String.isNotBlank(description)
        ? '<description>' + escapeXml(description) + '</description>'
        : '') +
      '<visibility>' +
      escapeXml(visibility) +
      '</visibility>' +
      '</CustomObject>';

    String filePath = 'objects/' + fullApiName + '.object';
    ZipBuilder.addFile('CustomObject', fullApiName, filePath, xml);

    System.debug(
      'CustomMetadataHelper: type [' + fullApiName + '] staged for deploy'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // ADD FIELD TO TYPE
  // Same ZipBuilder-first pattern as CustomSettingHelper
  // After staging the field, auto-add it to the default page layout
  // ─────────────────────────────────────────────────────────────
  public static void addFieldToCustomMetadataType(Map<String, Object> args) {
    String apiName = getRequired(args, 'apiName');
    String fieldName = getRequired(args, 'fieldName');
    String fieldLabel = getRequired(args, 'fieldLabel');
    String fieldType = getRequired(args, 'fieldType');

    // Ensure __mdt suffix
    String fullApiName = apiName.endsWith('__mdt')
      ? apiName
      : apiName + '__mdt';
    String fullField = fieldName.endsWith('__c')
      ? fieldName
      : fieldName + '__c';

    System.debug(
      'CustomMetadataHelper.addFieldToCustomMetadataType(): ' +
        fullApiName +
        '.' +
        fullField
    );

    String filePath = 'objects/' + fullApiName + '.object';
    String stagedXml = ZipBuilder.files.get(filePath);

    List<String> existingFieldBlocks;
    if (String.isNotBlank(stagedXml)) {
      existingFieldBlocks = extractFieldBlocksFromXml(stagedXml);
    } else {
      existingFieldBlocks = readExistingFieldBlocks(fullApiName);
    }

    // Build new field block
    String newFieldBlock = buildFieldBlock(
      fullField,
      fieldLabel,
      fieldType,
      args
    );

    // Rebuild object XML with all fields
    String objectXml;
    if (String.isNotBlank(stagedXml)) {
      // Inject new field before closing tag
      objectXml = stagedXml.replace(
        '</CustomObject>',
        newFieldBlock + '</CustomObject>'
      );
    } else {
      // Read existing object metadata
      String existingObjectXml = readExistingObjectXml(fullApiName);
      if (String.isNotBlank(existingObjectXml)) {
        objectXml = existingObjectXml.replace(
          '</CustomObject>',
          newFieldBlock + '</CustomObject>'
        );
      } else {
        // Type doesn't exist yet or can't be read — build minimal wrapper
        objectXml =
          '<?xml version="1.0" encoding="UTF-8"?>' +
          '<CustomObject xmlns="' +
          NAMESPACE +
          '">' +
          newFieldBlock +
          '</CustomObject>';
      }
    }

    ZipBuilder.addFile('CustomObject', fullApiName, filePath, objectXml);
    System.debug(
      'CustomMetadataHelper: field [' +
        fullField +
        '] staged on [' +
        fullApiName +
        ']'
    );

    // ── Auto-add field to page layout ──────────────────────
    autoAddFieldToPageLayout(fullApiName, fullField);
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Auto-add a newly staged field to the default layout.
  //
  // Assumptions:
  //   - The CMDT already exists in the org (created in a previous deploy)
  //   - The default layout "{ObjectApiName}-{Label} Layout" exists
  //   - We're just adding a new field to an existing type
  //
  // Strategy:
  //   1. Resolve the label to derive the layout name
  //   2. Call PageLayoutHelper.addFieldsToLayout()
  //   3. If it fails (layout not found), log a warning
  //
  // For brand new CMDTs created in the same ticket as the field:
  //   - This will fail (layout doesn't exist yet)
  //   - That's OK — we accept this limitation
  //   - Solution: Create CMDT in one ticket, add fields in subsequent tickets
  // ─────────────────────────────────────────────────────────────
  private static void autoAddFieldToPageLayout(
    String fullApiName,
    String fieldName
  ) {
    System.debug(
      'CustomMetadataHelper.autoAddFieldToPageLayout(): ' +
        fullApiName +
        ' / ' +
        fieldName
    );
    try {
      // ── Resolve the label to derive the layout name ────
      String label = resolveLabelForLayoutName(fullApiName);
      String layoutName = label + ' Layout';

      System.debug(
        'CustomMetadataHelper.autoAddFieldToPageLayout(): ' +
          'layout name = [' +
          layoutName +
          ']'
      );

      // ── Add field to the layout ────────────────────────
      PageLayoutHelper.addFieldsToLayout(
        new Map<String, Object>{
          'objectApiName' => fullApiName,
          'layoutName' => layoutName,
          'sectionLabel' => 'Information',
          'fields' => '["' +
          fieldName +
          '"]'
        }
      );

      System.debug(
        'CustomMetadataHelper.autoAddFieldToPageLayout(): ' +
          'field [' +
          fieldName +
          '] added to layout [' +
          layoutName +
          ']. Done.'
      );
    } catch (Exception e) {
      // Non-fatal — field is already staged successfully
      // This will fail if CMDT + field were created in the same ticket
      // (layout doesn't exist yet)
      System.debug(
        'CustomMetadataHelper.autoAddFieldToPageLayout(): ' +
          'WARNING — could not update layout: ' +
          e.getMessage() +
          ' | This is expected if the CMDT was just created in the same deploy.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Resolve the label used to derive the layout name.
  //
  // Priority:
  //   1. Staged XML in ZipBuilder  — type created this session
  //   2. Org Metadata API          — type already deployed
  //   3. Fallback string           — strip __mdt, replace _ with space
  // ─────────────────────────────────────────────────────────────
  private static String resolveLabelForLayoutName(String fullApiName) {
    // ── 1. Check ZipBuilder for staged object XML ──────────
    String filePath = 'objects/' + fullApiName + '.object';
    String stagedXml = ZipBuilder.files.get(filePath);

    if (String.isNotBlank(stagedXml)) {
      String extracted = extractTagValue(stagedXml, 'label');
      if (String.isNotBlank(extracted)) {
        System.debug(
          'CustomMetadataHelper.resolveLabelForLayoutName(): ' +
            'label from staged XML = [' +
            extracted +
            ']'
        );
        return extracted;
      }
    }

    // ── 2. Read from org via Metadata API ─────────────────
    try {
      MetadataService.IReadResult readResult = port.readMetadata(
        'CustomObject',
        new List<String>{ fullApiName }
      );

      if (
        readResult != null &&
        readResult.getRecords() != null &&
        !readResult.getRecords().isEmpty() &&
        readResult.getRecords()[0] != null
      ) {
        MetadataService.CustomObject obj = (MetadataService.CustomObject) readResult.getRecords()[0];

        if (String.isNotBlank(obj.label)) {
          System.debug(
            'CustomMetadataHelper.resolveLabelForLayoutName(): ' +
              'label from org = [' +
              obj.label +
              ']'
          );
          return obj.label;
        }
      }
    } catch (Exception e) {
      System.debug(
        'CustomMetadataHelper.resolveLabelForLayoutName(): ' +
          'Metadata API read failed: ' +
          e.getMessage()
      );
    }

    // ── 3. Fallback — derive from API name ─────────────────
    String fallback = fullApiName.replace('__mdt', '').replace('_', ' ').trim();
    System.debug(
      'CustomMetadataHelper.resolveLabelForLayoutName(): ' +
        'using fallback label = [' +
        fallback +
        ']'
    );
    return fallback;
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Extract a tag value from an XML string
  // e.g. extractTagValue(xml, 'label') → "Testing"
  // ─────────────────────────────────────────────────────────────
  private static String extractTagValue(String xml, String tagName) {
    String open = '<' + tagName + '>';
    String close = '</' + tagName + '>';
    Integer start = xml.indexOf(open);
    if (start == -1) {
      return null;
    }
    Integer endPos = xml.indexOf(close, start);
    if (endPos == -1) {
      return null;
    }
    return xml.substring(start + open.length(), endPos).trim();
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Build field XML block
  // ─────────────────────────────────────────────────────────────
  private static String buildFieldBlock(
    String fieldName,
    String fieldLabel,
    String fieldType,
    Map<String, Object> args
  ) {
    String safeType = fieldType.capitalize();
    String xml =
      '<fields>' +
      '<fullName>' +
      escapeXml(fieldName) +
      '</fullName>' +
      '<label>' +
      escapeXml(fieldLabel) +
      '</label>' +
      '<type>' +
      escapeXml(safeType) +
      '</type>';

    if (safeType == 'Checkbox') {
      xml +=
        '<defaultValue>' +
        getOptional(args, 'defaultValue', 'false') +
        '</defaultValue>';
    } else if (safeType == 'Text' || safeType == 'Textarea') {
      Integer len = Integer.valueOf(getOptional(args, 'length', '255'));
      xml += '<length>' + len + '</length>';
    } else if (safeType == 'Longtextarea') {
      Integer len = Integer.valueOf(getOptional(args, 'length', '32768'));
      xml += '<length>' + len + '</length>' + '<visibleLines>3</visibleLines>';
    } else if (safeType == 'Number' || safeType == 'Percent') {
      Integer precision = Integer.valueOf(getOptional(args, 'precision', '18'));
      Integer scale = Integer.valueOf(getOptional(args, 'scale', '0'));
      xml +=
        '<precision>' +
        precision +
        '</precision>' +
        '<scale>' +
        scale +
        '</scale>';
    } else if (safeType == 'Picklist') {
      String picklistValues = getOptional(args, 'picklistValues', '');
      if (String.isNotBlank(picklistValues)) {
        xml += '<valueSet><valueSetDefinition>';
        for (String pv : picklistValues.split(',')) {
          String trimmed = pv.trim();
          xml +=
            '<value>' +
            '<fullName>' +
            escapeXml(trimmed) +
            '</fullName>' +
            '<default>false</default>' +
            '<label>' +
            escapeXml(trimmed) +
            '</label>' +
            '</value>';
        }
        xml += '</valueSetDefinition></valueSet>';
      }
    }

    String required = getOptional(args, 'required', 'false');
    if (safeType != 'Checkbox') {
      xml += '<required>' + required + '</required>';
    }

    xml += '</fields>';
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Read existing field blocks from staged XML
  // ─────────────────────────────────────────────────────────────
  private static List<String> extractFieldBlocksFromXml(String xml) {
    List<String> blocks = new List<String>();
    if (String.isBlank(xml)) {
      return blocks;
    }
    Integer searchFrom = 0;
    while (true) {
      Integer blockStart = xml.indexOf('<fields>', searchFrom);
      if (blockStart == -1) {
        break;
      }
      Integer blockEnd = xml.indexOf('</fields>', blockStart);
      if (blockEnd == -1) {
        break;
      }
      blockEnd += '</fields>'.length();
      blocks.add(xml.substring(blockStart, blockEnd));
      searchFrom = blockEnd;
    }
    return blocks;
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Read existing field blocks from org
  // ─────────────────────────────────────────────────────────────
  private static List<String> readExistingFieldBlocks(String fullApiName) {
    List<String> blocks = new List<String>();
    String xml = readExistingObjectXml(fullApiName);
    if (String.isNotBlank(xml)) {
      blocks = extractFieldBlocksFromXml(xml);
    }
    return blocks;
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Read existing object XML from org via Metadata API
  // ─────────────────────────────────────────────────────────────
  private static String readExistingObjectXml(String fullApiName) {
    try {
      MetadataService.IReadResult readResult = port.readMetadata(
        'CustomObject',
        new List<String>{ fullApiName }
      );

      if (
        readResult == null ||
        readResult.getRecords() == null ||
        readResult.getRecords().isEmpty() ||
        readResult.getRecords()[0] == null
      ) {
        return '';
      }

      MetadataService.CustomObject obj = (MetadataService.CustomObject) readResult.getRecords()[0];

      String label = String.isNotBlank(obj.label)
        ? obj.label
        : fullApiName.replace('__mdt', '');
      String pluralLabel = String.isNotBlank(obj.pluralLabel)
        ? obj.pluralLabel
        : label + 's';
      String description = String.isNotBlank(obj.description)
        ? obj.description
        : null;

      return '<?xml version="1.0" encoding="UTF-8"?>' +
        '<CustomObject xmlns="' +
        NAMESPACE +
        '">' +
        '<label>' +
        escapeXml(label) +
        '</label>' +
        '<pluralLabel>' +
        escapeXml(pluralLabel) +
        '</pluralLabel>' +
        (String.isNotBlank(description)
          ? '<description>' + escapeXml(description) + '</description>'
          : '') +
        '</CustomObject>';
    } catch (Exception e) {
      System.debug(
        'CustomMetadataHelper.readExistingObjectXml() failed: ' + e.getMessage()
      );
    }
    return '';
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Helpers
  // ─────────────────────────────────────────────────────────────
  private static String escapeXml(String val) {
    if (String.isBlank(val)) {
      return '';
    }
    return val.replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
      .replace('"', '&quot;')
      .replace('\'', '&apos;');
  }

  private static String getRequired(Map<String, Object> args, String key) {
    Object val = args?.get(key);
    if (val == null || String.isBlank(String.valueOf(val))) {
      throw new CustomMetadataException('Required parameter missing: ' + key);
    }
    return String.valueOf(val).trim();
  }

  private static String getOptional(
    Map<String, Object> args,
    String key,
    String defaultValue
  ) {
    Object val = args?.get(key);
    if (val == null) {
      return defaultValue;
    }
    String strVal = String.valueOf(val).trim();
    if (String.isBlank(strVal) || strVal == 'null') {
      return defaultValue;
    }
    return strVal;
  }

  public class CustomMetadataException extends Exception {
  }
}
