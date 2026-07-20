public with sharing class PromptBuilder {
  public static String build(GenerationContext context) {
    String prompt = '';

    // System Prompt
    prompt += context.systemPrompt + '\n\n';

    // User Story
    prompt += buildStorySection(context) + '\n\n';

    // Story Analysis
    prompt += buildStoryAnalysisSection(context) + '\n\n';

    // Metadata
    prompt += buildMetadataSection(context) + '\n\n';

    // Existing Code
    prompt += buildExistingCodeSection(context) + '\n\n';

    // Org State
    prompt += buildOrgStateSection(context) + '\n\n';

    // Rules
    prompt += buildImplementationRules(context) + '\n\n';

    // Output Rules
    prompt += buildOutputRules();

    return prompt;
  }

  /*
   * --------------------------------------------------------
   * USER STORY
   * --------------------------------------------------------
   */
  private static String buildStorySection(GenerationContext context) {
    String text = '';

    text += '===== USER STORY =====\n';
    text += 'Summary : ' + context.summary + '\n';
    text += 'Description : ' + context.description + '\n';

    return text;
  }

  /*
   * --------------------------------------------------------
   * STORY ANALYSIS
   * --------------------------------------------------------
   */
  private static String buildStoryAnalysisSection(GenerationContext context) {
    if (context.story == null) {
      return '';
    }

    StoryAnalysis story = context.story;

    String text = '';

    text += '===== STORY ANALYSIS =====\n';
    text += 'Object : ' + story.objectName + '\n';
    text += 'Operation : ' + story.operation + '\n';
    text += 'Artifact : ' + story.artifactType + '\n';
    text += 'Trigger Event : ' + story.triggerEvent + '\n';

    return text;
  }

  /*
   * --------------------------------------------------------
   * METADATA
   * --------------------------------------------------------
   */
  private static String buildMetadataSection(GenerationContext context) {
    if (context.metadata == null) {
      return '';
    }

    MetadataContext metadata = context.metadata;

    String text = '';

    text += '===== METADATA =====\n';
    text += 'Object : ' + metadata.objectName + '\n';

    if (metadata.fields != null) {
      text += 'Fields:\n';

      for (FieldInfo field : metadata.fields) {
        text += '- ' + field.apiName + ' (' + field.type + ')\n';
      }
    }

    return text;
  }

  /*
   * --------------------------------------------------------
   * EXISTING CODE
   * --------------------------------------------------------
   */
  private static String buildExistingCodeSection(GenerationContext context) {
    if (context.existingCode == null) {
      return '';
    }

    ExistingCodeContext code = context.existingCode;

    String text = '';

    text += '===== EXISTING CODE =====\n';

    if (code.triggerExists) {
      text += 'Trigger : ' + code.triggerName + '\n';
    }

    if (code.handlerExists) {
      text += 'Handler : ' + code.handlerName + '\n';
    }

    if (code.serviceExists) {
      text += 'Service : ' + code.serviceName + '\n';
    }

    if (code.selectorExists) {
      text += 'Selector : ' + code.selectorName + '\n';
    }

    text += '\n';

    text += 'IMPORTANT:\n';
    text += '- Modify existing classes whenever possible.\n';
    text += '- Never create duplicate triggers.\n';
    text += '- Never create duplicate handlers.\n';
    text += '- Reuse existing services.\n';

    return text;
  }

  /*
   * --------------------------------------------------------
   * ORG STATE
   * --------------------------------------------------------
   */
  private static String buildOrgStateSection(GenerationContext context) {
    if (context.orgState == null) {
      return '';
    }

    String text = '';

    text += '===== ORG STATE =====\n';
    text += JSON.serializePretty(context.orgState);

    return text;
  }

  /*
   * --------------------------------------------------------
   * IMPLEMENTATION RULES
   * --------------------------------------------------------
   */
  private static String buildImplementationRules(GenerationContext context) {
    String text = '';

    text += '===== IMPLEMENTATION RULES =====\n';
    text += '- Follow Salesforce Best Practices.\n';
    text += '- Use Trigger Handler Pattern.\n';
    text += '- Use Service Layer Pattern.\n';
    text += '- Bulkify all Apex.\n';
    text += '- Never use SOQL inside loops.\n';
    text += '- Never use DML inside loops.\n';
    text += '- Use WITH SHARING unless required otherwise.\n';
    text += '- Follow Apex naming conventions.\n';
    text += '- Generate deployable code only.\n';

    if (context.story != null) {
      if (context.story.needTrigger) {
        text += '- Create only one trigger.\n';
      }

      if (context.story.needHandler) {
        text += '- Create one trigger handler.\n';
      }

      if (context.story.needTestClass) {
        text += '- Generate comprehensive test class.\n';
      }

      if (context.story.needLwc) {
        text += '- Generate HTML, JS and js-meta.xml.\n';
      }
    }

    return text;
  }

  /*
   * --------------------------------------------------------
   * OUTPUT RULES
   * --------------------------------------------------------
   */
  private static String buildOutputRules() {
    String text = '';

    text += '===== OUTPUT FORMAT =====\n';
    text += 'Return JSON only.\n';
    text += 'Do not return markdown.\n';
    text += 'Do not explain the code.\n';
    text += 'Return complete deployable files.\n';
    text += 'Include matching meta.xml files.\n';
    text += 'Do not create duplicate Apex classes.\n';
    text += 'Do not create duplicate triggers.\n';
    text += 'Update existing classes whenever possible.\n';

    return text;
  }
}
