/**
 * LwcCodeValidator — Static analysis for generated LWC HTML/JS source
 * Mirrors ApexCodeValidator's pattern: regex-based checks against known
 * failure signatures, called by LLMResponseProcessor before ZipBuilder
 * staging. Throws ApexCodeValidator.ValidationException (shared exception
 * type) so the existing repair-retry mechanism in
 * LLMResponseProcessor.runXmlGenerationStage handles LWC failures the
 * same way it already handles Apex failures, with no changes needed there.
 */
public class LwcCodeValidator {
  // ECMAScript reserved words most likely to collide with Salesforce object/
  // field names lowercased into a variable name by the LLM — "case" (the
  // Case object) being the one that actually broke a deploy. Full reserved
  // list kept rather than just "case" so the same generation habit doesn't
  // resurface under a different object/field name later (Lead → fine,
  // "Default" flag → default, a Delete action → delete, etc.).
  private static final Set<String> JS_RESERVED_WORDS = new Set<String>{
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'debugger',
    'default',
    'delete',
    'do',
    'else',
    'enum',
    'export',
    'extends',
    'false',
    'finally',
    'for',
    'function',
    'if',
    'implements',
    'import',
    'in',
    'instanceof',
    'interface',
    'let',
    'new',
    'null',
    'package',
    'private',
    'protected',
    'public',
    'return',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'typeof',
    'var',
    'void',
    'while',
    'with',
    'yield'
  };

  // Identifiers that CAN appear as the root of a {...} template binding
  // (they're valid JS syntax, so the "is this a bare identifier" regex in
  // validateTemplateBindingsDeclaredInJs matches them) but can NEVER
  // legitimately be a property/getter name the JS "declares" — they are
  // JS literals/keywords, not property names. Used to give these a
  // distinct, actually-fixable error instead of the generic "add a
  // matching field named exactly this" message, which is nonsensical
  // advice for a reserved word.
  private static final Set<String> JS_LITERAL_BINDING_ROOTS = new Set<String>{
    'true',
    'false',
    'null',
    'undefined',
    'NaN',
    'this'
  };

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE RULE: IMPERATIVE CALL TO A cacheable=true APEX METHOD
  // catches a real Salesforce platform gotcha, not a syntax error: a
  // cacheable Apex method can return a CACHED (stale) response even when
  // called imperatively, not just via @wire. A component that calls such a
  // method imperatively from a "Refresh"/reload action can look like it
  // works (the click handler runs, the spinner shows) while silently never
  // fetching fresh data — confirmed as a real incident 2026-08-20: a
  // Refresh button on accountContacts appeared broken because its
  // imperative getContacts() call hit AccountContactsController.getContacts,
  // which the LLM had marked @AuraEnabled(cacheable=true) per the general
  // "use cacheable=true for read-only methods" guidance, without noticing
  // the component never uses @wire at all.
  //
  // Cross-file by nature (the annotation lives in the .cls file, the call
  // site in the .js file), so unlike every other rule in this class it
  // cannot run through the per-file validate() entry point below — it scans
  // the WHOLE files[] list from one LLM response in a single pass. Called
  // from LLMResponseProcessor.processXmlGenerationResponse() before the
  // main per-file loop, same as LLMTriggerMerger.enforceTriggerMerge().
  //
  // Scope: only catches the pattern when both the Apex class and the LWC
  // JS are present in the SAME generation response. A cacheable method left
  // over from an earlier ticket that a later ticket calls imperatively
  // without regenerating the Apex file is not caught here — orgState's
  // existingLwcApexControllers would need to be threaded through too, which
  // this method doesn't currently do.
  // ─────────────────────────────────────────────────────────────
  public static void validateNoImperativeCallToCacheableMethod(
    List<Object> files
  ) {
    if (files == null || files.isEmpty()) {
      return;
    }

    // "ClassName.methodName" (lowercased) -> true, for every Apex method in
    // this batch annotated @AuraEnabled(cacheable=true).
    Set<String> cacheableMethods = new Set<String>();
    Pattern cacheableMethodPat = Pattern.compile(
      '(?is)@AuraEnabled\\s*\\(\\s*cacheable\\s*=\\s*true\\s*\\)\\s*' +
      '(?:public|global)\\s+static\\s+[\\w<>,.\\s]+?\\s+(\\w+)\\s*\\('
    );

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String xmlContent = (String) file.get('xmlContent');
      if (
        metadataType != 'ApexClass' ||
        String.isBlank(memberName) ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }
      Matcher m = cacheableMethodPat.matcher(xmlContent);
      while (m.find()) {
        cacheableMethods.add((memberName + '.' + m.group(1)).toLowerCase());
      }
    }

    if (cacheableMethods.isEmpty()) {
      return;
    }

    Pattern importPat = Pattern.compile(
      '(?m)^\\s*import\\s+(\\w+)\\s+from\\s+[\'"]@salesforce/apex/' +
      '(\\w+)\\.(\\w+)[\'"]'
    );

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String filePath = (String) file.get('filePath');
      String xmlContent = (String) file.get('xmlContent');
      if (
        filePath == null ||
        !filePath.toLowerCase().endsWith('.js') ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }

