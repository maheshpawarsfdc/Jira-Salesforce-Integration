public class LLMResponseProcessor {
  // ── Shared state written here, read by LLMService after call ──
  public static String pendingZip2DataJson;
  // ── Apex test context: set when Apex classes + test classes detected ──
  public static List<String> pendingApexClassNames;
  public static List<String> pendingApexClassContents;
  public static List<String> pendingTestClassNames;
  public static List<String> pendingTestClassContents;

  // ─────────────────────────────────────────────────────────────
  // STAGE 1.6 — EXISTENCE GATE
  // Calls LLM to compare ticket requirements against org state and
  // determine whether EVERY requested component already exists —
  // i.e. this ticket is a pure duplicate/re-run with nothing new to do.
  // Any error, missing CMT record, or uncertainty falls back to
  // allSatisfied=false so the normal generation pipeline still runs.
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> runExistenceGateStage(
    String summary,
    String description,
    Map<String, Object> orgState
  ) {
    try {
      String gateSystemPrompt = PromptService.getPromptByKey('EXISTENCE_GATE');
      if (String.isBlank(gateSystemPrompt)) {
        System.debug(
          '[EXISTENCE-GATE] EXISTENCE_GATE prompt not found — skipping gate, proceeding normally.'
        );
        return new Map<String, Object>{ 'allSatisfied' => false };
      }

      String userMsg =
        'Ticket Summary: ' +
        summary +
        '\nTicket Description: ' +
        (String.isBlank(description) ? '(none)' : description) +
        '\n\nCurrent org state (JSON):\n' +
        JSON.serialize(orgState);

      List<Map<String, Object>> gateMessages = new List<Map<String, Object>>{
        new Map<String, Object>{
          'role' => 'system',
          'content' => gateSystemPrompt
        },
        new Map<String, Object>{ 'role' => 'user', 'content' => userMsg }
      };

      System.debug('[EXISTENCE-GATE] Calling LLM for existence check...');
      Long gateCallStart = Datetime.now().getTime();

      Map<String, Object> gateResponse = LLMGroqClient.callLLM(
        gateMessages,
        new List<Map<String, Object>>(),
        null
      );
      System.debug(
        '[LLM-TRACE] gate-call | ' +
          (Datetime.now().getTime() - gateCallStart) +
          'ms'
      );

      if (gateResponse == null || !gateResponse.containsKey('choices')) {
        System.debug(
          '[EXISTENCE-GATE] ERROR — response missing choices. Response: ' +
          gateResponse
        );
        return new Map<String, Object>{ 'allSatisfied' => false };
      }

      List<Object> gateChoices = (List<Object>) gateResponse.get('choices');
      Map<String, Object> gateChoice = (Map<String, Object>) gateChoices[0];
      Map<String, Object> gateMessage = (Map<String, Object>) gateChoice.get(
        'message'
      );
      String content = LLMGroqClient.cleanJsonResponse(
        (String) gateMessage.get('content')
      );

      System.debug('[EXISTENCE-GATE] Raw response: ' + content);

      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        content
      );
      List<Object> items = (List<Object>) parsed.get('items');

      // Hard cross-check — never trust the LLM's existsAlready claim
      // blindly for any metadata type we have real org-state data for;
      // verify programmatically so a hallucinated "already exists"
      // (like the Reservation_Access PermissionSet incident) can't
      // wrongly cause a skip.
      Boolean allSatisfied = (items != null && !items.isEmpty());
      List<Map<String, Object>> verifiedItems = new List<Map<String, Object>>();

      if (items != null) {
        for (Object rawItem : items) {
          Map<String, Object> item = (Map<String, Object>) rawItem;
          String itype = (String) item.get('type');
          String iname = (String) item.get('name');
          Boolean claimedExists = item.get('existsAlready') == true;
          Boolean verifiedExists = verifyItemExists(
            itype,
            iname,
            orgState,
            claimedExists
          );

          if (!verifiedExists) {
            allSatisfied = false;
          }
          verifiedItems.add(
            new Map<String, Object>{
              'type' => itype,
              'name' => iname,
              'existsAlready' => verifiedExists
            }
          );
        }
      }

      String gateSummary = (String) parsed.get('summary');
      if (String.isBlank(gateSummary)) {
        gateSummary = allSatisfied
          ? 'All requested metadata already exists in the org — nothing to deploy.'
          : 'Some requested metadata is new — proceeding with deployment.';
      }

      System.debug(
        '[EXISTENCE-GATE] allSatisfied=' +
          allSatisfied +
          ' items=' +
          verifiedItems
      );

      return new Map<String, Object>{
        'allSatisfied' => allSatisfied,
        'summary' => gateSummary,
        'items' => verifiedItems
      };
    } catch (Exception ex) {
      System.debug(
        '[EXISTENCE-GATE] ERROR — ' + ex.getTypeName() + ': ' + ex.getMessage()
      );
      System.debug('[EXISTENCE-GATE] Stack trace: ' + ex.getStackTraceString());
      ErrorLogger.log(ex);
      // Fail-safe: any error in the gate must NOT block real work.
      return new Map<String, Object>{ 'allSatisfied' => false };
    }
  }

  // ─────────────────────────────────────────────────────────────
  // EXISTENCE GATE — PER-TYPE VERIFICATION
  // Dispatches to the right orgState list/map for each metadata
  // type this tool supports. Falls back to trusting the LLM's own
  // claim only for types we have no ground truth for.
  // ─────────────────────────────────────────────────────────────
  private static Boolean verifyItemExists(
    String itype,
    String iname,
    Map<String, Object> orgState,
    Boolean claimedExists
  ) {
    if (String.isBlank(itype) || String.isBlank(iname)) {
      return claimedExists;
    }

    // CustomSetting and CustomMetadataType are both just CustomObject
    // variants under the hood (__c / __mdt suffix) — Schema.getGlobalDescribe()
    // doesn't distinguish them from regular custom objects, so they already
    // live in existingObjects/existingFields. Route them to the same check
    // regardless of which label the LLM used.
    if (
      'CustomObject'.equalsIgnoreCase(itype) ||
      'CustomSetting'.equalsIgnoreCase(itype) ||
      'CustomMetadataType'.equalsIgnoreCase(itype)
    ) {
      return listContainsIgnoreCase(orgState.get('existingObjects'), iname);
    }

    if (
      ('CustomField'.equalsIgnoreCase(itype) ||
      'CustomSettingField'.equalsIgnoreCase(itype) ||
      'CustomMetadataField'.equalsIgnoreCase(itype)) && iname.contains('.')
    ) {
      String parentObj = iname.substringBefore('.');
      String fieldName = iname.substringAfter('.');
      Object fieldsMap = orgState.get('existingFields');
      Object fieldsForObj = fieldsMap instanceof Map<String, Object>
        ? ((Map<String, Object>) fieldsMap).get(parentObj)
        : null;
      return listContainsIgnoreCase(fieldsForObj, fieldName);
    }

    if ('ApexClass'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingApexClassNames'),
        iname
      );
    }

    if ('ApexTrigger'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingApexTriggerNames'),
        iname
      );
    }

    if ('LWC'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingLwcComponentNames'),
        iname
      );
    }

    if ('PermissionSet'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingPermissionSetNames'),
        iname
      );
    }

    if ('Profile'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingProfileNames'),
        iname
      );
    }

    if ('CustomTab'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingCustomTabSobjectNames'),
        iname
      );
    }

    if ('StaticResource'.equalsIgnoreCase(itype)) {
      return listContainsIgnoreCase(
        orgState.get('existingStaticResourceNames'),
        iname
      );
    }

    if ('Layout'.equalsIgnoreCase(itype) && iname.contains('-')) {
      String parentObj = iname.substringBefore('-');
      Object layoutsMap = orgState.get('existingLayouts');
      Object layoutsForObj = layoutsMap instanceof Map<String, Object>
        ? ((Map<String, Object>) layoutsMap).get(parentObj)
        : null;
      if (layoutsForObj instanceof List<Object>) {
        for (Object raw : (List<Object>) layoutsForObj) {
          Map<String, Object> l = (Map<String, Object>) raw;
          if (iname.equalsIgnoreCase((String) l.get('fullName'))) {
            return true;
          }
        }
      }
      return false;
    }

    if ('RecordType'.equalsIgnoreCase(itype)) {
      Object rtList = orgState.get('existingRecordTypes');
      if (rtList instanceof List<Object>) {
        for (Object raw : (List<Object>) rtList) {
          Map<String, Object> rt = (Map<String, Object>) raw;
          String rtName = (String) rt.get('developerName');
          String rtObj = (String) rt.get('sobjectType');
          if (
            iname.equalsIgnoreCase(rtObj + '.' + rtName) ||
            iname.equalsIgnoreCase(rtName)
          ) {
            return true;
          }
        }
      }
      return false;
    }

    if (
      'CustomLabel'.equalsIgnoreCase(itype) ||
      'CustomLabels'.equalsIgnoreCase(itype)
    ) {
      Object labelList = orgState.get('existingCustomLabels');
      if (labelList instanceof List<Object>) {
        for (Object raw : (List<Object>) labelList) {
          Map<String, Object> lbl = (Map<String, Object>) raw;
          if (iname.equalsIgnoreCase((String) lbl.get('name'))) {
            return true;
          }
        }
      }
      return false;
    }

    if (
      'Translations'.equalsIgnoreCase(itype) ||
      'Translation'.equalsIgnoreCase(itype)
    ) {
      String normalizedLang = LLMXmlSanitizer.normalizeTranslationLanguageCode(
        iname
      );
      return listContainsIgnoreCase(
        orgState.get('existingTranslationLanguages'),
        normalizedLang
      );
    }

    if ('ValidationRule'.equalsIgnoreCase(itype) && iname.contains('.')) {
      String parentObj = iname.substringBefore('.');
      String ruleName = iname.substringAfter('.');
      Object vrMap = orgState.get('existingValidationRules');
      Object rulesForObj = vrMap instanceof Map<String, Object>
        ? ((Map<String, Object>) vrMap).get(parentObj)
        : null;
      return listContainsIgnoreCase(rulesForObj, ruleName);
    }

    if ('Queue'.equalsIgnoreCase(itype)) {
      return matchesMapListByKeys(
        orgState.get('existingQueues'),
        iname,
        new List<String>{ 'developerName', 'name' }
      );
    }

    if ('PublicGroup'.equalsIgnoreCase(itype)) {
      return matchesMapListByKeys(
        orgState.get('existingGroups'),
        iname,
        new List<String>{ 'developerName', 'name' }
      );
    }

    if ('NamedCredential'.equalsIgnoreCase(itype)) {
      return matchesMapListByKeys(
        orgState.get('existingNamedCredentials'),
        iname,
        new List<String>{ 'apiName' }
      );
    }

    if ('AuthProvider'.equalsIgnoreCase(itype)) {
      return matchesMapListByKeys(
        orgState.get('existingAuthProviders'),
        iname,
        new List<String>{ 'developerName' }
      );
    }

    if (
      'AssignmentRules'.equalsIgnoreCase(itype) ||
      'AssignmentRule'.equalsIgnoreCase(itype)
    ) {
      Object arList = orgState.get('existingAssignmentRules');
      if (arList instanceof List<Object>) {
        for (Object raw : (List<Object>) arList) {
          Map<String, Object> ar = (Map<String, Object>) raw;
          String objType = (String) ar.get('objectType');
          Object rules = ar.get('rules');
          if (rules instanceof List<Object>) {
            for (Object rRaw : (List<Object>) rules) {
              Map<String, Object> rule = (Map<String, Object>) rRaw;
              String ruleName = (String) rule.get('fullName');
              if (
                iname.equalsIgnoreCase(objType + '.' + ruleName) ||
                iname.equalsIgnoreCase(ruleName)
              ) {
                return true;
              }
            }
          }

        }
      }
      return false;
    }

    // Unknown/unmapped type — no dedicated ground truth available;
    // trust the LLM's own claim rather than block it.
    return claimedExists;
  }

  private static Boolean listContainsIgnoreCase(Object rawList, String target) {
    if (!(rawList instanceof List<Object>) || String.isBlank(target)) {
      return false;
    }
    for (Object o : (List<Object>) rawList) {
      if (target.equalsIgnoreCase(String.valueOf(o))) {
        return true;
      }
    }
    return false;
  }

  private static Boolean matchesMapListByKeys(
    Object rawList,
    String target,
    List<String> keys
  ) {
    if (!(rawList instanceof List<Object>) || String.isBlank(target)) {
      return false;
    }
    for (Object raw : (List<Object>) rawList) {
      if (!(raw instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> m = (Map<String, Object>) raw;
      for (String k : keys) {
        Object v = m.get(k);
        if (v != null && target.equalsIgnoreCase(String.valueOf(v))) {
          return true;
        }
      }
    }
    return false;
  }

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

      Long routerCallStart = Datetime.now().getTime();
      Map<String, Object> routerResponse = LLMGroqClient.callLLM(
        routerMessages,
        new List<Map<String, Object>>(),
        null
      );
      System.debug(
        '[LLM-TRACE] router-call | ' +
          (Datetime.now().getTime() - routerCallStart) +
          'ms'
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

    Long generateCallStart = Datetime.now().getTime();
    Map<String, Object> response = LLMGroqClient.callLLM(
      messages,
      new List<Map<String, Object>>(),
      null,
      8096
    );
    System.debug(
      '[LLM-TRACE] generate-call | ' +
        (Datetime.now().getTime() - generateCallStart) +
        'ms'
    );
    List<Object> choices = (List<Object>) response.get('choices');
    Map<String, Object> choice = (Map<String, Object>) choices[0];
    Map<String, Object> message = (Map<String, Object>) choice.get('message');
    String content = (String) message.get('content');

    System.debug('=== RAW LLM XML RESPONSE START ===');
    System.debug(content);
    System.debug('=== RAW LLM XML RESPONSE END ===');
    System.debug('── STAGE 2 raw LLM response: ' + content);

    if (hasInvalidApexSource(content)) {
      System.debug(
        '[DEPLOY-TRACE] Blank or placeholder Apex source detected in LLM response; requesting one repair attempt.'
      );
      messages.add(
        new Map<String, Object>{ 'role' => 'assistant', 'content' => content }
      );
      messages.add(
        new Map<String, Object>{
          'role' => 'user',
          'content' => 'The previous JSON is invalid because one or more ApexClass or ApexTrigger files ' +
          'have blank source or placeholder comments instead of real logic. Return the COMPLETE corrected JSON again. ' +
          'For ApexTrigger .trigger files, xmlContent must start with "trigger ". ' +
          'For ApexClass .cls files, xmlContent must contain the full public class source. ' +
          'Do not leave any Apex source blank. Do not include TODO, placeholder, or "logic here" comments. ' +
          'Implement the exact business logic from the Jira ticket. Return ONLY valid JSON.'
        }
      );

      Long repair1CallStart = Datetime.now().getTime();
      Map<String, Object> retryResponse = LLMGroqClient.callLLM(
        messages,
        new List<Map<String, Object>>(),
        null,
        8096
      );
      System.debug(
        '[LLM-TRACE] generate-repair-1 | ' +
          (Datetime.now().getTime() - repair1CallStart) +
          'ms'
      );
      List<Object> retryChoices = (List<Object>) retryResponse.get('choices');
      Map<String, Object> retryChoice = (Map<String, Object>) retryChoices[0];
      Map<String, Object> retryMessage = (Map<String, Object>) retryChoice.get(
        'message'
      );
      content = (String) retryMessage.get('content');

      System.debug('=== RAW LLM XML REPAIR RESPONSE START ===');
      System.debug(content);
      System.debug('=== RAW LLM XML REPAIR RESPONSE END ===');
    }

    try {
      return processXmlGenerationResponse(content, issueKey, orgState);
    } catch (ApexCodeValidator.ValidationException ve) {
      System.debug(
        '[APEX-VALIDATOR] Caught ValidationException — requesting targeted repair: ' +
        ve.getMessage()
      );
      messages.add(
        new Map<String, Object>{ 'role' => 'assistant', 'content' => content }
      );
      messages.add(
        new Map<String, Object>{
          'role' => 'user',
          'content' => 'The generated Apex code failed static analysis with this error:\n' +
          ve.getMessage() +
          '\n\nReturn the COMPLETE corrected JSON. Fix ONLY the identified issue — do not change other files. ' +
          'Key rules to remember:\n' +
          '- Use && for logical AND and || for logical OR in Apex (not AND/OR — those are SOQL-only).\n' +
          '- Every opening brace { must have a matching closing brace }.\n' +
          'Return ONLY valid JSON with no markdown fences.'
        }
      );
      Long repair2CallStart = Datetime.now().getTime();
      Map<String, Object> repairResponse = LLMGroqClient.callLLM(
        messages,
        new List<Map<String, Object>>(),
        null,
        8096
      );
      System.debug(
        '[LLM-TRACE] generate-repair-2 | ' +
          (Datetime.now().getTime() - repair2CallStart) +
          'ms'
      );
      List<Object> repairChoices = (List<Object>) repairResponse.get('choices');
      Map<String, Object> repairChoice = (Map<String, Object>) repairChoices[0];
      Map<String, Object> repairMsg = (Map<String, Object>) repairChoice.get(
        'message'
      );
      content = (String) repairMsg.get('content');
      FunctionHelper.hadError = false;
      System.debug(
        '[APEX-VALIDATOR] Repair response received — re-processing.'
      );
      try {
        return processXmlGenerationResponse(content, issueKey, orgState);
      } catch (ApexCodeValidator.ValidationException ve2) {
        System.debug(
          '[APEX-VALIDATOR] Repair attempt still failed validation: ' +
          ve2.getMessage()
        );
        FunctionHelper.hadError = true;
        return 'Error: Apex code failed static validation after repair attempt: ' +
          ve2.getMessage();
      }
    }
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

    // ── FORCE SINGLE-DEPLOY ────────────────────────────────────
    // A new CustomObject + its Layout previously deployed in two chained
    // rounds (ZIP1 = object/tab/profiles, then — only after ZIP1 fully
    // succeeds — ZIP2 = layout). That second Metadata API deploy + poll
    // cycle added ~15-20s of wall-clock time to every object-creation
    // ticket. Salesforce resolves intra-deployment dependencies, so the
    // object, its fields, and the layout that references them can all
    // deploy together in ONE round. Forcing 'single' routes every file
    // into ZIP1 via the normal ZipBuilder path; the existing single-deploy
    // promotion block (further below) folds in any backstop-generated
    // layouts, and no ZIP2 is ever staged.
    if (deployScenario == 'chained') {
      System.debug(
        '[DEPLOY-TRACE] *** FORCE SINGLE *** merging chained ZIP1+ZIP2 into one deploy'
      );
      deployScenario = 'single';
      zip2FilePaths.clear();
    }

    Map<String, String> zip2Files = new Map<String, String>();
    Map<String, Set<String>> zip2MetadataTypes = new Map<String, Set<String>>();

    // ── Apex test validation tracking ──────────────────────────
    List<String> detectedApexNames = new List<String>();
    List<String> detectedApexContents = new List<String>();
    List<String> detectedTestNames = new List<String>();
    List<String> detectedTestContents = new List<String>();

    List<Object> files = (List<Object>) parsed.get('files');

    // ── Schema-aware field validation setup (runs before files loop) ──
    // Reset per-response so a previous repair attempt's pending fields don't
    // leak in, then register every field newly declared in this response's
    // CustomObject files as "pending" — those legitimately don't exist in
    // the org yet, so field-existence checks below must accept them too.
    SchemaFieldValidator.reset();
    SchemaFieldValidator.registerPendingFieldsFromResponse(files);

    // Objects with at least one field declaring trackHistory=true — their
    // CustomObject file needs enableHistory=true too, or the field-level
    // setting silently does nothing. See collectObjectsNeedingHistoryTracking().
    Set<String> objectsNeedingHistoryTracking = LLMXmlSanitizer.collectObjectsNeedingHistoryTracking(
      files
    );

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
          xmlContent = LLMXmlSanitizer.sanitizePermissionSetXml(xmlContent);
          xmlContent = PermissionSetHelper.ensureParentReadAccessForXml(
            xmlContent
          );
          // Strip viewAllFields again — parent injector may reintroduce it
          xmlContent = xmlContent.replaceAll(
            '(?s)\\s*<viewAllFields>[^<]*</viewAllFields>',
            ''
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
          xmlContent = LLMXmlSanitizer.normalizeFormulaFieldTypesInCustomObjectXml(
            xmlContent
          );
        }

        if (metadataType == 'CustomField') {
          xmlContent = LLMXmlSanitizer.normalizeFormulaFieldTypeInCustomFieldXml(
            xmlContent
          );
        }

        if (
          metadataType == 'CustomObject' &&
          memberName != null &&
          memberName.endsWith('__c') &&
          orgState != null
        ) {
          Set<String> existingObjs = new Set<String>();
          Object rawObjs = orgState.get('existingObjects');
          if (rawObjs instanceof List<Object>) {
            for (Object o : (List<Object>) rawObjs) {
              if (o != null) {
                existingObjs.add(String.valueOf(o));
              }
            }
          }
          if (existingObjs.contains(memberName)) {
            xmlContent = LLMXmlSanitizer.sanitizeExistingCustomObjectXml(
              xmlContent
            );
            System.debug(
              '[DEPLOY-TRACE] sanitizeExistingCustomObjectXml applied to [' +
                filePath +
                ']'
            );
          }
          xmlContent = LLMXmlSanitizer.injectMissingXmlDefaults(
            'CustomObject',
            xmlContent
          );
          System.debug(
            '[DEPLOY-TRACE] injectMissingXmlDefaults applied to [' +
              filePath +
              ']'
          );
          if (objectsNeedingHistoryTracking.contains(memberName)) {
            xmlContent = LLMXmlSanitizer.forceEnableHistory(xmlContent);
            System.debug(
              '[DEPLOY-TRACE] forceEnableHistory applied to [' +
                filePath +
                '] — a field on this object declares trackHistory=true'
            );
          }
        }

        // ── VALIDATE VALIDATION RULE FIELD TYPES before deployment ──────
        if (metadataType == 'CustomObject' && String.isNotBlank(memberName)) {
          try {
            LLMXmlSanitizer.validateValidationRuleFieldTypes(
              memberName,
              xmlContent
            );
          } catch (ApexCodeValidator.ValidationException e) {
            System.debug(
              'processXmlGenerationResponse: validation rule field check FAILED for [' +
                filePath +
                ']: ' +
                e.getMessage()
            );
            throw e; // re-throw so runXmlGenerationStage() retry can catch, repair, and re-process
          }
        }

        if (metadataType == 'Layout') {
          xmlContent = LLMXmlSanitizer.sanitizeLayoutXml(xmlContent);

          if (memberName != null && memberName.contains('-')) {
            String layoutParentObj = memberName.substringBefore('-');
            String nameFieldType = 'Text';
            for (Object f2Raw : files) {
              Map<String, Object> f2 = (Map<String, Object>) f2Raw;
              if (
                'CustomObject'.equals(f2.get('metadataType')) &&
                layoutParentObj.equals(f2.get('memberName'))
              ) {
                String coXml = (String) f2.get('xmlContent');
                if (String.isNotBlank(coXml)) {
                  Pattern nfPat = Pattern.compile(
                    '(?s)<nameField>.*?<type>(\\w+)</type>.*?</nameField>'
                  );
                  Matcher nfMat = nfPat.matcher(coXml);
                  if (nfMat.find()) {
                    nameFieldType = nfMat.group(1).trim();
                  }
                }
                break;
              }
            }
            xmlContent = LLMXmlSanitizer.fixNameFieldBehaviorInLayout(
              xmlContent,
              nameFieldType
            );
          }

          if (
            memberName != null &&
            memberName.contains('-') &&
            orgState != null
          ) {
            String parentObj = memberName.substringBefore('-');
            Set<String> existingObjs = new Set<String>();
            Object rawObjs = orgState.get('existingObjects');
            if (rawObjs instanceof List<Object>) {
              for (Object o : (List<Object>) rawObjs) {
                if (o != null) {
                  existingObjs.add(String.valueOf(o));
                }
              }
            }
            if (existingObjs.contains(parentObj)) {
              // Collect new fields defined in sibling CustomObject/CustomField
              // files so they are injected even if the LLM's layout XML omits
              // them (LLMs frequently generate a layout without referencing the
              // exact field API names of the fields they just created).
              List<String> siblingNewFields = new List<String>();
              for (Object f2Raw : files) {
                Map<String, Object> f2 = (Map<String, Object>) f2Raw;
                String f2mt = (String) f2.get('metadataType');
                String f2mn = (String) f2.get('memberName');
                if (f2mt == 'CustomObject' && parentObj.equals(f2mn)) {
                  List<Map<String, String>> fis = LLMLayoutHelper.extractFieldInfosFromObjectXml(
                    (String) f2.get('xmlContent')
                  );
                  for (Map<String, String> fi : fis) {
                    siblingNewFields.add(fi.get('name'));
                  }
                } else if (
                  f2mt == 'CustomField' &&
                  f2mn != null &&
                  f2mn.contains('.') &&
                  parentObj.equals(f2mn.substringBefore('.'))
                ) {
                  siblingNewFields.add(f2mn.substringAfter('.'));
                }
              }

              String merged = LLMLayoutHelper.mergeLayoutForExistingObject(
                memberName,
                xmlContent,
                siblingNewFields
              );
              if (String.isNotBlank(merged)) {
                xmlContent = merged;
                System.debug(
                  '[DEPLOY-TRACE] mergeLayoutForExistingObject applied to [' +
                    memberName +
                    ']'
                );
              } else if (!siblingNewFields.isEmpty()) {
                // Metadata API unavailable — inject sibling new fields
                // directly into the LLM's layout XML (no API call needed).
                xmlContent = LLMLayoutHelper.injectNewFieldsIntoLayoutXml(
                  xmlContent,
                  siblingNewFields
                );
                System.debug(
                  '[DEPLOY-TRACE] Layout fallback injection: added ' +
                    siblingNewFields +
                    ' directly into [' +
                    memberName +
                    ']'
                );
              }
            }
          }

          // Force Readonly on all formula/rollup/autonumber fields — runs
          // after merge/injection so behavior is safe for final layout XML.
          if (memberName != null && memberName.contains('-')) {
            String lParentObj = memberName.substringBefore('-');
            Set<String> formulaFields = new Set<String>();
            for (Object f3Raw : files) {
              Map<String, Object> f3 = (Map<String, Object>) f3Raw;
              String f3mt = (String) f3.get('metadataType');
              String f3mn = (String) f3.get('memberName');
              String f3Xml = (String) f3.get('xmlContent');
              if (String.isBlank(f3Xml)) {
                continue;
              }
              if ('CustomObject'.equals(f3mt) && lParentObj.equals(f3mn)) {
                formulaFields.addAll(LLMXmlSanitizer.extractFormulaFieldNames(f3Xml));
              } else if (
                'CustomField'.equals(f3mt) &&
                f3mn != null &&
                f3mn.contains('.') &&
                lParentObj.equals(f3mn.substringBefore('.')) &&
                f3Xml.contains('<formula>')
              ) {
                formulaFields.add(f3mn.substringAfter('.'));
              }
            }

            // Fallback for existing objects: if this run doesn't include
            // sibling field XML, infer readonly fields directly from schema.
            for (String layoutField : LLMLayoutHelper.extractFieldNamesFromLayoutXml(
              xmlContent
            )) {
              if (
                SchemaFieldValidator.isLayoutReadOnlyField(
                  lParentObj,
                  layoutField
                )
              ) {
                formulaFields.add(layoutField);
              }
            }

            if (!formulaFields.isEmpty()) {
              xmlContent = LLMXmlSanitizer.fixFormulaFieldBehaviorsInLayout(
                xmlContent,
                formulaFields
              );
            }
          }
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
          xmlContent = LLMXmlSanitizer.defaultCustomTabVisibilityToOn(
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

        // Trust the file extension over the LLM's self-reported metadataType
        // for the ApexClass/ApexTrigger distinction. A mismatch here (e.g. a
        // trigger's meta file mislabeled ApexClassMeta) registers the member
        // in package.xml under the wrong type with no matching zipped file,
        // causing "named in package.xml but not found in zipped directory".
        // No-op when the LLM already got it right.
        if (
          filePath != null &&
          (effectiveType == 'ApexClass' ||
          effectiveType == 'ApexTrigger')
        ) {
          String lowerPath = filePath.toLowerCase();
          if (
            (lowerPath.endsWith('.trigger') ||
            lowerPath.endsWith('.trigger-meta.xml')) &&
            effectiveType != 'ApexTrigger'
          ) {
            System.debug(
              '[DEPLOY-TRACE] TYPE CORRECTION — [' +
                filePath +
                '] declared as [' +
                effectiveType +
                '] but extension indicates ApexTrigger. Correcting.'
            );
            effectiveType = 'ApexTrigger';
          } else if (
            (lowerPath.endsWith('.cls') ||
            lowerPath.endsWith('.cls-meta.xml')) && effectiveType != 'ApexClass'
          ) {
            System.debug(
              '[DEPLOY-TRACE] TYPE CORRECTION — [' +
                filePath +
                '] declared as [' +
                effectiveType +
                '] but extension indicates ApexClass. Correcting.'
            );
            effectiveType = 'ApexClass';
          }
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

        if (metadataType == 'Profile') {
          // NOTE: custom-object (__c) tabVisibilities are intentionally left
          // alone here — LLMXmlSanitizer.sanitizeProfileStandardObjectTabs()
          // already ran above and stripped only the standard-object entries.
          // Blanket-stripping ALL tabVisibilities here previously left every
          // newly created custom tab with no visibility on any profile, so
          // the tab existed (Setup > Tabs) but could never be added to a
          // Lightning app's navigation — nothing had made it visible.
          //
          // Salesforce rejects fieldPermissions entries for required fields
          // ("You cannot deploy to a required field: Object__c.Field__c") —
          // required fields get implicit read/edit access already. Same
          // safeguard PermissionSet files already get below.
          xmlContent = PermissionSetHelper.stripRequiredFieldPermissions(
            xmlContent
          );
        }

        // When a permissionSetClone already staged this file path, merge the
        // new permissions into the cloned XML instead of overwriting it.
        // Without this, the LLM's files[] entry (containing only the new
        // object permissions) would silently replace the full cloned XML,
        // losing all permissions that existed in the source permission set.
        if (metadataType == 'PermissionSet') {
          if (ZipBuilder.files.containsKey(filePath)) {
            String clonedXml = ZipBuilder.files.get(filePath);
            xmlContent = PermissionSetHelper.mergePermissionXml(
              clonedXml,
              xmlContent
            );
            System.debug(
              'processXmlGenerationResponse: merged new PS permissions into cloned base [' +
                filePath +
                ']'
            );
          }
          xmlContent = PermissionSetHelper.stripRequiredFieldPermissions(
            xmlContent
          );
          // Final safety strip — remove viewAllFields which is invalid in PS metadata v61+
          xmlContent = xmlContent.replaceAll(
            '(?s)\\s*<viewAllFields>[^<]*</viewAllFields>',
            ''
          );
        }

        // ── VALIDATE APEX CODE before deployment ──────────────────────
        if (isApexCode || metadataType == 'ApexTrigger') {
          try {
            ApexCodeValidator.validate(filePath, xmlContent);
          } catch (ApexCodeValidator.ValidationException e) {
            System.debug(
              'processXmlGenerationResponse: Apex validation FAILED for [' +
                filePath +
                ']: ' +
                e.getMessage()
            );
            throw e; // re-throw so runXmlGenerationStage() retry can catch, repair, and re-process
          }
        }

        // ── VALIDATE SOQL FIELD EXISTENCE before deployment ────────────
        if (isApexCode) {
          try {
            LLMXmlSanitizer.validateSoqlFieldsExist(filePath, xmlContent);
          } catch (ApexCodeValidator.ValidationException e) {
            System.debug(
              'processXmlGenerationResponse: SOQL field check FAILED for [' +
                filePath +
                ']: ' +
                e.getMessage()
            );
            throw e; // re-throw so runXmlGenerationStage() retry can catch, repair, and re-process
          }
        }

        // ── VALIDATE LWC SOURCE before deployment ──────────────────────
        if (isLwcHtml || isLwcJs) {
          try {
            LwcCodeValidator.validate(filePath, xmlContent);
          } catch (ApexCodeValidator.ValidationException e) {
            System.debug(
              'processXmlGenerationResponse: LWC validation FAILED for [' +
                filePath +
                ']: ' +
                e.getMessage()
            );
            throw e; // re-throw so runXmlGenerationStage() retry can catch, repair, and re-process
          }
        }

        // ── VALIDATE LWC SCHEMA IMPORTS before deployment ──────────────
        if (isLwcJs) {
          try {
            LLMXmlSanitizer.validateLwcSchemaImports(filePath, xmlContent);
          } catch (ApexCodeValidator.ValidationException e) {
            System.debug(
              'processXmlGenerationResponse: LWC schema import check FAILED for [' +
                filePath +
                ']: ' +
                e.getMessage()
            );
            throw e; // re-throw so runXmlGenerationStage() retry can catch, repair, and re-process
          }
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

    // ── Stage Apex context if classes detected ──────────────
    pendingApexClassNames = null;
    pendingApexClassContents = null;
    pendingTestClassNames = null;
    pendingTestClassContents = null;
    if (!detectedApexNames.isEmpty()) {
      pendingApexClassNames = detectedApexNames;
      pendingApexClassContents = detectedApexContents;
      // Test classes are optional; only stage if detected
      if (!detectedTestNames.isEmpty()) {
        pendingTestClassNames = detectedTestNames;
        pendingTestClassContents = detectedTestContents;
        System.debug(
          '[APEX-TEST] Staged: ' +
            detectedApexNames.size() +
            ' class(es), ' +
            detectedTestNames.size() +
            ' test class(es)'
        );
      } else {
        System.debug(
          '[APEX-TEST] Staged: ' +
            detectedApexNames.size() +
            ' class(es), no test class(es) (optional)'
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
    // Inject default FLS (fieldPermissions) for all new custom fields
    // into every Profile file already staged in ZipBuilder
    LLMXmlSanitizer.injectDefaultFieldPermissions(files);
    // Guarantee Admin gets DefaultOn visibility for every new custom tab
    LLMXmlSanitizer.injectDefaultTabVisibility(files);

    // ── Promote backstop layout files into ZIP1 for single deploys ─────────
    // When adding fields to an existing object (deployScenario='single'),
    // the backstop may produce layout files in zip2Files. Rather than
    // triggering a second deploy chain, inject them directly into ZIP1.
    if (deployScenario == 'single' && !zip2Files.isEmpty()) {
      Set<String> promoted = new Set<String>();
      for (String path : zip2Files.keySet()) {
        if (!path.startsWith('layouts/')) {
          continue;
        }
        String layoutFullName = path.removeStart('layouts/')
          .removeEnd('.layout');
        String safeLayoutXml = enforceReadonlyFormulaFieldsInLayout(
          layoutFullName,
          zip2Files.get(path),
          files
        );
        ZipBuilder.addFile('Layout', layoutFullName, path, safeLayoutXml);
        promoted.add(path);
        System.debug(
          '[DEPLOY-TRACE] promoted backstop Layout to ZIP1: ' + path
        );
      }
      for (String path : promoted) {
        zip2Files.remove(path);
        if (zip2MetadataTypes.containsKey('Layout')) {
          String layoutFullName = path.removeStart('layouts/')
            .removeEnd('.layout');
          zip2MetadataTypes.get('Layout').remove(layoutFullName);
          if (zip2MetadataTypes.get('Layout').isEmpty()) {
            zip2MetadataTypes.remove('Layout');
          }
        }
      }
    }

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
          if (String.isBlank(metadataType)) {
            metadataType = (String) file.get('type');
          }
          String memberName = (String) file.get('member');
          if (String.isBlank(memberName)) {
            memberName = (String) file.get('memberName');
          }
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
      for (String path : new List<String>(zip2Files.keySet())) {
        if (!path.startsWith('layouts/')) {
          continue;
        }
        String layoutFullName = path.removeStart('layouts/')
          .removeEnd('.layout');
        zip2Files.put(
          path,
          enforceReadonlyFormulaFieldsInLayout(
            layoutFullName,
            zip2Files.get(path),
            files
          )
        );
      }

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
  private static String enforceReadonlyFormulaFieldsInLayout(
    String layoutFullName,
    String layoutXml,
    List<Object> files
  ) {
    if (
      String.isBlank(layoutXml) ||
      String.isBlank(layoutFullName) ||
      !layoutFullName.contains('-')
    ) {
      return layoutXml;
    }

    String parentObj = layoutFullName.substringBefore('-');
    Set<String> readOnlyFields = new Set<String>();

    if (files != null) {
      for (Object rawFile : files) {
        Map<String, Object> f = (Map<String, Object>) rawFile;
        String mt = (String) f.get('metadataType');
        String mn = (String) f.get('memberName');
        String x = (String) f.get('xmlContent');
        if (String.isBlank(x)) {
          continue;
        }

        if ('CustomObject'.equals(mt) && parentObj.equals(mn)) {
          readOnlyFields.addAll(LLMXmlSanitizer.extractFormulaFieldNames(x));
        } else if (
          'CustomField'.equals(mt) &&
          mn != null &&
          mn.contains('.') &&
          parentObj.equals(mn.substringBefore('.')) &&
          x.contains('<formula>')
        ) {
          readOnlyFields.add(mn.substringAfter('.'));
        }
      }
    }

    for (String layoutField : LLMLayoutHelper.extractFieldNamesFromLayoutXml(
      layoutXml
    )) {
      if (SchemaFieldValidator.isLayoutReadOnlyField(parentObj, layoutField)) {
        readOnlyFields.add(layoutField);
      }
    }

    if (readOnlyFields.isEmpty()) {
      return layoutXml;
    }
    return LLMXmlSanitizer.fixFormulaFieldBehaviorsInLayout(
      layoutXml,
      readOnlyFields
    );
  }

  private static Boolean hasInvalidApexSource(String llmResponse) {
    if (String.isBlank(llmResponse)) {
      return false;
    }

    try {
      String cleaned = LLMGroqClient.cleanJsonResponse(llmResponse);
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        cleaned
      );
      List<Object> files = (List<Object>) parsed.get('files');
      if (files == null || files.isEmpty()) {
        return false;
      }

      for (Object rawFile : files) {
        Map<String, Object> file = (Map<String, Object>) rawFile;
        String metadataType = (String) file.get('metadataType');
        if (metadataType != 'ApexClass' && metadataType != 'ApexTrigger') {
          continue;
        }

        String xmlContent = (String) file.get('xmlContent');
        if (String.isBlank(xmlContent)) {
          return true;
        }

        String upperContent = xmlContent.toUpperCase();
        if (
          upperContent.contains('LOGIC HERE') ||
          upperContent.contains('PLACEHOLDER') ||
          upperContent.contains('IMPLEMENTATION HERE') ||
          upperContent.contains('ADD LOGIC') ||
          upperContent.contains('TODO') ||
          upperContent.contains('FIXME')
        ) {
          return true;
        }
      }
    } catch (Exception e) {
      System.debug(
        'hasInvalidApexSource: skipped preflight due to parse error: ' +
        e.getMessage()
      );
    }

    return false;
  }

  public static List<String> extractRecordTypeNamesFromObjectXml(
    String xmlContent
  ) {
    List<String> result = new List<String>();
    if (String.isBlank(xmlContent) || !xmlContent.contains('<recordTypes>')) {
      return result;
    }

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

        String normalizedCsvType = csvType == null
          ? ''
          : csvType.toLowerCase().trim().replace('objects', 'object');

        if (normalizedCsvType == 'custom_object') {
          generateCustomObjectsFromCsvWithLlm(fileName);
          System.debug(
            'processDmlOperations: custom_object CSV — LLM generation complete for [' +
              fileName +
              ']'
          );
        } else {
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

  // ─────────────────────────────────────────────────────────────
  // CSV CUSTOM OBJECT — LLM-BASED XML GENERATION
  //
  // Reads the cached CSV rows for the given file, groups them by
  // objectApiName, builds a compact definitions JSON, and calls
  // the LLM to produce CustomObject + CustomField metadata XML in
  // the standard files[] format.  The files are added directly to
  // ZipBuilder — identical to the ticket-based flow.
  //
  // Expected CSV columns (object-level, repeated per field row):
  //   objectApiName, objectLabel, objectPluralLabel, sharingModel,
  //   nameFieldLabel, nameFieldType, description,
  //   enableActivities, enableHistory, enableReports
  // Field columns (one per row):
  //   fieldName, fieldLabel, fieldType,
  //   length, precision, scale, required, defaultValue,
  //   picklistValues (semicolon-separated)
  // ─────────────────────────────────────────────────────────────
  private static void generateCustomObjectsFromCsvWithLlm(String fileName) {
    List<Map<String, Object>> rows = CsvProcessor.getCachedRows(fileName);
    if (rows == null || rows.isEmpty()) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: no cached rows for [' +
          fileName +
          ']. Call csv_read first.'
      );
    }

    // ── Group rows by objectApiName ───────────────────────────
    Map<String, Map<String, Object>> firstRowByObj = new Map<String, Map<String, Object>>();
    Map<String, List<Map<String, Object>>> fieldRowsByObj = new Map<String, List<Map<String, Object>>>();

    for (Map<String, Object> row : rows) {
      String rawName = csvStr(row, 'objectApiName');
      if (String.isBlank(rawName)) {
        rawName = csvStr(row, 'apiName');
      }
      if (String.isBlank(rawName)) {
        continue;
      }
      String apiName = rawName.endsWith('__c') ? rawName : rawName + '__c';

      if (!firstRowByObj.containsKey(apiName)) {
        firstRowByObj.put(apiName, row);
        fieldRowsByObj.put(apiName, new List<Map<String, Object>>());
      }
      if (String.isNotBlank(csvStr(row, 'fieldName'))) {
        fieldRowsByObj.get(apiName).add(row);
      }
    }

    if (firstRowByObj.isEmpty()) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: no valid objectApiName values in [' +
          fileName +
          ']'
      );
    }

    // ── Build compact definitions JSON ────────────────────────
    List<Map<String, Object>> objDefs = new List<Map<String, Object>>();

    for (String apiName : firstRowByObj.keySet()) {
      Map<String, Object> meta = firstRowByObj.get(apiName);
      String defaultLabel = apiName.replace('__c', '').replace('_', ' ');

      List<Map<String, Object>> fieldDefs = new List<Map<String, Object>>();
      for (Map<String, Object> row : fieldRowsByObj.get(apiName)) {
        String fn = csvStr(row, 'fieldName');
        if (String.isBlank(fn)) {
          continue;
        }
        if (!fn.endsWith('__c')) {
          fn += '__c';
        }

        Map<String, Object> fDef = new Map<String, Object>{
          'name' => fn,
          'label' => csvStr(row, 'fieldLabel'),
          'type' => csvStr(row, 'fieldType')
        };
        String len = csvStr(row, 'length');
        String pre = csvStr(row, 'precision');
        String scl = csvStr(row, 'scale');
        String req = csvStr(row, 'required');
        String dv = csvStr(row, 'defaultValue');
        String pvs = csvStr(row, 'picklistValues');
        if (String.isNotBlank(len)) {
          fDef.put('length', len);
        }
        if (String.isNotBlank(pre)) {
          fDef.put('precision', pre);
        }
        if (String.isNotBlank(scl)) {
          fDef.put('scale', scl);
        }
        if (String.isNotBlank(req)) {
          fDef.put('required', req);
        }
        if (String.isNotBlank(dv)) {
          fDef.put('defaultValue', dv);
        }
        if (String.isNotBlank(pvs)) {
          fDef.put('picklistValues', pvs);
        }
        fieldDefs.add(fDef);
      }

      String resolvedLabel = csvStr(meta, 'objectLabel');
      if (String.isBlank(resolvedLabel)) {
        resolvedLabel = csvStrDef(meta, 'label', defaultLabel);
      }
      String resolvedPluralLabel = csvStr(meta, 'objectPluralLabel');
      if (String.isBlank(resolvedPluralLabel)) {
        resolvedPluralLabel = csvStrDef(
          meta,
          'pluralLabel',
          defaultLabel + 's'
        );
      }

      Map<String, Object> objDef = new Map<String, Object>{
        'apiName' => apiName,
        'label' => resolvedLabel,
        'pluralLabel' => resolvedPluralLabel,
        'sharingModel' => csvStrDef(meta, 'sharingModel', 'ReadWrite'),
        'nameFieldLabel' => csvStrDef(
          meta,
          'nameFieldLabel',
          defaultLabel + ' Name'
        ),
        'nameFieldType' => csvStrDef(meta, 'nameFieldType', 'Text'),
        'fields' => fieldDefs
      };
      String objDesc = csvStr(meta, 'description');
      if (String.isNotBlank(objDesc)) {
        objDef.put('description', objDesc);
      }
      String enAct = csvStr(meta, 'enableActivities');
      String enHist = csvStr(meta, 'enableHistory');
      String enRep = csvStr(meta, 'enableReports');
      if (String.isNotBlank(enAct)) {
        objDef.put('enableActivities', enAct);
      }
      if (String.isNotBlank(enHist)) {
        objDef.put('enableHistory', enHist);
      }
      if (String.isNotBlank(enRep)) {
        objDef.put('enableReports', enRep);
      }

      objDefs.add(objDef);
    }

    String definitionsJson = JSON.serialize(
      new Map<String, Object>{ 'objects' => objDefs }
    );
    System.debug(
      'generateCustomObjectsFromCsvWithLlm: definitions = ' + definitionsJson
    );

    // ── Build LLM messages ────────────────────────────────────
    String systemPrompt = PromptService.getPromptByKey('CSV_OBJECT_GENERATION');
    if (String.isBlank(systemPrompt)) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: CSV_OBJECT_GENERATION prompt not found in LLM_Prompt__mdt. Deploy the CMT record.'
      );
    }

    String userPrompt =
      'Generate Salesforce custom object and field metadata XML for:\n' +
      definitionsJson;

    List<Map<String, Object>> messages = new List<Map<String, Object>>{
      new Map<String, Object>{ 'role' => 'system', 'content' => systemPrompt },
      new Map<String, Object>{ 'role' => 'user', 'content' => userPrompt }
    };

    // ── Call LLM ─────────────────────────────────────────────
    System.debug(
      'generateCustomObjectsFromCsvWithLlm: calling LLM for [' +
        fileName +
        ']...'
    );
    Map<String, Object> llmResponse = LLMGroqClient.callLLM(
      messages,
      null,
      null,
      8192
    );

    List<Object> choices = (List<Object>) llmResponse.get('choices');
    if (choices == null || choices.isEmpty()) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: LLM returned no choices for [' +
          fileName +
          ']'
      );
    }
    Map<String, Object> msg = (Map<String, Object>) ((Map<String, Object>) choices[0])
      .get('message');
    String content = (String) msg.get('content');
    System.debug(
      'generateCustomObjectsFromCsvWithLlm: LLM raw response = ' + content
    );

    // ── Parse files[] ─────────────────────────────────────────
    String cleanedJson = LLMGroqClient.cleanJsonResponse(content);
    Map<String, Object> parsed;
    try {
      parsed = (Map<String, Object>) JSON.deserializeUntyped(cleanedJson);
    } catch (Exception e) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: JSON parse failed — ' +
          e.getMessage() +
          ' | raw: ' +
          content
      );
    }

    List<Object> files = (List<Object>) parsed.get('files');
    if (files == null || files.isEmpty()) {
      throw new LLMService.LLMException(
        'generateCustomObjectsFromCsvWithLlm: LLM returned no files[] for [' +
          fileName +
          ']'
      );
    }

    // ── Stage each file into ZipBuilder ──────────────────────
    Integer count = 0;
    for (Object fileObj : files) {
      Map<String, Object> file = (Map<String, Object>) fileObj;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String filePath = (String) file.get('filePath');
      String xmlContent = (String) file.get('xmlContent');

      if (String.isBlank(filePath) || String.isBlank(xmlContent)) {
        System.debug(
          'generateCustomObjectsFromCsvWithLlm: skipping file with blank path or content'
        );
        continue;
      }

      // Strip root-level <apiName> — invalid in CustomObject; name is determined by file path
      if (metadataType == 'CustomObject') {
        xmlContent = xmlContent.replaceAll('<apiName>[^<]*</apiName>', '');
      }

      String effectiveType = String.isNotBlank(metadataType)
        ? metadataType
        : 'CustomObject';
      String effectiveMember = String.isNotBlank(memberName)
        ? memberName
        : filePath;

      ZipBuilder.addFile(effectiveType, effectiveMember, filePath, xmlContent);
      System.debug(
        'generateCustomObjectsFromCsvWithLlm: staged [' +
          filePath +
          '] as [' +
          effectiveType +
          ']'
      );
      count++;
    }

    // Inject default FLS for all new custom fields into any Profile files staged
    LLMXmlSanitizer.injectDefaultFieldPermissions(files);
    // Guarantee Admin gets DefaultOn visibility for every new custom tab
    LLMXmlSanitizer.injectDefaultTabVisibility(files);

    System.debug(
      'generateCustomObjectsFromCsvWithLlm: ' +
        count +
        ' file(s) staged for deploy from [' +
        fileName +
        ']'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // ROW HELPERS (used only by generateCustomObjectsFromCsvWithLlm)
  // ─────────────────────────────────────────────────────────────
  private static String csvStr(Map<String, Object> row, String key) {
    Object val = row?.get(key);
    if (val == null) {
      return '';
    }
    String s = String.valueOf(val).trim();
    return (s == 'null') ? '' : s;
  }

  private static String csvStrDef(
    Map<String, Object> row,
    String key,
    String defaultVal
  ) {
    String v = csvStr(row, key);
    return String.isBlank(v) ? defaultVal : v;
  }
}
