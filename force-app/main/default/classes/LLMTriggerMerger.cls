public class LLMTriggerMerger {
  // ─────────────────────────────────────────────────────────────
  // TRIGGER MERGE ENFORCER — entry point
  // Sanitizes and merges existing trigger/handler with LLM output
  // ─────────────────────────────────────────────────────────────
  public static void enforceTriggerMerge(
    List<Object> files,
    Map<String, Object> orgState
  ) {
    if (orgState == null) {
      return;
    }

    Map<String, Object> existingTrigger = (Map<String, Object>) orgState.get(
      'existingTrigger'
    );
    Map<String, Object> existingHandler = (Map<String, Object>) orgState.get(
      'existingHandlerClass'
    );

    if (existingTrigger == null) {
      return;
    }

    String existingTriggerBody = (String) existingTrigger.get('body');
    String existingHandlerBody = existingHandler != null
      ? (String) existingHandler.get('body')
      : null;

    existingTriggerBody = LLMXmlSanitizer.sanitizeStandardFieldReferences(
      existingTriggerBody,
      orgState
    );
    if (existingHandlerBody != null) {
      existingHandlerBody = LLMXmlSanitizer.sanitizeStandardFieldReferences(
        existingHandlerBody,
        orgState
      );
    }

    if (files == null) {
      return;
    }

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String metadataType = (String) file.get('metadataType');
      String generatedBody = (String) file.get('xmlContent');
      if (String.isBlank(generatedBody)) {
        continue;
      }

      generatedBody = LLMXmlSanitizer.sanitizeStandardFieldReferences(
        generatedBody,
        orgState
      );
      file.put('xmlContent', generatedBody);

      if (
        metadataType == 'ApexTrigger' && String.isNotBlank(existingTriggerBody)
      ) {
        String merged = mergeTriggerEvents(existingTriggerBody, generatedBody);
        if (merged != null) {
          file.put('xmlContent', merged);
          System.debug('enforceTriggerMerge: trigger events enforced');
        }
      }

      if (
        metadataType == 'ApexClass' && String.isNotBlank(existingHandlerBody)
      ) {
        String merged = mergeClassMethods(existingHandlerBody, generatedBody);
        if (merged != null) {
          file.put('xmlContent', merged);
          System.debug('enforceTriggerMerge: class methods enforced');
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // MERGE TRIGGER EVENTS
  // Computes union of existing and generated event lists,
  // writes them back in canonical Salesforce order.
  // ─────────────────────────────────────────────────────────────
  public static String mergeTriggerEvents(
    String existingBody,
    String generatedBody
  ) {
    try {
      Pattern evPat = Pattern.compile('(?i)on\\s+\\w+\\s*\\(([^)]+)\\)');

      Matcher em = evPat.matcher(existingBody);
      Matcher gm = evPat.matcher(generatedBody);
      if (!em.find() || !gm.find()) {
        return null;
      }

      Set<String> allEvents = new Set<String>();
      for (String e : em.group(1).split(',')) {
        allEvents.add(e.trim().toLowerCase());
      }
      for (String e : gm.group(1).split(',')) {
        allEvents.add(e.trim().toLowerCase());
      }

      List<String> canonical = new List<String>{
        'before insert',
        'before update',
        'before delete',
        'after insert',
        'after update',
        'after delete',
        'after undelete'
      };
      List<String> merged = new List<String>();
      for (String ev : canonical) {
        if (allEvents.contains(ev))
          merged.add(ev);
      }

      Set<String> existingSet = new Set<String>();
      for (String e : em.group(1).split(',')) {
        existingSet.add(e.trim().toLowerCase());
      }
      if (merged.size() == existingSet.size()) {
        return null;
      }

      String mergedStr = String.join(merged, ', ');
      return existingBody.replaceFirst(
        '(?i)(on\\s+\\w+\\s*\\()([^)]+)(\\))',
        '$1' + mergedStr + '$3'
      );
    } catch (Exception e) {
      System.debug('mergeTriggerEvents failed: ' + e.getMessage());
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // MERGE CLASS METHODS — no naming convention required
  // Uses brace-depth tracking to extract ALL top-level methods
  // from both existing and generated class bodies, then injects
  // any method present in existing but absent from generated.
  // ─────────────────────────────────────────────────────────────
  public static String mergeClassMethods(
    String existingBody,
    String generatedBody
  ) {
    try {
      Map<String, String> existingMethods = extractTopLevelMethods(
        existingBody
      );
      Map<String, String> generatedMethods = extractTopLevelMethods(
        generatedBody
      );

      System.debug(
        'mergeClassMethods: existing methods  = ' + existingMethods.keySet()
      );
      System.debug(
        'mergeClassMethods: generated methods = ' + generatedMethods.keySet()
      );

      Map<String, String> replacementMethodBodies = new Map<String, String>();
      List<String> newMethodBodies = new List<String>();
      for (String name : generatedMethods.keySet()) {
        if (name == 'dispatch') {
          continue;
        }
        if (
          existingMethods.containsKey(name) &&
          isPlaceholderOrEmptyMethod(existingMethods.get(name)) &&
          !isPlaceholderOrEmptyMethod(generatedMethods.get(name))
        ) {
          replacementMethodBodies.put(name, generatedMethods.get(name));
          System.debug(
            'mergeClassMethods: placeholder method to replace [' + name + ']'
          );
        } else if (!existingMethods.containsKey(name)) {
          newMethodBodies.add(generatedMethods.get(name));
          System.debug(
            'mergeClassMethods: new method to inject [' + name + ']'
          );
        }
      }

      String existingDispatch = existingMethods.get('dispatch');
      String generatedDispatch = generatedMethods.get('dispatch');

      String newDispatchBlocks = '';
      if (existingDispatch != null && generatedDispatch != null) {
        newDispatchBlocks = extractNewDispatchBlocks(
          existingDispatch,
          generatedDispatch
        );
      }

      if (
        replacementMethodBodies.isEmpty() &&
        newMethodBodies.isEmpty() &&
        String.isBlank(newDispatchBlocks)
      ) {
        System.debug('mergeClassMethods: nothing new to merge');
        return null;
      }

      String result = existingBody;

      for (String name : replacementMethodBodies.keySet()) {
        result = result.replace(
          existingMethods.get(name),
          replacementMethodBodies.get(name)
        );
      }

      if (String.isNotBlank(newDispatchBlocks) && existingDispatch != null) {
        Integer lastBraceInDispatch = existingDispatch.lastIndexOf('}');
        if (lastBraceInDispatch >= 0) {
          String updatedDispatch =
            existingDispatch.substring(0, lastBraceInDispatch) +
            '\n        // ── Added by automation ──' +
            newDispatchBlocks +
            '\n    }';
          result = result.replace(existingDispatch, updatedDispatch);
        }
      }

      if (!newMethodBodies.isEmpty()) {
        Integer lastBrace = result.lastIndexOf('}');
        if (lastBrace < 0) {
          return null;
        }
        String injection = '\n\n    // ── Added by automation ──';
        for (String m : newMethodBodies) {
          injection += '\n    ' + m.trim() + '\n';
        }
        result = result.substring(0, lastBrace) + injection + '\n}';
      }

      System.debug('mergeClassMethods: merge complete');
      return result;
    } catch (Exception e) {
      System.debug('mergeClassMethods failed: ' + e.getMessage());
      ErrorLogger.log(e);
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT NEW DISPATCH BLOCKS
  // Returns only the if-blocks from generated that handle
  // TriggerOperation values NOT already present in existing.
  // ─────────────────────────────────────────────────────────────
  public static String extractNewDispatchBlocks(
    String existingDispatch,
    String generatedDispatch
  ) {
    Pattern opPat = Pattern.compile('System\\.TriggerOperation\\.(\\w+)');

    Set<String> existingOps = new Set<String>();
    Matcher em = opPat.matcher(existingDispatch);
    while (em.find()) {
      existingOps.add(em.group(1));
    }

    Set<String> generatedOps = new Set<String>();
    Matcher gm = opPat.matcher(generatedDispatch);
    while (gm.find()) {
      generatedOps.add(gm.group(1));
    }

    System.debug('extractNewDispatchBlocks: existingOps=' + existingOps);
    System.debug('extractNewDispatchBlocks: generatedOps=' + generatedOps);

    String result = '';
    for (String op : generatedOps) {
      if (existingOps.contains(op)) {
        continue;
      }

      Pattern linePat = Pattern.compile(
        '[ \\t]*(if\\s*\\([^)]*' + op + '[^)]*\\)\\s*\\w+\\([^)]*\\)\\s*;)'
      );
      Matcher lm = linePat.matcher(generatedDispatch);
      if (lm.find()) {
        result += '\n        ' + lm.group(1).trim();
        System.debug(
          'extractNewDispatchBlocks: adding if-block for op [' +
            op +
            ']: ' +
            lm.group(1).trim()
        );
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT TOP-LEVEL METHODS (brace-depth parser)
  // Returns Map<lowercaseMethodName, fullMethodText>
  // ─────────────────────────────────────────────────────────────
  public static Map<String, String> extractTopLevelMethods(String classBody) {
    Map<String, String> result = new Map<String, String>();
    if (String.isBlank(classBody)) {
      return result;
    }

    Integer len = classBody.length();

    Integer classOpen = classBody.indexOf('{');
    if (classOpen < 0) {
      return result;
    }

    Integer i = classOpen + 1;
    Integer depth = 1;

    Integer sigStart = -1;

    while (i < len) {
      String ch = classBody.substring(i, i + 1);

      if (
        ch == '/' &&
        i + 1 < len &&
        classBody.substring(i + 1, i + 2) == '/'
      ) {
        i = classBody.indexOf('\n', i);
        if (i < 0) {
          break;
        }
        i++;
        continue;
      }

      if (
        ch == '/' &&
        i + 1 < len &&
        classBody.substring(i + 1, i + 2) == '*'
      ) {
        Integer endComment = classBody.indexOf('*/', i + 2);
        i = (endComment < 0) ? len : endComment + 2;
        continue;
      }

      if (ch == '\'') {
        i++;
        while (i < len) {
          String sc = classBody.substring(i, i + 1);
          if (sc == '\\' && i + 1 < len) {
            i += 2;
            continue;
          }
          if (sc == '\'') {
            i++;
            break;
          }
          i++;
        }
        continue;
      }

      if (ch == '{') {
        if (depth == 1) {
          sigStart = findSignatureStart(classBody, i, classOpen);
        }
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 1 && sigStart >= 0) {
          String fullBlock = classBody.substring(sigStart, i + 1).trim();
          String methodName = extractMethodName(fullBlock);
          if (String.isNotBlank(methodName)) {
            result.put(methodName.toLowerCase(), fullBlock);
            System.debug(
              'extractTopLevelMethods: found method [' + methodName + ']'
            );
          }
          sigStart = -1;
        }
      }

      i++;
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // FIND SIGNATURE START
  // Walks backwards from the opening brace of a method
  // ─────────────────────────────────────────────────────────────
  public static Integer findSignatureStart(
    String body,
    Integer openBracePos,
    Integer classOpenPos
  ) {
    Integer i = openBracePos - 1;
    while (i > classOpenPos) {
      String ch = body.substring(i, i + 1);
      if (ch == ';' || ch == '}') {
        return i + 1;
      }
      i--;
    }
    return classOpenPos + 1;
  }

  // ─────────────────────────────────────────────────────────────
  // EXTRACT METHOD NAME
  // Finds the method name from a full method block text
  // ─────────────────────────────────────────────────────────────
  public static String extractMethodName(String methodText) {
    Integer bracePos = methodText.indexOf('{');
    String signature = bracePos > 0
      ? methodText.substring(0, bracePos)
      : methodText;

    Pattern wordParen = Pattern.compile('(\\w+)\\s*\\(');
    Matcher m = wordParen.matcher(signature);

    Set<String> reserved = new Set<String>{
      'if',
      'else',
      'for',
      'while',
      'do',
      'switch',
      'try',
      'catch',
      'finally',
      'new',
      'return',
      'throw',
      'class',
      'interface',
      'enum',
      'extends',
      'implements',
      'public',
      'private',
      'protected',
      'global',
      'static',
      'void',
      'abstract',
      'virtual',
      'override',
      'testMethod',
      'with',
      'sharing',
      'without',
      'String',
      'Integer',
      'Boolean',
      'Long',
      'Decimal',
      'Double',
      'Object',
      'Id',
      'Date',
      'Time',
      'DateTime',
      'Blob',
      'List',
      'Map',
      'Set',
      'Type',
      'System',
      'Schema',
      'Database',
      'Test',
      'Trigger',
      'SObject',
      'insert',
      'update',
      'delete',
      'upsert',
      'merge',
      'undelete'
    };

    String lastCandidate = null;
    while (m.find()) {
      String candidate = m.group(1);
      if (!reserved.contains(candidate)) {
        lastCandidate = candidate;
      }
    }
    return lastCandidate;
  }

  // ─────────────────────────────────────────────────────────────
  // MERGE DISPATCH CALLS
  // Ensures the generated dispatch() method contains all the
  // op == TriggerOperation.XXX branches from the existing one.
  // ─────────────────────────────────────────────────────────────
  private static Boolean isPlaceholderOrEmptyMethod(String methodBody) {
    if (String.isBlank(methodBody)) {
      return true;
    }

    String upperBody = methodBody.toUpperCase();
    if (
      upperBody.contains('LOGIC HERE') ||
      upperBody.contains('PLACEHOLDER') ||
      upperBody.contains('IMPLEMENTATION HERE') ||
      upperBody.contains('ADD LOGIC') ||
      upperBody.contains('TODO') ||
      upperBody.contains('FIXME')
    ) {
      return true;
    }

    String noComments = methodBody
      .replaceAll('//[^\\n]*', ' ')
      .replaceAll('/\\*.*?\\*/', ' ');
    Integer openBrace = noComments.indexOf('{');
    Integer closeBrace = noComments.lastIndexOf('}');
    if (openBrace < 0 || closeBrace <= openBrace) {
      return true;
    }

    String bodyOnly = noComments.substring(openBrace + 1, closeBrace).trim();
    return String.isBlank(bodyOnly);
  }

  public static String mergeDispatchCalls(
    String existingDispatch,
    String generatedDispatch
  ) {
    try {
      Pattern opPat = Pattern.compile('System\\.TriggerOperation\\.(\\w+)');

      Set<String> existingOps = new Set<String>();
      Set<String> generatedOps = new Set<String>();

      Matcher em = opPat.matcher(existingDispatch);
      while (em.find()) {
        existingOps.add(em.group(1));
      }

      Matcher gm = opPat.matcher(generatedDispatch);
      while (gm.find()) {
        generatedOps.add(gm.group(1));
      }

      System.debug('mergeDispatchCalls: existingOps  = ' + existingOps);
      System.debug('mergeDispatchCalls: generatedOps = ' + generatedOps);

      List<String> missing = new List<String>();
      for (String op : generatedOps) {
        if (!existingOps.contains(op)) {
          missing.add(op);
        }
      }
      if (missing.isEmpty()) {
        return null;
      }

      String injectedCalls = '';
      for (String op : missing) {
        Pattern callPat = Pattern.compile(
          '(?s)(if\\s*\\([^)]*' + op + '[^)]*\\)\\s*[^;{]+[;{][^}]*(?:\\})?)'
        );
        Matcher cm = callPat.matcher(generatedDispatch);
        if (cm.find()) {
          injectedCalls += '\n        ' + cm.group(1).trim();
          System.debug(
            'mergeDispatchCalls: injecting op block for [' + op + ']'
          );
        }
      }

      if (String.isBlank(injectedCalls)) {
        return null;
      }

      Integer lastBrace = existingDispatch.lastIndexOf('}');
      if (lastBrace < 0) {
        return null;
      }

      return existingDispatch.substring(0, lastBrace) +
        '\n        // ── New op checks ──' +
        injectedCalls +
        '\n    }';
    } catch (Exception e) {
      System.debug('mergeDispatchCalls failed: ' + e.getMessage());
      return null;
    }
  }
}
