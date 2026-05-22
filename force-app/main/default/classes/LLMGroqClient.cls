public class LLMGroqClient {
  private static final String GROQ_BASE_URL = App_Config__c.getOrgDefaults()
    .Groq_Base_URL__c;
  private static final String GROQ_API_KEY = App_Config__c.getOrgDefaults()
    .Groq_API_Key__c;
  private static final String GROQ_MODEL = App_Config__c.getOrgDefaults()
    .Groq_Model__c;

  // ── TOKEN TRACKING ─────────────────────────────────────────────
  public static Integer apiCallCount = 0;
  public static Integer totalPromptTokens = 0;
  public static Integer totalCompletionTokens = 0;
  public static Integer totalTokens = 0;

  // ─────────────────────────────────────────────────────────────
  // CALL GROQ API
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
    HttpRequest req = new HttpRequest();

    apiCallCount++;
    System.debug(
      '── GROQ API CALL #' + apiCallCount + ' (max_tokens=' + maxTokens + ')'
    );

    req.setEndpoint(GROQ_BASE_URL + '/chat/completions');
    req.setMethod('POST');
    req.setHeader('Authorization', 'Bearer ' + GROQ_API_KEY);
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);

    Map<String, Object> body = new Map<String, Object>{
      'model' => GROQ_MODEL,
      'messages' => messages,
      'max_tokens' => maxTokens
    };

    if (tools != null && !tools.isEmpty()) {
      body.put('tools', tools);
      body.put(
        'tool_choice',
        String.isNotBlank(toolChoice) ? toolChoice : 'auto'
      );
    }

    req.setBody(JSON.serialize(body));

    HttpResponse res;
    Integer MAX_RETRIES = 2;
    for (Integer retry = 0; retry <= MAX_RETRIES; retry++) {
      res = new Http().send(req);
      System.debug(
        'Groq HTTP Status: ' +
          res.getStatusCode() +
          (retry > 0 ? ' (retry ' + retry + ')' : '')
      );
      if (res.getStatusCode() == 200) {
        break; // success — fall through to response processing below
      }
      if (res.getStatusCode() != 429 || retry == MAX_RETRIES) {
        System.debug('Groq API Error: ' + res.getBody());
        throw new LLMService.LLMException(
          'Groq API error ' + res.getStatusCode() + ': ' + res.getBody()
        );
      }
      // 429 and retries remain — log and loop (callout overhead is ~100-300ms)
      System.debug(
        'Groq 429 rate-limit — retrying (' + retry + '/' + MAX_RETRIES + ')'
      );
    }

    Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );

    Map<String, Object> usage = (Map<String, Object>) response.get('usage');
    if (usage != null) {
      Integer prompt = (Integer) usage.get('prompt_tokens');
      Integer completion = (Integer) usage.get('completion_tokens');
      Integer total = (Integer) usage.get('total_tokens');

      totalPromptTokens += prompt;
      totalCompletionTokens += completion;
      totalTokens += total;
    }

    return response;
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
    if (String.isBlank(response))
      return '{}';

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
