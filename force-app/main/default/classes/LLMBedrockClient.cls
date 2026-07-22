public class LLMBedrockClient {
  public static Map<String, Object> callBedrock(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice,
    Integer maxTokens
  ) {
    String modelId = App_Config__c.getOrgDefaults().Bedrock_Model_Id__c;
    String encodedModelId = EncodingUtil.urlEncode(modelId, 'UTF-8');

    // Converse API requires the system prompt as a top-level array field,
    // and each message's content as an array of {"text": ...} blocks
    // (not a bare string like the old Anthropic Invoke format used).
    String systemPrompt = '';
    List<Map<String, Object>> conversationMessages = new List<Map<String, Object>>();
    for (Map<String, Object> msg : messages) {
      if ('system'.equals(msg.get('role'))) {
        systemPrompt = (String) msg.get('content');
      } else {
        conversationMessages.add(
          new Map<String, Object>{
            'role' => msg.get('role'),
            'content' => new List<Object>{
              new Map<String, Object>{ 'text' => msg.get('content') }
            }
          }
        );
      }
    }

    Map<String, Object> body = new Map<String, Object>{
      'messages' => conversationMessages,
      'inferenceConfig' => new Map<String, Object>{
        'maxTokens' => maxTokens,
        // Low, non-zero temperature: favors the model's most likely/consistent
        // completion (reduces run-to-run generation variance for the same
        // ticket) while leaving enough room to avoid degenerate/repetitive
        // output across the range of ticket types this pipeline handles.
        'temperature' => 0.15
      }
    };
    if (String.isNotBlank(systemPrompt)) {
      body.put(
        'system',
        new List<Object>{ new Map<String, Object>{ 'text' => systemPrompt } }
      );
    }

    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:Bedrock/model/' + encodedModelId + '/converse');
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('Accept', 'application/json');
    req.setTimeout(120000);
    req.setBody(JSON.serialize(body));

    LLMGroqClient.apiCallCount++;
    System.debug('════════════════════════════════════════════════');
    System.debug('── BEDROCK API CALL #' + LLMGroqClient.apiCallCount);
    System.debug('   Model ID   : ' + modelId);
    System.debug(
      '   Endpoint   : callout:Bedrock/model/' + encodedModelId + '/converse'
    );
    System.debug('   Max Tokens : ' + maxTokens);
    System.debug(
      '   Msg Count  : ' +
        conversationMessages.size() +
        ' (system prompt length: ' +
        systemPrompt.length() +
        ' chars)'
    );
    System.debug('════════════════════════════════════════════════');

    HttpResponse res;
    Integer MAX_RETRIES = 2;
    for (Integer retry = 0; retry <= MAX_RETRIES; retry++) {
      res = new Http().send(req);
      System.debug(
        '── BEDROCK RESPONSE STATUS: ' +
          res.getStatusCode() +
          (retry > 0 ? ' (retry ' + retry + ')' : '')
      );
      if (res.getStatusCode() == 200) {
        break; // success — fall through to response processing below
      }
      if (res.getStatusCode() != 429 || retry == MAX_RETRIES) {
        System.debug('── BEDROCK ERROR BODY: ' + res.getBody());
        throw new LLMService.LLMException(
          'Bedrock API error ' + res.getStatusCode() + ': ' + res.getBody()
        );
      }
      // 429 and retries remain — log and loop (callout overhead is ~100-300ms)
      System.debug(
        'Bedrock 429 rate-limit — retrying (' + retry + '/' + MAX_RETRIES + ')'
      );
    }

    System.debug('── BEDROCK RAW RESPONSE: ' + res.getBody());

    Map<String, Object> bedrockResp = (Map<String, Object>) JSON.deserializeUntyped(
      res.getBody()
    );

    // Update shared token counters on LLMGroqClient so LLMService token logging works unchanged
    Map<String, Object> usage = (Map<String, Object>) bedrockResp.get('usage');
    Integer inputTok = 0;
    Integer outputTok = 0;
    if (usage != null) {
      inputTok = (Integer) usage.get('inputTokens');
      outputTok = (Integer) usage.get('outputTokens');
      LLMGroqClient.totalPromptTokens += inputTok;
      LLMGroqClient.totalCompletionTokens += outputTok;
      LLMGroqClient.totalTokens += (inputTok + outputTok);

      System.debug(
        'TOKENS [call #' +
          LLMGroqClient.apiCallCount +
          '] >> ' +
          'input=' +
          inputTok +
          ' output=' +
          outputTok +
          ' total=' +
          (inputTok + outputTok)
      );
    }

    // Normalize Bedrock Converse response → Groq-shaped Map so LLMResponseProcessor needs no changes.
    // Bedrock Converse returns: { "output": {"message": {"content": [{"text":"..."}, {"reasoningContent":{...}}]}}, "stopReason": "end_turn", ... }
    // Groq returns:            { "choices": [{"message":{"role":"assistant","content":"..."}}], ... }
    Map<String, Object> output = (Map<String, Object>) bedrockResp.get(
      'output'
    );
    Map<String, Object> outputMessage = output != null
      ? (Map<String, Object>) output.get('message')
      : null;
    List<Object> contentBlocks = outputMessage != null
      ? (List<Object>) outputMessage.get('content')
      : null;
    String textContent = '';
    if (contentBlocks != null && !contentBlocks.isEmpty()) {
      for (Object rawBlock : contentBlocks) {
        Map<String, Object> block = (Map<String, Object>) rawBlock;
        if (block.get('text') != null) {
          textContent = (String) block.get('text');
          break;
        }
      }
    }

    Map<String, Object> message = new Map<String, Object>{
      'role' => 'assistant',
      'content' => textContent
    };
    Map<String, Object> choice = new Map<String, Object>{
      'message' => message,
      'finish_reason' => bedrockResp.get('stopReason')
    };
    Map<String, Object> normalizedUsage = new Map<String, Object>{
      'prompt_tokens' => inputTok,
      'completion_tokens' => outputTok,
      'total_tokens' => (inputTok + outputTok)
    };

    System.debug(
      '── BEDROCK EXTRACTED TEXT (' +
        textContent.length() +
        ' chars): ' +
        textContent.left(300) +
        (textContent.length() > 300 ? '...' : '')
    );
    System.debug(
      '── BEDROCK TOKENS >> input=' +
        inputTok +
        ' output=' +
        outputTok +
        ' total=' +
        (inputTok + outputTok)
    );
    System.debug('════════════════════════════════════════════════');

    return new Map<String, Object>{
      'choices' => new List<Object>{ choice },
      'usage' => normalizedUsage
    };
  }
}
