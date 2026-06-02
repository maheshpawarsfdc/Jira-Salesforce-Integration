public class LLMLayoutHelper {
  // ─────────────────────────────────────────────────────────────
  // SCENARIO B VIOLATION DETECTOR
  // ─────────────────────────────────────────────────────────────
  public static void detectScenarioBViolation(
    List<Object> files,
    Map<String, Object> orgState
  ) {
    if (orgState == null) {
      return;
    }
    Object rawExistingLayouts = orgState.get('existingLayouts');
    if (!(rawExistingLayouts instanceof Map<String, Object>)) {
      return;
    }
    Map<String, Object> existingLayouts = (Map<String, Object>) rawExistingLayouts;
    if (existingLayouts.isEmpty()) {
      return;
    }

    Object rawExistingObjects = orgState.get('existingObjects');
    Set<String> existingObjects = new Set<String>();
    if (rawExistingObjects instanceof List<Object>) {
      for (Object o : (List<Object>) rawExistingObjects) {
        if (o != null) {
          existingObjects.add(String.valueOf(o));
        }
      }
    }

    Set<String> objectsReceivingNewFields = new Set<String>();
    Set<String> objectsWithLayoutEmitted = new Set<String>();

    if (files != null) {
      for (Object rawFile : files) {
        Map<String, Object> file = (Map<String, Object>) rawFile;
        String metadataType = (String) file.get('metadataType');
        String memberName = (String) file.get('memberName');
        if (String.isBlank(metadataType) || String.isBlank(memberName)) {
          continue;
        }

        if (
          metadataType == 'CustomObject' && existingObjects.contains(memberName)
        ) {
          objectsReceivingNewFields.add(memberName);
        } else if (metadataType == 'CustomField' && memberName.contains('.')) {
          String parent = memberName.substringBefore('.');
          if (existingObjects.contains(parent)) {
            objectsReceivingNewFields.add(parent);
          }
        } else if (metadataType == 'Layout' && memberName.contains('-')) {
          String parent = memberName.substringBefore('-');
          objectsWithLayoutEmitted.add(parent);
        }
      }
    }

    for (String objName : objectsReceivingNewFields) {
      if (!existingLayouts.containsKey(objName)) {
        continue;
      }
      if (objectsWithLayoutEmitted.contains(objName)) {
        continue;
      }
      Object layoutsRaw = existingLayouts.get(objName);
      Integer layoutCount = (layoutsRaw instanceof List<Object>)
        ? ((List<Object>) layoutsRaw).size()
        : 0;
      System.debug(
        '[DEPLOY-TRACE] *** SCENARIO B VIOLATION *** object=' +
          objName +
          ' is in existingObjects with ' +
          layoutCount +
          ' existing layout(s),' +
          ' but the LLM emitted a CustomObject/CustomField without a matching Layout file.' +
          ' The new field will land in the palette only and will NOT appear in any layout section.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // SCENARIO B BACKSTOP
  // ─────────────────────────────────────────────────────────────
  public static void backstopMissingFieldsInExistingLayouts(
    List<Object> files,
    Map<String, Object> orgState,
    Map<String, String> zip2Files,
    Map<String, Set<String>> zip2MetadataTypes
  ) {
    if (orgState == null) {
      return;
    }
    Object rawExistingLayouts = orgState.get('existingLayouts');
    Map<String, Object> existingLayouts = (rawExistingLayouts instanceof Map<String, Object>)
      ? (Map<String, Object>) rawExistingLayouts
      : new Map<String, Object>();

    Set<String> existingObjects = new Set<String>();
    Object rawExistingObjects = orgState.get('existingObjects');
    if (rawExistingObjects instanceof List<Object>) {
      for (Object o : (List<Object>) rawExistingObjects) {
        if (o != null) {
          existingObjects.add(String.valueOf(o));
        }
      }
    }

    Map<String, List<String>> newFieldsByObject = new Map<String, List<String>>();
    Set<String> objectsWithLayoutEmitted = new Set<String>();

    if (files != null) {
      for (Object rawFile : files) {
        Map<String, Object> f = (Map<String, Object>) rawFile;
        String mt = (String) f.get('metadataType');
        String mn = (String) f.get('memberName');
        if (String.isBlank(mt) || String.isBlank(mn)) {
          continue;
        }

        if (mt == 'CustomObject' && existingObjects.contains(mn)) {
          List<Map<String, String>> infos = extractFieldInfosFromObjectXml(
            (String) f.get('xmlContent')
          );
          if (!infos.isEmpty()) {
            if (!newFieldsByObject.containsKey(mn)) {
              newFieldsByObject.put(mn, new List<String>());
            }
            for (Map<String, String> fi : infos) {
              newFieldsByObject.get(mn).add(fi.get('name'));
            }
          }
        } else if (mt == 'CustomField' && mn.contains('.')) {
          String parentObj = mn.substringBefore('.');
          String fieldName = mn.substringAfter('.');
          if (existingObjects.contains(parentObj)) {
            if (!newFieldsByObject.containsKey(parentObj)) {
              newFieldsByObject.put(parentObj, new List<String>());
            }
            newFieldsByObject.get(parentObj).add(fieldName);
          }
        } else if (mt == 'Layout' && mn.contains('-')) {
          objectsWithLayoutEmitted.add(mn.substringBefore('-'));
        }
      }
    }

    // On-demand layout name fetch for objects that have new fields but whose
    // layout names were not captured during runOrgCheck (e.g. Tooling API
    // callout timed out or returned empty).  A single batch call covers all
    // missing objects so we stay within the per-transaction callout limit.
    List<String> missingFromLayouts = new List<String>();
    for (String objName : newFieldsByObject.keySet()) {
      if (
        !existingLayouts.containsKey(objName) &&
        existingObjects.contains(objName)
      ) {
        missingFromLayouts.add(objName);
      }
    }
    if (!missingFromLayouts.isEmpty()) {
      try {
        Map<String, List<Map<String, Object>>> fetched = LLMOrgStateService.batchFetchLayoutNames(
          missingFromLayouts
        );
        for (String objName : fetched.keySet()) {
          existingLayouts.put(objName, (Object) fetched.get(objName));
          System.debug(
            '[DEPLOY-TRACE] backstopB: on-demand layout fetch succeeded for [' +
              objName +
              ']'
          );
        }
      } catch (Exception ex) {
        System.debug(
          '[DEPLOY-TRACE] backstopB: on-demand layout fetch failed — ' +
          ex.getMessage()
        );
      }
    }

    for (String objName : newFieldsByObject.keySet()) {
      if (!existingLayouts.containsKey(objName)) {
        continue;
      }
      // Do NOT skip when the LLM already emitted a Layout.
      // mergeLayoutForExistingObject only adds fields present in the LLM's
      // own layout XML — if the LLM's layout doesn't reference the new
      // custom fields (common), they are silently omitted from ZIP1.
      // The backstop's ZIP2 rebuild is always authoritative: it derives
      // from the live org layout + the new field list, so it is correct
      // even when ZIP1's layout was incomplete.

      List<String> newFields = newFieldsByObject.get(objName);
      if (newFields == null || newFields.isEmpty()) {
        continue;
      }

      Object rawLayouts = existingLayouts.get(objName);
      if (!(rawLayouts instanceof List<Object>)) {
        continue;
      }
      List<Object> layouts = (List<Object>) rawLayouts;
      if (layouts.isEmpty()) {
        continue;
      }

      Map<String, Object> firstLayout = (Map<String, Object>) layouts[0];
      String layoutFullName = (String) firstLayout.get('fullName');
      if (String.isBlank(layoutFullName)) {
        continue;
      }

      String layoutPath = 'layouts/' + layoutFullName + '.layout';
      if (zip2Files.containsKey(layoutPath)) {
        System.debug(
          '[DEPLOY-TRACE] backstopB: Layout already in zip2Files for [' +
            objName +
            '] — skipping'
        );
        continue;
      }

      // ── Fetch layout structure if sections are missing ────────
      // batchFetchLayoutNames only fetches layout names, not sections.
      // rebuildLayoutXmlWithNewFields needs sections to preserve existing
      // fields and behaviors (especially Name = Required).
      // If sections are missing, fetch structure now via Metadata API.
      if (
        !firstLayout.containsKey('sections') ||
        firstLayout.get('sections') == null
      ) {
        System.debug(
          '[DEPLOY-TRACE] backstopB: sections missing for [' +
            layoutFullName +
            '] — fetching structure via Metadata API'
        );
        Map<String, Object> structure = LLMOrgStateService.getLayoutStructure(
          layoutFullName
        );
        if (structure != null) {
          firstLayout = structure;
          System.debug(
            '[DEPLOY-TRACE] backstopB: structure fetched for [' +
              layoutFullName +
              ']'
          );
        } else {
          String layoutId = (String) firstLayout.get('id');
          Map<String, Object> toolingStructure = String.isNotBlank(layoutId)
            ? LLMOrgStateService.getLayoutStructureViaToolingId(layoutId)
            : null;
          if (toolingStructure != null) {
            firstLayout = toolingStructure;
            System.debug(
              '[DEPLOY-TRACE] backstopB: Tooling API fallback succeeded for [' +
                layoutFullName +
                ']'
            );
          } else {
            System.debug(
              '[DEPLOY-TRACE] backstopB: all layout structure fetches failed for [' +
                layoutFullName +
                '] — skipping to preserve existing layout fields'
            );
            continue;
          }
        }
      }

      String layoutXml = rebuildLayoutXmlWithNewFields(firstLayout, newFields);
      if (String.isBlank(layoutXml)) {
        continue;
      }

      zip2Files.put(layoutPath, layoutXml);
      if (!zip2MetadataTypes.containsKey('Layout')) {
        zip2MetadataTypes.put('Layout', new Set<String>());
      }
      zip2MetadataTypes.get('Layout').add(layoutFullName);

      System.debug(
        '[DEPLOY-TRACE] *** SCENARIO B BACKSTOP FIRED *** object=' +
          objName +
          ' | LLM omitted Layout — appending ' +
          newFields.size() +
          ' field(s) to [' +
          layoutFullName +
          '] via zip2Files'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // SCENARIO A BACKSTOP
  // ─────────────────────────────────────────────────────────────
  public static void backstopMissingLayoutsForNewObjects(
    List<Object> files,
    Map<String, Object> orgState,
    Map<String, String> zip2Files,
    Map<String, Set<String>> zip2MetadataTypes
  ) {
    if (files == null || files.isEmpty()) {
      return;
    }

    Set<String> existingObjects = new Set<String>();
    if (orgState != null) {
      Object raw = orgState.get('existingObjects');
      if (raw instanceof List<Object>) {
        for (Object o : (List<Object>) raw) {
          if (o != null) {
            existingObjects.add(String.valueOf(o));
          }
        }
      }
    }

    Map<String, String> newObjectXml = new Map<String, String>();
    Set<String> objectsWithLayout = new Set<String>();

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String xmlContent = (String) file.get('xmlContent');
      if (String.isBlank(metadataType) || String.isBlank(memberName)) {
        continue;
      }
      Boolean isCustomObj = memberName != null && (memberName.endsWith('__c'));
      if (
        metadataType == 'CustomObject' &&
        isCustomObj &&
        !existingObjects.contains(memberName)
      ) {
        newObjectXml.put(memberName, xmlContent);
      } else if (metadataType == 'Layout' && memberName.contains('-')) {
        objectsWithLayout.add(memberName.substringBefore('-'));
      }
    }

    for (String objApi : newObjectXml.keySet()) {
      if (objectsWithLayout.contains(objApi)) {
        Boolean alreadyInZip2 = false;
        for (String k : zip2Files.keySet()) {
          if (k.startsWith('layouts/' + objApi + '-')) {
            alreadyInZip2 = true;
            break;
          }
        }
        if (alreadyInZip2) {
          System.debug(
            '[DEPLOY-TRACE] backstop: Layout already in zip2Files for new object [' +
              objApi +
              '] — no synthesis needed'
          );
          continue;
        }
        System.debug(
          '[DEPLOY-TRACE] *** BACKSTOP SCENARIO-2 RESCUE *** Layout was emitted for [' +
            objApi +
            '] but is not in zip2Files — scenario override may have misfired.' +
            ' Synthesizing backstop layout for zip2.'
        );
      }

      List<Map<String, String>> fieldInfos = extractFieldInfosFromObjectXml(
        newObjectXml.get(objApi)
      );
      String objLabel = objApi.endsWith('__c')
        ? objApi.removeEnd('__c').replace('_', ' ')
        : objApi.endsWith('__mdt')
            ? objApi.removeEnd('__mdt').replace('_', ' ')
            : objApi;
      String layoutMember = objApi + '-' + objLabel + ' Layout';
      String layoutPath = 'layouts/' + layoutMember + '.layout';
      String layoutXml = buildDefaultLayoutXml(fieldInfos, objApi);

      zip2Files.put(layoutPath, layoutXml);
      if (!zip2MetadataTypes.containsKey('Layout')) {
        zip2MetadataTypes.put('Layout', new Set<String>());
      }
      zip2MetadataTypes.get('Layout').add(layoutMember);

      System.debug(
        '[DEPLOY-TRACE] *** SCENARIO A BACKSTOP FIRED *** object=' +
          objApi +
          ' | LLM omitted Layout — synthesized default with ' +
          fieldInfos.size() +
          ' field(s) | path=' +
          layoutPath +
          ' | layoutMember=' +
          layoutMember
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // REBUILD LAYOUT XML WITH NEW FIELDS
  // ─────────────────────────────────────────────────────────────
  public static String rebuildLayoutXmlWithNewFields(
    Map<String, Object> layoutStructure,
    List<String> newFields
  ) {
    //String fullName = (String) layoutStructure.get('fullName');
    Object rawSections = layoutStructure.get('sections');
    if (!(rawSections instanceof List<Object>)) {
      return null;
    }
    List<Object> sections = (List<Object>) rawSections;

    Set<String> alreadyOnLayout = new Set<String>();
    for (Object rawSecScan : sections) {
      Map<String, Object> secScan = (Map<String, Object>) rawSecScan;
      for (String f : toStringList(secScan.get('leftFields'))) {
        alreadyOnLayout.add(f.toLowerCase());
      }
      for (String f : toStringList(secScan.get('rightFields'))) {
        alreadyOnLayout.add(f.toLowerCase());
      }
    }
    List<String> filteredNew = new List<String>();
    for (String f : newFields) {
      if (!alreadyOnLayout.contains(f.toLowerCase())) {
        filteredNew.add(f);
      }
    }
    newFields = filteredNew;

    String xml =
      '<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';

    Boolean injected = false;
    for (Object rawSec : sections) {
      Map<String, Object> sec = (Map<String, Object>) rawSec;
      String label = (String) sec.get('label');

      List<String> leftFields = toStringList(sec.get('leftFields'));
      List<String> leftBehaviors = toStringList(sec.get('leftBehaviors'));
      List<String> rightFields = toStringList(sec.get('rightFields'));
      List<String> rightBehaviors = toStringList(sec.get('rightBehaviors'));

      if (!injected && label == 'Information') {
        // Ensure Name field is present at the start of Information section (Salesforce requirement)
        Boolean nameAlreadyPresent = false;
        for (String f : leftFields) {
          if ('Name'.equalsIgnoreCase(f)) {
            nameAlreadyPresent = true;
            break;
          }
        }
        if (!nameAlreadyPresent) {
          for (String f : rightFields) {
            if ('Name'.equalsIgnoreCase(f)) {
              nameAlreadyPresent = true;
              break;
            }
          }
        }
        if (!nameAlreadyPresent) {
          leftFields.add(0, 'Name');
          leftBehaviors.add(0, 'Edit'); // Will be corrected below based on object type
        }

        for (String f : newFields) {
          Integer total = leftFields.size() + rightFields.size();
          if (Math.mod(total, 2) == 0) {
            leftFields.add(f);
            leftBehaviors.add('Edit');
          } else {
            rightFields.add(f);
            rightBehaviors.add('Edit');
          }
        }
        injected = true;
      }

      xml +=
        '    <layoutSections>\n' +
        '        <customLabel>true</customLabel>\n' +
        '        <detailHeading>true</detailHeading>\n' +
        '        <editHeading>true</editHeading>\n' +
        '        <label>' +
        label +
        '</label>\n' +
        '        <layoutColumns>\n';

      for (Integer i = 0; i < leftFields.size(); i++) {
        String beh = (i < leftBehaviors.size()) ? leftBehaviors[i] : 'Edit';
        xml +=
          '            <layoutItems>\n' +
          '                <behavior>' +
          beh +
          '</behavior>\n' +
          '                <field>' +
          leftFields[i] +
          '</field>\n' +
          '            </layoutItems>\n';
      }

      xml += '        </layoutColumns>\n' + '        <layoutColumns>\n';

      for (Integer i = 0; i < rightFields.size(); i++) {
        String beh = (i < rightBehaviors.size()) ? rightBehaviors[i] : 'Edit';
        xml +=
          '            <layoutItems>\n' +
          '                <behavior>' +
          beh +
          '</behavior>\n' +
          '                <field>' +
          rightFields[i] +
          '</field>\n' +
          '            </layoutItems>\n';
      }

      xml +=
        '        </layoutColumns>\n' +
        '        <style>TwoColumnsTopToBottom</style>\n' +
        '    </layoutSections>\n';
    }

    if (!injected && !newFields.isEmpty()) {
      xml +=
        '    <layoutSections>\n' +
        '        <customLabel>true</customLabel>\n' +
        '        <detailHeading>true</detailHeading>\n' +
        '        <editHeading>true</editHeading>\n' +
        '        <label>Information</label>\n' +
        '        <layoutColumns>\n';
      for (String f : newFields) {
        xml +=
          '            <layoutItems>\n' +
          '                <behavior>Edit</behavior>\n' +
          '                <field>' +
          f +
          '</field>\n' +
          '            </layoutItems>\n';
      }
      xml +=
        '        </layoutColumns>\n' +
        '        <layoutColumns/>\n' +
        '        <style>TwoColumnsTopToBottom</style>\n' +
        '    </layoutSections>\n';
    }

    xml += '</Layout>';

    // Fix Name field behavior per object's nameField type before returning
    // (AutoNumber → Readonly, Text → Required)
    String fullName = (String) layoutStructure.get('fullName');
    if (String.isNotBlank(fullName) && fullName.contains('-')) {
      try {
        String parentObj = fullName.substringBefore('-');
        String nameFieldType = resolveNameFieldType(parentObj);
        xml = LLMXmlSanitizer.fixNameFieldBehaviorInLayout(xml, nameFieldType);
      } catch (Exception ex) {
        System.debug(
          '[DEPLOY-TRACE] rebuildLayoutXmlWithNewFields: could not fix Name behavior: ' +
          ex.getMessage()
        );
      }
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // BUILD DEFAULT LAYOUT XML
  // ─────────────────────────────────────────────────────────────
  public static String buildDefaultLayoutXml(
    List<Map<String, String>> fieldInfos
  ) {
    return buildDefaultLayoutXml(fieldInfos, null);
  }

  public static String buildDefaultLayoutXml(
    List<Map<String, String>> fieldInfos,
    String objectApiName
  ) {
    String s = '<?xml version="1.0" encoding="UTF-8"?>\n';
    s += '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';
    s += '    <layoutSections>\n';
    s += '        <customLabel>true</customLabel>\n';
    s += '        <detailHeading>true</detailHeading>\n';
    s += '        <editHeading>true</editHeading>\n';
    s += '        <label>Information</label>\n';
    s += '        <layoutColumns>\n';
    s += '            <layoutItems>\n';

    // Determine correct Name field behavior based on object's nameField type
    String nameBehavior = 'Edit';
    if (String.isNotBlank(objectApiName)) {
      try {
        String nameFieldType = LLMOrgStateService.getObjectNameFieldType(
          objectApiName
        );
        nameBehavior = 'AutoNumber'.equalsIgnoreCase(nameFieldType)
          ? 'Readonly'
          : 'Required';
      } catch (Exception ex) {
        System.debug(
          '[DEPLOY-TRACE] buildDefaultLayoutXml: could not determine Name behavior: ' +
          ex.getMessage()
        );
      }
    }

    s += '                <behavior>' + nameBehavior + '</behavior>\n';
    s += '                <field>Name</field>\n';
    s += '            </layoutItems>\n';
    if (fieldInfos != null) {
      for (Map<String, String> fi : fieldInfos) {
        String f = fi.get('name');
        String t = fi.get('type');
        if (String.isBlank(f)) {
          continue;
        }
        String behavior = (t == 'MasterDetail') ? 'Required' : 'Edit';
        s += '            <layoutItems>\n';
        s += '                <behavior>' + behavior + '</behavior>\n';
        s += '                <field>' + f + '</field>\n';
        s += '            </layoutItems>\n';
      }
    }
    s += '        </layoutColumns>\n';
    s += '        <layoutColumns/>\n';
    s += '        <style>TwoColumnsTopToBottom</style>\n';
    s += '    </layoutSections>\n';
    s += '</Layout>';
    return s;
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT FIELD INFOS FROM OBJECT XML
  // ─────────────────────────────────────────────────────────────
  public static List<Map<String, String>> extractFieldInfosFromObjectXml(
    String customObjectXml
  ) {
    List<Map<String, String>> result = new List<Map<String, String>>();
    if (String.isBlank(customObjectXml)) {
      return result;
    }
    Pattern fieldsBlock = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Matcher fbm = fieldsBlock.matcher(customObjectXml);
    Pattern fnPat = Pattern.compile('<fullName>([^<]+)</fullName>');
    Pattern typePat = Pattern.compile('<type>([^<]+)</type>');
    while (fbm.find()) {
      String block = fbm.group(1);
      Matcher fnm = fnPat.matcher(block);
      if (fnm.find()) {
        Matcher tym = typePat.matcher(block);
        String fieldType = tym.find() ? tym.group(1) : 'Text';
        result.add(
          new Map<String, String>{ 'name' => fnm.group(1), 'type' => fieldType }
        );
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // UTILITY — Convert Object list to String list
  // ─────────────────────────────────────────────────────────────
  public static List<String> toStringList(Object raw) {
    List<String> result = new List<String>();
    if (!(raw instanceof List<Object>)) {
      return result;
    }
    for (Object o : (List<Object>) raw) {
      if (o != null) {
        result.add(String.valueOf(o));
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // BUILD SAFE LAYOUT XML WITH FIELDS
  // ─────────────────────────────────────────────────────────────
  private static String buildSafeLayoutXmlWithFields(List<String> newFields) {
    String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
    xml += '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\n';
    xml += '    <layoutSections>\n';
    xml += '        <customLabel>true</customLabel>\n';
    xml += '        <detailHeading>true</detailHeading>\n';
    xml += '        <editHeading>true</editHeading>\n';
    xml += '        <label>Information</label>\n';
    xml += '        <layoutColumns>\n';
    xml += '            <layoutItems>\n';
    xml += '                <behavior>Required</behavior>\n';
    xml += '                <field>Name</field>\n';
    xml += '            </layoutItems>\n';
    for (String f : newFields) {
      xml += '            <layoutItems>\n';
      xml += '                <behavior>Edit</behavior>\n';
      xml += '                <field>' + f + '</field>\n';
      xml += '            </layoutItems>\n';
    }
    xml += '        </layoutColumns>\n';
    xml += '        <layoutColumns/>\n';
    xml += '        <style>TwoColumnsTopToBottom</style>\n';
    xml += '    </layoutSections>\n';
    xml += '</Layout>';
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // MERGE LLM LAYOUT WITH EXISTING LAYOUT
  // ─────────────────────────────────────────────────────────────
  public static String mergeLayoutForExistingObject(
    String layoutFullName,
    String llmLayoutXml
  ) {
    return mergeLayoutForExistingObject(layoutFullName, llmLayoutXml, null);
  }

  public static String mergeLayoutForExistingObject(
    String layoutFullName,
    String llmLayoutXml,
    List<String> requiredAdditionalFields
  ) {
    Map<String, Object> existingStructure = LLMOrgStateService.getLayoutStructure(
      layoutFullName
    );
    if (existingStructure == null) {
      System.debug(
        '[DEPLOY-TRACE] mergeLayoutForExistingObject: cannot fetch [' +
          layoutFullName +
          '] — returning null for caller fallback'
      );
      return null;
    }

    List<String> llmFields = extractFieldNamesFromLayoutXml(llmLayoutXml);

    Set<String> existingFieldNames = new Set<String>();
    Object rawSections = existingStructure.get('sections');
    if (rawSections instanceof List<Object>) {
      for (Object rawSec : (List<Object>) rawSections) {
        Map<String, Object> sec = (Map<String, Object>) rawSec;
        for (String f : toStringList(sec.get('leftFields'))) {
          existingFieldNames.add(f.toLowerCase());
        }
        for (String f : toStringList(sec.get('rightFields'))) {
          existingFieldNames.add(f.toLowerCase());
        }
      }
    }

    List<String> newFields = new List<String>();
    for (String f : llmFields) {
      if (!existingFieldNames.contains(f.toLowerCase())) {
        newFields.add(f);
      }
    }
    if (requiredAdditionalFields != null) {
      Set<String> dedupe = new Set<String>();
      for (String f : newFields) {
        dedupe.add(f.toLowerCase());
      }
      for (String f : requiredAdditionalFields) {
        if (
          !existingFieldNames.contains(f.toLowerCase()) &&
          !dedupe.contains(f.toLowerCase())
        ) {
          newFields.add(f);
          dedupe.add(f.toLowerCase());
        }
      }
    }

    System.debug(
      '[DEPLOY-TRACE] mergeLayoutForExistingObject: [' +
        layoutFullName +
        '] existing=' +
        existingFieldNames.size() +
        ' llmFields=' +
        llmFields.size() +
        ' newFields=' +
        newFields
    );

    return rebuildLayoutXmlWithNewFields(existingStructure, newFields);
  }

  // ─────────────────────────────────────────────────────────────
  // INJECT NEW FIELDS INTO EXISTING LAYOUT XML
  // ─────────────────────────────────────────────────────────────
  public static String injectNewFieldsIntoLayoutXml(
    String layoutXml,
    List<String> fieldsToAdd
  ) {
    if (
      String.isBlank(layoutXml) ||
      fieldsToAdd == null ||
      fieldsToAdd.isEmpty()
    ) {
      return layoutXml;
    }

    Set<String> alreadyPresent = new Set<String>();
    Pattern fp = Pattern.compile('<field>([^<]+)</field>');
    Matcher fm = fp.matcher(layoutXml);
    while (fm.find()) {
      alreadyPresent.add(fm.group(1).trim().toLowerCase());
    }

    List<String> missing = new List<String>();
    for (String f : fieldsToAdd) {
      if (!alreadyPresent.contains(f.toLowerCase())) {
        missing.add(f);
      }
    }
    if (missing.isEmpty()) {
      return layoutXml;
    }

    String injection = '';
    for (String f : missing) {
      injection +=
        '\n            <layoutItems>' +
        '\n                <behavior>Edit</behavior>' +
        '\n                <field>' +
        f +
        '</field>' +
        '\n            </layoutItems>';
    }

    Integer pos = layoutXml.indexOf('</layoutColumns>');
    if (pos < 0) {
      return layoutXml;
    }

    System.debug(
      '[DEPLOY-TRACE] injectNewFieldsIntoLayoutXml: injecting ' +
        missing +
        ' into layout XML'
    );
    return layoutXml.substring(0, pos) +
      injection +
      '\n        ' +
      layoutXml.substring(pos);
  }

  public static List<String> extractFieldNamesFromLayoutXml(String xml) {
    List<String> fields = new List<String>();
    if (String.isBlank(xml)) {
      return fields;
    }
    Pattern fieldPat = Pattern.compile('<field>([^<]+)</field>');
    Matcher m = fieldPat.matcher(xml);
    while (m.find()) {
      String fname = m.group(1).trim();
      if (String.isNotBlank(fname)) {
        fields.add(fname);
      }
    }
    return fields;
  }
  // ─────────────────────────────────────────────────────────────
  // RESOLVE NAME FIELD TYPE
  // Checks ZipBuilder first (for new objects in same deploy),
  // then falls back to org query (for existing objects).
  // ─────────────────────────────────────────────────────────────
  public static String resolveNameFieldType(String objectApiName) {
    if (String.isBlank(objectApiName)) {
      return 'Text';
    }
    // 1. New object being created in this same deploy — read from ZIP
    String objectFilePath = 'objects/' + objectApiName + '.object';
    String objectXml = ZipBuilder.files.get(objectFilePath);
    if (String.isNotBlank(objectXml) && objectXml.contains('<nameField>')) {
      Integer nfStart = objectXml.indexOf('<nameField>');
      Integer nfEnd = objectXml.indexOf('</nameField>');
      if (nfStart >= 0 && nfEnd > nfStart) {
        String nameFieldBlock = objectXml.substring(nfStart, nfEnd);
        Integer tStart = nameFieldBlock.indexOf('<type>') + '<type>'.length();
        Integer tEnd = nameFieldBlock.indexOf('</type>');
        if (tStart >= '<type>'.length() && tEnd > tStart) {
          String type = nameFieldBlock.substring(tStart, tEnd).trim();
          System.debug(
            '[DEPLOY-TRACE] resolveNameFieldType: [' +
              objectApiName +
              '] read from ZIP type=' +
              type
          );
          return type;
        }
      }
    }
    // 2. Existing object — query org
    return LLMOrgStateService.getObjectNameFieldType(objectApiName);
  }
}
