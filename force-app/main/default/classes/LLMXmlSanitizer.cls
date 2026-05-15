public class LLMXmlSanitizer {
  // ── Safety constants ───────────────────────────────────────────
  private static final Set<String> STANDARD_OBJECTS = new Set<String>{
    'Account',
    'Case',
    'Contact',
    'Lead',
    'Opportunity',
    'Task',
    'Event',
    'Campaign',
    'Order',
    'Contract',
    'Asset',
    'Solution',
    'Product2',
    'Pricebook2',
    'User',
    'UserRole',
    'Group',
    'Territory',
    'Forecast',
    'ForecastingItem'
  };

  private static final Map<String, String> PROCESS_DRIVEN_OBJECTS = new Map<String, String>{
    'Case' => 'Case',
    'Lead' => 'Lead',
    'Opportunity' => 'Opportunity',
    'Solution' => 'Solution'
  };

  // ─────────────────────────────────────────────────────────────
  // XML VALIDATION
  // ─────────────────────────────────────────────────────────────
  public static String validateXml(
    String metadataType,
    String memberName,
    String xmlContent
  ) {
    if (String.isBlank(xmlContent)) {
      return 'xmlContent is empty';
    }

    try {
      Dom.Document doc = new Dom.Document();
      doc.load(xmlContent);
    } catch (Exception e) {
      ErrorLogger.log(e);
      return 'Malformed XML: ' + e.getMessage();
    }

    if (metadataType == 'CustomObject') {
      if (!memberName.endsWith('__c') && !memberName.endsWith('__mdt')) {
        if (xmlContent.contains('<nameField>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <nameField>';
        }
        if (xmlContent.contains('<sharingModel>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <sharingModel>';
        }
        if (xmlContent.contains('<pluralLabel>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <pluralLabel>';
        }
        return null;
      }

      if (memberName != null && memberName.endsWith('__mdt')) {
        if (xmlContent.contains('<customMetadataType>')) {
          return 'Invalid element <customMetadataType> — this tag does not exist in Salesforce Metadata API';
        }
        if (xmlContent.contains('<customSettingsType>')) {
          return 'Custom Metadata Type cannot contain <customSettingsType>';
        }
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<label>', '<pluralLabel>' }
        );
      }
      if (xmlContent.contains('<customSettingsType>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<label>', '<customSettingsType>' }
        );
      }
      return validateRequiredElements(
        xmlContent,
        new List<String>{
          '<label>',
          '<pluralLabel>',
          '<nameField>',
          '<sharingModel>'
        }
      );
    }

    if (metadataType == 'CustomField' || xmlContent.contains('<fields>')) {
      return validateRequiredElements(
        xmlContent,
        new List<String>{ '<fullName>', '<label>', '<type>' }
      );
    }

    if (metadataType == 'PermissionSet') {
      return validateRequiredElements(
        xmlContent,
        new List<String>{ '<label>' }
      );
    }

    if (metadataType == 'Profile') {
      return null;
    }

    if (metadataType == 'ValidationRule') {
      return validateRequiredElements(
        xmlContent,
        new List<String>{
          '<fullName>',
          '<active>',
          '<errorConditionFormula>',
          '<errorMessage>'
        }
      );
    }

    if (metadataType == 'CustomLabel' || metadataType == 'CustomLabels') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{ '<fullName>', '<value>' }
      );
      if (String.isNotBlank(baseError))
        return baseError;
      Set<String> seenNames = new Set<String>();
      Integer searchFrom = 0;
      while (true) {
        Integer fnStart = xmlContent.indexOf('<fullName>', searchFrom);
        if (fnStart == -1)
          break;
        Integer fnEnd = xmlContent.indexOf('</fullName>', fnStart);
        if (fnEnd == -1)
          break;
        String labelName = xmlContent.substring(
            fnStart + '<fullName>'.length(),
            fnEnd
          )
          .trim();
        if (seenNames.contains(labelName)) {
          return 'Duplicate <fullName> "' +
            labelName +
            '" found in CustomLabels XML — each label must appear only once. ' +
            'For translations use translations/{language}.translation instead.';
        }
        seenNames.add(labelName);
        searchFrom = fnEnd + '</fullName>'.length();
      }
      return null;
    }

    if (metadataType == 'NamedCredential') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{
          '<label>',
          '<endpoint>',
          '<protocol>',
          '<principalType>'
        }
      );
      if (String.isNotBlank(baseError))
        return baseError;

      if (xmlContent.contains('<principalType>Anonymous</principalType>')) {
        return 'Invalid principalType — Named Principal credentials must use NamedUser, not Anonymous';
      }
      if (xmlContent.contains('<developerName>')) {
        return 'Invalid element <developerName> inside AuthProvider XML — remove it, ' +
          'the file name IS the developerName identity';
      }

      if (xmlContent.contains('<protocol>Oauth</protocol>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<authProvider>', '<oauthScope>' }
        );
      }
      if (xmlContent.contains('<protocol>Password</protocol>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<username>', '<password>' }
        );
      }

      return null;
    }

    if (metadataType == 'AuthProvider') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{ '<friendlyName>', '<providerType>' }
      );
      if (String.isNotBlank(baseError))
        return baseError;

      if (xmlContent.contains('<fullName>')) {
        return 'Invalid element <fullName> inside AuthProvider XML — remove it, the file name is the identity';
      }
      if (xmlContent.contains('<developerName>')) {
        return 'Invalid element <developerName> inside AuthProvider XML — remove it, the file name IS the developerName';
      }

      if (xmlContent.contains('<tokenEndpointUrl>')) {
        return 'Invalid element <tokenEndpointUrl> — correct element name is <tokenUrl>';
      }
      if (xmlContent.contains('<authorizeEndpointUrl>')) {
        return 'Invalid element <authorizeEndpointUrl> — correct element name is <authorizeUrl>';
      }
      if (xmlContent.contains('<scope>')) {
        return 'Invalid element <scope> — correct element name is <defaultScopes>';
      }
      if (xmlContent.contains('<urlSuffix>')) {
        return 'Invalid element <urlSuffix> — this element does not exist in AuthProvider metadata XML';
      }

      Set<String> validTypes = new Set<String>{
        'Apple',
        'Bitbucket',
        'Confluence3LO',
        'Facebook',
        'GitHub',
        'Google',
        'Janrain',
        'LinkedIn',
        'Microsoft',
        'MicrosoftACS',
        'MuleSoft',
        'OpenIdConnect',
        'Salesforce',
        'Slack',
        'Twitter'
      };
      Pattern ptPat = Pattern.compile('<providerType>([^<]+)</providerType>');
      Matcher ptMat = ptPat.matcher(xmlContent);
      if (ptMat.find()) {
        String pt = ptMat.group(1).trim();
        if (!validTypes.contains(pt)) {
          return 'Invalid providerType [' +
            pt +
            ']. Valid values: ' +
            String.join(new List<String>(validTypes), ', ');
        }
        if (
          (pt == 'OpenIdConnect' || pt == 'MicrosoftACS') &&
          !xmlContent.contains('<authorizeUrl>')
        ) {
          return 'providerType ' +
            pt +
            ' requires <authorizeUrl> and <tokenUrl>';
        }
      }
      return null;
    }

    return null;
  }

  public static String validateRequiredElements(
    String xml,
    List<String> requiredElements
  ) {
    for (String element : requiredElements) {
      if (!xml.contains(element)) {
        return 'Missing required element: ' + element;
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTH PROVIDER XML SANITIZER
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeAuthProviderXml(String xml) {
    if (String.isBlank(xml))
      return xml;

    List<String> forbiddenTags = new List<String>{
      'developerName',
      'fullName',
      'urlSuffix'
    };
    for (String tag : forbiddenTags) {
      xml = xml.replaceAll('(?i)\\s*<' + tag + '>[^<]*</' + tag + '>', '');
    }

    xml = xml.replace('<tokenEndpointUrl>', '<tokenUrl>')
      .replace('</tokenEndpointUrl>', '</tokenUrl>')
      .replace('<authorizeEndpointUrl>', '<authorizeUrl>')
      .replace('</authorizeEndpointUrl>', '</authorizeUrl>')
      .replace('<scope>', '<defaultScopes>')
      .replace('</scope>', '</defaultScopes>');

    if (!xml.contains('<friendlyName>') && xml.contains('<name>')) {
      xml = xml.replace('<name>', '<friendlyName>')
        .replace('</name>', '</friendlyName>');
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD OBJECT XML SANITIZER
  // Strips: <nameField>, <pluralLabel>, <deploymentStatus>, <sharingModel>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeStandardObjectXml(String xml) {
    if (String.isBlank(xml))
      return xml;

    Integer removedCount = 0;
    List<String> forbiddenBlocks = new List<String>{
      'nameField',
      'pluralLabel',
      'deploymentStatus',
      'sharingModel'
    };

    for (String tag : forbiddenBlocks) {
      Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
      Matcher m = p.matcher(xml);
      String cleaned = m.replaceAll('');
      if (cleaned != xml) {
        removedCount++;
        xml = cleaned;
      }
    }

    if (removedCount > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeStandardObjectXml: removed ' +
          removedCount +
          ' forbidden element(s) from standard object XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // CUSTOM METADATA TYPE SANITIZER
  // Strips: <customSettingsType>, <customMetadataType>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeMdtObjectXml(String xml) {
    if (String.isBlank(xml))
      return xml;

    Integer removedCount = 0;
    List<String> forbiddenTags = new List<String>{
      'customSettingsType',
      'customMetadataType'
    };

    for (String tag : forbiddenTags) {
      Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
      Matcher m = p.matcher(xml);
      String cleaned = m.replaceAll('');
      if (cleaned != xml) {
        removedCount++;
        xml = cleaned;
      }
    }

    if (removedCount > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeMdtObjectXml: removed ' +
          removedCount +
          ' forbidden element(s) from __mdt object XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // PROFILE STANDARD-OBJECT TAB SANITIZER
  // Strips any <tabVisibilities> block whose <tab> does NOT end with __c
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileStandardObjectTabs(String xml) {
    if (String.isBlank(xml) || !xml.contains('<tabVisibilities>'))
      return xml;

    Pattern tvPat = Pattern.compile(
      '(?s)\\s*<tabVisibilities>\\s*<tab>([^<]+)</tab>.*?</tabVisibilities>'
    );
    Matcher m = tvPat.matcher(xml);

    List<String> toRemove = new List<String>();
    while (m.find()) {
      String tabName = m.group(1).trim();
      if (!tabName.endsWith('__c')) {
        toRemove.add(m.group(0));
        System.debug(
          '[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: ' +
            'removing tabVisibilities for standard object tab [' +
            tabName +
            ']'
        );
      }
    }

    for (String block : toRemove) {
      xml = xml.replace(block, '');
    }

    if (!toRemove.isEmpty()) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: removed ' +
          toRemove.size() +
          ' standard-object tabVisibilities block(s)'
      );
    }
    return xml;
  }

  // Remove unsupported Profile elements that LLM may emit.
  public static String sanitizeProfileXml(String xml) {
    if (String.isBlank(xml))
      return xml;
    if (!xml.contains('<cloneFrom>'))
      return xml;
    String cleaned = xml.replaceAll('(?s)\\s*<cloneFrom>.*?</cloneFrom>', '');
    System.debug(
      '[DEPLOY-TRACE] sanitizeProfileXml: removed unsupported <cloneFrom> element'
    );
    return cleaned;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-INJECT <businessProcess> FOR PROCESS-DRIVEN OBJECTS
  // ─────────────────────────────────────────────────────────────
  public static String injectBusinessProcessIfMissing(
    String xml,
    String memberName,
    Map<String, Object> orgState
  ) {
    if (String.isBlank(xml) || !xml.contains('<recordTypes>'))
      return xml;
    if (!PROCESS_DRIVEN_OBJECTS.containsKey(memberName))
      return xml;
    String tableEnumOrId = PROCESS_DRIVEN_OBJECTS.get(memberName);

    String bpName = null;
    Object rawBps = orgState != null
      ? orgState.get('existingBusinessProcesses')
      : null;
    if (rawBps != null) {
      try {
        Map<String, Object> bpMap = (Map<String, Object>) JSON.deserializeUntyped(
          JSON.serialize(rawBps)
        );
        Object bpListRaw = bpMap.get(tableEnumOrId);
        if (bpListRaw instanceof List<Object>) {
          List<Object> bpList = (List<Object>) bpListRaw;
          if (!bpList.isEmpty())
            bpName = String.valueOf(bpList[0]);
        }
      } catch (Exception e) {
        System.debug(
          '[DEPLOY-TRACE] injectBusinessProcess: failed to parse bps — ' +
          e.getMessage()
        );
      }
    }

    if (String.isBlank(bpName)) {
      System.debug(
        '[DEPLOY-TRACE] injectBusinessProcess: no Business Process found for [' +
          memberName +
          '] in orgState — deploy may fail'
      );
      return xml;
    }

    Pattern rtPat = Pattern.compile('(?s)<recordTypes>(.*?)</recordTypes>');
    Matcher rm = rtPat.matcher(xml);
    List<String> origBlocks = new List<String>();
    List<String> fixedBlocks = new List<String>();

    while (rm.find()) {
      String fullBlock = rm.group(0);
      if (fullBlock.contains('<businessProcess>'))
        continue;
      String fixedBlock = fullBlock.replace(
        '</active>',
        '</active> <businessProcess>' + bpName + '</businessProcess>'
      );
      origBlocks.add(fullBlock);
      fixedBlocks.add(fixedBlock);
      System.debug(
        '[DEPLOY-TRACE] injectBusinessProcess: injected [' +
          bpName +
          '] into ' +
          memberName +
          ' record type'
      );
    }

    for (Integer i = 0; i < origBlocks.size(); i++) {
      xml = xml.replace(origBlocks[i], fixedBlocks[i]);
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-PREFIX BARE LAYOUT NAMES IN PROFILE <layoutAssignments>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileLayoutAssignments(String xml) {
    if (String.isBlank(xml) || !xml.contains('<layoutAssignments>'))
      return xml;

    Map<String, String> objToLayout = new Map<String, String>();
    Pattern blockPat = Pattern.compile(
      '(?s)<layoutAssignments>(.*?)</layoutAssignments>'
    );
    Matcher bm = blockPat.matcher(xml);
    while (bm.find()) {
      String inner1 = bm.group(1);
      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner1);
      if (!rm.find())
        continue;
      String objName = rm.group(1).trim();
      Pattern lPat = Pattern.compile('<layout>([^<]+)</layout>');
      Matcher lm = lPat.matcher(inner1);
      if (!lm.find())
        continue;
      String layoutVal = lm.group(1).trim();
      if (layoutVal.contains('-')) {
        objToLayout.put(objName, layoutVal.substringBefore('-'));
      } else {
        objToLayout.put(objName, objName);
      }
    }

    bm = blockPat.matcher(xml);
    List<String> origBlocks = new List<String>();
    List<String> fixedBlocks = new List<String>();

    while (bm.find()) {
      String fullBlock = bm.group(0);
      String inner1 = bm.group(1);

      Pattern layoutPat = Pattern.compile('<layout>([^<]+)</layout>');
      Matcher lm = layoutPat.matcher(inner1);
      if (!lm.find())
        continue;
      String layoutVal = lm.group(1).trim();
      if (layoutVal.contains('-'))
        continue;

      String objName = null;

      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner1);
      if (rm.find()) {
        objName = rm.group(1).trim();
      }
      if (String.isBlank(objName) && layoutVal.contains(' ')) {
        objName = layoutVal.substringBefore(' ').trim();
      }
      if (String.isBlank(objName) && !objToLayout.isEmpty()) {
        objName = objToLayout.values()[0];
      }

      if (String.isBlank(objName))
        continue;

      String fixedLayout = objName + '-' + layoutVal;
      String fixedBlock = fullBlock.replace(
        '<layout>' + layoutVal + '</layout>',
        '<layout>' + fixedLayout + '</layout>'
      );
      origBlocks.add(fullBlock);
      fixedBlocks.add(fixedBlock);
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileLayoutAssignments: ' +
          layoutVal +
          ' -> ' +
          fixedLayout
      );
    }

    for (Integer i = 0; i < origBlocks.size(); i++) {
      xml = xml.replace(origBlocks[i], fixedBlocks[i]);
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-INJECT/CORRECT <--master--> recordTypeVisibilities
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileMasterRecordType(String xml) {
    if (String.isBlank(xml) || !xml.contains('<recordTypeVisibilities>'))
      return xml;

    Pattern masterEntryPat = Pattern.compile(
      '(?s)\\s*<recordTypeVisibilities>\\s*<recordType>[^<]+\\.Master</recordType>.*?</recordTypeVisibilities>'
    );
    Matcher mm = masterEntryPat.matcher(xml);
    while (mm.find()) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileMasterRecordType: removing bogus Master entry: ' +
        mm.group(0)
      );
      xml = xml.replace(mm.group(0), '');
      mm = masterEntryPat.matcher(xml);
    }

    Map<String, Boolean> objHasDefault = new Map<String, Boolean>();
    Map<String, String> objFirstBlock = new Map<String, String>();

    Pattern blockPat = Pattern.compile(
      '(?s)<recordTypeVisibilities>(.*?)</recordTypeVisibilities>'
    );
    Matcher bm = blockPat.matcher(xml);
    while (bm.find()) {
      String inner2 = bm.group(1);
      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner2);
      if (!rm.find())
        continue;
      String objName = rm.group(1).trim();
      Boolean isDef = inner2.contains('<default>true</default>');
      if (!objHasDefault.containsKey(objName)) {
        objHasDefault.put(objName, false);
        objFirstBlock.put(objName, bm.group(0));
      }
      if (isDef)
        objHasDefault.put(objName, true);
    }

    for (String objName : objHasDefault.keySet()) {
      if (!objHasDefault.get(objName)) {
        String firstBlock = objFirstBlock.get(objName);
        String fixedBlock = firstBlock.replace(
          '<default>false</default>',
          '<default>true</default>'
        );
        xml = xml.replace(firstBlock, fixedBlock);
        System.debug(
          '[DEPLOY-TRACE] sanitizeProfileMasterRecordType: promoted [' +
            objName +
            '] first RT to default=true (no default existed)'
        );
      }
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // LAYOUT XML SANITIZER
  // Strips <layoutItems> blocks with empty <field>/<behavior>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeLayoutXml(String xml) {
    if (String.isBlank(xml))
      return xml;
    if (!xml.contains('<layoutItems>'))
      return xml;

    String cleaned = xml;
    Integer removed = 0;
    Integer safety = 500;

    while (safety-- > 0) {
      Integer emptyBehaviorIdx = cleaned.indexOf('<behavior></behavior>');
      Integer emptyFieldIdx = cleaned.indexOf('<field></field>');
      Integer target = -1;
      if (
        emptyBehaviorIdx >= 0 &&
        (emptyFieldIdx < 0 ||
        emptyBehaviorIdx < emptyFieldIdx)
      ) {
        target = emptyBehaviorIdx;
      } else if (emptyFieldIdx >= 0) {
        target = emptyFieldIdx;
      }
      if (target < 0)
        break;

      Integer itemStart = cleaned.lastIndexOf('<layoutItems>', target);
      Integer itemEnd = cleaned.indexOf('</layoutItems>', target);
      if (itemStart < 0 || itemEnd < 0)
        break;
      itemEnd += '</layoutItems>'.length();

      cleaned = cleaned.substring(0, itemStart) + cleaned.substring(itemEnd);
      removed++;
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeLayoutXml: stripped ' +
          removed +
          ' broken <layoutItems> block(s) from Layout XML'
      );
    }
    return cleaned;
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD FIELD SANITIZER
  // Strips erroneous __c suffix from standard object field names
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeStandardFieldReferences(
    String apexCode,
    Map<String, Object> orgState
  ) {
    if (String.isBlank(apexCode) || orgState == null)
      return apexCode;

    Map<String, Object> existingFields = (Map<String, Object>) orgState.get(
      'existingFields'
    );
    if (existingFields == null || existingFields.isEmpty())
      return apexCode;

    String result = apexCode;

    for (String objectName : existingFields.keySet()) {
      if (objectName.endsWith('__c') || objectName.endsWith('__mdt'))
        continue;

      List<Object> rawFields = (List<Object>) existingFields.get(objectName);
      if (rawFields == null)
        continue;

      for (Object rawField : rawFields) {
        String fieldName = String.valueOf(rawField);
        if (fieldName.endsWith('__c'))
          continue;

        String wrongName = fieldName + '__c';
        if (result.containsIgnoreCase(wrongName)) {
          result = result.replaceAll(
            '(?i)\\b' + Pattern.quote(wrongName) + '\\b',
            fieldName
          );
          System.debug(
            'sanitizeStandardFieldReferences: replaced [' +
              wrongName +
              '] → [' +
              fieldName +
              '] on object [' +
              objectName +
              ']'
          );
        }
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // NORMALIZE TRANSLATION LANGUAGE CODE
  // ─────────────────────────────────────────────────────────────
  public static String normalizeTranslationLanguageCode(String lang) {
    if (String.isBlank(lang))
      return lang;
    if (!lang.contains('_'))
      return lang;
    Set<String> validCompound = new Set<String>{
      'pt_BR',
      'zh_CN',
      'zh_TW',
      'en_US',
      'en_GB',
      'nl_BE',
      'fr_CA',
      'nb_NO',
      'en_AU',
      'en_IN'
    };
    if (validCompound.contains(lang))
      return lang;
    return lang.substringBefore('_');
  }

  // ─────────────────────────────────────────────────────────────
  // SANITIZE CUSTOM LABELS XML
  // Strips non-en_US <labels> blocks, redirecting them to the
  // correct translations/{lang}.translation file via ZipBuilder.
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeCustomLabelsXml(String xml) {
    if (String.isBlank(xml))
      return xml;
    if (!xml.contains('<labels>'))
      return xml;

    Set<String> seenFullNames = new Set<String>();
    String sanitized = xml;
    Integer redirected = 0;
    Integer dropped = 0;
    Integer searchFrom = 0;
    Integer safety = 200;

    while (safety-- > 0) {
      Integer blockStart = sanitized.indexOf('<labels>', searchFrom);
      if (blockStart == -1)
        break;
      Integer blockEnd = sanitized.indexOf('</labels>', blockStart);
      if (blockEnd == -1)
        break;
      blockEnd += '</labels>'.length();

      String block = sanitized.substring(blockStart, blockEnd);

      Integer fnStart = block.indexOf('<fullName>') + '<fullName>'.length();
      Integer fnEnd = block.indexOf('</fullName>');
      String fullName = (fnStart >= '<fullName>'.length() &&
        fnEnd >= 0)
        ? block.substring(fnStart, fnEnd).trim()
        : '';

      Integer lStart = block.indexOf('<language>') + '<language>'.length();
      Integer lEnd = block.indexOf('</language>');
      String language = (lStart >= '<language>'.length() &&
        lEnd >= 0)
        ? block.substring(lStart, lEnd).trim()
        : 'en_US';

      Integer vStart = block.indexOf('<value>') + '<value>'.length();
      Integer vEnd = block.indexOf('</value>');
      String value = (vStart >= '<value>'.length() &&
        vEnd >= 0)
        ? block.substring(vStart, vEnd).trim()
        : '';

      Boolean isEnglish = (language == 'en_US' || language == 'en');
      Boolean isDuplicate = seenFullNames.contains(fullName);

      if (
        !isEnglish &&
        String.isNotBlank(fullName) &&
        String.isNotBlank(value)
      ) {
        String normalizedLang = normalizeTranslationLanguageCode(language);
        String tFilePath = 'translations/' + normalizedLang + '.translation';
        String existing = ZipBuilder.files.get(tFilePath);
        String tXml;
        if (String.isNotBlank(existing)) {
          tXml = existing.replace(
            '</Translations>',
            '    <customLabels>\n        <label>' +
              value +
              '</label>\n        <name>' +
              fullName +
              '</name>\n    </customLabels>\n</Translations>'
          );
        } else {
          tXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n' +
            '<Translations xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
            '    <customLabels>\n' +
            '        <label>' +
            value +
            '</label>\n' +
            '        <name>' +
            fullName +
            '</name>\n' +
            '    </customLabels>\n' +
            '</Translations>';
        }
        ZipBuilder.addFile('Translations', normalizedLang, tFilePath, tXml);
        System.debug(
          '[SANITIZE] sanitizeCustomLabelsXml: redirected label [' +
            fullName +
            '] lang=[' +
            language +
            '] -> ' +
            tFilePath
        );
        redirected++;
        sanitized =
          sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
      } else if (isDuplicate) {
        System.debug(
          '[SANITIZE] sanitizeCustomLabelsXml: dropped duplicate label [' +
            fullName +
            '] lang=[' +
            language +
            ']'
        );
        dropped++;
        sanitized =
          sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
      } else {
        if (String.isNotBlank(fullName))
          seenFullNames.add(fullName);
        searchFrom = blockEnd;
      }
    }

    if (redirected > 0 || dropped > 0) {
      System.debug(
        '[SANITIZE] sanitizeCustomLabelsXml: redirected=' +
          redirected +
          ' dropped=' +
          dropped +
          ' seenNames=' +
          seenFullNames
      );
    }
    return sanitized;
  }

  // ─────────────────────────────────────────────────────────────
  // APEX REGEX SANITIZER
  // Fixes illegal escape sequences LLM commonly emits in Apex code
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeApexRegex(String apexCode) {
    if (String.isBlank(apexCode))
      return apexCode;

    apexCode = apexCode.replace('\\+', '[+]');
    apexCode = apexCode.replace('\\d', '[0-9]');
    apexCode = apexCode.replace('\\s', '[ \\t\\n\\r]');
    apexCode = apexCode.replace('\\w', '[a-zA-Z0-9_]');
    apexCode = apexCode.replace('\\.', '[.]');

    Pattern pmPat = Pattern.compile(
      'Pattern[.]matches[(]([^,]+),\\s*([^)]+)[)]'
    );
    Matcher pmMatcher = pmPat.matcher(apexCode);
    apexCode = pmMatcher.replaceAll(
      'Pattern.compile($1).matcher($2).matches()'
    );

    return apexCode;
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD OBJECT LAYOUT GUARD
  // Returns true if this Layout memberName targets a standard object
  // ─────────────────────────────────────────────────────────────
  public static Boolean isStandardObjectLayout(String memberName) {
    if (String.isBlank(memberName) || !memberName.contains('-'))
      return false;
    String objPart = memberName.substringBefore('-');
    return STANDARD_OBJECTS.contains(objPart);
  }

  // ─────────────────────────────────────────────────────────────
  // APPEND DESTRUCTIVE MEMBER
  // Adds a single entry to destructiveChangesPost.xml in ZipBuilder
  // ─────────────────────────────────────────────────────────────
  public static void appendDestructiveMember(
    String metadataType,
    String memberName
  ) {
    String typeEsc = escapeXmlValue(metadataType);
    String memberEsc = escapeXmlValue(memberName);
    String existing = ZipBuilder.files.get('destructiveChangesPost.xml');

    String typeBlock =
      '\n    <types>' +
      '\n        <members>' +
      memberEsc +
      '</members>' +
      '\n        <name>' +
      typeEsc +
      '</name>' +
      '\n    </types>';

    String xml;
    if (String.isBlank(existing)) {
      xml =
        '<?xml version="1.0" encoding="UTF-8"?>' +
        '\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">' +
        typeBlock +
        '\n    <version>61.0</version>' +
        '\n</Package>';
    } else if (existing.contains('<version>')) {
      xml = existing.replace('<version>', typeBlock + '\n    <version>');
    } else if (existing.contains('</Package>')) {
      xml = existing.replace('</Package>', typeBlock + '\n</Package>');
    } else {
      xml = existing + typeBlock;
    }

    ZipBuilder.addFile(
      '__destructive__',
      memberName,
      'destructiveChangesPost.xml',
      xml
    );
  }

  public static String escapeXmlValue(String val) {
    if (String.isBlank(val))
      return '';
    return val.replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
      .replace('"', '&quot;')
      .replace('\'', '&apos;');
  }
}
