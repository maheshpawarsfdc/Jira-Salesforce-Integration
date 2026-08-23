/**
 * ApexCodeValidator — Static analysis for generated Apex code
 * Validates against common anti-patterns and governor limit violations
 * Called by LLMResponseProcessor before ZipBuilder staging
 */
public class ApexCodeValidator {
  public class ValidationException extends Exception {
  }

  // ─────────────────────────────────────────────────────────────
  // PUBLIC ENTRY POINT
  // ─────────────────────────────────────────────────────────────
  public static void validate(String fileName, String apexCode) {
    validateNotBlank(fileName, apexCode);
    validateBalancedBraces(fileName, apexCode);
    validateBatchableClassesAreTopLevel(fileName, apexCode);
    validateAndOrOperators(fileName, apexCode);
    validateSecurityEnforcedPlacement(fileName, apexCode);
    validateSecurityEnforcedOrdering(fileName, apexCode);
    validateCacheableMethodHasNoDml(fileName, apexCode);
    validateApexOperatorsInSoql(fileName, apexCode);
    validateDmlInLoops(fileName, apexCode);
    validateSoqlInLoops(fileName, apexCode);
    validateUntypedCollections(fileName, apexCode);
    // validateDmlInBeforeTrigger(fileName, apexCode);
    validateTodoComments(fileName, apexCode);
    validateNoEmptyHandlerMethods(fileName, apexCode);
    validateMissingNullChecks(fileName, apexCode);
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 1: DML IN LOOPS (Governor Limit: 150 DML ops/transaction)
  // ─────────────────────────────────────────────────────────────
  private static void validateNotBlank(String fileName, String apexCode) {
    if (String.isBlank(apexCode)) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Apex source is blank. Retry generation; empty .cls/.trigger files must not be deployed.'
      );
    }

