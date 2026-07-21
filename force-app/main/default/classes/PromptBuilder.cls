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
    // Only pull in Apex/LWC/Trigger/Service rule blocks when the ticket
    // actually needs them — sending the full rule set on every request
    // (regardless of relevance) was inflating the generation prompt to
    // 50K+ chars even for metadata-only tickets, adding real seconds to
    // the LLM call for rules the model never needed to apply.
    Boolean needsTrigger = context.story != null && context.story.needTrigger;
    Boolean needsHandler = context.story != null && context.story.needHandler;
    Boolean needsTestClass =
      context.story != null && context.story.needTestClass;
    Boolean needsLwc = context.story != null && context.story.needLwc;
    Boolean needsApex = needsTrigger || needsHandler || needsTestClass;

    String text = '';

    text += '===== IMPLEMENTATION RULES =====\n';

    text += 'GENERAL\n';
    text += '- Generate production-ready Salesforce code only.\n';
    text += '- Return COMPLETE deployable code.\n';
    text += '- Do not generate placeholder implementations.\n';
    text += '- Never generate TODO/FIXME/HACK comments.\n';
    text += '- Use enterprise coding standards.\n';
    text += '- Use with sharing unless explicitly stated otherwise.\n';
    text += '- Follow Apex naming conventions.\n';
    text += '- Use meaningful variable names.\n';
    text += '- Avoid duplicate logic.\n';
    text += '- Reuse existing classes whenever possible.\n\n';

    if (needsApex) {
      text += 'APEX BEST PRACTICES\n';
      text += '- Bulkify all code.\n';
      text += '- Never perform SOQL inside loops.\n';
      text += '- Never perform DML inside loops.\n';
      text += '- Never perform callouts inside loops.\n';
      text += '- Validate all method input parameters.\n';
      text += '- Remove unused parameters.\n';
      text += '- Do not create methods that are never called.\n';
      text += '- Use constants instead of magic numbers.\n';
      text += '- Use collections efficiently.\n';
      text += '- Avoid duplicate SOQL queries.\n';
      text += '- Avoid duplicate DML operations.\n';
      text += '- Return early when collections are empty.\n\n';

      text += 'SECURITY\n';
      text += '- Use WITH SECURITY_ENFORCED for read operations whenever appropriate.\n';
      text += '- Use Security.stripInaccessible() before DML when records come from user input.\n';
      text += '- Respect CRUD and Field Level Security.\n\n';
    }

    if (needsTrigger) {
      text += 'TRIGGERS\n';
      text += '- Use one trigger per object.\n';
      text += '- Use Trigger Handler Pattern.\n';
      text += '- Keep triggers logic-free.\n';
      text += '- Call handler methods only.\n';
      text += '- Keep handlers bulkified.\n\n';
    }

    if (needsHandler) {
      text += 'SERVICES\n';
      text += '- Put business logic inside Service classes.\n';
      text += '- Keep handlers lightweight.\n\n';
    }

    if (needsLwc) {
      text += 'LWC CONTROLLERS\n';
      text += '- All @AuraEnabled methods must validate inputs.\n';
      text += '- Throw AuraHandledException with meaningful messages.\n';
      text += '- Do not expose internal exception details.\n';
      text += '- Use cacheable=true only for read-only methods.\n';
      text += '- Remove unused parameters.\n';
      text += '- Return only required fields.\n\n';

      text += 'LWC JAVASCRIPT\n';
      text += '- Prefer @wire for cacheable Apex methods.\n';
      text += '- Use imperative Apex only when required.\n';
      text += '- Handle loading state.\n';
      text += '- Handle errors gracefully.\n';
      text += '- Do not use unnecessary @track.\n';
      text += '- Keep components reusable.\n\n';
    }

    if (needsTestClass) {
      text += '===== TEST CLASS RULES =====\n';
      text += '- Generate a comprehensive Apex test class for every Apex class and trigger.\n';
      text += '- Use @TestSetup for common test data creation whenever possible.\n';
      text += '- Reuse @TestSetup data across all test methods instead of creating duplicate records.\n';
      text += '- Create meaningful and realistic test data.\n';
      text += '- Cover positive, negative, bulk, and edge-case scenarios.\n';
      text += '- Include tests for null values, empty collections, invalid inputs, and exception paths where applicable.\n';
      text += '- Use Test.startTest() and Test.stopTest() around the code under test.\n';
      text += '- Verify asynchronous processing (Batch, Queueable, Future, Scheduled) using Test.stopTest().\n';
      text += '- Use System.assertEquals(), System.assertNotEquals(), System.assert(), System.assertNotNull(), and System.assertThrows() where applicable.\n';
      text += '- Every test method must validate results using assertions. Never write tests that only execute code.\n';
      text += '- Use meaningful test method names such as testHandleAfterInsert_WhenAccountExists().\n';
      text += '- Follow Arrange-Act-Assert (AAA) pattern in every test method.\n';
      text += '- Do not use SeeAllData=true.\n';
      text += '- Generate tests with at least 90% meaningful code coverage.\n';
      text += '- Validate field values, record counts, DML results, and business logic using assertions.\n';
      text += '- Generate production-quality test classes that follow Salesforce best practices.\n\n';
    }

    if (needsLwc) {
      text += '===== LWC RULES =====\n';
      text += '- Use @wire whenever reactive data retrieval is sufficient.\n';
      text += '- Use imperative Apex only when necessary.\n';
      text += '- Handle loading states.\n';
      text += '- Handle errors gracefully.\n';
      text += '- Remove unused imports, variables, and methods.\n';
      text += '- Use Lightning Data Service whenever possible.\n';
      text += '- Use cacheable=true for read-only Apex methods.\n';
      text += '- Do not hardcode record Ids or object names.\n';
      text += '- Follow Salesforce Lightning Design System best practices.\n\n';
    }

    if (needsApex) {
      text += '===== APEX QUALITY RULES =====\n';
      text += '- Use with sharing unless explicitly required otherwise.\n';
      text += '- Validate all input parameters.\n';
      text += '- Never include unused variables or parameters.\n';
      text += '- Use constants instead of magic numbers or hardcoded strings.\n';
      text += '- Use WITH SECURITY_ENFORCED or Security.stripInaccessible() where appropriate.\n';
      text += '- Handle exceptions gracefully using AuraHandledException for LWC controllers.\n';
      text += '- Bulkify all Apex code.\n';
      text += '- Never use SOQL inside loops.\n';
      text += '- Never use DML inside loops.\n';
      text += '- Generate deployable production-ready code.\n\n';
    }

    text += '===== CLEAN CODE RULES =====\n';
    text += '- Do not generate unused classes.\n';
    text += '- Do not generate unused methods.\n';
    text += '- Do not generate unused variables.\n';
    text += '- Do not generate unused constants.\n';
    text += '- Do not generate dead code.\n';
    text += '- Every generated method must be referenced.\n';
    text += '- Keep the solution as small as possible while satisfying the requirements.\n\n';

    if (needsApex) {
      text += '===== SOQL BEST PRACTICES =====\n';
      text += '- Query only required fields.\n';
      text += '- Never use SELECT * style logic.\n';
      text += '- Avoid duplicate SOQL queries.\n';
      text += '- Use relationship queries where appropriate.\n';
      text += '- Use AggregateResult instead of iterating large datasets when possible.\n';
      text += '- Use LIMIT only when business requirement requires it.\n\n';

      text += '===== DML BEST PRACTICES =====\n';
      text += '- Batch DML operations.\n';
      text += '- Skip DML when no records changed.\n';
      text += '- Avoid unnecessary updates.\n';
      text += '- Use Database methods only when partial success is required.\n';
      text += '- Perform one DML operation per object whenever possible.\n\n';
    }

    if (needsTrigger) {
      text += '===== TRIGGER DESIGN =====\n';
      text += '- One trigger per object.\n';
      text += '- Trigger must contain no business logic.\n';
      text += '- Trigger should only invoke handler methods.\n';
      text += '- Prevent recursion.\n';
      text += '- Support all trigger contexts.\n';
      text += '- Never query Trigger.new records.\n';
      text += '- Never modify Trigger.new in after triggers.\n';
      text += '- Bulkify all trigger logic.\n\n';
    }

    if (needsHandler) {
      text += '===== SERVICE LAYER =====\n';
      text += '- Business logic belongs in Service classes.\n';
      text += '- Service methods should be reusable.\n';
      text += '- Avoid duplicate business logic.\n';
      text += '- Keep handlers lightweight.\n\n';
    }

    if (needsApex || needsLwc) {
      text += '===== EXCEPTION HANDLING =====\n';
      text += '- Catch only expected exceptions.\n';
      text += '- Never swallow exceptions.\n';
      text += '- Log meaningful error messages.\n';
      text += '- Throw AuraHandledException for LWC Apex controllers.\n';
      text += '- Do not expose stack traces to end users.\n\n';
    }

    if (needsLwc) {
      text += '===== LWC BEST PRACTICES =====\n';
      text += '- Prefer @wire for cacheable Apex.\n';
      text += '- Use imperative Apex only when necessary.\n';
      text += '- Avoid unnecessary @track decorators.\n';
      text += '- Use getters instead of duplicated variables.\n';
      text += '- Use Lightning Data Service where possible.\n';
      text += '- Show spinner during server calls.\n';
      text += '- Display friendly error messages.\n';
      text += '- Remove unused imports.\n';
      text += '- Remove unused methods.\n';
      text += '- Keep components reusable.\n';
      text += '- Use SLDS best practices.\n\n';
    }

    if (needsApex) {
      text += '===== PERFORMANCE =====\n';
      text += '- Minimize CPU time.\n';
      text += '- Minimize heap usage.\n';
      text += '- Minimize SOQL queries.\n';
      text += '- Minimize DML operations.\n';
      text += '- Avoid nested loops whenever possible.\n';
      text += '- Use Maps for lookups.\n';
      text += '- Use Sets for uniqueness.\n\n';

      text += '===== SECURITY =====\n';
      text += '- Enforce CRUD permissions.\n';
      text += '- Enforce Field Level Security.\n';
      text += '- Use WITH SECURITY_ENFORCED for queries whenever supported.\n';
      text += '- Use Security.stripInaccessible() before DML when required.\n';
      text += '- Never bypass security checks.\n';
      text += '- Avoid dynamic SOQL unless required.\n';
      text += '- Escape dynamic SOQL inputs.\n\n';
    }

    if (context.story != null) {
      if (needsTrigger) {
        text += '- Create only one trigger.\n';
      }

      if (needsHandler) {
        text += '- Create one trigger handler.\n';
      }

      if (needsTestClass) {
        text += '- Generate comprehensive test class.\n';
      }

      if (needsLwc) {
        text += '- Generate HTML, JS, CSS (if required) and js-meta.xml.\n';
        text += '- Generate matching Apex controller if needed.\n';
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
    text += '- Return VALID JSON only.\n';
    text += '- Do not return Markdown.\n';
    text += '- Do not wrap JSON inside ``` blocks.\n';
    text += '- Do not include explanations before or after the JSON.\n';
    text += '- Do not include reasoning.\n';
    text += '- Do not include comments outside generated source code.\n';
    text += '- Return complete deployable source files only.\n\n';

    text += '===== OUTPUT REQUIREMENTS =====\n';
    text += '- Every generated file must compile independently.\n';
    text += '- Return complete source code.\n';
    text += '- Never truncate code.\n';
    text += '- Ensure all opening braces have matching closing braces.\n';
    text += '- Ensure every generated Apex class compiles successfully.\n';
    text += '- Include matching metadata (.cls-meta.xml, .trigger-meta.xml, .js-meta.xml) files where applicable.\n';
    text += '- Include imports only when required.\n';
    text += '- Ensure every referenced class exists or is generated in the response.\n';
    text += '- Do not reference classes that are not present in the org metadata or generated output.\n';
    text += '- Do not invent object names.\n';
    text += '- Do not invent field names.\n';
    text += '- Use only metadata provided in the prompt.\n';
    text += '- If metadata is missing, do not guess. State that the required metadata is unavailable.\n';
    text += '- Do not generate duplicate Apex classes.\n';
    text += '- Do not generate duplicate triggers.\n';
    text += '- Update existing classes whenever possible instead of creating new ones.\n';
    text += '- Every generated method must be fully implemented.\n';
    text += '- Never generate empty methods.\n';
    text += '- Never generate TODO, FIXME, HACK, PLACEHOLDER, or stub implementations.\n';
    text += '- Every generated file must be production-ready.\n';

    return text;
  }
}
