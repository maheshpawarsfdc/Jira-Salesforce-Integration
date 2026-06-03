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
    validateDmlInLoops(fileName, apexCode);
    validateSoqlInLoops(fileName, apexCode);
    validateUntypedCollections(fileName, apexCode);
    validateDmlInBeforeTrigger(fileName, apexCode);
    validateTodoComments(fileName, apexCode);
    validateNoEmptyHandlerMethods(fileName, apexCode);
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

  private static void validateDmlInLoops(String fileName, String apexCode) {
    String normalized = removeComments(apexCode);

    Boolean hasInsertInLoop = hasPatternInLoop(normalized, 'insert ');
    Boolean hasUpdateInLoop = hasPatternInLoop(normalized, 'update ');
    Boolean hasDeleteInLoop = hasPatternInLoop(normalized, 'delete ');
    Boolean hasUpsertInLoop = hasPatternInLoop(normalized, 'upsert ');

    if (
      hasInsertInLoop ||
      hasUpdateInLoop ||
      hasDeleteInLoop ||
      hasUpsertInLoop
    ) {
      throw new ValidationException(
        '[' +
          fileName +
          '] DML operation (insert/update/delete/upsert) found inside loop. ' +
          'This violates governor limits. Batch all DML outside the loop.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 2: SOQL IN LOOPS (Governor Limit: 100 SOQL queries/transaction)
  // ─────────────────────────────────────────────────────────────
  private static void validateSoqlInLoops(String fileName, String apexCode) {
    String normalized = removeComments(apexCode);

    if (hasPatternInLoop(normalized, '[SELECT ')) {
      throw new ValidationException(
        '[' +
          fileName +
          '] SOQL query found inside loop. ' +
          'This violates governor limits (max 100 queries per transaction). ' +
          'Move query outside loop or batch queries.'
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

    if (normalized.contains('List ') && !normalized.contains('List<')) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Untyped List detected. Use List<Type> instead of List.'
      );
    }
    if (normalized.contains('Map ') && !normalized.contains('Map<')) {
      throw new ValidationException(
        '[' +
          fileName +
          '] Untyped Map detected. Use Map<Key, Value> instead of Map.'
      );
    }
    if (normalized.contains('Set ') && !normalized.contains('Set<')) {
      throw new ValidationException(
        '[' + fileName + '] Untyped Set detected. Use Set<Type> instead of Set.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE 4: DML IN BEFORE TRIGGER (Salesforce limitation)
  // ─────────────────────────────────────────────────────────────
  private static void validateDmlInBeforeTrigger(
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
  }

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
  private static Boolean hasPatternInLoop(String code, String pattern) {
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
  }
}