    String normalized = apexCode.toLowerCase();
    if (fileName != null && fileName.endsWith('.trigger')) {
      if (!normalized.contains('trigger ') || !normalized.contains(' on ')) {
        throw new ValidationException(
          '[' + fileName + '] Apex trigger source is incomplete.'
        );
      }
    } else if (fileName != null && fileName.endsWith('.cls')) {
      if (!normalized.contains(' class ')) {
        throw new ValidationException(
          '[' + fileName + '] Apex class source is incomplete.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: BALANCED BRACES (catches <EOF> compile error)
  // ─────────────────────────────────────────────────────────────
  private static void validateBalancedBraces(String fileName, String apexCode) {
    String cleaned = removeComments(apexCode);
    // Strip string literals so braces inside strings are ignored
    cleaned = cleaned.replaceAll('\'[^\']*\'', '\'\'');
    Integer open = 0;
    Integer close = 0;
    for (Integer i = 0; i < cleaned.length(); i++) {
      String ch = cleaned.substring(i, i + 1);
      if (ch == '{') {
        open++;
      } else if (ch == '}') {
        close++;
      }
    }
    if (open != close) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Unbalanced braces: ' +
          open +
          ' opening { but ' +
          close +
          ' closing }. The Apex source is incomplete and will cause unexpected token: <EOF>. ' +
          'Return the COMPLETE class with every opening brace matched by a closing brace.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: BATCHABLE CLASSES MUST BE TOP-LEVEL
  // Database.Batchable implementations cannot be nested in Apex.
  // ─────────────────────────────────────────────────────────────
  private static void validateBatchableClassesAreTopLevel(
    String fileName,
    String apexCode
  ) {
    String cleaned = removeComments(apexCode);
    cleaned = cleaned.replaceAll('\'[^^\']*\'', '\'\'');

    Pattern batchablePattern = Pattern.compile(
      '(?i)\\bimplements\\b[^{};]*\\bDatabase\\.Batchable\\s*<'
    );
    Matcher matcher = batchablePattern.matcher(cleaned);
    while (matcher.find()) {
      Integer braceDepth = 0;
      for (Integer index = 0; index < matcher.start(); index++) {
        String character = cleaned.substring(index, index + 1);
        if (character == '{') {
          braceDepth++;
        } else if (character == '}') {
          braceDepth--;
        }
      }
      if (braceDepth > 0) {
        throw new ValidationException(
          '[' +
            fileName +
            '] A class implementing Database.Batchable<SObject> must be a top-level Apex class. ' +
            'Move the Batchable implementation outside any enclosing class.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: AND/OR AS APEX LOGICAL OPERATORS
  // catches: Extra 'IDENTIFIER', at 'AND' / Unexpected token 'AND'
  // ─────────────────────────────────────────────────────────────
  private static void validateAndOrOperators(String fileName, String apexCode) {
    String noSoql = apexCode.replaceAll('(?s)\\[[^\\]]*SELECT[^\\]]*\\]', ' ');

    String cleaned = removeComments(noSoql);
    cleaned = cleaned.replaceAll('\'[^\']*\'', '\'\'');
    cleaned = cleaned.toUpperCase();

    Pattern p = Pattern.compile('\\b(AND|OR)\\b');
    Matcher m = p.matcher(cleaned);

    if (m.find()) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Invalid logical operator detected. ' +
          'Use && and || in Apex. AND/OR are only allowed inside SOQL.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: && / || INSIDE SOQL
  // catches: Unexpected token '|' or '&' / Missing ';' inside a query,
  // and the cascade of downstream errors that follow (undeclared query
  // variables, unrelated tokens like WITH/SECURITY_ENFORCED flagged as
  // errors, etc.) once the query itself fails to parse.
  // Mirror image of validateAndOrOperators: SOQL requires the AND / OR
  // keywords — Apex's && and || operators are invalid inside [SELECT ...].
  // ─────────────────────────────────────────────────────────────
  private static void validateApexOperatorsInSoql(
    String fileName,
    String apexCode
  ) {
    Pattern soqlPat = Pattern.compile('(?s)\\[[^\\]]*SELECT[^\\]]*\\]');
    Matcher soqlMatcher = soqlPat.matcher(removeComments(apexCode));

    while (soqlMatcher.find()) {
      String soqlBlock = soqlMatcher.group();
      if (soqlBlock.contains('&&') || soqlBlock.contains('||')) {
        throw new ValidationException(
          '[' +
            fileName +
            '] Found && or || inside a SOQL query: ' +
            soqlBlock.abbreviate(150) +
            '. SOQL requires the AND / OR keywords, not Apex\'s && / || operators. ' +
            'Replace && with AND and || with OR inside [SELECT ...] queries.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: WITH SECURITY_ENFORCED OUTSIDE SOQL
  // catches: Unexpected token 'WITH' / Extra 'IDENTIFIER', at 'WITH'
  // WITH SECURITY_ENFORCED is a SOQL-only clause — it must appear inside
  // [SELECT ...] query brackets, and cannot be passed as an argument to
  // Security.stripInaccessible() or used anywhere else in Apex.
  // ─────────────────────────────────────────────────────────────
  private static void validateSecurityEnforcedPlacement(
    String fileName,
    String apexCode
  ) {
    String noSoql = apexCode.replaceAll('(?s)\\[[^\\]]*SELECT[^\\]]*\\]', ' ');

    String cleaned = removeComments(noSoql);
    cleaned = cleaned.replaceAll('\'[^\']*\'', '\'\'');

    Pattern p = Pattern.compile('(?i)\\bWITH\\s+SECURITY_ENFORCED\\b');
    Matcher m = p.matcher(cleaned);

    if (m.find()) {
      throw new ValidationException(
        '[' +
          fileName +
          '] "WITH SECURITY_ENFORCED" found outside a SOQL query. ' +
          'It is only valid inside [SELECT ...] query brackets, e.g. ' +
          '[SELECT Id FROM Account WHERE Id = :accId WITH SECURITY_ENFORCED]. ' +
          'To enforce object/field security on records outside a query (e.g. before DML), ' +
          'use Security.stripInaccessible(AccessType.READABLE, records) instead — it takes ' +
          'an AccessType enum (not AccessLevel) and a List<SObject>, and returns an ' +
          'SObjectAccessDecision (call .getRecords() on it). It never takes WITH SECURITY_ENFORCED ' +
          'as an argument and does not return void.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: WITH SECURITY_ENFORCED / WITH USER_MODE ORDERING INSIDE SOQL
  // catches: Unexpected token 'WITH' / Extra 'IDENTIFIER', at 'WITH' /
  // unexpected token: '<EOF>' — the SAME error signature as
  // validateSecurityEnforcedPlacement above, but for a case that check
  // structurally cannot see: it strips each whole [SELECT ...] block
  // before scanning for a stray WITH, so a WITH clause that IS inside
  // the brackets but in the WRONG position (e.g. after ORDER BY/GROUP BY/
  // LIMIT instead of right after WHERE) is invisible to it. Correct SOQL
  // clause order is SELECT..FROM..WHERE..WITH..GROUP BY..ORDER BY..LIMIT..
  // OFFSET..FOR UPDATE, so this rule flags WITH SECURITY_ENFORCED/WITH
  // USER_MODE appearing after any of those later clauses, and flags a
  // second WITH clause in the same query (only one is ever valid).
  // ─────────────────────────────────────────────────────────────
  private static void validateSecurityEnforcedOrdering(
    String fileName,
    String apexCode
  ) {
    String cleaned = removeComments(apexCode);
    cleaned = cleaned.replaceAll('\'[^\']*\'', '\'\'');

    Pattern soqlPat = Pattern.compile('(?s)\\[[^\\]]*SELECT[^\\]]*\\]');
    Matcher soqlMatcher = soqlPat.matcher(cleaned);

    Pattern withPat = Pattern.compile(
      '(?i)\\bWITH\\s+(SECURITY_ENFORCED|USER_MODE|SYSTEM_MODE)\\b'
    );

    while (soqlMatcher.find()) {
      String soqlBlock = soqlMatcher.group();
      String upperBlock = soqlBlock.toUpperCase();

      Matcher withMatcher = withPat.matcher(soqlBlock);
      if (!withMatcher.find()) {
        continue;
      }
      Integer withIdx = withMatcher.start();

      if (withMatcher.find()) {
        throw new ValidationException(
          '[' +
            fileName +
            '] More than one WITH SECURITY_ENFORCED/WITH USER_MODE clause found in a single SOQL query: ' +
            soqlBlock.abbreviate(150) +
            '. Only one WITH clause is allowed per query — remove the duplicate.'
        );
      }

      List<String> laterClauseKeywords = new List<String>{
        'GROUP BY',
        'ORDER BY',
        'LIMIT',
        'OFFSET',
        'FOR UPDATE',
        'FOR VIEW',
        'FOR REFERENCE'
      };
      Boolean misplaced = false;
      for (String kw : laterClauseKeywords) {
        Integer idx = upperBlock.indexOf(kw);
        if (idx != -1 && idx < withIdx) {
          misplaced = true;
          break;
        }
      }

      if (misplaced) {
        throw new ValidationException(
          '[' +
            fileName +
            '] "WITH SECURITY_ENFORCED"/"WITH USER_MODE" is out of order in this SOQL query: ' +
            soqlBlock.abbreviate(150) +
            '. It must come immediately after the WHERE clause (or FROM, if there is no WHERE) ' +
            'and BEFORE GROUP BY / ORDER BY / LIMIT / OFFSET / FOR UPDATE, e.g. ' +
            '[SELECT Id FROM Contact WHERE AccountId = :accId WITH SECURITY_ENFORCED ORDER BY Name]. ' +
            'The current placement causes "Unexpected token \'WITH\'" / "Extra \'IDENTIFIER\', at \'WITH\'" ' +
            'compile errors — reorder the clause.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: DML INSIDE A cacheable=true METHOD (LWC wired-Apex integration)
  // catches: a method annotated @AuraEnabled(cacheable=true) — the only
  // annotation a @wire adapter accepts — that also performs DML. This is
  // a real Salesforce platform restriction (cacheable Apex methods must
  // never perform DML), but it's enforced at RUNTIME, not compile time —
  // the class deploys cleanly and only fails once the method is actually
  // invoked, so catching it here saves a real deploy-and-fail round trip.
  // Locates each @AuraEnabled(cacheable=true) annotation textually, then
  // walks brace-depth from the first '{' after it (same technique
  // containsDmlInsideLoop already uses below) to isolate THAT method's own
  // body before scanning it — never the whole class — so a DML statement
  // in a different, non-cacheable method never triggers a false positive.
  // ─────────────────────────────────────────────────────────────
  private static void validateCacheableMethodHasNoDml(
    String fileName,
    String apexCode
  ) {
    if (fileName == null || !fileName.endsWith('.cls')) {
      return;
    }

    String code = removeComments(apexCode);
    code = code.replaceAll('\'[^\']*\'', '\'\'');

    Pattern annPat = Pattern.compile(
      '(?i)@AuraEnabled\\s*\\(\\s*cacheable\\s*=\\s*true\\s*\\)'
    );
    Matcher annMatcher = annPat.matcher(code);

    while (annMatcher.find()) {
      Integer annEnd = annMatcher.end();
      Integer openBrace = code.indexOf('{', annEnd);
      if (openBrace == -1) {
        continue;
      }

      Integer depth = 1;
      Integer pos = openBrace + 1;
      while (pos < code.length() && depth > 0) {
        String ch = code.substring(pos, pos + 1);
        if (ch == '{') {
          depth++;
        } else if (ch == '}') {
          depth--;
        }
        pos++;
      }
      if (depth != 0) {
        continue;
      }

      String body = code.substring(openBrace + 1, pos - 1).toLowerCase();
      Boolean hasDml =
        containsStandaloneWord(body, 'insert') ||
        containsStandaloneWord(body, 'update') ||
        containsStandaloneWord(body, 'delete') ||
        containsStandaloneWord(body, 'upsert') ||
        containsStandaloneWord(body, 'undelete') ||
        body.contains('database.insert') ||
        body.contains('database.update') ||
        body.contains('database.delete') ||
        body.contains('database.upsert') ||
        body.contains('database.undelete');

      if (hasDml) {
        throw new ValidationException(
          '[' +
            fileName +
            '] @AuraEnabled(cacheable=true) method contains a DML statement. ' +
            'Cacheable Apex methods must never perform DML — this is enforced ' +
            'by the Salesforce platform at runtime and will fail after deploy, ' +
            'not at compile time. Either remove cacheable=true from this ' +
            'method (if it must write data), or move the write into a ' +
            'separate plain @AuraEnabled method.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 1: DML IN LOOPS (Governor Limit: 150 DML ops/transaction)
  // ─────────────────────────────────────────────────────────────
  private static void validateDmlInLoops(String fileName, String apexCode) {
    String normalized = sanitizeCode(apexCode);

    if (containsDmlInsideLoop(normalized)) {
      throw new ValidationException(
        '[' +
          fileName +
          '] DML operation (insert/update/delete/upsert) found inside loop. ' +
          'Move the DML outside the loop and perform it in bulk.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 2: SOQL IN LOOPS (Governor Limit: 100 SOQL queries/transaction)
  // ─────────────────────────────────────────────────────────────
  private static void validateSoqlInLoops(String fileName, String apexCode) {
    String normalized = sanitizeCode(apexCode);

    if (containsSoqlInsideLoop(normalized)) {
      throw new ValidationException(
        '[' +
          fileName +
          '] SOQL query found inside loop. ' +
          'Move the query outside the loop.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 3: UNTYPED COLLECTIONS (ClassCastException risk)
  // ─────────────────────────────────────────────────────────────
  private static void validateUntypedCollections(
    String fileName,
    String apexCode
  ) {
    String normalized = removeComments(apexCode);

    Pattern collectionPattern = Pattern.compile('\\b(List|Map|Set)\\b');
    Matcher matcher = collectionPattern.matcher(normalized);

    while (matcher.find()) {
      String collectionType = matcher.group();

      Integer start = matcher.end();

      while (
        start < normalized.length() &&
        normalized.substring(start, start + 1) == ' '
      ) {
        start++;
      }

      if (
        start >= normalized.length() ||
        normalized.substring(start, start + 1) != '<'
      ) {
        throw new ValidationException(
          '[' +
            fileName +
            '] Untyped ' +
            collectionType +
            ' detected. Use generic collections.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 4: DML IN BEFORE TRIGGER (Salesforce limitation)
  // ─────────────────────────────────────────────────────────────
  /* private static void validateDmlInBeforeTrigger(
    String fileName,
    String apexCode
  ) {
    if (!fileName.contains('Trigger')) {
      return;
    }

    String normalized = removeComments(apexCode).toLowerCase();

    Boolean isBeforeTrigger =
      normalized.contains('before insert') ||
      normalized.contains('before update') ||
      normalized.contains('before delete');

    if (!isBeforeTrigger) {
      return;
    }

    Boolean hasDml =
      normalized.contains('insert ') ||
      normalized.contains('update ') ||
      normalized.contains('delete ') ||
      normalized.contains('upsert ');

    if (hasDml) {
      throw new ValidationException(
        '[' +
          fileName +
          '] BEFORE trigger contains DML statements. ' +
          'Salesforce does not allow DML in BEFORE triggers. Use AFTER trigger instead.'
      );
    }
  } */

  // ─────────────────────────────────────────────────────────────
  // RULE 5: TODO/FIXME COMMENTS (Incomplete code)
  // ─────────────────────────────────────────────────────────────
  private static void validateTodoComments(String fileName, String apexCode) {
    String upperCode = apexCode.toUpperCase();

    if (
      upperCode.contains('TODO') ||
      upperCode.contains('FIXME') ||
      upperCode.contains('HACK') ||
      upperCode.contains('XXX') ||
      upperCode.contains('LOGIC HERE') ||
      upperCode.contains('PLACEHOLDER') ||
      upperCode.contains('IMPLEMENTATION HERE') ||
      upperCode.contains('ADD LOGIC')
    ) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Placeholder or TODO comments found. ' +
          'Code is incomplete and must not be deployed.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 6: MISSING NULL CHECKS BEFORE COMPARISON
  // ─────────────────────────────────────────────────────────────
  private static void validateMissingNullChecks(
    String fileName,
    String apexCode
  ) {
    String normalized = removeComments(apexCode);

    // Look for patterns like "if (record.SomeField__c < oldRecord.SomeField__c)"
    // or "if (record.InvoiceDate < ...)"
    // And ensure "!= null" is in the same if-statement.
    Pattern ifPattern = Pattern.compile('(?s)if\\s*\\(([^)]+)\\)');
    Matcher m = ifPattern.matcher(normalized);
    while (m.find()) {
      String condition = m.group(1);
      // If there's a > or < comparison on an sObject field (word.word)
      if (condition.contains('<') || condition.contains('>')) {
        Pattern fieldComp = Pattern.compile('\\b\\w+\\.\\w+\\s*[<>]');
        Matcher compMatch = fieldComp.matcher(condition);
        if (compMatch.find()) {
          if (!condition.contains('!= null')) {
            throw new ValidationException(
              '[' +
                fileName +
                '] Missing null check before numeric/date comparison (< or >). ' +
                'ALWAYS add a != null check before comparing sObject fields.'
            );
          }
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // HELPER: Remove comments and string literals
  // ─────────────────────────────────────────────────────────────
  private static void validateNoEmptyHandlerMethods(
    String fileName,
    String apexCode
  ) {
    if (fileName == null || !fileName.endsWith('.cls')) {
      return;
    }

    String normalized = removeComments(apexCode);
    Pattern emptyHandlerMethod = Pattern.compile(
      '(?is)\\bhandle\\w+\\s*\\([^)]*\\)\\s*\\{\\s*\\}'
    );
    Matcher matcher = emptyHandlerMethod.matcher(normalized);
    if (matcher.find()) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Empty trigger handler method found. Implement the ticket logic before deployment.'
      );
    }
  }

  private static String removeComments(String code) {
    String result = code;
    result = result.replaceAll('//[^\n]*', ' ');
    result = result.replaceAll('/\\*.*?\\*/', ' ');
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // HELPER: Check if pattern exists inside a for/while loop
  // ─────────────────────────────────────────────────────────────
  /* private static Boolean hasPatternInLoop(String code, String pattern) {
    Integer patternIdx = code.indexOf(pattern);

    while (patternIdx >= 0) {
      Integer forIdx = code.lastIndexOf('for (', patternIdx);
      Integer whileIdx = code.lastIndexOf('while (', patternIdx);
      Integer loopStart = Math.max(forIdx, whileIdx);

      if (loopStart < 0) {
        patternIdx = code.indexOf(pattern, patternIdx + 1);
        continue;
      }

      Integer braceCount = 0;
      Boolean foundOpen = false;

      for (Integer i = loopStart; i < patternIdx && i < code.length(); i++) {
        String c = code.substring(i, i + 1);
        if (c == '{') {
          foundOpen = true;
          braceCount++;
        } else if (c == '}' && foundOpen) {
          braceCount--;
        }
      }

      if (foundOpen && braceCount > 0) {
        return true;
      }

      patternIdx = code.indexOf(pattern, patternIdx + 1);
    }

    return false;
  } */

  private static String sanitizeCode(String code) {
    if (String.isBlank(code)) {
      return '';
    }

    // Normalize line endings
    code = code.replace('\r\n', '\n');
    code = code.replace('\r', '\n');

    // Remove single-line comments
    code = code.replaceAll('//[^\\n]*', ' ');

    // Remove multi-line comments
    code = code.replaceAll('/\\*[\\s\\S]*?\\*/', ' ');

    // Remove string literals
    code = code.replaceAll('\'([^\'\\\\]|\\\\.)*\'', '\'\'');

    // Normalize whitespace
    code = code.replaceAll('\\s+', ' ');

    return code;
  }
  private static Boolean containsDmlInsideLoop(String code) {
    code = removeComments(code);

    Integer index = 0;

    while (index < code.length()) {
      Integer forIndex = code.indexOf('for (', index);
      Integer whileIndex = code.indexOf('while (', index);

      Integer loopIndex;

      if (forIndex == -1) {
        loopIndex = whileIndex;
      } else if (whileIndex == -1) {
        loopIndex = forIndex;
      } else {
        loopIndex = Math.min(forIndex, whileIndex);
      }

      if (loopIndex == -1) {
        break;
      }

      Integer openBrace = code.indexOf('{', loopIndex);

      if (openBrace == -1) {
        index = loopIndex + 1;
        continue;
      }

      Integer braceDepth = 1;
      Integer pos = openBrace + 1;

      while (pos < code.length() && braceDepth > 0) {
        String ch = code.substring(pos, pos + 1);

        if (ch == '{') {
          braceDepth++;
        } else if (ch == '}') {
          braceDepth--;
        }

        pos++;
      }

      if (braceDepth != 0) {
        break;
      }

      String loopBody = code.substring(openBrace + 1, pos - 1).toLowerCase();

      if (
        containsStandaloneWord(loopBody, 'insert') ||
        containsStandaloneWord(loopBody, 'update') ||
        containsStandaloneWord(loopBody, 'delete') ||
        containsStandaloneWord(loopBody, 'upsert')
      ) {
        return true;
      }

      index = pos;
    }

    return false;
  }

  private static Boolean containsSoqlInsideLoop(String code) {
    Integer pos = 0;

    while (true) {
      Integer forPos = code.indexOf('for (', pos);
      Integer whilePos = code.indexOf('while (', pos);

      Integer loopPos;

      if (forPos == -1)
        loopPos = whilePos;
      else if (whilePos == -1)
        loopPos = forPos;
      else
        loopPos = Math.min(forPos, whilePos);

      if (loopPos == -1)
        break;

      Integer openBrace = code.indexOf('{', loopPos);

      if (openBrace == -1)
        break;

      Integer braceDepth = 1;
      Integer i = openBrace + 1;

      while (i < code.length() && braceDepth > 0) {
        String ch = code.substring(i, i + 1);

        if (ch == '{')
          braceDepth++;
        else if (ch == '}')
          braceDepth--;

        i++;
      }

      String loopBody = code.substring(openBrace + 1, i - 1).toLowerCase();

      if (loopBody.contains('[select')) {
        return true;
      }

      pos = i;
    }

    return false;
  }

  private static Integer getLineNumber(String code, Integer index) {
    Integer line = 1;

    for (Integer i = 0; i < index; i++) {
      if (code.substring(i, i + 1) == '\n') {
        line++;
      }
    }

    return line;
  }

  private static Boolean containsStandaloneWord(String text, String word) {
    Pattern p = Pattern.compile('\\b' + word.toLowerCase() + '\\b');
    Matcher m = p.matcher(text.toLowerCase());

    return m.find();
  }
}