      Matcher importMatcher = importPat.matcher(xmlContent);
      while (importMatcher.find()) {
        String localName = importMatcher.group(1);
        String importedClass = importMatcher.group(2);
        String importedMethod = importMatcher.group(3);
        String key = (importedClass + '.' + importedMethod).toLowerCase();
        if (!cacheableMethods.contains(key)) {
          continue;
        }

        Boolean usedViaWire = Pattern.compile(
            '@wire\\s*\\(\\s*' + Pattern.quote(localName) + '\\b'
          )
          .matcher(xmlContent)
          .find();
        if (usedViaWire) {
          continue;
        }

        Boolean calledImperatively = Pattern.compile(
            '\\b' + Pattern.quote(localName) + '\\s*\\('
          )
          .matcher(xmlContent)
          .find();
        if (!calledImperatively) {
          continue;
        }

        throw new ApexCodeValidator.ValidationException(
          '[' +
            filePath +
            '] Calls "' +
            localName +
            '" (Apex ' +
            importedClass +
            '.' +
            importedMethod +
            ') IMPERATIVELY, but that method is annotated ' +
            '@AuraEnabled(cacheable=true). A cacheable method can return a ' +
            'cached (stale) response even on an imperative call — this ' +
            'silently breaks any Refresh/reload action built on it, since ' +
            'the UI appears to call the server but may receive the same ' +
            'old data back. Fix ONE of these two ways: (1) remove ' +
            'cacheable=true from ' +
            importedClass +
            '.' +
            importedMethod +
            ' in the Apex file, since it is only ever called imperatively ' +
            'here — a plain @AuraEnabled method always re-executes on the ' +
            'server; or (2) switch this JS to use @wire(' +
            importedMethod +
            ', { ... }) instead of an imperative call, and call ' +
            'refreshApex() on the wired result to refresh it. Option (1) ' +
            'is simpler and correct whenever the component never uses ' +
            '@wire for this method at all.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE RULE: LWC BUNDLE memberName MUST MATCH ITS FOLDER NAME
  // catches: an LWC file's memberName field disagreeing with (or missing
  // relative to) the actual bundle folder its filePath places it in.
  // LLMResponseProcessor trusts memberName directly for package.xml
  // membership (ZipBuilder.metadataTypes) rather than deriving it from
  // filePath — so a single file with a wrong/blank memberName produces a
  // package.xml entry that does not line up with where the file actually
  // ends up in the zip, which then fails at deploy time with a completely
  // opaque Metadata API error — "Cannot find Lightning Component Bundle
  // X" — instead of anything actionable. Confirmed as a real,
  // REPRODUCIBLE incident 2026-08-25 (caseEscalationWorkflow, failed
  // identically on 2 separate generation attempts for the same ticket).
  //
  // Cross-file by nature (needs every file's filePath + memberName from
  // the same bundle folder together), same reasoning as
  // validateNoImperativeCallToCacheableMethod above — cannot run through
  // the per-file validate() entry point below. Called from
  // LLMResponseProcessor.processXmlGenerationResponse() before the main
  // per-file loop, same call site as that method, so it throws into the
  // same repair-retry loop.
  // ─────────────────────────────────────────────────────────────
  public static void validateLwcBundleMemberNamesMatchFolder(
    List<Object> files
  ) {
    if (files == null || files.isEmpty()) {
      return;
    }

    List<String> problems = new List<String>();

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String filePath = (String) file.get('filePath');
      String memberName = (String) file.get('memberName');

      if (
        String.isBlank(filePath) || !filePath.toLowerCase().startsWith('lwc/')
      ) {
        continue;
      }

      List<String> segments = filePath.split('/');
      if (segments.size() < 3) {
        continue; // not a real "lwc/<folder>/<file>" path — nothing to check
      }
      String folderName = segments[1];

      // .equals() — NOT == — is deliberate: Apex's == operator (and
      // Set<String>/Map<String,x> membership, which an earlier version of
      // this exact check used) is CASE-INSENSITIVE by default. That
      // earlier version silently failed to catch a deliberately-injected
      // casing-only mismatch ("CaseEscalationWorkflow" vs
      // "caseEscalationWorkflow") in a live test run — exactly the class
      // of mismatch this rule exists to catch. .equals() is case-sensitive.
      if (memberName == null || !memberName.equals(folderName)) {
        problems.add(
          '[' +
            filePath +
            '] memberName is "' +
            (memberName == null ? '(blank)' : memberName) +
            '" but the file lives in the "' +
            folderName +
            '" bundle folder — memberName must exactly match the folder ' +
            'name (case-sensitive).'
        );
      }
    }

    if (!problems.isEmpty()) {
      throw new ApexCodeValidator.ValidationException(
        'LWC bundle memberName mismatch — this produces a package.xml ' +
          'entry that does not line up with the actual zip folder, and ' +
          'fails at deploy time with "Cannot find Lightning Component ' +
          'Bundle X" instead of a clear message. Fix every affected ' +
          'file\'s memberName to exactly match its own bundle folder ' +
          'name:\n' +
          String.join(problems, '\n')
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE DETECTOR (WARN-ONLY): LDS WRITE + REDUNDANT APEX DML ON THE
  // SAME GENERATION BATCH
  // flags (does NOT throw): a JS file that both calls an LDS write
  // function (createRecord/updateRecord/deleteRecord, imported from
  // 'lightning/uiRecordApi') AND imperatively calls an Apex method whose
  // class performs its OWN DML (insert/update/upsert/delete, or a
  // Database.* DML call) in the same generation response — two separate
  // write paths against what is very likely the same data, which is
  // redundant and can also race/duplicate a write depending on which path
  // the LLM actually wired the button to.
  //
  // Ships WARN-ONLY (System.debug, no throw) per the Area 3 (Lightning
  // Data Service) risk decision — promote to a hard ValidationException
  // only after verifying a low false-positive rate against real ticket
  // generations. A false positive is easy to construct here (e.g. the LDS
  // write and the Apex DML genuinely target different objects/records in
  // the same component), so this starts as a visibility tool, not a gate.
  //
  // Cross-file by nature, same reasoning as
  // validateNoImperativeCallToCacheableMethod above — cannot run through
  // the per-file validate() entry point below. Called from
  // LLMResponseProcessor.processXmlGenerationResponse() alongside that
  // method's other cross-file checks.
  // ─────────────────────────────────────────────────────────────
  public static void validateNoRedundantLdsAndApexDml(List<Object> files) {
    if (files == null || files.isEmpty()) {
      return;
    }

    // "ClassName" (lowercased) -> true, for every Apex class in this batch
    // whose body contains a real DML statement.
    Set<String> dmlApexClasses = new Set<String>();
    Pattern dmlPat = Pattern.compile(
      '(?i)\\b(?:insert|update|upsert|delete)\\s+\\w|' +
      'Database\\s*\\.\\s*(?:insert|update|upsert|delete)\\s*\\('
    );

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String memberName = (String) file.get('memberName');
      String xmlContent = (String) file.get('xmlContent');
      if (
        metadataType != 'ApexClass' ||
        String.isBlank(memberName) ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }
      if (dmlPat.matcher(xmlContent).find()) {
        dmlApexClasses.add(memberName.toLowerCase());
      }
    }

    if (dmlApexClasses.isEmpty()) {
      return;
    }

    Pattern apexImportPat = Pattern.compile(
      'import\\s+(\\w+)\\s+from\\s+[\'"]@salesforce/apex/(\\w+)\\.(\\w+)[\'"]'
    );
    Set<String> ldsWriteFunctions = new Set<String>{
      'createRecord',
      'updateRecord',
      'deleteRecord'
    };

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String filePath = (String) file.get('filePath');
      String xmlContent = (String) file.get('xmlContent');
      if (
        filePath == null ||
        !filePath.toLowerCase().endsWith('.js') ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }

      Boolean callsLdsWrite = false;
      for (String fn : ldsWriteFunctions) {
        Boolean usesFn = Pattern.compile('\\b' + fn + '\\s*\\(')
          .matcher(xmlContent)
          .find();
        Boolean importsFn = Pattern.compile(
            'import\\s*\\{[^}]*\\b' +
              fn +
              '\\b[^}]*\\}\\s*from\\s*[\'"]lightning/uiRecordApi[\'"]'
          )
          .matcher(xmlContent)
          .find();
        if (usesFn && importsFn) {
          callsLdsWrite = true;
          break;
        }
      }
      if (!callsLdsWrite) {
        continue;
      }

      Matcher importMatcher = apexImportPat.matcher(xmlContent);
      while (importMatcher.find()) {
        String localName = importMatcher.group(1);
        String importedClass = importMatcher.group(2);
        String importedMethod = importMatcher.group(3);
        if (!dmlApexClasses.contains(importedClass.toLowerCase())) {
          continue;
        }
        Boolean calledImperatively = Pattern.compile(
            '\\b' + Pattern.quote(localName) + '\\s*\\('
          )
          .matcher(xmlContent)
          .find();
        if (calledImperatively) {
          System.debug(
            LoggingLevel.WARN,
            '[' +
              filePath +
              '] WARN: calls an LDS write function (createRecord/' +
              'updateRecord/deleteRecord) AND imperatively calls ' +
              importedClass +
              '.' +
              importedMethod +
              '(...), which itself performs Apex DML — two separate write ' +
              'paths in the same component. Review whether both are ' +
              'actually needed, or whether one should be removed.'
          );
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE RULE: TEMPLATE BINDING REFERENCES A PROPERTY THE JS NEVER
  // DECLARES
  // catches: {someProp} in a bundle's .html with no matching field,
  // getter, wired property, or method named someProp anywhere in the
  // SAME bundle's .js — LWC does not error on this: binding to an
  // undeclared property silently evaluates to undefined (falsy), so a
  // gate like <template if:true={record}> where the JS never declares
  // `record` at all just permanently hides everything inside it, with no
  // compile error, no runtime error, no console warning. Confirmed as a
  // real incident 2026-08-25 (opportunityStageInlineEdit, MS-138): the
  // HTML gated its entire body — picklist, Save/Cancel buttons — on
  // {record}, but the JS only ever set currentStage/selectedStage/etc.
  // and never declared `record` anywhere; the component deployed clean,
  // placed on the page clean, and rendered nothing but its
  // <lightning-card title="..."> wrapper — "only the component name" is
  // exactly what a user sees when this bug fires.
  //
  // Cross-file by nature (needs both the .html and .js of the SAME
  // bundle together), same reasoning as
  // validateNoImperativeCallToCacheableMethod above — cannot run through
  // the per-file validate() entry point below. Called from
  // LLMResponseProcessor.processXmlGenerationResponse() alongside that
  // method's other cross-file checks. Only runs for a bundle whose BOTH
  // .html AND .js are present in the SAME response — a bundle where only
  // one of the two is being regenerated this round can't be verified
  // here and is left unchecked, same precision tradeoff as the other
  // cross-file rules in this class.
  // ─────────────────────────────────────────────────────────────
  public static void validateTemplateBindingsDeclaredInJs(List<Object> files) {
    if (files == null || files.isEmpty()) {
      return;
    }

    Map<String, String> htmlByBundle = new Map<String, String>();
    Map<String, String> jsByBundle = new Map<String, String>();

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String filePath = (String) file.get('filePath');
      String xmlContent = (String) file.get('xmlContent');
      if (
        String.isBlank(filePath) ||
        !filePath.toLowerCase().startsWith('lwc/') ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }
      List<String> segments = filePath.split('/');
      if (segments.size() < 3) {
        continue;
      }
      String bundleFolder = segments[1];
      String lowerPath = filePath.toLowerCase();
      if (lowerPath.endsWith('.html')) {
        htmlByBundle.put(bundleFolder, xmlContent);
      } else if (lowerPath.endsWith('.js') && !lowerPath.endsWith('.test.js')) {
        jsByBundle.put(bundleFolder, xmlContent);
      }
    }

    Pattern forItemPat = Pattern.compile(
      'for:item\\s*=\\s*["\']([a-zA-Z_$][a-zA-Z0-9_$]*)["\']'
    );
    Pattern forIndexPat = Pattern.compile(
      'for:index\\s*=\\s*["\']([a-zA-Z_$][a-zA-Z0-9_$]*)["\']'
    );
    Pattern iteratorPat = Pattern.compile(
      'iterator:([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*='
    );
    Pattern bindingPat = Pattern.compile('\\{([^{}]+)\\}');
    Pattern fieldDeclPat = Pattern.compile(
      '(?m)^\\s*(?:@track\\s+|@api\\s+|@wire\\([^)]*\\)\\s*)?' +
      '([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*[=;]'
    );
    Pattern methodOrGetterPat = Pattern.compile(
      '\\b([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*\\(([^()]*)\\)\\s*\\{'
    );
    Set<String> nonDeclarationKeywords = new Set<String>{
      'if',
      'while',
      'for',
      'switch',
      'catch'
    };

    for (String bundleFolder : htmlByBundle.keySet()) {
      if (!jsByBundle.containsKey(bundleFolder)) {
        continue; // .js not in this response — can't verify, skip
      }
      String htmlContent = htmlByBundle.get(bundleFolder);
      String jsContent = jsByBundle.get(bundleFolder);

      Set<String> localTemplateVars = new Set<String>();
      Matcher forItemMatcher = forItemPat.matcher(htmlContent);
      while (forItemMatcher.find()) {
        localTemplateVars.add(forItemMatcher.group(1));
      }
      Matcher forIndexMatcher = forIndexPat.matcher(htmlContent);
      while (forIndexMatcher.find()) {
        localTemplateVars.add(forIndexMatcher.group(1));
      }
      Matcher iteratorMatcher = iteratorPat.matcher(htmlContent);
      while (iteratorMatcher.find()) {
        localTemplateVars.add(iteratorMatcher.group(1));
      }

      Set<String> declaredInJs = new Set<String>();
      Matcher fieldMatcher = fieldDeclPat.matcher(jsContent);
      while (fieldMatcher.find()) {
        declaredInJs.add(fieldMatcher.group(1));
      }
      Matcher methodMatcher = methodOrGetterPat.matcher(jsContent);
      while (methodMatcher.find()) {
        String ident = methodMatcher.group(1);
        if (!nonDeclarationKeywords.contains(ident)) {
          declaredInJs.add(ident);
        }
      }

      Set<String> missing = new Set<String>();
      Set<String> literalBindings = new Set<String>();
      Matcher bindingMatcher = bindingPat.matcher(htmlContent);
      while (bindingMatcher.find()) {
        String expr = bindingMatcher.group(1).trim();
        Boolean isSimpleReference = Pattern.matches(
          '[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*',
          expr
        );
        if (!isSimpleReference) {
          continue; // not a bare identifier/dot-path — skip, not this rule's concern
        }
        String root = expr.split('\\.')[0];
        // A JS literal/reserved keyword used AS the binding root (e.g.
        // {false}, {true}, {null}) is a COMPLETELY DIFFERENT failure than a
        // genuinely undeclared property — there is no field/getter that
        // could ever be "added" named exactly false/true/null (they are
        // reserved words), so lumping this into `missing` sends the repair
        // loop an unfixable instruction ("add a property named exactly
        // false") and burns every repair attempt without ever succeeding.
        // Confirmed as a real incident 2026-08-26 (opportunityPipelineManager):
        // generation failed after 2 repair attempts on exactly this
        // message shape. Handled separately below with actionable guidance.
        if (JS_LITERAL_BINDING_ROOTS.contains(root)) {
          literalBindings.add(root);
          continue;
        }
        if (!localTemplateVars.contains(root) && !declaredInJs.contains(root)) {
          missing.add(root);
        }
      }

      if (!literalBindings.isEmpty()) {
        List<String> sortedLiterals = new List<String>(literalBindings);
        sortedLiterals.sort();
        throw new ApexCodeValidator.ValidationException(
          '[lwc/' +
            bundleFolder +
            '] Template uses a JS literal AS a binding — {' +
            String.join(sortedLiterals, '}, {') +
            '}. A {...} template binding can ONLY reference a property, ' +
            'getter, or method on the JS class — it can never be a literal ' +
            'value like true/false/null/undefined directly (e.g. ' +
            '<template lwc:if={false}> is invalid LWC; there is no way to ' +
            '"declare" a property literally named ' +
            (sortedLiterals.size() == 1
              ? '"' + sortedLiterals[0] + '"'
              : 'one of these') +
            ' since it is a reserved JavaScript keyword, not a property ' +
            'name). Fix with ONE of: (1) if the element/branch is meant to ' +
            'be permanently shown or hidden, DELETE the conditional ' +
            'directive entirely instead of gating it on a hardcoded ' +
            'literal; or (2) if it is meant to reflect real component ' +
            'state, replace the literal with a real boolean property or ' +
            'getter on the JS class and bind to THAT instead.'
        );
      }

      if (!missing.isEmpty()) {
        List<String> sortedMissing = new List<String>(missing);
        sortedMissing.sort();
        throw new ApexCodeValidator.ValidationException(
          '[lwc/' +
            bundleFolder +
            '] Template binds to ' +
            (sortedMissing.size() == 1 ? 'a property' : 'properties') +
            ' the JS never declares: {' +
            String.join(sortedMissing, '}, {') +
            '}. LWC does not error on this — an undeclared binding just ' +
            'evaluates to undefined (falsy), so any element or ' +
            '<template if:true=.../lwc:if=...> gated on it silently ' +
            'never renders, with no deploy-time or runtime signal. Add a ' +
            'matching field, getter, wired property, or method named ' +
            'exactly ' +
            (sortedMissing.size() == 1 ? 'this' : 'each of these') +
            ' to the JS class — or fix the HTML if it was meant to bind ' +
            'to a differently-named property that already exists.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE RULE: type:'action' DATATABLE COLUMN WITHOUT AN onrowaction
  // HANDLER
  // catches: a bundle's JS defining a lightning-datatable column with
  // type: 'action' (a per-row action menu), while the SAME bundle's HTML
  // never wires an onrowaction handler onto its <lightning-datatable>
  // element. The platform does not error on this — the action dropdown
  // renders and opens normally, but selecting any item in it does nothing
  // at all (no event has anywhere to go), which reads as a silently
  // broken menu with zero error signal at deploy or runtime.
  //
  // Cross-file by nature (columns are typically a JS array literal, the
  // onrowaction wiring lives in the HTML), same reasoning as
  // validateTemplateBindingsDeclaredInJs above — cannot run through the
  // per-file validate() entry point below. Called from
  // LLMResponseProcessor.processXmlGenerationResponse() alongside that
  // method's other cross-file checks. Only runs for a bundle whose BOTH
  // .html AND .js are present in the same response, same precision
  // tradeoff as the other bundle-pairing cross-file rules in this class.
  // ─────────────────────────────────────────────────────────────
  public static void validateDatatableRowActionsHaveHandler(
    List<Object> files
  ) {
    Map<String, String> htmlByBundle = new Map<String, String>();
    Map<String, String> jsByBundle = new Map<String, String>();
    populateBundleMaps(files, htmlByBundle, jsByBundle);

    Pattern actionColumnPat = Pattern.compile('type\\s*:\\s*[\'"]action[\'"]');
    Pattern onRowActionPat = Pattern.compile(
      '(?is)<lightning-datatable\\b[^>]*\\bonrowaction\\s*='
    );

    for (String bundleFolder : jsByBundle.keySet()) {
      if (!htmlByBundle.containsKey(bundleFolder)) {
        continue; // .html not in this response — can't verify, skip
      }
      String jsContent = jsByBundle.get(bundleFolder);
      String htmlContent = htmlByBundle.get(bundleFolder);

      if (!actionColumnPat.matcher(jsContent).find()) {
        continue;
      }
      if (!onRowActionPat.matcher(htmlContent).find()) {
        throw new ApexCodeValidator.ValidationException(
          '[lwc/' +
            bundleFolder +
            '] Defines a datatable column with type: \'action\' but its ' +
            '<lightning-datatable> element has no onrowaction handler. The ' +
            'action dropdown will render and open normally, but selecting ' +
            'any item in it does nothing — there is no handler for the ' +
            'event it dispatches. Add onrowaction={handleRowAction} to the ' +
            '<lightning-datatable> tag and dispatch on ' +
            'event.detail.action.name inside it.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CROSS-FILE RULE: editable:true DATATABLE COLUMN WITHOUT AN onsave
  // HANDLER
  // catches: a bundle's JS defining at least one column with
  // editable: true, while the SAME bundle's HTML never wires an onsave
  // handler onto its <lightning-datatable> element. A user can still
  // click into an editable cell and type a change, and the Save/Cancel
  // action bar still appears — but clicking Save has nowhere to go, since
  // onsave is the only event the datatable dispatches with the edited
  // draftValues. Same silent-failure shape as the row-actions rule above.
  //
  // Cross-file by nature and precision tradeoff, same as
  // validateDatatableRowActionsHaveHandler above.
  // ─────────────────────────────────────────────────────────────
  public static void validateDatatableEditableColumnsHaveSaveHandler(
    List<Object> files
  ) {
    Map<String, String> htmlByBundle = new Map<String, String>();
    Map<String, String> jsByBundle = new Map<String, String>();
    populateBundleMaps(files, htmlByBundle, jsByBundle);

    Pattern editableColumnPat = Pattern.compile('editable\\s*:\\s*true\\b');
    Pattern onSavePat = Pattern.compile(
      '(?is)<lightning-datatable\\b[^>]*\\bonsave\\s*='
    );

    for (String bundleFolder : jsByBundle.keySet()) {
      if (!htmlByBundle.containsKey(bundleFolder)) {
        continue; // .html not in this response — can't verify, skip
      }
      String jsContent = jsByBundle.get(bundleFolder);
      String htmlContent = htmlByBundle.get(bundleFolder);

      if (!editableColumnPat.matcher(jsContent).find()) {
        continue;
      }
      if (!onSavePat.matcher(htmlContent).find()) {
        throw new ApexCodeValidator.ValidationException(
          '[lwc/' +
            bundleFolder +
            '] Defines a datatable column with editable: true but its ' +
            '<lightning-datatable> element has no onsave handler. A user ' +
            'can edit a cell and see the Save/Cancel bar appear, but ' +
            'clicking Save does nothing — onsave is the only event ' +
            'carrying the edited draftValues out of the component. Add ' +
            'onsave={handleSave} to the <lightning-datatable> tag and ' +
            'process event.detail.draftValues inside it (see LWC_DATATABLE\'s ' +
            'inline-edit guidance, including resetting draftValues back to ' +
            '[] once the save completes).'
        );
      }
    }
  }

  // Shared helper for this class's bundle-pairing cross-file rules
  // (validateTemplateBindingsDeclaredInJs's own inline version predates
  // this helper and is left as-is rather than refactored to share it —
  // this helper exists so the two newer datatable rules above don't each
  // duplicate the same bundle-folder-grouping loop a third/fourth time).
  // Populates htmlByBundle/jsByBundle in place from files[], keyed by LWC
  // bundle folder name (the "lwc/<folder>/..." path segment).
  private static void populateBundleMaps(
    List<Object> files,
    Map<String, String> htmlByBundle,
    Map<String, String> jsByBundle
  ) {
    if (files == null || files.isEmpty()) {
      return;
    }
    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String filePath = (String) file.get('filePath');
      String xmlContent = (String) file.get('xmlContent');
      if (
        String.isBlank(filePath) ||
        !filePath.toLowerCase().startsWith('lwc/') ||
        String.isBlank(xmlContent)
      ) {
        continue;
      }
      List<String> segments = filePath.split('/');
      if (segments.size() < 3) {
        continue;
      }
      String bundleFolder = segments[1];
      String lowerPath = filePath.toLowerCase();
      if (lowerPath.endsWith('.html')) {
        htmlByBundle.put(bundleFolder, xmlContent);
      } else if (lowerPath.endsWith('.js') && !lowerPath.endsWith('.test.js')) {
        jsByBundle.put(bundleFolder, xmlContent);
      }
    }
  }

  public static void validate(String fileName, String content) {
    validateNotBlank(fileName, content);
    validateTemplateBindingExpressions(fileName, content);
    validateNoHtmlEntitiesInJs(fileName, content);
    validateNoReservedWordIdentifiers(fileName, content);
    validateCustomEventNameLowercase(fileName, content);
    validateLmsSubscribeHasUnsubscribe(fileName, content);
    validateLmsMessageContextWired(fileName, content);
    validateDecoratorsImportedFromLwc(fileName, content);
    validateRefreshApexImported(fileName, content);
    validateNoDirectWiredResultMutation(fileName, content);
    validateNoMixedConditionalAndIteratorOnSameTemplate(fileName, content);
    validateForEachHasKeyAttribute(fileName, content);
    validateLwcElseChainingOrder(fileName, content);
    validateLightningBadgeVariant(fileName, content);
    validateTodoComments(fileName, content);
    validateNavigationMixinExtendsClause(fileName, content);
    validateNavigationMixinImported(fileName, content);
    validateWriteActionHasToastFeedback(fileName, content);
    validateSpinnerResetOnError(fileName, content);
    validateLdsWriteFunctionsImported(fileName, content);
    validateUpdateRecordHasIdField(fileName, content);
    validateCreateRecordHasApiName(fileName, content);
    validateGetRecordWireHasFieldsOrLayoutTypes(fileName, content);
    validateNoLayoutsAccessOnGetRecordWire(fileName, content);
    validateDatatableHasKeyField(fileName, content);
    validateDatatableDraftValuesReset(fileName, content);
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: BLANK/PLACEHOLDER SOURCE
  // ─────────────────────────────────────────────────────────────
  private static void validateNotBlank(String fileName, String content) {
    if (String.isBlank(content)) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] LWC source is blank. Retry generation; empty .html/.js files must not be deployed.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: TEMPLATE BINDING EXPRESSIONS MUST BE SIMPLE REFERENCES
  // catches: LWC1058 Invalid HTML syntax (unexpected-equals-sign-before-
  // attribute-name, unexpected-character-in-unquoted-attribute-value) —
  // caused by writing an inline JS expression/operator inside a {...}
  // template binding, e.g. disabled={isLoading || currentPage === 1}.
  // A binding may only be a bare identifier or dot-path (e.g. {isLoading},
  // {contact.name}) — never contain operators, comparisons, or spaces.
  // ─────────────────────────────────────────────────────────────
  private static void validateTemplateBindingExpressions(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern bindingPat = Pattern.compile('\\{([^{}]+)\\}');
    Matcher m = bindingPat.matcher(content);

    while (m.find()) {
      String expr = m.group(1).trim();
      // A valid binding is a bare identifier or dot-path: letters, digits,
      // underscores, dots only. Anything else (operators, comparisons,
      // spaces, quotes, parens) means an inline expression was used.
      Boolean isSimpleReference = Pattern.matches(
        '[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*',
        expr
      );
      if (!isSimpleReference) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] Invalid template binding {' +
            expr +
            '}. A {...} binding may only be a single property or getter ' +
            'reference (e.g. {isLoading}, {contact.name}) — it cannot contain ' +
            'operators, comparisons, or inline expressions (||, &&, ===, +, etc.). ' +
            'Expose the computed value as a getter in the JS class instead, and bind to that getter.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: NO HTML ENTITIES INSIDE JS SOURCE
  // catches: literal "&#124;" (etc.) text embedded in .js source instead
  // of the real character — HTML entities are meaningless outside HTML
  // markup and break JavaScript parsing.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoHtmlEntitiesInJs(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern entityPat = Pattern.compile('&(#\\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);');
    Matcher m = entityPat.matcher(content);

    if (m.find()) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Found HTML entity "' +
          m.group() +
          '" inside JavaScript source. .js files are not HTML — write ' +
          'operators and characters literally (e.g. || not &#124;&#124;, && not &amp;&amp;).'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: TODO/FIXME/PLACEHOLDER (Incomplete code)
  // ─────────────────────────────────────────────────────────────
  private static void validateTodoComments(String fileName, String content) {
    String upperContent = content.toUpperCase();

    // Note: "PLACEHOLDER" is deliberately excluded — it's a standard, legitimate
    // HTML attribute name (placeholder="...") used on virtually every input/search
    // field, not a signal of stub/incomplete code the way it is in Apex source.
    if (
      upperContent.contains('TODO') ||
      upperContent.contains('FIXME') ||
      upperContent.contains('HACK') ||
      upperContent.contains('LOGIC HERE') ||
      upperContent.contains('IMPLEMENTATION HERE') ||
      upperContent.contains('ADD LOGIC')
    ) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Placeholder or TODO comments found. Code is incomplete and must not be deployed.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: JS RESERVED WORDS USED AS DECLARED IDENTIFIERS
  // catches: LWC1211 "X is a reserved keyword and cannot be used as an
  // identifier" — a compile-time failure Salesforce only reports at deploy,
  // not something the pipeline caught before. Most common trigger in this
  // pipeline specifically: Salesforce object names lowercase directly into
  // exactly this trap — "Case" → "case" being the one that actually broke
  // a deploy (a loop/arrow-param variable named after the object it holds).
  //
  // Scoped to DECLARATION/BINDING positions only — let/const/var and
  // arrow-function parameters (which also covers for-of/for-in, since
  // "for (const case of cases)" still matches the let/const/var pattern).
  // A reserved word appearing anywhere else — a string, a comment, a
  // property access like record.case, or inside a longer identifier like
  // caseId — is completely legal JS and must never be flagged.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoReservedWordIdentifiers(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    // let/const/var IDENT — variable declarations, including for-of/for-in
    // loop bindings ("for (const case of cases)" still starts with "const ").
    Pattern declPat = Pattern.compile(
      '\\b(?:let|const|var)\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\\b'
    );
    Matcher declMatcher = declPat.matcher(content);
    while (declMatcher.find()) {
      String ident = declMatcher.group(1);
      if (JS_RESERVED_WORDS.contains(ident)) {
        throwReservedWordError(
          fileName,
          ident,
          'a variable name (let/const/var)'
        );
      }
    }

    // Arrow-function parameter lists: case => ...  or  (a, case, b) => ...
    // Every parameter in the list is checked, not just the first, so a
    // reserved word in the middle or at the end is still caught.
    Pattern arrowPat = Pattern.compile(
      '(\\([^()]*\\)|\\b[a-zA-Z_$][a-zA-Z0-9_$]*)\\s*=>'
    );
    Matcher arrowMatcher = arrowPat.matcher(content);
    while (arrowMatcher.find()) {
      String paramBlock = arrowMatcher.group(1);
      String paramList = paramBlock.startsWith('(')
        ? paramBlock.substring(1, paramBlock.length() - 1)
        : paramBlock;
      for (String rawParam : paramList.split(',')) {
        String param = rawParam.trim();
        // Strip a default value (param = default) — only plain identifier
        // params are checked; destructured params ({ Id, Status }) are
        // skipped rather than risk a false positive on their contents.
        Integer eqIdx = param.indexOf('=');
        if (eqIdx >= 0) {
          param = param.substring(0, eqIdx).trim();
        }
        if (
          Pattern.matches('[a-zA-Z_$][a-zA-Z0-9_$]*', param) &&
          JS_RESERVED_WORDS.contains(param)
        ) {
          throwReservedWordError(
            fileName,
            param,
            'an arrow-function parameter name'
          );
        }
      }
    }

    // Function/method declarations and catch clauses:
    //   function name(params) { ...      handleClick(case) { ...
    //   async loadData(case) { ...       catch (case) { ...
    // All of these share the shape IDENTIFIER(params){ — including
    // if/while/for/switch, which is why those four are excluded below:
    // they're control flow, not a declaration, and their parenthesized
    // content (especially a C-style "for (let i=0; i<10; i++)") isn't even
    // a comma-separated param list, so parsing it as one would misfire.
    Set<String> nonDeclarationKeywords = new Set<String>{
      'if',
      'while',
      'for',
      'switch'
    };
    Pattern funcPat = Pattern.compile(
      '\\b([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*\\(([^()]*)\\)\\s*\\{'
    );
    Matcher funcMatcher = funcPat.matcher(content);
    while (funcMatcher.find()) {
      if (nonDeclarationKeywords.contains(funcMatcher.group(1))) {
        continue;
      }
      for (String rawParam : funcMatcher.group(2).split(',')) {
        String param = rawParam.trim();
        Integer eqIdx = param.indexOf('=');
        if (eqIdx >= 0) {
          param = param.substring(0, eqIdx).trim();
        }
        if (
          Pattern.matches('[a-zA-Z_$][a-zA-Z0-9_$]*', param) &&
          JS_RESERVED_WORDS.contains(param)
        ) {
          throwReservedWordError(
            fileName,
            param,
            'a function/method parameter name'
          );
        }
      }
    }

    // Destructured declarations: const { case } = obj;
    // Only bare shorthand fields are a real conflict — "const { case: x }"
    // binds the identifier "x", not "case", so a colon means skip that field.
    Pattern destructurePat = Pattern.compile(
      '\\b(?:let|const|var)\\s*\\{([^}]*)\\}'
    );
    Matcher destructureMatcher = destructurePat.matcher(content);
    while (destructureMatcher.find()) {
      for (String rawField : destructureMatcher.group(1).split(',')) {
        String field = rawField.trim();
        if (field.contains(':')) {
          continue;
        }
        Integer eqIdx = field.indexOf('=');
        if (eqIdx >= 0) {
          field = field.substring(0, eqIdx).trim();
        }
        if (
          Pattern.matches('[a-zA-Z_$][a-zA-Z0-9_$]*', field) &&
          JS_RESERVED_WORDS.contains(field)
        ) {
          throwReservedWordError(
            fileName,
            field,
            'a destructured variable name'
          );
        }
      }
    }

    // Class field declarations — LWC's most common reactive-property form:
    //   case = [];         @track case = [];        @api case;
    // No let/const/var precedes a class field, so none of the checks above
    // catch it. Scoped to a small set of words that plausibly come from a
    // Salesforce object/action name lowercased into a property name (case,
    // default, delete, new, class, switch) — deliberately NOT the full
    // reserved-word list, because that list also contains ordinary bare
    // statement keywords (return; break; continue;) that legitimately open
    // a line followed by nothing or a semicolon; flagging those would be a
    // false positive on completely normal code.
    //
    // "^IDENT[=;]" (only whitespace / an optional decorator before it) is
    // what distinguishes a field DECLARATION from a property ASSIGNMENT —
    // "this.case = []" or "obj.case = []" never match, because "." isn't
    // whitespace and isn't consumed by this pattern, so the character
    // right after the captured word is never "=" or ";" in that case.
    Set<String> classFieldRiskWords = new Set<String>{
      'case',
      'default',
      'delete',
      'new',
      'class',
      'switch'
    };
    Pattern classFieldPat = Pattern.compile(
      '(?m)^\\s*(?:@track\\s+|@api\\s+|@wire\\([^)]*\\)\\s*)?' +
      '([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*[=;]'
    );
    Matcher classFieldMatcher = classFieldPat.matcher(content);
    while (classFieldMatcher.find()) {
      String ident = classFieldMatcher.group(1);
      if (classFieldRiskWords.contains(ident)) {
        throwReservedWordError(fileName, ident, 'a class field name');
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: CUSTOM EVENT NAMES MUST BE LOWERCASE
  // catches: an LLM emitting new CustomEvent('contactSelect', ...) — LWC
  // silently lowercases mixed-case event names at dispatch time, so a
  // parent listening via oncontactSelect={handler} never fires. No error
  // is thrown by the platform, so this only ever surfaces as "the button
  // appears broken" — catching it here is the only safety net.
  // Read directly from the string literal passed to the constructor, so
  // there is no heuristic guessing and no false-positive risk.
  // ─────────────────────────────────────────────────────────────
  private static void validateCustomEventNameLowercase(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern eventPat = Pattern.compile(
      'new\\s+CustomEvent\\s*\\(\\s*[\'"]([^\'"]+)[\'"]'
    );
    Matcher m = eventPat.matcher(content);
    while (m.find()) {
      String eventName = m.group(1);
      Boolean containsUppercase = Pattern.compile('[A-Z]')
        .matcher(eventName)
        .find();
      if (containsUppercase) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] CustomEvent name "' +
            eventName +
            '" contains uppercase characters. LWC requires event names to be ' +
            'entirely lowercase — the platform silently lowercases the name at ' +
            'dispatch, so a parent handler bound as on' +
            eventName.toLowerCase() +
            '={handler} will never fire otherwise. Rename to "' +
            eventName.toLowerCase() +
            '".'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: LMS subscribe() WITHOUT A MATCHING unsubscribe()
  // catches: a component that subscribes to a Lightning Message Channel
  // in connectedCallback() but never releases it in disconnectedCallback()
  // — a real, well-documented LWC memory-leak footgun (every mount/unmount
  // cycle stacks a new listener on top of the last one). Gated on the file
  // actually importing lightning/messageService so it never fires on
  // unrelated code. \bsubscribe\( does not match inside unsubscribe( since
  // there is no word boundary between "n" and "s" — no special-casing needed.
  // ─────────────────────────────────────────────────────────────
  private static void validateLmsSubscribeHasUnsubscribe(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }
    if (!content.contains('lightning/messageService')) {
      return;
    }

    Boolean callsSubscribe = Pattern.compile('\\bsubscribe\\s*\\(')
      .matcher(content)
      .find();
    Boolean callsUnsubscribe = Pattern.compile('\\bunsubscribe\\s*\\(')
      .matcher(content)
      .find();
    if (callsSubscribe && !callsUnsubscribe) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Calls subscribe() from lightning/messageService but never calls ' +
          'unsubscribe(). Store the subscribe() return value (e.g. ' +
          'this.subscription = subscribe(...)) and call ' +
          'unsubscribe(this.subscription) inside disconnectedCallback() — ' +
          'otherwise every mount of this component leaks a listener.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: LMS publish()/subscribe() WITHOUT A WIRED MessageContext
  // catches: calling publish() or subscribe() without the required
  // MessageContext as their first argument — both functions fail at
  // runtime without it. Gated on the lightning/messageService import,
  // same as the unsubscribe rule above.
  // ─────────────────────────────────────────────────────────────
  private static void validateLmsMessageContextWired(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }
    if (!content.contains('lightning/messageService')) {
      return;
    }

    Boolean usesPublishOrSubscribe =
      Pattern.compile('\\bpublish\\s*\\(').matcher(content).find() ||
      Pattern.compile('\\bsubscribe\\s*\\(').matcher(content).find();
    if (!usesPublishOrSubscribe) {
      return;
    }

    Boolean hasWiredMessageContext = Pattern.compile(
        '@wire\\s*\\(\\s*MessageContext\\s*\\)'
      )
      .matcher(content)
      .find();
    if (!hasWiredMessageContext) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Calls publish()/subscribe() from lightning/messageService without ' +
          'a wired MessageContext. Add: import { MessageContext } from ' +
          '\'lightning/messageService\'; and a class property ' +
          '@wire(MessageContext) messageContext; — both functions require it ' +
          'as their first argument.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: @api / @wire / @track USED WITHOUT BEING IMPORTED FROM 'lwc'
  // catches: a class using @api/@wire/@track as a decorator without a
  // matching `import { api } from 'lwc';` (etc.) — importing the BASE
  // class (LightningElement from 'lwc', or LightningModal from
  // 'lightning/modal') does not also bring the decorators in. This is a
  // deploy-time compiler error (LWC1102: Invalid 'x' decorator usage), not
  // a runtime one — confirmed as a real incident 2026-08-24:
  // confirmDeleteModal used `@api recordName;` after only importing
  // LightningModal from 'lightning/modal', with no `import { api } from
  // 'lwc';` at all. Root cause traced back to the LWC_NAVIGATION prompt's
  // OWN modal example missing that import — the LLM was faithfully
  // copying a bug baked into the prompt template itself.
  // ─────────────────────────────────────────────────────────────
  private static void validateDecoratorsImportedFromLwc(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Map<String, Pattern> usagePatterns = new Map<String, Pattern>{
      'api' => Pattern.compile('@api\\b'),
      'wire' => Pattern.compile('@wire\\s*\\('),
      'track' => Pattern.compile('@track\\b')
    };

    for (String decorator : usagePatterns.keySet()) {
      Boolean usesDecorator = usagePatterns.get(decorator)
        .matcher(content)
        .find();
      if (!usesDecorator) {
        continue;
      }

      Boolean importsDecorator = Pattern.compile(
          'import\\s*\\{[^}]*\\b' +
            decorator +
            '\\b[^}]*\\}\\s*from\\s*[\'"]lwc[\'"]'
        )
        .matcher(content)
        .find();

      if (!importsDecorator) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] Uses @' +
            decorator +
            ' without importing it. Add \'' +
            decorator +
            '\' to the import from \'lwc\' (e.g. import { ' +
            decorator +
            ' } from \'lwc\';) — importing LightningElement or ' +
            'LightningModal does not also bring the decorators in.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: refreshApex() CALLED WITHOUT BEING IMPORTED
  // catches: a Tier 2A wired component calling refreshApex(...) to force a
  // cacheable wire result to refetch, without importing it — refreshApex is
  // not a global function, it must be imported from '@salesforce/apex'
  // (not 'lwc', where the rest of a wired component's imports come from).
  // ─────────────────────────────────────────────────────────────
  private static void validateRefreshApexImported(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean callsRefreshApex = Pattern.compile('\\brefreshApex\\s*\\(')
      .matcher(content)
      .find();
    if (!callsRefreshApex) {
      return;
    }

    Boolean importsRefreshApex = Pattern.compile(
        'import\\s*\\{[^}]*\\brefreshApex\\b[^}]*\\}\\s*from\\s*[\'"]@salesforce/apex[\'"]'
      )
      .matcher(content)
      .find();

    if (!importsRefreshApex) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Calls refreshApex() without importing it. Add: ' +
          'import { refreshApex } from \'@salesforce/apex\'; — refreshApex ' +
          'is not a global function, it must be imported explicitly.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: DIRECT MUTATION OF A WIRED RESULT'S .data PROPERTY
  // catches: this.wiredProp.data = ... — a @wire result is owned and
  // managed by the LWC wire service; mutating it directly doesn't trigger
  // a real refetch and fights the framework. Gated on the file both using
  // @wire( and importing from '@salesforce/apex/' together, so this never
  // fires on an unrelated object's .data property (e.g. a charting-library
  // config) or on lightning/ui*Api / MessageContext wires, which aren't
  // the pattern this rule is about.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoDirectWiredResultMutation(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean isWiredApexFile =
      content.contains('@wire(') && content.contains('@salesforce/apex/');
    if (!isWiredApexFile) {
      return;
    }

    Pattern mutatePat = Pattern.compile(
      'this\\.[a-zA-Z_$][a-zA-Z0-9_$]*\\.data\\s*=(?!=)'
    );
    Matcher m = mutatePat.matcher(content);
    if (m.find()) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Directly assigns to a wired result\'s .data property (' +
          m.group().trim() +
          '...). A @wire result is managed by the LWC wire service — never ' +
          'mutate it directly. Import refreshApex from \'@salesforce/apex\' ' +
          'and call refreshApex(wiredResultProperty) to force a refetch instead.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: CONDITIONAL DIRECTIVE + for:each ON THE SAME <template> TAG
  // catches: <template lwc:if={x} for:each={items} for:item="item"> — LWC
  // does not allow a conditional rendering directive (lwc:if/lwc:elseif/
  // lwc:else, or the legacy if:true/if:false) and an iterator directive
  // (for:each or iterator:x) on the SAME template tag. The platform
  // rejects this at deploy (a template-compiler error), not something
  // that merely renders wrong — nest two separate <template> tags
  // instead, one for the condition and one for the loop.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoMixedConditionalAndIteratorOnSameTemplate(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern templateTagPat = Pattern.compile('(?is)<template\\b([^>]*)>');
    Pattern conditionalPat = Pattern.compile(
      'lwc:if\\s*=|lwc:elseif\\s*=|lwc:else\\b|if:true\\s*=|if:false\\s*='
    );
    Pattern iteratorPat = Pattern.compile('for:each\\s*=|iterator:\\w+\\s*=');

    Matcher m = templateTagPat.matcher(content);
    while (m.find()) {
      String attrs = m.group(1);
      Boolean hasConditional = conditionalPat.matcher(attrs).find();
      Boolean hasIterator = iteratorPat.matcher(attrs).find();
      if (hasConditional && hasIterator) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] <template ' +
            attrs.trim().replaceAll('\\s+', ' ') +
            '> combines a conditional directive (lwc:if/lwc:elseif/lwc:else ' +
            'or if:true/if:false) with an iterator directive (for:each/' +
            'iterator:x) on the SAME tag. LWC does not allow this and rejects ' +
            'it at deploy. Nest two separate <template> tags instead — one ' +
            'carrying the conditional, the other (nested inside or around it) ' +
            'carrying the iterator.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: for:each WITHOUT A key ATTRIBUTE
  // catches: <template for:each={items} for:item="item"> ... </template>
  // with no key={...} on the iterated element. LWC requires a unique key
  // on every for:each-rendered element so its rendering diff algorithm can
  // track which DOM node maps to which array item — omitting it is a real
  // deploy-time template-compiler rejection, not a style preference.
  //
  // Heuristic scope: matches from the <template ...for:each...> opening
  // tag to its first following </template> (lazy match) and checks for
  // key= anywhere in between. A for:each block that itself contains a
  // NESTED <template> (e.g. a conditional inside the loop) can cause this
  // to stop at the inner </template> instead of the outer one — a known
  // v1 limitation, consistent with this validator's other regex-based
  // (non-AST) checks.
  // ─────────────────────────────────────────────────────────────
  private static void validateForEachHasKeyAttribute(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern forEachBlockPat = Pattern.compile(
      '(?is)<template\\b[^>]*\\bfor:each\\s*=\\s*\\{[^}]+\\}[^>]*>(.*?)</template>'
    );
    Pattern keyPat = Pattern.compile('\\bkey\\s*=');
    Matcher m = forEachBlockPat.matcher(content);
    while (m.find()) {
      String block = m.group(1);
      if (!keyPat.matcher(block).find()) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] A for:each loop is missing a key={...} attribute on its ' +
            'iterated element. LWC requires a unique key on every for:each ' +
            'item for its rendering diff algorithm to work — add ' +
            'key={item.Id} (or another field unique per row) to the element ' +
            'directly inside the loop.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: lwc:elseif / lwc:else WITHOUT A PRECEDING lwc:if
  // catches: a <template lwc:elseif={x}> or <template lwc:else> tag that
  // does not follow a <template lwc:if={...}> (or another lwc:elseif
  // continuing the same chain). LWC requires lwc:elseif/lwc:else to be a
  // direct sibling continuing the lwc:if that starts the chain — used
  // standalone (copy-pasted without its lwc:if, or left over after the
  // lwc:if branch was deleted) it is a deploy-time template-compiler
  // error, not merely a runtime bug.
  //
  // NESTING-AWARE: scans both <template> open tags AND </template> close
  // tags in document order and maintains a STACK, so the "last chain
  // directive seen" is tracked PER NESTING LEVEL, not as one flat
  // document-wide value. Without this, an unrelated nested chain inside
  // one branch (e.g. a per-row lwc:if/lwc:else inside a for:each nested
  // in an outer lwc:elseif block) corrupts tracking for the OUTER chain
  // once control returns to it — confirmed as a real false positive
  // 2026-08-24: a valid isLoading/hasError/hasData/else outer chain with
  // a nested per-row if/else inside the hasData branch was rejected
  // because the nested chain's trailing 'else' leaked out as the
  // "last directive" seen before the outer lwc:else, even though the
  // outer chain (elseif={hasData} → else) was perfectly valid. A non-chain
  // <template> (e.g. one only using for:each) still does not reset the
  // chain at ITS OWN level — same deliberate, pragmatic scope as before,
  // just now correctly scoped per nesting level instead of globally.
  // ─────────────────────────────────────────────────────────────
  private static void validateLwcElseChainingOrder(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern tagPat = Pattern.compile(
      '(?is)<template\\b([^>]*)>|(</template\\s*>)'
    );
    Pattern ifPat = Pattern.compile('lwc:if\\s*=');
    Pattern elseifPat = Pattern.compile('lwc:elseif\\s*=');
    Pattern elsePat = Pattern.compile('lwc:else\\b');

    Matcher m = tagPat.matcher(content);
    String currentLast = null; // 'if' | 'elseif' | 'else' | null — last
    // chain directive seen so far AT THE CURRENT NESTING LEVEL.
    List<String> ownDirectiveStack = new List<String>(); // this
    // <template>'s own directive, pushed on open / popped on close — used
    // to update the PARENT level's currentLast once this element closes.
    List<String> parentLastStack = new List<String>(); // currentLast of
    // the PARENT level at the moment we descended, restored when this
    // element's own directive is null (a non-chain template, e.g.
    // for:each) so it doesn't erase the parent chain's position.

    while (m.find()) {
      Boolean isCloseTag = m.group(2) != null;

      if (isCloseTag) {
        if (ownDirectiveStack.isEmpty()) {
          continue; // unmatched close tag — not this validator's concern
        }
        Integer lastIdx = ownDirectiveStack.size() - 1;
        String myDirective = ownDirectiveStack.remove(lastIdx);
        String parentLast = parentLastStack.remove(lastIdx);
        currentLast = (myDirective != null) ? myDirective : parentLast;
        continue;
      }

      String attrs = m.group(1);
      String directive = null;
      if (ifPat.matcher(attrs).find()) {
        directive = 'if';
      } else if (elseifPat.matcher(attrs).find()) {
        directive = 'elseif';
      } else if (elsePat.matcher(attrs).find()) {
        directive = 'else';
      }

      if (
        (directive == 'elseif' ||
        directive == 'else') &&
        currentLast != 'if' &&
        currentLast != 'elseif'
      ) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] <template ' +
            (directive == 'elseif' ? 'lwc:elseif' : 'lwc:else') +
            '> found without an immediately preceding <template lwc:if={...}> ' +
            '(or an lwc:elseif continuing that chain). LWC requires lwc:elseif/' +
            'lwc:else to directly follow the lwc:if that starts the ' +
            'conditional chain — add the missing lwc:if, or remove this ' +
            'orphaned branch.'
        );
      }

      // Descend into this <template>'s own scope: remember the parent
      // level's chain position (to restore if this template turns out to
      // be a non-chain one, e.g. for:each) and this template's own
      // directive (to apply to the parent level once we hit its matching
      // </template>), then start fresh chain-tracking for its children.
      ownDirectiveStack.add(directive);
      parentLastStack.add(currentLast);
      currentLast = null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: <lightning-badge> VARIANT MUST BE "base" OR "inverse"
  // catches: variant="brand"/"warning"/"success"/"error" (etc.) on
  // <lightning-badge> — this base component supports ONLY "base" (default
  // grey) and "inverse". Salesforce does not error on an invalid variant
  // value; it silently falls back to the default grey badge, so a
  // status-conditional with 3 branches each passing a different (all
  // invalid) variant renders every branch identically grey with zero
  // deploy-time signal anything is wrong. Confirmed as a real incident
  // 2026-08-21: caseStatusBadge used variant="brand"/"warning"/"success"
  // and every badge rendered grey regardless of Status.
  //
  // Only checks LITERAL string variant values (variant="success") — a
  // variant bound to a computed property (variant={badgeVariant}) can't be
  // statically resolved here and is intentionally left unchecked, same as
  // this validator's other literal-only checks (e.g. CustomEvent names).
  // ─────────────────────────────────────────────────────────────
  private static void validateLightningBadgeVariant(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Set<String> validVariants = new Set<String>{ 'base', 'inverse' };
    Pattern badgePat = Pattern.compile(
      '(?is)<lightning-badge\\b[^>]*\\bvariant\\s*=\\s*["\']([^"\']+)["\']'
    );
    Matcher m = badgePat.matcher(content);
    while (m.find()) {
      String variantValue = m.group(1);
      if (!validVariants.contains(variantValue)) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] <lightning-badge variant="' +
            variantValue +
            '"> is not a supported value — this component only accepts ' +
            '"base" or "inverse". Salesforce silently renders the default ' +
            'grey badge for any other value instead of erroring, so this ' +
            'would deploy successfully while every badge renders identically ' +
            'grey. For a COLORED status badge, replace <lightning-badge> with ' +
            'plain SLDS markup instead: <span class="slds-badge ' +
            'slds-theme_success">Label</span> (swap slds-theme_success for ' +
            'slds-theme_warning/slds-theme_error/slds-theme_info as needed).'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // DETECTOR (not a throwing rule): PURE REUSABLE/GENERIC SLOT-ONLY COMPONENT
  // Identifies a component whose ENTIRE template is just a single wrapper
  // element around a bare <slot> — the "generic card" shape from the
  // LWC_DYNAMIC_UI prompt's reusable-component guidance. Such a component
  // is deliberately unconfigured on its own (no title, no content) —
  // dropping it raw onto a FlexiPage renders an empty, useless card, since
  // page-builder placement has no way to set its @api properties or supply
  // slot content. LLMResponseProcessor uses this to EXCLUDE this kind of
  // component from automatic page placement — the ticket's separate
  // CONSUMER component (the one that actually configures/fills it) should
  // be placed instead. Confirmed as a real incident 2026-08-21: a bare
  // genericInfoCard was placed on the Case record page with zero
  // configured attributes and an empty slot, rendering nothing useful.
  //
  // Deliberately conservative — returns false (not a shell) whenever there
  // is any ambiguity, since wrongly EXCLUDING a real standalone component
  // from placement is worse than wrongly failing to exclude a shell (the
  // prior behavior: silently placing a blank card). Returns false if:
  //   - the template uses any conditional/loop directive (real logic, not
  //     a pure passthrough)
  //   - there isn't EXACTLY one <slot> in the whole file
  //   - once that <slot> is removed, more than one other element remains
  //     at the top level (a real wrapper PLUS other real content/markup)
  // ─────────────────────────────────────────────────────────────
  public static Boolean isSlotOnlyReusableComponent(String htmlContent) {
    if (String.isBlank(htmlContent)) {
      return false;
    }

    Pattern directivePat = Pattern.compile(
      'for:each\\s*=|iterator:\\w+\\s*=|lwc:if\\s*=|lwc:elseif\\s*=|' +
      'lwc:else\\b|if:true\\s*=|if:false\\s*='
    );
    if (directivePat.matcher(htmlContent).find()) {
      return false;
    }

    Matcher slotMatcher = Pattern.compile('(?i)<slot\\b').matcher(htmlContent);
    Integer slotCount = 0;
    while (slotMatcher.find()) {
      slotCount++;
    }
    if (slotCount != 1) {
      return false;
    }

    // Remove the single <slot ...>...</slot> (or self-closing <slot .../>)
    // element, then count remaining opening tags (excluding <template>
    // itself) — 0 (the slot was the only element) or 1 (a single wrapper
    // element) both count as "shell".
    String withoutSlot = Pattern.compile(
        '(?is)<slot\\b[^>]*?(?:/>|>.*?</slot\\s*>)'
      )
      .matcher(htmlContent)
      .replaceFirst('');

    Matcher openingTagMatcher = Pattern.compile('<[a-zA-Z][\\w-]*\\b')
      .matcher(withoutSlot);
    Integer remainingElementCount = 0;
    while (openingTagMatcher.find()) {
      String tag = openingTagMatcher.group().substring(1).toLowerCase();
      if (tag != 'template') {
        remainingElementCount++;
      }
    }

    return remainingElementCount <= 1;
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: NavigationMixin USED WITHOUT THE MIXIN IN THE extends CLAUSE
  // catches: this[NavigationMixin.Navigate](...) called on a class that
  // still extends plain LightningElement — NavigationMixin is a mixin
  // function that must wrap LightningElement in the extends clause for
  // this[NavigationMixin.Navigate] to exist at all; calling it otherwise
  // throws "Cannot read properties of undefined" at runtime, not a
  // deploy-time error, so it silently ships broken until a user clicks it.
  // ─────────────────────────────────────────────────────────────
  private static void validateNavigationMixinExtendsClause(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean usesNavigate = Pattern.compile(
        'this\\s*\\[\\s*NavigationMixin\\.Navigate\\s*\\]'
      )
      .matcher(content)
      .find();
    if (!usesNavigate) {
      return;
    }

    Boolean extendsNavigationMixin = Pattern.compile(
        'extends\\s+NavigationMixin\\s*\\('
      )
      .matcher(content)
      .find();
    if (!extendsNavigationMixin) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Calls this[NavigationMixin.Navigate](...) but the class does ' +
          'not extend NavigationMixin(LightningElement). Change ' +
          '"extends LightningElement" to ' +
          '"extends NavigationMixin(LightningElement)".'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: NavigationMixin USED WITHOUT BEING IMPORTED
  // catches: "extends NavigationMixin(LightningElement)" with no import —
  // NavigationMixin is not a global, it must come from 'lightning/navigation'.
  // ─────────────────────────────────────────────────────────────
  private static void validateNavigationMixinImported(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean extendsNavigationMixin = Pattern.compile(
        'extends\\s+NavigationMixin\\s*\\('
      )
      .matcher(content)
      .find();
    if (!extendsNavigationMixin) {
      return;
    }

    Boolean importsNavigationMixin = Pattern.compile(
        'import\\s*\\{[^}]*\\bNavigationMixin\\b[^}]*\\}\\s*from\\s*[\'"]lightning/navigation[\'"]'
      )
      .matcher(content)
      .find();
    if (!importsNavigationMixin) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Extends NavigationMixin but never imports it. Add: ' +
          'import { NavigationMixin } from \'lightning/navigation\';'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: WRITE ACTION WITHOUT ShowToastEvent FEEDBACK
  // catches: a component that calls an LDS write function (createRecord/
  // updateRecord/deleteRecord) or an imperative Apex method, but never
  // shows a ShowToastEvent anywhere — the user clicks a button and gets no
  // confirmation the action succeeded OR failed, which looks identical to
  // the button silently doing nothing.
  //
  // Scoped deliberately to presence-only (content.contains('ShowToastEvent'))
  // rather than verifying it fires on BOTH the success and error paths
  // specifically — a real, accepted precision tradeoff: nearly every write
  // in this pipeline is user-initiated, so a false positive here is more
  // likely than a false negative, and this still catches the common case
  // of a write with NO toast feedback at all.
  // ─────────────────────────────────────────────────────────────
  private static void validateWriteActionHasToastFeedback(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean callsLdsWrite = Pattern.compile(
        '\\b(createRecord|updateRecord|deleteRecord)\\s*\\('
      )
      .matcher(content)
      .find();

    Boolean callsImperativeApex = false;
    Pattern apexImportPat = Pattern.compile(
      'import\\s+(\\w+)\\s+from\\s+[\'"]@salesforce/apex/[\\w.]+[\'"]'
    );
    Matcher apexImportMatcher = apexImportPat.matcher(content);
    while (apexImportMatcher.find()) {
      String localName = apexImportMatcher.group(1);
      Boolean usedViaWire = Pattern.compile(
          '@wire\\s*\\(\\s*' + Pattern.quote(localName) + '\\b'
        )
        .matcher(content)
        .find();
      if (usedViaWire) {
        continue;
      }
      Boolean calledImperatively = Pattern.compile(
          '\\b' + Pattern.quote(localName) + '\\s*\\('
        )
        .matcher(content)
        .find();
      if (calledImperatively) {
        callsImperativeApex = true;
        break;
      }
    }

    if (!callsLdsWrite && !callsImperativeApex) {
      return;
    }

    if (!content.contains('ShowToastEvent')) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Performs a create/update/delete action (LDS write or an ' +
          'imperative Apex call) but never shows a ShowToastEvent — the ' +
          'user gets no confirmation the action succeeded or failed. ' +
          'Import ShowToastEvent from \'lightning/platformShowToastEvent\' ' +
          'and dispatch one on both the success and error paths.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: isLoading SPINNER NEVER RESET ON FAILURE
  // catches: isLoading = true set to show a spinner, but no catch or
  // finally block anywhere in the file ever resets it back to false —
  // if the operation fails, the spinner spins forever with no way out.
  // Checks BOTH catch(...) blocks and finally blocks (not just catch)
  // since the project's own recommended patterns legitimately put the
  // reset in finally, not in catch itself — EITHER as a promise chain
  // (.then().catch().finally(() => { isLoading = false })) OR as a plain
  // try/catch/finally statement (async/await style: finally { isLoading
  // = false }, no leading dot or parens) — this rule must not flag
  // either correct, endorsed shape as a violation. Confirmed as a real
  // false-positive incident 2026-08-26 (accountRatingUpdater): the
  // finally-detection pattern required a leading '.' and '(', so it only
  // ever matched the promise-chain form and silently never matched a
  // bare try/catch/finally statement's finally block at all — code that
  // correctly reset isLoading in that finally block was rejected because
  // only the (reset-less) catch block was ever actually inspected.
  //
  // Uses a real balanced-brace scan (extractBalancedBlock) rather than a
  // regex over the block body, since catch/finally bodies routinely
  // contain their own nested { } (an if statement, an object literal)
  // that a non-greedy regex match would truncate at the wrong '}'.
  // ─────────────────────────────────────────────────────────────
  private static void validateSpinnerResetOnError(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }
    if (
      !Pattern.compile('\\bisLoading\\s*=\\s*true\\b').matcher(content).find()
    ) {
      return;
    }

    List<Pattern> errorPathAnchors = new List<Pattern>{
      Pattern.compile('\\bcatch\\s*\\([^)]*\\)\\s*'),
      // Matches BOTH '.finally(' (promise chain) and a bare 'finally'
      // keyword (try/catch/finally statement) — '\b' is a word boundary
      // that exists just as validly right after a '.' as after
      // whitespace, so this single pattern covers both without needing
      // the dot/paren requirement that caused the false positive above.
      Pattern.compile('\\bfinally\\b\\s*')
    };

    Boolean foundErrorPath = false;
    Boolean resetSomewhere = false;

    for (Pattern anchor : errorPathAnchors) {
      Matcher m = anchor.matcher(content);
      while (m.find()) {
        Integer braceStart = content.indexOf('{', m.end());
        if (braceStart < 0) {
          continue;
        }
        String block = extractBalancedBlock(content, braceStart);
        if (block == null) {
          continue;
        }
        foundErrorPath = true;
        if (blockResetsIsLoading(content, block)) {
          resetSomewhere = true;
        }
      }
    }

    if (foundErrorPath && !resetSomewhere) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Sets isLoading = true but no catch block or finally block ' +
          '(promise .finally(...) or a try/catch/finally statement) ever ' +
          'resets it back to false — the spinner will spin forever if the ' +
          'operation fails. Reset isLoading = false inside the catch ' +
          'block, or in a finally that runs regardless of success or ' +
          'failure.'
      );
    }
  }

  // Returns true if `block` (a catch or finally body) resets isLoading —
  // either directly, or ONE level of indirection deep: the block calls a
  // this.someMethod() whose OWN body (found elsewhere in the same file)
  // resets isLoading. Delegating cleanup to a small helper method (e.g.
  // finally { this.finishLoading(); }) is legitimate, common code
  // structure — checking only the block's own literal text would
  // false-positive on it. Confirmed as a real incident 2026-08-26
  // (accountRatingUpdater): a correctly-reset spinner was rejected
  // because the reset lived inside a helper method the finally block
  // called, not inline in the finally block itself.
  private static Boolean blockResetsIsLoading(
    String fileContent,
    String block
  ) {
    if (
      Pattern.compile('\\bisLoading\\s*=\\s*false\\b').matcher(block).find()
    ) {
      return true;
    }
    Matcher callMatcher = Pattern.compile('\\bthis\\.(\\w+)\\s*\\(')
      .matcher(block);
    while (callMatcher.find()) {
      String methodName = callMatcher.group(1);
      Matcher declMatcher = Pattern.compile(
          '\\b' + methodName + '\\s*\\([^)]*\\)\\s*\\{'
        )
        .matcher(fileContent);
      while (declMatcher.find()) {
        Integer methodBraceStart = fileContent.indexOf(
          '{',
          declMatcher.start()
        );
        if (methodBraceStart < 0) {
          continue;
        }
        String methodBody = extractBalancedBlock(fileContent, methodBraceStart);
        if (
          methodBody != null &&
          Pattern.compile('\\bisLoading\\s*=\\s*false\\b')
            .matcher(methodBody)
            .find()
        ) {
          return true;
        }
      }
    }
    return false;
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: LDS RECORD API FUNCTIONS USED WITHOUT BEING IMPORTED
  // catches: createRecord/updateRecord/deleteRecord/getFieldValue called
  // without importing them from 'lightning/uiRecordApi' — none of these
  // are globals, and unlike @wire/@api/@track (LWC1102), Salesforce does
  // NOT catch a missing import for these at deploy time. An unimported
  // LDS function call throws "X is not defined" at RUNTIME instead, so
  // the button/page appears to work until a user actually triggers it.
  // ─────────────────────────────────────────────────────────────
  private static void validateLdsWriteFunctionsImported(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Set<String> ldsFunctions = new Set<String>{
      'createRecord',
      'updateRecord',
      'deleteRecord',
      'getFieldValue'
    };

    for (String fn : ldsFunctions) {
      Boolean usesFunction = Pattern.compile('\\b' + fn + '\\s*\\(')
        .matcher(content)
        .find();
      if (!usesFunction) {
        continue;
      }

      Boolean importsFunction = Pattern.compile(
          'import\\s*\\{[^}]*\\b' +
            fn +
            '\\b[^}]*\\}\\s*from\\s*[\'"]lightning/uiRecordApi[\'"]'
        )
        .matcher(content)
        .find();

      if (!importsFunction) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] Calls ' +
            fn +
            '(...) without importing it. Add \'' +
            fn +
            '\' to the import from \'lightning/uiRecordApi\' (e.g. import ' +
            '{ ' +
            fn +
            ' } from \'lightning/uiRecordApi\';) — it is not a global ' +
            'function, and this fails at RUNTIME (not deploy time) with "' +
            fn +
            ' is not defined".'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: updateRecord({ fields: {...} }) MISSING THE REQUIRED Id FIELD
  // catches: calling updateRecord with a literal fields object that never
  // sets Id — LDS's updateRecord requires Id inside fields to know which
  // record to write to; omitting it throws at RUNTIME ("Id is required"),
  // not a deploy-time error, so this silently ships broken until a user
  // actually clicks the button that triggers it.
  //
  // Literal-only, same precision tradeoff as this validator's other
  // literal-only checks (e.g. lightning-badge variant): only checked when
  // updateRecord is called with an inline object literal AND that literal
  // has a literal fields: { ... } sub-object — a variable passed in
  // (updateRecord(recordInput), a fields object assembled elsewhere and
  // referenced by name) can't be statically resolved here and is
  // intentionally left unchecked.
  // ─────────────────────────────────────────────────────────────
  private static void validateUpdateRecordHasIdField(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern callPat = Pattern.compile('\\bupdateRecord\\s*\\(');
    Matcher m = callPat.matcher(content);
    while (m.find()) {
      Integer parenStart = m.end() - 1;
      String argsBlock = extractBalancedRegion(content, parenStart, '(', ')');
      if (argsBlock == null) {
        continue;
      }
      String args = argsBlock.substring(1, argsBlock.length() - 1).trim();
      if (!args.startsWith('{')) {
        continue; // not an inline object literal — can't verify statically
      }

      Matcher fieldsMatcher = Pattern.compile('fields\\s*:\\s*\\{')
        .matcher(args);
      if (!fieldsMatcher.find()) {
        continue; // no literal fields: {...} sub-object — can't verify
      }

      String fieldsBlock = extractBalancedRegion(
        args,
        fieldsMatcher.end() - 1,
        '{',
        '}'
      );
      if (fieldsBlock == null) {
        continue;
      }

      Boolean hasId = Pattern.compile('\\bId\\b\\s*(:|,|\\})')
        .matcher(fieldsBlock)
        .find();
      if (!hasId) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] updateRecord(...) is called with a fields object that ' +
            'never sets Id. LDS requires Id inside fields to know which ' +
            'record to update — omitting it throws at runtime, not ' +
            'deploy time. Add Id: this.recordId (or the relevant record ' +
            'Id) as a key in the fields object.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: createRecord({ fields: {...} }) MISSING THE REQUIRED apiName
  // catches: calling createRecord with a literal record-input object that
  // has a fields sub-object but never sets apiName at the top level —
  // LDS's createRecord requires apiName to know which object to insert
  // into; omitting it throws at RUNTIME, not deploy time ("Cannot
  // destructure property 'apiName'" is the typical error shape).
  //
  // Literal-only, same precision tradeoff as validateUpdateRecordHasIdField
  // above — a variable passed to createRecord (e.g. one built via
  // generateRecordInputForCreate) is intentionally left unchecked.
  // ─────────────────────────────────────────────────────────────
  private static void validateCreateRecordHasApiName(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern callPat = Pattern.compile('\\bcreateRecord\\s*\\(');
    Matcher m = callPat.matcher(content);
    while (m.find()) {
      Integer parenStart = m.end() - 1;
      String argsBlock = extractBalancedRegion(content, parenStart, '(', ')');
      if (argsBlock == null) {
        continue;
      }
      String args = argsBlock.substring(1, argsBlock.length() - 1).trim();
      if (!args.startsWith('{')) {
        continue; // not an inline object literal — can't verify statically
      }

      // Only checked when the literal also has a fields: {...} sub-object
      // — the clearest signal this is a real inline record-input literal,
      // rather than some other unrelated call this regex happened to
      // match.
      if (!Pattern.compile('fields\\s*:\\s*\\{').matcher(args).find()) {
        continue;
      }

      Boolean hasApiName = Pattern.compile('\\bapiName\\s*:')
        .matcher(args)
        .find();
      if (!hasApiName) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] createRecord(...) is called with a record-input literal ' +
            'that never sets apiName. LDS requires apiName (the object\'s ' +
            'API name) at the top level of the object passed to ' +
            'createRecord — omitting it throws at runtime, not deploy ' +
            'time. Add apiName: \'ObjectApiName\' alongside fields.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: @wire(getRecord, {...}) MISSING fields/optionalFields/layoutTypes
  // catches: wiring getRecord with a config object that supplies recordId
  // but none of fields, optionalFields, or layoutTypes — LDS requires at
  // least one of these to know what to fetch; omitting all three throws
  // at RUNTIME ("either fields or layout type must be specified"), not a
  // deploy-time error, so this silently ships broken.
  // ─────────────────────────────────────────────────────────────
  private static void validateGetRecordWireHasFieldsOrLayoutTypes(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern wirePat = Pattern.compile('@wire\\s*\\(\\s*getRecord\\s*,');
    Matcher m = wirePat.matcher(content);
    while (m.find()) {
      Integer wireParenStart = content.indexOf('(', m.start());
      String wireBlock = extractBalancedRegion(
        content,
        wireParenStart,
        '(',
        ')'
      );
      if (wireBlock == null) {
        continue;
      }

      Boolean suppliesShape =
        Pattern.compile('\\bfields\\s*:').matcher(wireBlock).find() ||
        Pattern.compile('\\boptionalFields\\s*:').matcher(wireBlock).find() ||
        Pattern.compile('\\blayoutTypes\\s*:').matcher(wireBlock).find();

      if (!suppliesShape) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] @wire(getRecord, {...}) never supplies fields, ' +
            'optionalFields, or layoutTypes. LDS requires at least one of ' +
            'these to know what to fetch — omitting all three throws at ' +
            'runtime ("either fields or layout type must be specified"), ' +
            'not deploy time. Add a fields: [...] array (imported field ' +
            'references from \'@salesforce/schema/...\') to the wire ' +
            'config.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: .layouts ACCESSED ON A getRecord (NOT getRecordUi) WIRE RESULT
  // catches: reading record.layouts.Full.sections (or similar) off a
  // getRecord wire result — getRecord's response is always a plain
  // RecordRepresentation ({ apiName, fields, id, ... }); it NEVER has a
  // layouts property, even when layoutTypes is set. layoutTypes on
  // getRecord only changes which fields are populated inside
  // record.fields — it does not attach layout/section metadata. That
  // { records, layouts, objectInfos } shape belongs exclusively to a
  // DIFFERENT wire adapter, getRecordUi. Confirmed as a real incident
  // 2026-08-25: caseFullLayoutPanel wired getRecord with
  // layoutTypes: ['Full'] and read record.layouts.Full.sections — always
  // undefined, so the component deployed clean and placed on the page,
  // but rendered a permanently empty card with no data, no spinner, and
  // no error, since the wire itself never fails.
  //
  // Gated on the file using @wire(getRecord, — not merely importing it —
  // AND never using getRecordUi anywhere in the same file. If both
  // adapters appear together, this is left unchecked (can't confidently
  // attribute which wire's result a given .layouts access belongs to) —
  // same conservative-on-ambiguity approach as this validator's other
  // literal/heuristic-scoped checks.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoLayoutsAccessOnGetRecordWire(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Boolean usesGetRecordWire = Pattern.compile(
        '@wire\\s*\\(\\s*getRecord\\s*,'
      )
      .matcher(content)
      .find();
    if (!usesGetRecordWire) {
      return;
    }

    Boolean usesGetRecordUi = Pattern.compile('\\bgetRecordUi\\b')
      .matcher(content)
      .find();
    if (usesGetRecordUi) {
      return;
    }

    Boolean accessesLayouts = Pattern.compile('\\.layouts\\b')
      .matcher(content)
      .find();
    if (accessesLayouts) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Accesses ".layouts" on a getRecord wire result. getRecord ' +
          'NEVER returns a layouts property — even with layoutTypes set, ' +
          'layoutTypes only filters which fields populate record.fields. ' +
          'This silently renders empty (no error, no deploy-time signal) ' +
          'since the property is always undefined. To read actual layout ' +
          'metadata (sections/rows/fields), use getRecordUi instead — it ' +
          'genuinely returns { records, layouts, objectInfos }. Or, for ' +
          'simply DISPLAYING a record\'s full/compact layout, skip custom ' +
          'wire code entirely and use <lightning-record-form record-id=' +
          '{recordId} object-api-name="X" layout-type="Full"> instead.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: <lightning-datatable> MISSING key-field
  // catches: <lightning-datatable data={records} columns={columns}> with
  // no key-field attribute at all. key-field defaults to "id" (lowercase)
  // when omitted — but a Salesforce record's real unique identifier field
  // is "Id" (capital I), as returned by Apex/SOQL/getRecord alike, so the
  // default value never matches real data. The component still renders
  // rows (rendering doesn't depend on key-field), so this ships with no
  // deploy-time signal and only surfaces later as flaky row
  // selection/inline-edit draft tracking/row-action targeting.
  // ─────────────────────────────────────────────────────────────
  private static void validateDatatableHasKeyField(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern tagPat = Pattern.compile('(?is)<lightning-datatable\\b([^>]*)>');
    Matcher m = tagPat.matcher(content);
    while (m.find()) {
      String attrs = m.group(1);
      Boolean hasKeyField = Pattern.compile('\\bkey-field\\s*=')
        .matcher(attrs)
        .find();
      if (!hasKeyField) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] <lightning-datatable> is missing a key-field attribute. ' +
            'key-field defaults to "id" (lowercase) when omitted, but a ' +
            'Salesforce record\'s real unique identifier field is "Id" ' +
            '(capital I) — the default never matches real data, so row ' +
            'selection, inline-edit draft tracking, and row actions can ' +
            'all misbehave with no deploy-time error. Add ' +
            'key-field="Id" (or whichever field genuinely holds each ' +
            'row\'s unique identifier).'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: draftValues NEVER RESET BACK TO AN EMPTY ARRAY
  // catches: a component that uses draftValues (lightning-datatable
  // inline edit) but never resets it to [] anywhere in the file. Without
  // the reset, the datatable stays permanently in its "editing" state
  // after a save — the edited cells remain visually highlighted and the
  // Save/Cancel action bar never disappears, even though the underlying
  // write succeeded. A real, well-documented lightning-datatable footgun,
  // not a hypothetical one — the reset is easy to forget because the save
  // itself (e.g. updateRecord) succeeding gives no indication the UI-side
  // draftValues state also needs clearing.
  //
  // Presence-only, same precision tradeoff as validateSpinnerResetOnError
  // above: only checks that draftValues = [] appears SOMEWHERE in the
  // file, not that it specifically runs on both the success and failure
  // path of the same handler — a false negative here (a reset gated only
  // on success) is accepted as consistent with how the rest of this
  // validator scopes presence-only checks.
  // ─────────────────────────────────────────────────────────────
  private static void validateDatatableDraftValuesReset(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }
    if (!Pattern.compile('\\bdraftValues\\b').matcher(content).find()) {
      return;
    }

    // "this." is deliberately required — a bare "draftValues = [];" with no
    // "this." is the class FIELD DECLARATION every draftValues-using
    // component starts with (draftValues = [];), not a reset performed
    // after a save. Without requiring "this.", a component that declares
    // the field but never actually resets it after saving would incorrectly
    // pass this check on its declaration alone.
    Boolean resetsDraftValues = Pattern.compile(
        '\\bthis\\.draftValues\\s*=\\s*\\[\\s*\\]'
      )
      .matcher(content)
      .find();
    if (!resetsDraftValues) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Uses draftValues (lightning-datatable inline edit) but ' +
          'never resets it back to an empty array anywhere in the file. ' +
          'Without resetting draftValues after a save completes, the ' +
          'datatable stays stuck in its "editing" state — edited cells ' +
          'stay highlighted and the Save/Cancel bar never goes away, even ' +
          'though the write succeeded. Add this.draftValues = []; in the ' +
          'onsave handler after the write completes (ideally in a path ' +
          'that runs on both success and failure, e.g. a finally block).'
      );
    }
  }

  // Scans forward from an opening bracket character at openIndex and
  // returns the substring up to (and including) its matching closing
  // bracket, counting nesting depth. Generic over the bracket pair so it
  // works for both '(' + ')' and '{' + '}' call/object-literal scanning.
  // Returns null if no matching close is found (malformed or truncated
  // source) — callers must treat null as "could not verify, skip this
  // occurrence" rather than a violation.
  private static String extractBalancedRegion(
    String content,
    Integer openIndex,
    String openChar,
    String closeChar
  ) {
    if (
      openIndex == null ||
      openIndex < 0 ||
      openIndex >= content.length() ||
      content.substring(openIndex, openIndex + 1) != openChar
    ) {
      return null;
    }
    Integer depth = 0;
    for (Integer i = openIndex; i < content.length(); i++) {
      String ch = content.substring(i, i + 1);
      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) {
          return content.substring(openIndex, i + 1);
        }
      }
    }
    return null;
  }

  // Scans forward from an opening '{' at contentIndex and returns the
  // substring up to (and including) its matching closing '}', counting
  // nested braces. Returns null if no matching close is found (malformed
  // or truncated source) — callers must treat null as "could not verify,
  // skip this occurrence" rather than a violation.
  private static String extractBalancedBlock(
    String content,
    Integer openBraceIndex
  ) {
    if (
      openBraceIndex == null ||
      openBraceIndex < 0 ||
      openBraceIndex >= content.length()
    ) {
      return null;
    }
    Integer depth = 0;
    for (Integer i = openBraceIndex; i < content.length(); i++) {
      String ch = content.substring(i, i + 1);
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return content.substring(openBraceIndex, i + 1);
        }
      }
    }
    return null;
  }

  private static void throwReservedWordError(
    String fileName,
    String reservedWord,
    String usedAs
  ) {
    throw new ApexCodeValidator.ValidationException(
      '[' +
        fileName +
        '] "' +
        reservedWord +
        '" is a reserved JavaScript keyword and cannot be used as ' +
        usedAs +
        ' — Salesforce will reject this at deploy with LWC1211. Rename it, ' +
        'e.g. "' +
        reservedWord +
        '" → "' +
        reservedWord +
        'Record" or "' +
        reservedWord +
        'Item".'
    );
  }
}
