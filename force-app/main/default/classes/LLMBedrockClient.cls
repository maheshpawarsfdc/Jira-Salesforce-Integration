public class LLMBedrockClient {
  public static Map<String, Object> callBedrock(
    List<Map<String, Object>> messages,
    List<Map<String, Object>> tools,
    String toolChoice,
    Integer maxTokens
  ) {
    String modelId = App_Config__c.getOrgDefaults().Bedrock_Model_Id__c;
    String encodedModelId = EncodingUtil.urlEncode(modelId, 'UTF-8');

    // Bedrock Anthropic models require system prompt as a top-level field,
    // not as a message with role "system" like OpenAI/Groq format
    String systemPrompt = '';
    List<Map<String, Object>> conversationMessages = new List<Map<String, Object>>();
    for (Map<String, Object> msg : messages) {
      if ('system'.equals(msg.get('role'))) {
        systemPrompt = (String) msg.get('content');
      } else {
        conversationMessages.add(msg);
      }
    }

    Map<String, Object> body = new Map<String, Object>{
      'anthropic_version' => 'bedrock-2023-05-31',
      'max_tokens' => maxTokens,
      'messages' => conversationMessages
    };
    if (String.isNotBlank(systemPrompt)) {
      body.put('system', systemPrompt);
    }

    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:Bedrock/model/' + encodedModelId + '/invoke');
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
      '   Endpoint   : callout:Bedrock/model/' + encodedModelId + '/invoke'
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

    HttpResponse res = new Http().send(req);
    System.debug('── BEDROCK RESPONSE STATUS: ' + res.getStatusCode());

    if (res.getStatusCode() != 200) {
      System.debug('── BEDROCK ERROR BODY: ' + res.getBody());
      throw new LLMService.LLMException(
        'Bedrock API error ' + res.getStatusCode() + ': ' + res.getBody()
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
      inputTok = (Integer) usage.get('input_tokens');
      outputTok = (Integer) usage.get('output_tokens');
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

    // Normalize Bedrock response → Groq-shaped Map so LLMResponseProcessor needs no changes.
    // Bedrock returns: { "content": [{"type":"text","text":"..."}], "stop_reason": "end_turn", ... }
    // Groq returns:   { "choices": [{"message":{"role":"assistant","content":"..."}}], ... }
    List<Object> contentBlocks = (List<Object>) bedrockResp.get('content');
    String textContent = '';
    if (contentBlocks != null && !contentBlocks.isEmpty()) {
      Map<String, Object> firstBlock = (Map<String, Object>) contentBlocks[0];
      if ('text'.equals(firstBlock.get('type'))) {
        textContent = (String) firstBlock.get('text');
      }
    }

    Map<String, Object> message = new Map<String, Object>{
      'role' => 'assistant',
      'content' => textContent
    };
    Map<String, Object> choice = new Map<String, Object>{
      'message' => message,
      'finish_reason' => bedrockResp.get('stop_reason')
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
