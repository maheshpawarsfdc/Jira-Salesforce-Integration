public class LLMGroqClient {
  // ── TOKEN TRACKING (shared across all LLM calls, any provider) ─
  public static Integer apiCallCount = 0;
  public static Integer totalPromptTokens = 0;
  public static Integer totalCompletionTokens = 0;
  public static Integer totalTokens = 0;

  // ─────────────────────────────────────────────────────────────
  // CALL LLM — delegates to LLMBedrockClient.
  // Kept as a distinct method (rather than removed) because
  // ApexTestRunQueueable calls this entry point directly.
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> callGroq(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice
  ) {
    return callGroq(messages, tools, toolChoice, 4096);
  }

  public static Map<String, Object> callGroq(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice,
    Integer maxTokens
  ) {
    return LLMBedrockClient.callBedrock(messages, tools, toolChoice, maxTokens);
  }

  // ─────────────────────────────────────────────────────────────
  // CALL LLM — single entry point used by the rest of the pipeline.
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> callLLM(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice
  ) {
    return callLLM(messages, tools, toolChoice, 4096);
  }

  public static Map<String, Object> callLLM(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice,
    Integer maxTokens
  ) {
    return LLMBedrockClient.callBedrock(messages, tools, toolChoice, maxTokens);
  }

  // ─────────────────────────────────────────────────────────────
  // SYSTEM PROMPT (content moved to LLM_Prompt__mdt CMT records)
  // ─────────────────────────────────────────────────────────────
  public static String buildXmlGenerationSystemPrompt() {
    return PromptService.assemblePrompt(
      new Set<String>(PromptService.getRoutableFeatureKeys())
    );
  }

  // ─────────────────────────────────────────────────────────────
  // USER PROMPT
  // ─────────────────────────────────────────────────────────────
  public static String buildXmlGenerationUserPrompt(
    String issueKey,
    String summary,
    String description,
    Map<String, Object> orgState
  ) {
    String prompt =
      'Jira Issue: ' +
      issueKey +
      '\nSummary: ' +
      summary +
      '\nDescription: ' +
      (String.isBlank(description) ? '(no description)' : description);

    if (!StaticResourceHelper.currentAttachments.isEmpty()) {
      prompt += '\n\nATTACHMENTS ON THIS TICKET:';
      for (String fileName : StaticResourceHelper.currentAttachments.keySet()) {
        String mime = StaticResourceHelper.currentAttachments.get(fileName)
          .get('mimeType');
        prompt += '\n- ' + fileName + ' (' + mime + ')';
        if (fileName.toLowerCase().endsWith('.csv')) {
          prompt += '\n  → CSV file — use dmlOperations csvProcess, do NOT read content yourself';
        }
      }
    }

    if (orgState.containsKey('csvFiles')) {
      prompt +=
        '\n\nCSV FILES HAVE BEEN PRE-READ BY APEX (rows are cached server-side).' +
        '\nColumn names and row counts are in org state under "csvFiles".' +
        '\nFor each CSV file — use dmlOperations with type csvProcess.' +
        '\nIdentify the csvType from the column names in org state.' +
        '\nDo NOT generate XML for CSV data. Apex handles it via csvProcess.';
    }

    prompt +=
      '\n\nCURRENT ORG STATE (from pre-checks):\n' + JSON.serialize(orgState);
    prompt +=
      '\n\nGenerate the Salesforce Metadata XML files needed to implement this ticket. ' +
      'Return ONLY the JSON object as specified in the system prompt.';

    return prompt;
  }

  // ─────────────────────────────────────────────────────────────
  // UTILITY — Clean JSON response from LLM
  // Strips markdown code fences if present
  // ─────────────────────────────────────────────────────────────
  public static String cleanJsonResponse(String response) {
    if (String.isBlank(response)) {
      return '{}';
    }

    String cleaned = response.trim();

    if (cleaned.startsWith('```json')) {
      cleaned = cleaned.substring(7);
    } else if (cleaned.startsWith('```')) {
      cleaned = cleaned.substring(3);
    }

    if (cleaned.endsWith('```')) {
      cleaned = cleaned.substring(0, cleaned.length() - 3);
    }

    cleaned = cleaned.trim();

    cleaned = cleaned.replaceAll(',\\s*\\}', '}');
    cleaned = cleaned.replaceAll(',\\s*\\]', ']');

    return cleaned;
  }

  // ─────────────────────────────────────────────────────────────
  // LOG + RESET TOKEN COUNTERS
  // ─────────────────────────────────────────────────────────────
  public static void logTokenSummary() {
    System.debug('');
    System.debug('╔══════════════════════════════════════╗');
    System.debug('║         LLM USAGE SUMMARY            ║');
    System.debug('╠══════════════════════════════════════╣');
    System.debug('║  API Calls        : ' + apiCallCount);
    System.debug('║  Prompt Tokens    : ' + totalPromptTokens);
    System.debug('║  Completion Tokens: ' + totalCompletionTokens);
    System.debug('║  Total Tokens     : ' + totalTokens);
    System.debug('╚══════════════════════════════════════╝');
  }

  public static void resetTokenCounters() {
    apiCallCount = 0;
    totalPromptTokens = 0;
    totalCompletionTokens = 0;
    totalTokens = 0;
  }
}
