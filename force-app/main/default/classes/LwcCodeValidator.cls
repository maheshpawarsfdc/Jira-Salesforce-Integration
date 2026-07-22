/**
 * LwcCodeValidator — Static analysis for generated LWC HTML/JS source
 * Mirrors ApexCodeValidator's pattern: regex-based checks against known
 * failure signatures, called by LLMResponseProcessor before ZipBuilder
 * staging. Throws ApexCodeValidator.ValidationException (shared exception
 * type) so the existing repair-retry mechanism in
 * LLMResponseProcessor.runXmlGenerationStage handles LWC failures the
 * same way it already handles Apex failures, with no changes needed there.
 */
public class LwcCodeValidator {
  public static void validate(String fileName, String content) {
    validateNotBlank(fileName, content);
    validateTemplateBindingExpressions(fileName, content);
    validateNoHtmlEntitiesInJs(fileName, content);
    validateTodoComments(fileName, content);
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: BLANK/PLACEHOLDER SOURCE
  // ─────────────────────────────────────────────────────────────
  private static void validateNotBlank(String fileName, String content) {
    if (String.isBlank(content)) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] LWC source is blank. Retry generation; empty .html/.js files must not be deployed.'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: TEMPLATE BINDING EXPRESSIONS MUST BE SIMPLE REFERENCES
  // catches: LWC1058 Invalid HTML syntax (unexpected-equals-sign-before-
  // attribute-name, unexpected-character-in-unquoted-attribute-value) —
  // caused by writing an inline JS expression/operator inside a {...}
  // template binding, e.g. disabled={isLoading || currentPage === 1}.
  // A binding may only be a bare identifier or dot-path (e.g. {isLoading},
  // {contact.name}) — never contain operators, comparisons, or spaces.
  // ─────────────────────────────────────────────────────────────
  private static void validateTemplateBindingExpressions(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.html')) {
      return;
    }

    Pattern bindingPat = Pattern.compile('\\{([^{}]+)\\}');
    Matcher m = bindingPat.matcher(content);

    while (m.find()) {
      String expr = m.group(1).trim();
      // A valid binding is a bare identifier or dot-path: letters, digits,
      // underscores, dots only. Anything else (operators, comparisons,
      // spaces, quotes, parens) means an inline expression was used.
      Boolean isSimpleReference = Pattern.matches(
        '[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*',
        expr
      );
      if (!isSimpleReference) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] Invalid template binding {' +
            expr +
            '}. A {...} binding may only be a single property or getter ' +
            'reference (e.g. {isLoading}, {contact.name}) — it cannot contain ' +
            'operators, comparisons, or inline expressions (||, &&, ===, +, etc.). ' +
            'Expose the computed value as a getter in the JS class instead, and bind to that getter.'
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: NO HTML ENTITIES INSIDE JS SOURCE
  // catches: literal "&#124;" (etc.) text embedded in .js source instead
  // of the real character — HTML entities are meaningless outside HTML
  // markup and break JavaScript parsing.
  // ─────────────────────────────────────────────────────────────
  private static void validateNoHtmlEntitiesInJs(
    String fileName,
    String content
  ) {
    if (fileName == null || !fileName.toLowerCase().endsWith('.js')) {
      return;
    }

    Pattern entityPat = Pattern.compile('&(#\\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);');
    Matcher m = entityPat.matcher(content);

    if (m.find()) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Found HTML entity "' +
          m.group() +
          '" inside JavaScript source. .js files are not HTML — write ' +
          'operators and characters literally (e.g. || not &#124;&#124;, && not &amp;&amp;).'
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RULE: TODO/FIXME/PLACEHOLDER (Incomplete code)
  // ─────────────────────────────────────────────────────────────
  private static void validateTodoComments(String fileName, String content) {
    String upperContent = content.toUpperCase();

    // Note: "PLACEHOLDER" is deliberately excluded — it's a standard, legitimate
    // HTML attribute name (placeholder="...") used on virtually every input/search
    // field, not a signal of stub/incomplete code the way it is in Apex source.
    if (
      upperContent.contains('TODO') ||
      upperContent.contains('FIXME') ||
      upperContent.contains('HACK') ||
      upperContent.contains('LOGIC HERE') ||
      upperContent.contains('IMPLEMENTATION HERE') ||
      upperContent.contains('ADD LOGIC')
    ) {
      throw new ApexCodeValidator.ValidationException(
        '[' +
          fileName +
          '] Placeholder or TODO comments found. Code is incomplete and must not be deployed.'
      );
    }
  }
}
