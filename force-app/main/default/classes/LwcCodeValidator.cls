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

  public static void validate(String fileName, String content) {
    validateNotBlank(fileName, content);
    validateTemplateBindingExpressions(fileName, content);
    validateNoHtmlEntitiesInJs(fileName, content);
    validateTodoComments(fileName, content);
    validateNoReservedWordIdentifiers(fileName, content);
    validateCustomEventNameLowercase(fileName, content);
    validateLmsSubscribeHasUnsubscribe(fileName, content);
    validateLmsMessageContextWired(fileName, content);
    validateRefreshApexImported(fileName, content);
    validateNoDirectWiredResultMutation(fileName, content);
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
      if (eventName != eventName.toLowerCase()) {
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
