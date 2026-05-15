public class LLMLayoutHelper {
  // ─────────────────────────────────────────────────────────────
  // SCENARIO B VIOLATION DETECTOR
  // Logs when LLM adds a field to an existing object but omits
  // the matching Layout update. Detection only — no fix here.
  // ─────────────────────────────────────────────────────────────
  public static void detectScenarioBViolation(
    List<Object> files,
    Map<String, Object> orgState
  ) {
    if (orgState == null)
      return;
    Object rawExistingLayouts = orgState.get('existingLayouts');
    if (!(rawExistingLayouts instanceof Map<String, Object>))
      return;
    Map<String, Object> existingLayouts = (Map<String, Object>) rawExistingLayouts;
    if (existingLayouts.isEmpty())
      return;

    Object rawExistingObjects = orgState.get('existingObjects');
    Set<String> existingObjects = new Set<String>();
    if (rawExistingObjects instanceof List<Object>) {
      for (Object o : (List<Object>) rawExistingObjects) {
        if (o != null)
          existingObjects.add(String.valueOf(o));
      }
    }

    Set<String> objectsReceivingNewFields = new Set<String>();
    Set<String> objectsWithLayoutEmitted = new Set<String>();

    if (files != null) {
      for (Object rawFile : files) {
        Map<String, Object> file = (Map<String, Object>) rawFile;
        String metadataType = (String) file.get('metadataType');
        String memberName = (String) file.get('memberName');
        if (String.isBlank(metadataType) || String.isBlank(memberName))
          continue;

        if (
          metadataType == 'CustomObject' && existingObjects.contains(memberName)
        ) {
          objectsReceivingNewFields.add(memberName);
        } else if (metadataType == 'CustomField' && memberName.contains('.')) {
          String parent = memberName.substringBefore('.');
          if (existingObjects.contains(parent))
            objectsReceivingNewFields.add(parent);
        } else if (metadataType == 'Layout' && memberName.contains('-')) {
          String parent = memberName.substringBefore('-');
          objectsWithLayoutEmitted.add(parent);
        }
      }
    }

    for (String objName : objectsReceivingNewFields) {
      if (!existingLayouts.containsKey(objName))
        continue;
      if (objectsWithLayoutEmitted.contains(objName))
        continue;
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
  // Rebuilds layout XML from orgState sections + appends new fields
  // when LLM adds fields to an existing object but omits Layout.
  // ─────────────────────────────────────────────────────────────
  public static void backstopMissingFieldsInExistingLayouts(
    List<Object> files,
    Map<String, Object> orgState,
    Map<String, String> zip2Files,
    Map<String, Set<String>> zip2MetadataTypes
  ) {
    if (orgState == null)
      return;
    Object rawExistingLayouts = orgState.get('existingLayouts');
    if (!(rawExistingLayouts instanceof Map<String, Object>))
      return;
    Map<String, Object> existingLayouts = (Map<String, Object>) rawExistingLayouts;
    if (existingLayouts.isEmpty())
      return;

    Set<String> existingObjects = new Set<String>();
    Object rawExistingObjects = orgState.get('existingObjects');
    if (rawExistingObjects instanceof List<Object>) {
      for (Object o : (List<Object>) rawExistingObjects) {
        if (o != null)
          existingObjects.add(String.valueOf(o));
      }
    }

    Map<String, List<String>> newFieldsByObject = new Map<String, List<String>>();
    Set<String> objectsWithLayoutEmitted = new Set<String>();

    if (files != null) {
      for (Object rawFile : files) {
        Map<String, Object> f = (Map<String, Object>) rawFile;
        String mt = (String) f.get('metadataType');
        String mn = (String) f.get('memberName');
        if (String.isBlank(mt) || String.isBlank(mn))
          continue;

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

    for (String objName : newFieldsByObject.keySet()) {
      if (!existingLayouts.containsKey(objName))
        continue;
      if (objectsWithLayoutEmitted.contains(objName)) {
        System.debug(
          '[DEPLOY-TRACE] backstopB: Layout already emitted for [' +
            objName +
            '] — no injection needed'
        );
        continue;
      }

      List<String> newFields = newFieldsByObject.get(objName);
      if (newFields == null || newFields.isEmpty())
        continue;

      Object rawLayouts = existingLayouts.get(objName);
      if (!(rawLayouts instanceof List<Object>))
        continue;
      List<Object> layouts = (List<Object>) rawLayouts;
      if (layouts.isEmpty())
        continue;

      Map<String, Object> firstLayout = (Map<String, Object>) layouts[0];
      String layoutFullName = (String) firstLayout.get('fullName');
      if (String.isBlank(layoutFullName))
        continue;

      String layoutPath = 'layouts/' + layoutFullName + '.layout';
      if (zip2Files.containsKey(layoutPath)) {
        System.debug(
          '[DEPLOY-TRACE] backstopB: Layout already in zip2Files for [' +
            objName +
            '] — skipping'
        );
        continue;
      }

      String layoutXml = rebuildLayoutXmlWithNewFields(firstLayout, newFields);
      if (String.isBlank(layoutXml))
        continue;

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
  // Synthesizes a minimal default Layout for any new CustomObject
  // when the LLM forgot to emit one.
  // ─────────────────────────────────────────────────────────────
  public static void backstopMissingLayoutsForNewObjects(
    List<Object> files,
    Map<String, Object> orgState,
    Map<String, String> zip2Files,
    Map<String, Set<String>> zip2MetadataTypes
  ) {
    if (files == null || files.isEmpty())
      return;

    Set<String> existingObjects = new Set<String>();
    if (orgState != null) {
      Object raw = orgState.get('existingObjects');
      if (raw instanceof List<Object>) {
        for (Object o : (List<Object>) raw) {
          if (o != null)
            existingObjects.add(String.valueOf(o));
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
      if (String.isBlank(metadataType) || String.isBlank(memberName))
        continue;
      Boolean isCustomObj =
        memberName != null &&
        (memberName.endsWith('__c') || memberName.endsWith('__mdt'));
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
        System.debug(
          '[DEPLOY-TRACE] backstop: Layout already present for new object ' +
            objApi +
            ' — no synthesis needed'
        );
        continue;
      }

      List<Map<String, String>> fieldInfos = extractFieldInfosFromObjectXml(
        newObjectXml.get(objApi)
      );
      String objLabel = objApi.endsWith('__c')
        ? objApi.removeEnd('__c').replace('_', ' ')
        : objApi;
      String layoutMember = objApi + '-' + objLabel + ' Layout';
      String layoutPath = 'layouts/' + layoutMember + '.layout';
      String layoutXml = buildDefaultLayoutXml(fieldInfos);

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
    String fullName = (String) layoutStructure.get('fullName');
    Object rawSections = layoutStructure.get('sections');
    if (!(rawSections instanceof List<Object>))
      return null;
    List<Object> sections = (List<Object>) rawSections;

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
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // BUILD DEFAULT LAYOUT XML (minimal — just Name + all fields)
  // ─────────────────────────────────────────────────────────────
  public static String buildDefaultLayoutXml(
    List<Map<String, String>> fieldInfos
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
    s += '                <behavior>Required</behavior>\n';
    s += '                <field>Name</field>\n';
    s += '            </layoutItems>\n';
    if (fieldInfos != null) {
      for (Map<String, String> fi : fieldInfos) {
        String f = fi.get('name');
        String t = fi.get('type');
        if (String.isBlank(f))
          continue;
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
  // Returns list of {name, type} maps from <fields> blocks
  // ─────────────────────────────────────────────────────────────
  public static List<Map<String, String>> extractFieldInfosFromObjectXml(
    String customObjectXml
  ) {
    List<Map<String, String>> result = new List<Map<String, String>>();
    if (String.isBlank(customObjectXml))
      return result;
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
    if (!(raw instanceof List<Object>))
      return result;
    for (Object o : (List<Object>) raw) {
      if (o != null)
        result.add(String.valueOf(o));
    }
    return result;
  }
}
