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
    validateAndOrOperators(fileName, apexCode);
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
