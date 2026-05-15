public class LLMOrgStateService {
  // ── METADATA PORT (lazy-init) ──────────────────────────────────
  private static MetadataPort metaPort {
    get {
      if (metaPort == null) {
        System.debug('LLMOrgStateService: initializing MetadataPort...');
        metaPort = new MetadataPort();
        metaPort.endpoint_x =
          'https://' +
          DomainCreator.getOrgMyDomainHostname() +
          '/services/Soap/m/61.0';
        metaPort.SessionHeader = new MetadataService.SessionHeader_element();
        metaPort.SessionHeader.sessionId = getMetadataSessionId();
        System.debug('LLMOrgStateService: MetadataPort ready.');
      }
      return metaPort;
    }
    set;
  }

  // ─────────────────────────────────────────────────────────────
  // METADATA SESSION ID
  // ─────────────────────────────────────────────────────────────
  public static String getMetadataSessionId() {
    if (Test.isRunningTest())
      return UserInfo.getSessionId();
    try {
      PageReference vfPage = Page.SessionId;
      String content = vfPage.getContent().toString();
      Integer s =
        content.indexOf('Start_Of_Session_Id') + 'Start_Of_Session_Id'.length();
      Integer e = content.indexOf('End_Of_Session_Id');
      return content.substring(s, e);
    } catch (Exception ex) {
      ErrorLogger.log(ex);
      return UserInfo.getSessionId();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // LIGHTWEIGHT ORG CHECK
  // Reads existing fields, layouts, queues, labels, triggers, LWC
  // so XML generation stage knows what already exists in the org.
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> runOrgCheck(
    String summary,
    String description
  ) {
    Map<String, Object> orgState = new Map<String, Object>();
    Map<String, Object> sharingModels = new Map<String, Object>();
    Map<String, Object> existingFields = new Map<String, Object>();
    List<String> existingObjects = new List<String>();

    try {
      for (Schema.SObjectType objType : Schema.getGlobalDescribe().values()) {
        Schema.DescribeSObjectResult describe = objType.getDescribe();
        if (!describe.isCustom())
          continue;

        String apiName = describe.getName();

        String ticketText = (summary + ' ' + description).toLowerCase();
        String objShortName = apiName.replace('__c', '')
          .replace('_', '')
          .toLowerCase();
        if (
          !ticketText.contains(objShortName) &&
          !ticketText.contains(apiName.toLowerCase())
        )
          continue;

        existingObjects.add(apiName);

        List<String> fieldNames = new List<String>();
        Boolean hasMasterDetail = false;

        for (Schema.SObjectField f : describe.fields.getMap().values()) {
          Schema.DescribeFieldResult fr = f.getDescribe();
          fieldNames.add(fr.getName());
          if (fr.isCascadeDelete()) {
            hasMasterDetail = true;
            System.debug(
              'runOrgCheck: MasterDetail on [' +
                apiName +
                '] field [' +
                fr.getName() +
                ']'
            );
          }
        }

        existingFields.put(apiName, fieldNames);
        sharingModels.put(
          apiName,
          hasMasterDetail ? 'ControlledByParent' : 'ReadWrite'
        );
      }

      Set<String> standardObjectNames = new Set<String>{
        'Account',
        'Contact',
        'Lead',
        'Opportunity',
        'Case',
        'Task',
        'Event',
        'Campaign',
        'User',
        'Product2',
        'Order',
        'Contract',
        'Asset',
        'Solution',
        'Pricebook2',
        'PricebookEntry',
        'Quote',
        'QuoteLineItem',
        'OpportunityLineItem',
        'CampaignMember',
        'CaseComment',
        'EmailMessage',
        'FeedItem',
        'ContentDocument',
        'ContentVersion',
        'Attachment',
        'Note'
      };

      String ticketTextStd = (summary + ' ' + description).toLowerCase();
      for (String stdObjName : standardObjectNames) {
        if (!ticketTextStd.contains(stdObjName.toLowerCase()))
          continue;
        try {
          Schema.SObjectType stdObjType = Schema.getGlobalDescribe()
            .get(stdObjName);
          if (stdObjType == null)
            continue;
          Schema.DescribeSObjectResult stdDescribe = stdObjType.getDescribe();
          List<String> stdFieldNames = new List<String>();
          for (Schema.SObjectField f : stdDescribe.fields.getMap().values()) {
            stdFieldNames.add(f.getDescribe().getName());
          }
          existingFields.put(stdObjName, stdFieldNames);
          System.debug(
            'runOrgCheck: standard object [' +
              stdObjName +
              '] — ' +
              stdFieldNames.size() +
              ' field(s) added to existingFields'
          );
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: failed to describe standard object [' +
              stdObjName +
              '] — ' +
              e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      orgState.put('existingObjects', existingObjects);
      orgState.put('existingFields', existingFields);
      orgState.put('sharingModels', sharingModels);

      if (!existingObjects.isEmpty()) {
        Map<String, List<Map<String, Object>>> layoutsByObject = new Map<String, List<Map<String, Object>>>();

        for (String objName : existingObjects) {
          try {
            List<Map<String, Object>> layouts = PageLayoutHelper.listPageLayouts(
              new Map<String, Object>{ 'objectApiName' => objName }
            );

            List<Map<String, Object>> layoutDetails = new List<Map<String, Object>>();
            for (Map<String, Object> layout : layouts) {
              String fullName = (String) layout.get('fullName');
              Map<String, Object> structure = getLayoutStructure(fullName);
              if (structure != null) {
                layoutDetails.add(structure);
              }
            }

            if (!layoutDetails.isEmpty()) {
              layoutsByObject.put(objName, layoutDetails);
            }
          } catch (Exception e) {
            System.debug(
              'runOrgCheck: layout fetch failed for [' +
                objName +
                ']: ' +
                e.getMessage()
            );
          }
        }

        orgState.put('existingLayouts', layoutsByObject);
      }

      if (!StaticResourceHelper.currentAttachments.isEmpty()) {
        List<Map<String, Object>> csvSummaries = new List<Map<String, Object>>();
        for (
          String fileName : StaticResourceHelper.currentAttachments.keySet()
        ) {
          if (fileName.toLowerCase().endsWith('.csv')) {
            try {
              Map<String, Object> readResult = CsvProcessor.readCsv(
                new Map<String, Object>{ 'fileName' => fileName }
              );
              csvSummaries.add(
                new Map<String, Object>{
                  'fileName' => fileName,
                  'columns' => readResult.get('columns'),
                  'totalRows' => readResult.get('totalRows')
                }
              );
              System.debug(
                'runOrgCheck: pre-read CSV [' +
                  fileName +
                  '] — ' +
                  readResult.get('totalRows') +
                  ' rows, columns=' +
                  readResult.get('columns')
              );
            } catch (Exception e) {
              System.debug(
                'runOrgCheck: CSV read failed [' +
                  fileName +
                  '] — ' +
                  e.getMessage()
              );
            }
          }
        }
        if (!csvSummaries.isEmpty()) {
          orgState.put('csvFiles', csvSummaries);
        }
      }

      String ticketTextLower = (summary + ' ' + description).toLowerCase();

      if (ticketTextLower.contains('queue')) {
        try {
          List<Map<String, Object>> queueList = new List<Map<String, Object>>();
          for (Group g : [
            SELECT Id, Name, DeveloperName, Email, DoesSendEmailToMembers
            FROM Group
            WHERE Type = 'Queue'
            ORDER BY Name
          ]) {
            List<String> sobjectTypes = new List<String>();
            for (QueueSobject qs : [
              SELECT SobjectType
              FROM QueueSobject
              WHERE QueueId = :g.Id
            ]) {
              sobjectTypes.add(qs.SobjectType);
            }
            List<String> members = new List<String>();
            for (GroupMember gm : [
              SELECT UserOrGroup.Name
              FROM GroupMember
              WHERE GroupId = :g.Id
            ]) {
              members.add((String) gm.getSObject('UserOrGroup').get('Name'));
            }
            queueList.add(
              new Map<String, Object>{
                'developerName' => g.DeveloperName,
                'name' => g.Name,
                'email' => g.Email,
                'doesSendEmailToMembers' => g.DoesSendEmailToMembers,
                'sobjectTypes' => sobjectTypes,
                'members' => members
              }
            );
          }
          if (!queueList.isEmpty()) {
            orgState.put('existingQueues', queueList);
            System.debug(
              'runOrgCheck: fetched ' + queueList.size() + ' queue(s)'
            );
          }
        } catch (Exception e) {
          System.debug('runOrgCheck: queue fetch failed — ' + e.getMessage());
          ErrorLogger.log(e);
        }
      }

      if (ticketTextLower.contains('public group')) {
        try {
          List<Map<String, Object>> groupList = new List<Map<String, Object>>();
          for (Group g : [
            SELECT
              Id,
              Name,
              DeveloperName,
              DoesIncludeBosses,
              DoesSendEmailToMembers
            FROM Group
            WHERE Type = 'Regular'
            ORDER BY Name
          ]) {
            List<String> members = new List<String>();
            for (GroupMember gm : [
              SELECT UserOrGroup.Name
              FROM GroupMember
              WHERE GroupId = :g.Id
            ]) {
              members.add((String) gm.getSObject('UserOrGroup').get('Name'));
            }
            groupList.add(
              new Map<String, Object>{
                'developerName' => g.DeveloperName,
                'name' => g.Name,
                'doesIncludeBosses' => g.DoesIncludeBosses,
                'doesSendEmailToMembers' => g.DoesSendEmailToMembers,
                'members' => members
              }
            );
          }
          if (!groupList.isEmpty()) {
            orgState.put('existingGroups', groupList);
            System.debug(
              'runOrgCheck: fetched ' + groupList.size() + ' public group(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: public group fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (ticketTextLower.contains('assignment rule')) {
        try {
          List<Map<String, Object>> assignmentRulesState = new List<Map<String, Object>>();
          for (String objType : new List<String>{ 'Lead', 'Case' }) {
            Map<String, Object> state = getAssignmentRulesState(objType);
            if (state != null)
              assignmentRulesState.add(state);
          }
          if (!assignmentRulesState.isEmpty()) {
            orgState.put('existingAssignmentRules', assignmentRulesState);
            System.debug('runOrgCheck: fetched assignment rules state');
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: assignment rules fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (ticketTextLower.contains('named credential')) {
        try {
          List<Map<String, Object>> ncState = getNamedCredentialsState();
          if (ncState != null && !ncState.isEmpty()) {
            orgState.put('existingNamedCredentials', ncState);
            System.debug(
              'runOrgCheck: fetched ' + ncState.size() + ' named credential(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: named credentials fetch failed — ' + e.getMessage()
          );
        }
      }

      if (
        ticketTextLower.contains('auth provider') ||
        ticketTextLower.contains('authentication provider') ||
        ticketTextLower.contains('authprovider')
      ) {
        try {
          List<Map<String, Object>> apState = getAuthProvidersState();
          if (apState != null && !apState.isEmpty()) {
            orgState.put('existingAuthProviders', apState);
            System.debug(
              'runOrgCheck: fetched ' + apState.size() + ' auth provider(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: auth providers fetch failed — ' + e.getMessage()
          );
        }
      }

      if (ticketTextLower.contains('record type')) {
        Set<String> stdObjects = new Set<String>{
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
          'Pricebook2'
        };
        Map<String, Object> stdLayoutNames = new Map<String, Object>();
        for (String stdObj : stdObjects) {
          if (!ticketTextLower.contains(stdObj.toLowerCase()))
            continue;
          try {
            List<Map<String, Object>> layouts = PageLayoutHelper.listPageLayouts(
              new Map<String, Object>{ 'objectApiName' => stdObj }
            );
            List<String> fullNames = new List<String>();
            for (Map<String, Object> layout : layouts) {
              String fn = (String) layout.get('fullName');
              if (String.isNotBlank(fn))
                fullNames.add(fn);
            }
            if (!fullNames.isEmpty()) {
              stdLayoutNames.put(stdObj, fullNames);
              System.debug(
                'runOrgCheck: standardObjectLayoutNames[' +
                  stdObj +
                  '] = ' +
                  fullNames
              );
            }
          } catch (Exception e) {
            System.debug(
              'runOrgCheck: layout fetch failed for std obj [' +
                stdObj +
                ']: ' +
                e.getMessage()
            );
          }
        }
        if (!stdLayoutNames.isEmpty()) {
          orgState.put('standardObjectLayoutNames', stdLayoutNames);
        }
      }

      if (ticketTextLower.contains('record type')) {
        Set<String> processDrivenObjects = new Set<String>{
          'case',
          'lead',
          'opportunity',
          'solution'
        };
        Boolean mentionsProcessObject = false;
        for (String pObj : processDrivenObjects) {
          if (ticketTextLower.contains(pObj)) {
            mentionsProcessObject = true;
            break;
          }
        }
        if (mentionsProcessObject) {
          try {
            Map<String, List<String>> bpByObject = new Map<String, List<String>>();
            for (BusinessProcess bp : [
              SELECT Id, Name, TableEnumOrId, IsActive
              FROM BusinessProcess
              WHERE IsActive = TRUE
              ORDER BY TableEnumOrId, Name
            ]) {
              String objKey = bp.TableEnumOrId;
              if (!bpByObject.containsKey(objKey)) {
                bpByObject.put(objKey, new List<String>());
              }
              bpByObject.get(objKey).add(bp.Name);
            }
            if (!bpByObject.isEmpty()) {
              orgState.put('existingBusinessProcesses', bpByObject);
              System.debug(
                'runOrgCheck: existingBusinessProcesses = ' +
                JSON.serialize(bpByObject)
              );
            } else {
              System.debug(
                'runOrgCheck: no active Business Processes found in org'
              );
            }
          } catch (Exception e) {
            System.debug(
              'runOrgCheck: business process fetch failed — ' + e.getMessage()
            );
          }
        }
      }

      if (ticketTextLower.contains('record type')) {
        try {
          List<Map<String, Object>> rtList = new List<Map<String, Object>>();
          for (RecordType rt : [
            SELECT Id, Name, DeveloperName, SobjectType, IsActive, Description
            FROM RecordType
            WHERE NamespacePrefix = NULL
            ORDER BY SobjectType, DeveloperName
          ]) {
            rtList.add(
              new Map<String, Object>{
                'developerName' => rt.DeveloperName,
                'label' => rt.Name,
                'sobjectType' => rt.SobjectType,
                'isActive' => rt.IsActive,
                'description' => rt.Description
              }
            );
          }
          if (!rtList.isEmpty()) {
            orgState.put('existingRecordTypes', rtList);
            System.debug(
              'runOrgCheck: fetched ' + rtList.size() + ' record type(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: record type fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (ticketTextLower.contains('trigger')) {
        try {
          List<String> candidateObjects = new List<String>();
          Set<String> stdTriggerObjects = new Set<String>{
            'Account',
            'Contact',
            'Lead',
            'Opportunity',
            'Case',
            'Task',
            'Event',
            'Campaign',
            'Order',
            'Contract',
            'Asset',
            'Product2',
            'Quote',
            'Pricebook2'
          };
          for (String stdObj : stdTriggerObjects) {
            if (ticketTextLower.contains(stdObj.toLowerCase())) {
              candidateObjects.add(stdObj);
            }
          }
          List<Object> existingObjs = (List<Object>) orgState.get(
            'existingObjects'
          );
          if (existingObjs != null) {
            for (Object o : existingObjs) {
              String objName = String.valueOf(o);
              String shortName = objName.replace('__c', '')
                .replace('_', ' ')
                .toLowerCase();
              if (
                ticketTextLower.contains(shortName) ||
                ticketTextLower.contains(objName.toLowerCase())
              ) {
                candidateObjects.add(objName);
              }
            }
          }

          if (!candidateObjects.isEmpty()) {
            String targetObject = candidateObjects[0];
            System.debug(
              'runOrgCheck: checking apex trigger on object [' +
                targetObject +
                ']'
            );
            Map<String, Object> triggerState = getApexTriggerState(
              targetObject
            );

            if (triggerState != null) {
              orgState.put(
                'existingTrigger',
                new Map<String, Object>{
                  'name' => triggerState.get('name'),
                  'body' => triggerState.get('body')
                }
              );
              if (triggerState.containsKey('handlerName')) {
                orgState.put(
                  'existingHandlerClass',
                  new Map<String, Object>{
                    'name' => triggerState.get('handlerName'),
                    'body' => triggerState.get('handlerBody')
                  }
                );
              } else {
                orgState.put('existingHandlerClass', null);
              }
              System.debug(
                'runOrgCheck: existingTrigger = [' +
                  triggerState.get('name') +
                  ']'
              );
            } else {
              orgState.put('existingTrigger', null);
              orgState.put('existingHandlerClass', null);
              System.debug(
                'runOrgCheck: no existing trigger found on [' +
                  targetObject +
                  ']'
              );
            }
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: trigger state fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (
        ticketTextLower.contains('class') &&
        !ticketTextLower.contains('trigger')
      ) {
        try {
          String combined = summary + ' ' + description;
          Pattern clsPat = Pattern.compile('(?i)class\\s+([A-Z][A-Za-z0-9_]+)');
          Matcher clsMatch = clsPat.matcher(combined);
          String detectedClassName = null;
          if (clsMatch.find()) {
            detectedClassName = clsMatch.group(1);
          }
          if (String.isNotBlank(detectedClassName)) {
            System.debug(
              'runOrgCheck: detected class name [' +
                detectedClassName +
                '] — fetching from org'
            );
            Map<String, Object> classState = getApexClassState(
              detectedClassName
            );
            orgState.put('existingClass', classState);
            System.debug(
              'runOrgCheck: existingClass = ' +
              (classState != null ? classState.get('name') : 'null')
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: class state fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (
        ticketTextLower.contains('lwc') ||
        ticketTextLower.contains('lightning web component') ||
        ticketTextLower.contains('lightning component')
      ) {
        try {
          String detectedComponentName = extractLwcComponentName(
            summary + ' ' + description
          );

          if (String.isNotBlank(detectedComponentName)) {
            System.debug(
              'runOrgCheck: detected LWC name [' +
                detectedComponentName +
                '] — fetching from org'
            );
            Map<String, Object> componentState = getLwcComponentState(
              detectedComponentName
            );
            orgState.put('existingLwcComponent', componentState);
            System.debug(
              'runOrgCheck: existingLwcComponent = ' +
              (componentState != null
                ? componentState.get('developerName')
                : 'null (create mode)')
            );
          } else {
            System.debug(
              'runOrgCheck: no LWC component name found in ticket — create mode assumed'
            );
            orgState.put('existingLwcComponent', null);
          }

          String combined = summary + ' ' + description;
          Pattern controllerPat = Pattern.compile(
            '([A-Z][A-Za-z0-9_]+(?:Controller|Service|Handler|Helper))'
          );
          Matcher controllerMatch = controllerPat.matcher(combined);
          String detectedControllerName = null;
          while (controllerMatch.find()) {
            String candidate = controllerMatch.group(1);
            Set<String> sfBuiltInControllers = new Set<String>{
              'LightningController',
              'StandardController',
              'ApexPages'
            };
            if (!sfBuiltInControllers.contains(candidate)) {
              detectedControllerName = candidate;
              break;
            }
          }
          if (String.isNotBlank(detectedControllerName)) {
            System.debug(
              'runOrgCheck: detected LWC Apex controller [' +
                detectedControllerName +
                '] — fetching from org'
            );
            Map<String, Object> controllerState = getApexClassState(
              detectedControllerName
            );
            orgState.put('existingLwcApexController', controllerState);
            System.debug(
              'runOrgCheck: existingLwcApexController = ' +
              (controllerState != null
                ? controllerState.get('name')
                : 'null (will be created)')
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: LWC state fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (
        ticketTextLower.contains('custom label') ||
        ticketTextLower.contains('update label') ||
        ticketTextLower.contains('label')
      ) {
        try {
          Map<String, Object> labelResult = MetadataHelper.runToolingApiQuery(
            'SELECT Id, Name, Value, Language, MasterLabel, Category FROM ExternalString WHERE NamespacePrefix = null ORDER BY Name'
          );
          List<Object> labelRecords = (List<Object>) labelResult.get('records');
          if (labelRecords != null && !labelRecords.isEmpty()) {
            List<Map<String, Object>> labelList = new List<Map<String, Object>>();
            for (Object raw : labelRecords) {
              Map<String, Object> rec = (Map<String, Object>) raw;
              labelList.add(
                new Map<String, Object>{
                  'name' => rec.get('Name'),
                  'masterLabel' => rec.get('MasterLabel'),
                  'value' => rec.get('Value'),
                  'language' => rec.get('Language'),
                  'category' => rec.get('Category')
                }
              );
            }
            orgState.put('existingCustomLabels', labelList);
            System.debug(
              'runOrgCheck: fetched ' + labelList.size() + ' custom label(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: custom labels fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (
        ticketTextLower.contains('class access') ||
        ticketTextLower.contains('apex class') ||
        ticketTextLower.contains('apex classes')
      ) {
        try {
          Map<String, Object> classResult = MetadataHelper.runToolingApiQuery(
            'SELECT Name FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name'
          );
          List<Object> classRecords = (List<Object>) classResult.get('records');
          if (classRecords != null && !classRecords.isEmpty()) {
            List<String> classList = new List<String>();
            for (Object raw : classRecords) {
              Map<String, Object> rec = (Map<String, Object>) raw;
              classList.add((String) rec.get('Name'));
            }
            orgState.put('apexClasses', classList);
            System.debug(
              'runOrgCheck: fetched ' + classList.size() + ' Apex class(es)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: Apex classes fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }

      if (
        ticketTextLower.contains('visualforce') ||
        ticketTextLower.contains('page access')
      ) {
        try {
          Map<String, Object> pageResult = MetadataHelper.runToolingApiQuery(
            'SELECT Name FROM ApexPage WHERE NamespacePrefix = null ORDER BY Name'
          );
          List<Object> pageRecords = (List<Object>) pageResult.get('records');
          if (pageRecords != null && !pageRecords.isEmpty()) {
            List<String> pageList = new List<String>();
            for (Object raw : pageRecords) {
              Map<String, Object> rec = (Map<String, Object>) raw;
              pageList.add((String) rec.get('Name'));
            }
            orgState.put('visualforcePages', pageList);
            System.debug(
              'runOrgCheck: fetched ' + pageList.size() + ' Visualforce page(s)'
            );
          }
        } catch (Exception e) {
          System.debug(
            'runOrgCheck: Visualforce pages fetch failed — ' + e.getMessage()
          );
          ErrorLogger.log(e);
        }
      }
    } catch (Exception e) {
      System.debug('runOrgCheck failed: ' + e.getMessage());
      ErrorLogger.log(e);
    }

    return orgState;
  }

  // ─────────────────────────────────────────────────────────────
  // GET LAYOUT STRUCTURE
  // Retrieves existing layout sections + fields via Metadata API
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> getLayoutStructure(String fullName) {
    try {
      List<Metadata.Metadata> retrieved = Metadata.Operations.retrieve(
        Metadata.MetadataType.Layout,
        new List<String>{ fullName }
      );

      if (retrieved == null || retrieved.isEmpty() || retrieved[0] == null) {
        return null;
      }

      Metadata.Layout layout = (Metadata.Layout) retrieved[0];
      List<Map<String, Object>> sections = new List<Map<String, Object>>();

      if (layout.layoutSections != null) {
        for (Metadata.LayoutSection section : layout.layoutSections) {
          List<String> leftFields = new List<String>();
          List<String> leftBehaviors = new List<String>();
          List<String> rightFields = new List<String>();
          List<String> rightBehaviors = new List<String>();

          if (
            section.layoutColumns != null &&
            section.layoutColumns.size() > 0
          ) {
            Metadata.LayoutColumn leftCol = section.layoutColumns[0];
            if (leftCol.layoutItems != null) {
              for (Metadata.LayoutItem item : leftCol.layoutItems) {
                if (String.isNotBlank(item.field)) {
                  leftFields.add(item.field);
                  leftBehaviors.add(behaviorToString(item.behavior));
                }
              }
            }
          }
          if (
            section.layoutColumns != null &&
            section.layoutColumns.size() > 1
          ) {
            Metadata.LayoutColumn rightCol = section.layoutColumns[1];
            if (rightCol.layoutItems != null) {
              for (Metadata.LayoutItem item : rightCol.layoutItems) {
                if (String.isNotBlank(item.field)) {
                  rightFields.add(item.field);
                  rightBehaviors.add(behaviorToString(item.behavior));
                }
              }
            }
          }

          if (leftFields.isEmpty() && rightFields.isEmpty()) {
            System.debug(
              'getLayoutStructure: skipping non-field section [' +
                section.label +
                '] in layout [' +
                fullName +
                ']'
            );
            continue;
          }

          sections.add(
            new Map<String, Object>{
              'label' => section.label,
              'leftFields' => leftFields,
              'leftBehaviors' => leftBehaviors,
              'rightFields' => rightFields,
              'rightBehaviors' => rightBehaviors
            }
          );
        }
      }

      return new Map<String, Object>{
        'fullName' => fullName,
        'sections' => sections
      };
    } catch (Exception e) {
      System.debug(
        'getLayoutStructure failed for [' + fullName + ']: ' + e.getMessage()
      );
      return null;
    }
  }

  public static String behaviorToString(Metadata.UiBehavior b) {
    if (b == null)
      return 'Edit';
    if (b == Metadata.UiBehavior.Required)
      return 'Required';
    if (b == Metadata.UiBehavior.Readonly)
      return 'Readonly';
    return 'Edit';
  }

  // ─────────────────────────────────────────────────────────────
  // GET ASSIGNMENT RULES STATE
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> getAssignmentRulesState(String objectType) {
    try {
      MetadataService.IReadResult readResult = metaPort.readMetadata(
        'AssignmentRules',
        new List<String>{ objectType }
      );
      MetadataService.Metadata[] records = readResult.getRecords();

      if (records == null || records.isEmpty() || records[0] == null) {
        System.debug(
          'getAssignmentRulesState: no AssignmentRules found for [' +
            objectType +
            ']'
        );
        return null;
      }

      MetadataService.AssignmentRules rules = (MetadataService.AssignmentRules) records[0];
      List<Map<String, Object>> ruleList = new List<Map<String, Object>>();

      if (rules.assignmentRule != null) {
        for (MetadataService.AssignmentRule rule : rules.assignmentRule) {
          List<Map<String, Object>> entries = new List<Map<String, Object>>();
          if (rule.ruleEntry != null) {
            for (MetadataService.RuleEntry entry : rule.ruleEntry) {
              List<Map<String, Object>> criteriaList = new List<Map<String, Object>>();
              if (entry.criteriaItems != null) {
                for (MetadataService.FilterItem item : entry.criteriaItems) {
                  criteriaList.add(
                    new Map<String, Object>{
                      'field' => item.field,
                      'operation' => item.operation,
                      'value' => item.value
                    }
                  );
                }
              }
              entries.add(
                new Map<String, Object>{
                  'assignedTo' => entry.assignedTo,
                  'assignedToType' => entry.assignedToType,
                  'formula' => entry.formula,
                  'criteriaItems' => criteriaList
                }
              );
            }
          }
          ruleList.add(
            new Map<String, Object>{
              'fullName' => rule.fullName,
              'active' => rule.active,
              'ruleEntries' => entries
            }
          );
        }
      }

      if (ruleList.isEmpty())
        return null;

      System.debug(
        'getAssignmentRulesState: found ' +
          ruleList.size() +
          ' rule(s) for [' +
          objectType +
          ']'
      );
      return new Map<String, Object>{
        'objectType' => objectType,
        'rules' => ruleList
      };
    } catch (Exception e) {
      System.debug(
        'getAssignmentRulesState failed for [' +
          objectType +
          ']: ' +
          e.getMessage()
      );
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // GET NAMED CREDENTIALS STATE
  // ─────────────────────────────────────────────────────────────
  public static List<Map<String, Object>> getNamedCredentialsState() {
    try {
      List<String> names = new List<String>();
      for (NamedCredential nc : [
        SELECT DeveloperName
        FROM NamedCredential
        ORDER BY DeveloperName
      ]) {
        names.add(nc.DeveloperName);
      }

      if (names.isEmpty()) {
        System.debug(
          'getNamedCredentialsState: no Named Credentials found in org'
        );
        return null;
      }

      System.debug(
        'getNamedCredentialsState: reading ' +
          names.size() +
          ' NC(s) via readMetadata: ' +
          names
      );

      MetadataService.IReadResult readResult = metaPort.readMetadata(
        'NamedCredential',
        names
      );
      MetadataService.Metadata[] records = readResult.getRecords();

      if (records == null || records.isEmpty()) {
        System.debug(
          'getNamedCredentialsState: readMetadata returned no records'
        );
        return null;
      }

      List<Map<String, Object>> result = new List<Map<String, Object>>();

      for (MetadataService.Metadata raw : records) {
        if (raw == null)
          continue;
        MetadataService.NamedCredential nc = (MetadataService.NamedCredential) raw;

        Map<String, Object> ncMap = new Map<String, Object>{
          'apiName' => nc.fullName,
          'label' => nc.label,
          'endpoint' => nc.endpoint,
          'protocol' => nc.protocol,
          'principalType' => nc.principalType,
          'calloutStatus' => 'Enabled',
          'generateAuthorizationHeader' => nc.generateAuthorizationHeader,
          'allowMergeFieldsInBody' => nc.allowMergeFieldsInBody,
          'allowMergeFieldsInHeader' => nc.allowMergeFieldsInHeader
        };

        try {
          if (nc.authProvider != null)
            ncMap.put('authProvider', nc.authProvider);
        } catch (Exception ex) {
        }
        try {
          if (nc.oauthScope != null)
            ncMap.put('oauthScope', nc.oauthScope);
        } catch (Exception ex) {
        }
        try {
          if (nc.username != null)
            ncMap.put('username', nc.username);
        } catch (Exception ex) {
        }

        result.add(ncMap);
        System.debug(
          'getNamedCredentialsState: read NC [' +
            nc.fullName +
            '] protocol=[' +
            nc.protocol +
            ']'
        );
      }

      System.debug(
        'getNamedCredentialsState: returning ' + result.size() + ' NC(s)'
      );
      return result;
    } catch (Exception e) {
      System.debug('getNamedCredentialsState failed: ' + e.getMessage());
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // GET AUTH PROVIDERS STATE
  // ─────────────────────────────────────────────────────────────
  public static List<Map<String, Object>> getAuthProvidersState() {
    try {
      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (AuthProvider ap : [
        SELECT
          DeveloperName,
          FriendlyName,
          ProviderType,
          ConsumerKey,
          DefaultScopes,
          AuthorizeUrl,
          TokenUrl,
          UserInfoUrl,
          IconUrl
        FROM AuthProvider
        ORDER BY DeveloperName
      ]) {
        Map<String, Object> apMap = new Map<String, Object>{
          'developerName' => ap.DeveloperName,
          'friendlyName' => ap.FriendlyName,
          'providerType' => ap.ProviderType
        };
        if (ap.ConsumerKey != null)
          apMap.put('consumerKey', ap.ConsumerKey);
        if (ap.DefaultScopes != null)
          apMap.put('defaultScopes', ap.DefaultScopes);
        if (ap.AuthorizeUrl != null)
          apMap.put('authorizeUrl', ap.AuthorizeUrl);
        if (ap.TokenUrl != null)
          apMap.put('tokenUrl', ap.TokenUrl);
        if (ap.UserInfoUrl != null)
          apMap.put('userInfoUrl', ap.UserInfoUrl);
        if (ap.IconUrl != null)
          apMap.put('iconUrl', ap.IconUrl);
        result.add(apMap);
        System.debug(
          'getAuthProvidersState: read AP [' +
            ap.DeveloperName +
            '] type=[' +
            ap.ProviderType +
            ']'
        );
      }
      System.debug(
        'getAuthProvidersState: returning ' + result.size() + ' AP(s)'
      );
      return result.isEmpty() ? null : result;
    } catch (Exception e) {
      System.debug('getAuthProvidersState failed: ' + e.getMessage());
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // GET APEX TRIGGER STATE
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> getApexTriggerState(String objectApiName) {
    try {
      System.debug(
        'getApexTriggerState: checking for trigger on [' + objectApiName + ']'
      );

      String triggerQuery =
        'SELECT Id, Name, Body FROM ApexTrigger' +
        ' WHERE TableEnumOrId = \'' +
        objectApiName +
        '\'' +
        ' AND NamespacePrefix = null' +
        ' LIMIT 1';

      String triggerJson = JSON.serialize(
        MetadataHelper.runToolingApiQuery(triggerQuery)
      );
      Map<String, Object> triggerResult = (Map<String, Object>) JSON.deserializeUntyped(
        triggerJson
      );
      List<Object> triggerRecords = (List<Object>) triggerResult.get('records');

      if (triggerRecords == null || triggerRecords.isEmpty()) {
        System.debug(
          'getApexTriggerState: no trigger found on [' + objectApiName + ']'
        );
        return null;
      }

      Map<String, Object> triggerRec = (Map<String, Object>) triggerRecords[0];
      String triggerName = (String) triggerRec.get('Name');
      String triggerBody = (String) triggerRec.get('Body');

      System.debug(
        'getApexTriggerState: found trigger [' +
          triggerName +
          '] on [' +
          objectApiName +
          ']'
      );

      String baseName = objectApiName.endsWith('__c')
        ? objectApiName.removeEnd('__c')
        : objectApiName;

      Set<String> sfBuiltIns = new Set<String>{
        'Trigger',
        'System',
        'Schema',
        'Database',
        'Test',
        'UserInfo',
        'Math',
        'String',
        'Date',
        'DateTime',
        'Decimal',
        'Integer',
        'Boolean',
        'List',
        'Map',
        'Set',
        'SObject',
        'Id',
        'Type',
        'JSON',
        'Limits',
        'ApexPages',
        'PageReference',
        'URL',
        'Blob',
        'Exception',
        'CalloutException',
        'DmlException'
      };

      String triggerBodyInner = triggerBody;
      Integer openBrace = triggerBody.indexOf('{');
      if (openBrace >= 0) {
        triggerBodyInner = triggerBody.substring(openBrace + 1);
      }

      String detectedHandlerName = null;
      Pattern handlerPat = Pattern.compile('([A-Z][A-Za-z0-9_]+)\\.');
      Matcher handlerMatcher = handlerPat.matcher(triggerBodyInner);
      while (handlerMatcher.find()) {
        String candidate = handlerMatcher.group(1);
        if (!sfBuiltIns.contains(candidate)) {
          detectedHandlerName = candidate;
          System.debug(
            'getApexTriggerState: detected handler name from trigger body: [' +
              detectedHandlerName +
              ']'
          );
          break;
        }
      }

      String handlerQuery;
      if (String.isNotBlank(detectedHandlerName)) {
        handlerQuery =
          'SELECT Id, Name, Body FROM ApexClass' +
          ' WHERE Name = \'' +
          detectedHandlerName +
          '\'' +
          ' AND NamespacePrefix = null' +
          ' LIMIT 1';
      } else {
        System.debug(
          'getApexTriggerState: body parse found nothing — using convention-based name fallback'
        );
        handlerQuery =
          'SELECT Id, Name, Body FROM ApexClass' +
          ' WHERE Name IN (\'' +
          baseName +
          'Handler\', \'' +
          baseName +
          'TriggerHandler\', \'' +
          baseName +
          'Helper\', \'' +
          baseName +
          'Controller\')' +
          ' AND NamespacePrefix = null' +
          ' LIMIT 1';
      }

      String handlerJson = JSON.serialize(
        MetadataHelper.runToolingApiQuery(handlerQuery)
      );
      Map<String, Object> handlerResult = (Map<String, Object>) JSON.deserializeUntyped(
        handlerJson
      );
      List<Object> handlerRecords = (List<Object>) handlerResult.get('records');

      Map<String, Object> state = new Map<String, Object>{
        'name' => triggerName,
        'body' => triggerBody
      };

      if (handlerRecords != null && !handlerRecords.isEmpty()) {
        Map<String, Object> handlerRec = (Map<String, Object>) handlerRecords[0];
        String handlerName = (String) handlerRec.get('Name');
        String handlerBody = (String) handlerRec.get('Body');
        state.put('handlerName', handlerName);
        state.put('handlerBody', handlerBody);
        System.debug(
          'getApexTriggerState: found handler [' + handlerName + ']'
        );
      } else {
        System.debug(
          'getApexTriggerState: no handler class found for [' +
            objectApiName +
            ']'
        );
      }

      return state;
    } catch (Exception e) {
      System.debug(
        'getApexTriggerState failed for [' +
          objectApiName +
          ']: ' +
          e.getMessage()
      );
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // GET APEX CLASS STATE
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> getApexClassState(String className) {
    try {
      System.debug('getApexClassState: fetching class [' + className + ']');
      String classQuery =
        'SELECT Id, Name, Body FROM ApexClass' +
        ' WHERE Name = \'' +
        className +
        '\'' +
        ' AND NamespacePrefix = null' +
        ' LIMIT 1';

      String classJson = JSON.serialize(
        MetadataHelper.runToolingApiQuery(classQuery)
      );
      Map<String, Object> classResult = (Map<String, Object>) JSON.deserializeUntyped(
        classJson
      );
      List<Object> classRecords = (List<Object>) classResult.get('records');

      if (classRecords == null || classRecords.isEmpty()) {
        System.debug(
          'getApexClassState: class [' + className + '] not found in org'
        );
        return null;
      }

      Map<String, Object> rec = (Map<String, Object>) classRecords[0];
      System.debug('getApexClassState: found class [' + className + ']');
      return new Map<String, Object>{
        'name' => rec.get('Name'),
        'body' => rec.get('Body')
      };
    } catch (Exception e) {
      System.debug(
        'getApexClassState failed for [' + className + ']: ' + e.getMessage()
      );
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // GET LWC COMPONENT STATE
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> getLwcComponentState(String developerName) {
    try {
      System.debug(
        'getLwcComponentState: checking for LWC [' + developerName + ']'
      );

      String bundleQuery =
        'SELECT Id, DeveloperName FROM LightningComponentBundle' +
        ' WHERE DeveloperName = \'' +
        developerName +
        '\'' +
        ' AND NamespacePrefix = null' +
        ' LIMIT 1';

      Map<String, Object> bundleResult = MetadataHelper.runToolingApiQuery(
        bundleQuery
      );
      List<Object> bundleRecords = (List<Object>) bundleResult.get('records');

      if (bundleRecords == null || bundleRecords.isEmpty()) {
        System.debug(
          'getLwcComponentState: no bundle found for [' +
            developerName +
            '] — create mode'
        );
        return null;
      }

      Map<String, Object> bundleRec = (Map<String, Object>) bundleRecords[0];
      String bundleId = (String) bundleRec.get('Id');
      System.debug('getLwcComponentState: found bundle id=' + bundleId);

      String resourceQuery =
        'SELECT FilePath, Source FROM LightningComponentResource' +
        ' WHERE LightningComponentBundleId = \'' +
        bundleId +
        '\'' +
        ' LIMIT 10';

      Map<String, Object> resourceResult = MetadataHelper.runToolingApiQuery(
        resourceQuery
      );
      List<Object> resourceRecords = (List<Object>) resourceResult.get(
        'records'
      );

      if (resourceRecords == null || resourceRecords.isEmpty()) {
        System.debug(
          'getLwcComponentState: bundle exists but no resources returned — treating as create mode'
        );
        return null;
      }

      String htmlSource = null;
      String jsSource = null;
      String metaXml = null;

      for (Object raw : resourceRecords) {
        Map<String, Object> rec = (Map<String, Object>) raw;
        String filePath = (String) rec.get('FilePath');
        String source = (String) rec.get('Source');
        if (String.isBlank(filePath))
          continue;
        if (filePath.endsWith('.html'))
          htmlSource = source;
        else if (filePath.endsWith('-meta.xml'))
          metaXml = source;
        else if (filePath.endsWith('.js'))
          jsSource = source;
      }

      System.debug(
        'getLwcComponentState: resolved' +
          ' html=' +
          (htmlSource != null) +
          ' js=' +
          (jsSource != null) +
          ' meta=' +
          (metaXml != null)
      );

      return new Map<String, Object>{
        'developerName' => developerName,
        'html' => htmlSource,
        'js' => jsSource,
        'metaXml' => metaXml
      };
    } catch (Exception e) {
      System.debug(
        'getLwcComponentState failed for [' +
          developerName +
          ']: ' +
          e.getMessage()
      );
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT LWC COMPONENT NAME FROM TICKET TEXT
  // ─────────────────────────────────────────────────────────────
  public static String extractLwcComponentName(String ticketText) {
    if (String.isBlank(ticketText))
      return null;

    Pattern p1 = Pattern.compile('(?i)(?:called|named)\\s+([a-z][A-Za-z0-9]+)');
    Matcher m1 = p1.matcher(ticketText);
    if (m1.find()) {
      System.debug('extractLwcComponentName: matched P1 → ' + m1.group(1));
      return m1.group(1);
    }

    Pattern p2 = Pattern.compile(
      '(?i)(?:the\\s+)?([a-z][A-Za-z0-9]+)\\s+(?:lwc|component|lightning web component|lightning component)'
    );
    Matcher m2 = p2.matcher(ticketText);
    if (m2.find()) {
      System.debug('extractLwcComponentName: matched P2 → ' + m2.group(1));
      return m2.group(1);
    }

    Pattern p3 = Pattern.compile(
      '(?i)(?:lwc|component)\\s+([a-z][A-Za-z0-9]+)'
    );
    Matcher m3 = p3.matcher(ticketText);
    if (m3.find()) {
      System.debug('extractLwcComponentName: matched P3 → ' + m3.group(1));
      return m3.group(1);
    }

    Pattern p4 = Pattern.compile(
      '(?i)(?:update|modify|edit|fix|change)\\s+(?:the\\s+)?([a-z][A-Za-z0-9]+)'
    );
    Matcher m4 = p4.matcher(ticketText);
    if (m4.find()) {
      System.debug('extractLwcComponentName: matched P4 → ' + m4.group(1));
      return m4.group(1);
    }

    System.debug(
      'extractLwcComponentName: no match — LLM will name the component'
    );
    return null;
  }
}
