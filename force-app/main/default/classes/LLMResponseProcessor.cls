public class LLMResponseProcessor {
  // ── Shared state written here, read by LLMService after call ──
  public static String pendingZip2DataJson;
  // ── Apex test context: set when Apex classes + test classes detected ──
  public static List<String> pendingApexClassNames;
  public static List<String> pendingApexClassContents;
  public static List<String> pendingTestClassNames;
  public static List<String> pendingTestClassContents;

  // ─────────────────────────────────────────────────────────────
  // STAGE 1.5 — PROMPT ROUTER
  // Calls LLM to classify ticket and pick prompt sections,
  // then assembles the XML-generation system prompt from CMT records.
  // Falls back to the full prompt on any error.
  // ─────────────────────────────────────────────────────────────
  public static String runRouterStage(String summary, String description) {
    try {
      String routerSystemPrompt = PromptService.getRouterSystemPrompt();
      List<String> availableKeys = PromptService.getRoutableFeatureKeys();

      String userMsg =
        'Available feature keys: ' +
        JSON.serialize(availableKeys) +
        '\n\nTicket Summary: ' +
        summary +
        '\nTicket Description: ' +
        (String.isBlank(description) ? '(none)' : description) +
        '\n\nReturn ONLY a JSON array of the relevant feature keys from the list above.';

      System.debug('[ROUTER] Available keys count: ' + availableKeys.size());
      System.debug('[ROUTER] Calling Groq for feature classification...');

      List<Map<String, Object>> routerMessages = new List<Map<String, Object>>{
        new Map<String, Object>{
          'role' => 'system',
          'content' => routerSystemPrompt
        },
        new Map<String, Object>{ 'role' => 'user', 'content' => userMsg }
      };

      Map<String, Object> routerResponse = LLMGroqClient.callGroq(
        routerMessages,
        new List<Map<String, Object>>(),
        null
      );

      if (routerResponse == null || !routerResponse.containsKey('choices')) {
        System.debug(
          '[ROUTER] ERROR — callGroq returned null or missing choices. ' +
            'Response: ' +
            routerResponse
        );
        return LLMGroqClient.buildXmlGenerationSystemPrompt();
      }

      List<Object> routerChoices = (List<Object>) routerResponse.get('choices');
      Map<String, Object> routerChoice = (Map<String, Object>) routerChoices[0];
      Map<String, Object> routerMessage = (Map<String, Object>) routerChoice.get(
        'message'
      );
      String routerContent = LLMGroqClient.cleanJsonResponse(
        (String) routerMessage.get('content')
      );

      System.debug('[ROUTER] Raw response: ' + routerContent);

      Set<String> selectedKeys = new Set<String>();
      List<Object> keyList = (List<Object>) JSON.deserializeUntyped(
        routerContent
      );
      for (Object k : keyList) {
        selectedKeys.add((String) k);
      }

      System.debug(
        '[ROUTER] Selected keys (' + selectedKeys.size() + '): ' + selectedKeys
      );
      return PromptService.assemblePrompt(selectedKeys);
    } catch (Exception ex) {
      System.debug(
        '[ROUTER] ERROR — ' + ex.getTypeName() + ': ' + ex.getMessage()
      );
      System.debug('[ROUTER] Stack trace: ' + ex.getStackTraceString());
      System.debug('[ROUTER] Falling back to full prompt (all CMT sections).');
      return LLMGroqClient.buildXmlGenerationSystemPrompt();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // STAGE 2 — XML GENERATION
  // ─────────────────────────────────────────────────────────────
  public static String runXmlGenerationStage(
    String issueKey,
    String summary,
    String description,
    Map<String, Object> orgState,
    String systemPrompt
  ) {
    List<Map<String, Object>> messages = new List<Map<String, Object>>{
      new Map<String, Object>{ 'role' => 'system', 'content' => systemPrompt },
      new Map<String, Object>{
        'role' => 'user',
        'content' => LLMGroqClient.buildXmlGenerationUserPrompt(
          issueKey,
          summary,
          description,
          orgState
        )
      }
    };

    Map<String, Object> response = LLMGroqClient.callGroq(
      messages,
      new List<Map<String, Object>>(),
      null
    );
    List<Object> choices = (List<Object>) response.get('choices');
    Map<String, Object> choice = (Map<String, Object>) choices[0];
    Map<String, Object> message = (Map<String, Object>) choice.get('message');
    String content = (String) message.get('content');

    System.debug('=== RAW LLM XML RESPONSE START ===');
    System.debug(content);
    System.debug('=== RAW LLM XML RESPONSE END ===');
    System.debug('── STAGE 2 raw LLM response: ' + content);

    return processXmlGenerationResponse(content, issueKey, orgState);
  }

  // ─────────────────────────────────────────────────────────────
  // PROCESS XML GENERATION RESPONSE
  // Parses LLM JSON, validates XML, feeds files to ZipBuilder
  // ─────────────────────────────────────────────────────────────
  public static String processXmlGenerationResponse(
    String llmResponse,
    String issueKey,
    Map<String, Object> orgState
  ) {
    String cleaned = LLMGroqClient.cleanJsonResponse(llmResponse);

    System.debug('=== XML GENERATION RESPONSE START ===');
    System.debug(cleaned);
    System.debug('=== XML GENERATION RESPONSE END ===');

    Map<String, Object> parsed;
    try {
      parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
    } catch (Exception e) {
      System.debug(
        'processXmlGenerationResponse: JSON parse failed: ' + e.getMessage()
      );
      ErrorLogger.log(e);
      FunctionHelper.hadError = true;
      return 'Error: LLM returned invalid JSON. Raw response: ' + llmResponse;
    }

    // ── Clone DML ops run first so files[] can layer updates on cloned XML ──
    List<Object> dmlOps = (List<Object>) parsed.get('dmlOperations');
    List<Object> cloneOps = new List<Object>();
    List<Object> nonCloneOps = new List<Object>();
    if (dmlOps != null && !dmlOps.isEmpty()) {
      for (Object rawOp : dmlOps) {
        Map<String, Object> op = (Map<String, Object>) rawOp;
        String opType = (String) op.get('type');
        if (opType == 'permissionSetClone' || opType == 'profileClone') {
          cloneOps.add(rawOp);
        } else {
          nonCloneOps.add(rawOp);
        }
      }
    }
    if (!cloneOps.isEmpty()) {
      System.debug(
        'processXmlGenerationResponse: processing ' +
          cloneOps.size() +
          ' clone DML operation(s) first'
      );
      processDmlOperations(cloneOps);
    }

    // ── Deployment plan ────────────────────────────────────────
    Map<String, Object> deploymentPlan = (Map<String, Object>) parsed.get(
      'deploymentPlan'
    );
    String deployScenario = (deploymentPlan != null &&
      deploymentPlan.get('scenario') != null)
      ? (String) deploymentPlan.get('scenario')
      : 'single';
    Set<String> zip2FilePaths = new Set<String>();
    if (deployScenario == 'chained' && deploymentPlan != null) {
      List<Object> zip2List = (List<Object>) deploymentPlan.get('zip2Files');
      if (zip2List != null) {
        for (Object p : zip2List) {
          zip2FilePaths.add((String) p);
        }
      }
    }
    System.debug(
      'processXmlGenerationResponse: deployScenario=' +
        deployScenario +
        ', zip2FilePaths=' +
        zip2FilePaths
    );
    System.debug(
      '[DEPLOY-TRACE] LLM picked scenario=' +
        deployScenario +
        ' | zip2FilePaths=' +
        zip2FilePaths +
        ' | rawDeploymentPlan=' +
        JSON.serialize(deploymentPlan)
    );

    if (deployScenario == 'chained') {
      Boolean hasNewCustomObject = false;
      Set<String> existingObjs = new Set<String>();
      if (
        orgState != null &&
        orgState.get('existingObjects') instanceof List<Object>
      ) {
        for (Object o : (List<Object>) orgState.get('existingObjects')) {
          existingObjs.add(String.valueOf(o));
        }
      }
      List<Object> filesCheck = (List<Object>) parsed.get('files');
      if (filesCheck != null) {
        for (Object rawFile : filesCheck) {
          Map<String, Object> f = (Map<String, Object>) rawFile;
          String mt = (String) f.get('metadataType');
          String mn = (String) f.get('memberName');
          if (mt == 'CustomObject' && !existingObjs.contains(mn)) {
            hasNewCustomObject = true;
            break;
          }
        }
      }
      if (!hasNewCustomObject) {
        System.debug(
          '[DEPLOY-TRACE] *** SCENARIO OVERRIDE *** LLM chose chained but no new CustomObject — forcing single'
        );
        deployScenario = 'single';
        zip2FilePaths.clear();
      }
    }

    Map<String, String> zip2Files = new Map<String, String>();
    Map<String, Set<String>> zip2MetadataTypes = new Map<String, Set<String>>();

    // ── Apex test validation tracking ──────────────────────────
    List<String> detectedApexNames = new List<String>();
    List<String> detectedApexContents = new List<String>();
    List<String> detectedTestNames = new List<String>();
    List<String> detectedTestContents = new List<String>();

    List<Object> files = (List<Object>) parsed.get('files');

    // ── Trigger merge enforcer (runs before files loop) ────────
    LLMTriggerMerger.enforceTriggerMerge(files, orgState);

    // ── Scenario B violation detector ─────────────────────────
    LLMLayoutHelper.detectScenarioBViolation(files, orgState);

    if (files != null && !files.isEmpty()) {
      System.debug(
        'processXmlGenerationResponse: processing ' + files.size() + ' file(s)'
      );

      for (Object rawFile : files) {
        Map<String, Object> file = (Map<String, Object>) rawFile;

        String metadataType = (String) file.get('metadataType');
        String memberName = (String) file.get('memberName');
        String filePath = (String) file.get('filePath');
        String xmlContent = (String) file.get('xmlContent');

        System.debug(
          'processXmlGenerationResponse: processing file [' +
            filePath +
            '] type=[' +
            metadataType +
            ']'
        );

        if (metadataType == 'PermissionSet') {
          xmlContent = PermissionSetHelper.ensureParentReadAccessForXml(
            xmlContent
          );
        }

        if (metadataType == 'CustomObject') {
          String sourceObj = LLMRelationshipHelper.extractSourceObjectFromObjectPath(
            filePath
          );
          xmlContent = LLMRelationshipHelper.rewriteRelationshipNamesInCustomObjectXml(
            xmlContent,
            sourceObj
          );
        }

        if (metadataType == 'Layout') {
          xmlContent = LLMXmlSanitizer.sanitizeLayoutXml(xmlContent);
        }

        if (metadataType == 'CustomLabel' || metadataType == 'CustomLabels') {
          xmlContent = LLMXmlSanitizer.sanitizeCustomLabelsXml(xmlContent);
        }

        if (metadataType == 'Translations' && String.isNotBlank(memberName)) {
          String normalizedLang = LLMXmlSanitizer.normalizeTranslationLanguageCode(
            memberName
          );
          if (normalizedLang != memberName) {
            System.debug(
              '[DEPLOY-TRACE] Translations: normalizing lang [' +
                memberName +
                '] -> [' +
                normalizedLang +
                ']'
            );
            filePath = 'translations/' + normalizedLang + '.translation';
            memberName = normalizedLang;
          }
        }

        if (metadataType == 'CustomTab' && !memberName.endsWith('__c')) {
          System.debug(
            '[DEPLOY-TRACE] skipping CustomTab for standard object [' +
              memberName +
              '] — standard objects have built-in tabs'
          );
          continue;
        }

        if (
          metadataType == 'CustomObject' &&
          !memberName.endsWith('__c') &&
          !memberName.endsWith('__mdt')
        ) {
          xmlContent = LLMXmlSanitizer.sanitizeStandardObjectXml(xmlContent);
          System.debug(
            '[DEPLOY-TRACE] sanitizeStandardObjectXml applied to [' +
              filePath +
              ']'
          );
          xmlContent = LLMXmlSanitizer.injectBusinessProcessIfMissing(
            xmlContent,
            memberName,
            orgState
          );
        }

        if (
          metadataType == 'CustomObject' &&
          memberName != null &&
          memberName.endsWith('__mdt')
        ) {
          xmlContent = LLMXmlSanitizer.sanitizeMdtObjectXml(xmlContent);
          System.debug(
            '[DEPLOY-TRACE] sanitizeMdtObjectXml applied to [' + filePath + ']'
          );
        }

        if (metadataType == 'Profile') {
          xmlContent = LLMXmlSanitizer.sanitizeProfileXml(xmlContent);
          xmlContent = LLMXmlSanitizer.sanitizeProfileStandardObjectTabs(
            xmlContent
          );
          xmlContent = LLMXmlSanitizer.sanitizeProfileLayoutAssignments(
            xmlContent
          );
          xmlContent = LLMXmlSanitizer.sanitizeProfileMasterRecordType(
            xmlContent
          );
        }

        if (metadataType == 'AuthProvider') {
          filePath = 'authproviders/' + memberName + '.authprovider';
          xmlContent = LLMXmlSanitizer.sanitizeAuthProviderXml(xmlContent);
          System.debug(
            '[DEPLOY-TRACE] sanitizeAuthProviderXml applied to [' +
              filePath +
              ']'
          );
        }

        // ── Track Apex classes and their test classes ───────────
        if (
          metadataType == 'ApexClass' &&
          String.isNotBlank(xmlContent) &&
          !filePath.endsWith('-meta.xml')
        ) {
          Boolean isTestClass =
            (memberName != null &&
            memberName.toLowerCase().endsWith('_test')) ||
            xmlContent.toLowerCase().contains('@istest');
          if (isTestClass) {
            detectedTestNames.add(memberName);
            detectedTestContents.add(xmlContent);
            System.debug('[APEX-TEST] Detected test class: ' + memberName);
          } else {
            detectedApexNames.add(memberName);
            detectedApexContents.add(xmlContent);
            System.debug(
              '[APEX-TEST] Detected production Apex class: ' + memberName
            );
          }
        }

        Boolean isApexCode = (metadataType == 'ApexClass' ||
        metadataType == 'ApexTrigger');
        Boolean isApexMeta = (metadataType == 'ApexClassMeta' ||
        metadataType == 'ApexTriggerMeta');
        Boolean isLwcHtml = (metadataType == 'LwcHtml');
        Boolean isLwcJs = (metadataType == 'LwcJs');
        Boolean isLwcMeta = (metadataType == 'LwcMeta');
        Boolean isLwcTest = (metadataType == 'LwcTest');
        Boolean isLwcFile = isLwcHtml || isLwcJs || isLwcMeta;

        if (
          (metadataType == 'ApexClass' || metadataType == 'ApexTrigger') &&
          String.isNotBlank(xmlContent)
        ) {
          String trimmedContent = xmlContent.trim();
          if (
            trimmedContent.startsWith('<?xml') ||
            trimmedContent.startsWith('<ApexClass') ||
            trimmedContent.startsWith('<ApexTrigger')
          ) {
            System.debug(
              '[DEPLOY-TRACE] *** APEX CODE FILE CONTAINS XML *** file=[' +
                filePath +
                '] — LLM put meta XML in a code file. Aborting.'
            );
            return 'Error: LLM generated XML meta content inside Apex code file [' +
              filePath +
              ']. The .cls/.trigger file must contain Apex source code, ' +
              'not XML. Please retry.';
          }
        }

        if ((isLwcHtml || isLwcJs) && String.isNotBlank(xmlContent)) {
          String trimmedLwc = xmlContent.trim();
          if (
            trimmedLwc.startsWith('<?xml') ||
            trimmedLwc.startsWith('<LightningComponent')
          ) {
            System.debug(
              '[DEPLOY-TRACE] *** LWC SOURCE FILE CONTAINS XML *** file=[' +
                filePath +
                '] — LLM put meta XML in a source file. Aborting.'
            );
            return 'Error: LLM generated XML meta content inside LWC source file [' +
              filePath +
              ']. The .html and .js files must contain component source, ' +
              'not XML. Please retry.';
          }
        }

        if (isLwcHtml && String.isNotBlank(xmlContent)) {
          String correspondingJs = null;
          for (Object f2Raw : files) {
            Map<String, Object> f2 = (Map<String, Object>) f2Raw;
            if (
              'LwcJs'.equals((String) f2.get('metadataType')) &&
              memberName.equals((String) f2.get('memberName'))
            ) {
              correspondingJs = (String) f2.get('xmlContent');
              break;
            }
          }
          Boolean jsIsImperative =
            correspondingJs != null && correspondingJs.contains('.then(');
          if (jsIsImperative) {
            String htmlBefore = xmlContent;
            xmlContent = xmlContent.replaceAll(
              '\\{([a-zA-Z][a-zA-Z0-9_]*)\\.data\\}',
              '{$1}'
            );
            xmlContent = xmlContent.replaceAll(
              '\\{([a-zA-Z][a-zA-Z0-9_]*)\\.error\\}',
              '{error}'
            );
            if (!xmlContent.equals(htmlBefore)) {
              System.debug(
                '[DEPLOY-TRACE] LWC HTML [' +
                  memberName +
                  '] — auto-sanitized wire-style .data/.error bindings' +
                  ' for imperative Tier 2 component'
              );
            }
          }
        }

        if (
          metadataType == 'ApexClass' &&
          filePath != null &&
          !filePath.endsWith('-meta.xml') &&
          filePath.toLowerCase().endsWith('trigger.cls')
        ) {
          System.debug(
            '[DEPLOY-TRACE] SKIPPED [' +
              filePath +
              '] — trigger name found in classes/ directory.'
          );
          continue;
        }

        if (isLwcTest && String.isNotBlank(xmlContent)) {
          try {
            ContentVersion cv = new ContentVersion();
            cv.Title = 'LwcJest_' + memberName;
            cv.PathOnClient = memberName + '.test.js';
            cv.VersionData = Blob.valueOf(xmlContent);
            cv.IsMajorVersion = true;
            insert cv;
            System.debug(
              '[DEPLOY-TRACE] Jest test saved to ContentDocument title=[LwcJest_' +
                memberName +
                '] Id=[' +
                cv.Id +
                ']'
            );
          } catch (Exception e) {
            System.debug(
              '[DEPLOY-TRACE] Failed to save Jest test: ' + e.getMessage()
            );
          }
          continue;
        }

        Boolean isNonXmlSource =
          isApexCode ||
          isLwcHtml ||
          isLwcJs ||
          isLwcTest;

        if (!isNonXmlSource) {
          String validationError = LLMXmlSanitizer.validateXml(
            isApexMeta ? metadataType.replace('Meta', '') : metadataType,
            memberName,
            xmlContent
          );
          if (String.isNotBlank(validationError)) {
            System.debug(
              'processXmlGenerationResponse: XML validation FAILED for [' +
                filePath +
                ']: ' +
                validationError
            );
            FunctionHelper.hadError = true;
            return 'Error: Invalid XML generated for ' +
              filePath +
              ': ' +
              validationError;
          }
        } else {
          if (isApexCode) {
            xmlContent = LLMXmlSanitizer.sanitizeApexRegex(xmlContent);
          }
          System.debug(
            '[DEPLOY-TRACE] skipping XML validation for non-XML source file [' +
              filePath +
              '] metadataType=[' +
              metadataType +
              ']'
          );
        }

        String effectiveType = metadataType;
        if (isApexMeta) {
          effectiveType = metadataType.replace('Meta', '');
          System.debug(
            '[DEPLOY-TRACE] ApexMeta file — normalising metadataType [' +
              metadataType +
              '] → [' +
              effectiveType +
              '] for package.xml registration'
          );
        }

        if (isLwcFile) {
          effectiveType = 'LightningComponentBundle';
          System.debug(
            '[DEPLOY-TRACE] LWC file — normalising metadataType [' +
              metadataType +
              '] → [LightningComponentBundle] for package.xml'
          );
        }

        if (zip2FilePaths.contains(filePath)) {
          zip2Files.put(filePath, xmlContent);
          if (!zip2MetadataTypes.containsKey(effectiveType)) {
            zip2MetadataTypes.put(effectiveType, new Set<String>());
          }
          zip2MetadataTypes.get(effectiveType).add(memberName);
          System.debug(
            'processXmlGenerationResponse: held back [' +
              filePath +
              '] for ZIP 2'
          );
          System.debug(
            '[DEPLOY-TRACE] route ZIP2 <- ' + effectiveType + ' / ' + filePath
          );
          continue;
        }

        if (
          metadataType == 'Layout' &&
          LLMXmlSanitizer.isStandardObjectLayout(memberName)
        ) {
          System.debug(
            '[DEPLOY-TRACE] SKIPPED standard-object Layout file [' +
              filePath +
              '] — standard layouts must not be deployed.'
          );
          continue;
        }

        ZipBuilder.addFile(effectiveType, memberName, filePath, xmlContent);

        if (metadataType == 'CustomObject') {
          List<String> rtNames = extractRecordTypeNamesFromObjectXml(
            xmlContent
          );
          for (String rtName : rtNames) {
            ZipBuilder.registerMember('RecordType', memberName + '.' + rtName);
            System.debug(
              '[DEPLOY-TRACE] registered RecordType member: ' +
                memberName +
                '.' +
                rtName
            );
          }
        }

        System.debug(
          'processXmlGenerationResponse: added [' + filePath + '] to ZipBuilder'
        );
        System.debug(
          '[DEPLOY-TRACE] route ZIP1 <- ' + effectiveType + ' / ' + filePath
        );

        System.debug('=== FILE ADDED TO ZIP ===');
        System.debug('Path: ' + filePath);
        System.debug('Type: ' + effectiveType);
        System.debug('Content (first 500 chars): ' + xmlContent.left(500));
        System.debug('========================');
      }
    }

    // ── Stage Apex test context if classes detected ──────────────
    pendingApexClassNames = null;
    pendingApexClassContents = null;
    pendingTestClassNames = null;
    pendingTestClassContents = null;
    if (!detectedApexNames.isEmpty()) {
      if (detectedTestNames.isEmpty()) {
        System.debug(
          '[APEX-TEST] WARNING — Apex class(es) detected but no test class(es) generated: ' +
          detectedApexNames
        );
      } else {
        pendingApexClassNames = detectedApexNames;
        pendingApexClassContents = detectedApexContents;
        pendingTestClassNames = detectedTestNames;
        pendingTestClassContents = detectedTestContents;
        System.debug(
          '[APEX-TEST] Staged: ' +
            detectedApexNames.size() +
            ' class(es), ' +
            detectedTestNames.size() +
            ' test class(es) for validation'
        );
      }
    }

    // ── Backstops ──────────────────────────────────────────────
    LLMLayoutHelper.backstopMissingLayoutsForNewObjects(
      files,
      orgState,
      zip2Files,
      zip2MetadataTypes
    );
    LLMLayoutHelper.backstopMissingFieldsInExistingLayouts(
      files,
      orgState,
      zip2Files,
      zip2MetadataTypes
    );

    // ── Destructive changes ────────────────────────────────────
    List<Object> destructiveFiles = (List<Object>) parsed.get(
      'destructiveFiles'
    );
    if (destructiveFiles != null && !destructiveFiles.isEmpty()) {
      System.debug(
        'processXmlGenerationResponse: processing ' +
          destructiveFiles.size() +
          ' destructive file(s)'
      );
      for (Object rawFile : destructiveFiles) {
        Map<String, Object> file = (Map<String, Object>) rawFile;
        String xmlContent = (String) file.get('xmlContent');
        if (String.isBlank(xmlContent)) {
          String metadataType = (String) file.get('metadataType');
          if (String.isBlank(metadataType))
            metadataType = (String) file.get('type');
          String memberName = (String) file.get('member');
          if (String.isBlank(memberName))
            memberName = (String) file.get('memberName');
          if (String.isBlank(metadataType) || String.isBlank(memberName)) {
            FunctionHelper.hadError = true;
            return 'Error: Invalid destructiveFiles entry. Provide xmlContent OR metadataType/type + member/memberName.';
          }
          LLMXmlSanitizer.appendDestructiveMember(metadataType, memberName);
        } else {
          ZipBuilder.addFile(
            '__destructive__',
            'destructive',
            'destructiveChangesPost.xml',
            xmlContent
          );
        }
      }
    }

    // ── Non-clone DML ops ──────────────────────────────────────
    if (nonCloneOps != null && !nonCloneOps.isEmpty()) {
      System.debug(
        'processXmlGenerationResponse: processing ' +
          nonCloneOps.size() +
          ' non-clone DML operation(s)'
      );
      processDmlOperations(nonCloneOps);
    }

    // ── Persist zip2 data ──────────────────────────────────────
    if (!zip2Files.isEmpty()) {
      Map<String, Object> zip2Data = new Map<String, Object>{
        'files' => zip2Files,
        'binaryFiles' => new Map<String, String>(),
        'metadataTypesJson' => JSON.serialize(zip2MetadataTypes)
      };
      pendingZip2DataJson = JSON.serialize(zip2Data);
      System.debug(
        'processXmlGenerationResponse: zip2 data staged — ' +
          zip2Files.size() +
          ' file(s) for ZIP 2'
      );
      System.debug(
        '[DEPLOY-TRACE] ZIP2 staged | fileCount=' +
          zip2Files.size() +
          ' | files=' +
          zip2Files.keySet()
      );
    } else {
      pendingZip2DataJson = null;
      System.debug(
        '[DEPLOY-TRACE] ZIP2 staged | fileCount=0 (single-deploy mode)'
      );
    }

    String summary = (String) parsed.get('summary');
    return String.isNotBlank(summary)
      ? summary
      : 'Changes staged for deployment.';
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT RECORD TYPE NAMES FROM OBJECT XML
  // ─────────────────────────────────────────────────────────────
  public static List<String> extractRecordTypeNamesFromObjectXml(
    String xmlContent
  ) {
    List<String> result = new List<String>();
    if (String.isBlank(xmlContent) || !xmlContent.contains('<recordTypes>'))
      return result;

    Pattern rtBlock = Pattern.compile('(?s)<recordTypes>(.*?)</recordTypes>');
    Matcher m = rtBlock.matcher(xmlContent);
    Pattern fnPat = Pattern.compile('<fullName>([^<]+)</fullName>');

    while (m.find()) {
      Matcher fnm = fnPat.matcher(m.group(1));
      if (fnm.find()) {
        result.add(fnm.group(1));
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // PROCESS DML OPERATIONS
  // ─────────────────────────────────────────────────────────────
  public static void processDmlOperations(List<Object> dmlOps) {
    for (Object rawOp : dmlOps) {
      Map<String, Object> op = (Map<String, Object>) rawOp;
      String opType = (String) op.get('type');

      System.debug('processDmlOperations: processing op type=[' + opType + ']');

      if (opType == 'permissionSetAssign') {
        String psName = (String) op.get('permissionSetName');
        String username = (String) op.get('username');
        SObject assignment = PermissionSetHelper.buildAssignment(
          new Map<String, Object>{
            'permissionSetName' => psName,
            'username' => username
          }
        );
        FunctionHelper.recordsToInsert.add(assignment);
        System.debug(
          'processDmlOperations: queued PS assignment [' +
            psName +
            '] → [' +
            username +
            ']'
        );
      } else if (opType == 'permissionSetRemove') {
        String psName = (String) op.get('permissionSetName');
        String username = (String) op.get('username');
        SObject assignment = PermissionSetHelper.findAssignment(
          new Map<String, Object>{
            'permissionSetName' => psName,
            'username' => username
          }
        );
        FunctionHelper.recordsToDelete.add(assignment);
        System.debug(
          'processDmlOperations: queued PS removal [' +
            psName +
            '] → [' +
            username +
            ']'
        );
      } else if (opType == 'staticResourceDeploy') {
        String apiName = (String) op.get('apiName');
        String fileName = (String) op.get('fileName');
        String cacheControl = (String) op.get('cacheControl');
        StaticResourceHelper.deployStaticResource(
          new Map<String, Object>{
            'apiName' => apiName,
            'fileName' => fileName,
            'cacheControl' => cacheControl != null ? cacheControl : 'Public'
          }
        );
        System.debug(
          'processDmlOperations: static resource staged [' + apiName + ']'
        );
      } else if (opType == 'staticResourceDelete') {
        String apiName = (String) op.get('apiName');
        StaticResourceHelper.deleteStaticResource(
          new Map<String, Object>{ 'apiName' => apiName }
        );
        System.debug(
          'processDmlOperations: static resource delete queued [' +
            apiName +
            ']'
        );
      } else if (opType == 'permissionSetClone') {
        String sourcePermissionSetName = (String) op.get(
          'sourcePermissionSetName'
        );
        String newApiName = (String) op.get('newApiName');
        String newLabel = (String) op.get('newLabel');
        String description = (String) op.get('description');
        PermissionSetHelper.clonePermissionSet(
          new Map<String, Object>{
            'sourcePermissionSetName' => sourcePermissionSetName,
            'newApiName' => newApiName,
            'newLabel' => newLabel,
            'description' => description
          }
        );
        System.debug(
          'processDmlOperations: PS clone staged [' +
            sourcePermissionSetName +
            '] → [' +
            newApiName +
            ']'
        );
      } else if (
        String.isNotBlank(opType) &&
        opType.startsWith('permissionSet') &&
        opType != 'permissionSetAssign' &&
        opType != 'permissionSetRemove' &&
        opType != 'permissionSetClone'
      ) {
        FunctionHelper.hadError = true;
        throw new LLMService.LLMException(
          'Unsupported dmlOperations type [' +
            opType +
            '] for Permission Set. ' +
            'Use files[] PermissionSet XML for create/update/delete and keep only permissionSetClone in dmlOperations.'
        );
      } else if (opType == 'profileClone') {
        String sourceProfileName = (String) op.get('sourceProfileName');
        String newProfileName = (String) op.get('newProfileName');
        ProfileHelper.cloneProfile(
          new Map<String, Object>{
            'sourceProfileName' => sourceProfileName,
            'newProfileName' => newProfileName
          }
        );
        System.debug(
          'processDmlOperations: Profile clone staged [' +
            sourceProfileName +
            '] → [' +
            newProfileName +
            ']'
        );
      } else if (opType == 'csvProcess') {
        String fileName = (String) op.get('fileName');
        String csvType = (String) op.get('csvType');
        System.debug(
          'processDmlOperations: processing CSV [' +
            fileName +
            '] type=[' +
            csvType +
            ']'
        );

        Map<String, Object> readResult = CsvProcessor.readCsv(
          new Map<String, Object>{ 'fileName' => fileName }
        );
        System.debug(
          'processDmlOperations: CSV read complete — ' +
            readResult.get('totalRows') +
            ' rows'
        );

        Map<String, Object> processResult = CsvProcessor.process(
          new Map<String, Object>{ 'fileName' => fileName, 'type' => csvType }
        );
        System.debug(
          'processDmlOperations: CSV processed — ' +
            processResult.get('processed') +
            ' records staged'
        );
      }
    }
  }
}
