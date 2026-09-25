@isTest
private class LLMXmlSanitizerValidationRuleTest {
  // ISBLANK() called directly on a picklist field must be rejected — this
  // is the exact shape that broke DQ-03/DQ-04/DQ-09 real deploys
  // ("Field X is a picklist field. Picklist fields are only supported in
  // certain functions.").
  @isTest
  static void isblankOnPicklistFieldThrows() {
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Opportunity_Source__c',
      'PICKLIST',
      false
    );
    String xml =
      '<validationRules>' +
      '<errorConditionFormula>ISBLANK(Opportunity_Source__c)</errorConditionFormula>' +
      '</validationRules>';

    Boolean threw = false;
    try {
      LLMXmlSanitizer.validateValidationRuleFieldTypes('Opportunity', xml);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Opportunity_Source__c'),
        'Expected message to name the offending field: ' + e.getMessage()
      );
      System.assert(
        e.getMessage().contains('TEXT('),
        'Expected message to suggest the TEXT() wrap fix: ' + e.getMessage()
      );
    }
    System.assert(threw, 'Expected ISBLANK() on a picklist field to throw');
  }

  // Same defect, ISNULL() flavor, and on a multi-select picklist.
  @isTest
  static void isnullOnMultiSelectPicklistThrows() {
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Regions__c',
      'MULTIPICKLIST',
      false
    );
    String xml =
      '<validationRules>' +
      '<errorConditionFormula>ISNULL(Regions__c)</errorConditionFormula>' +
      '</validationRules>';

    Boolean threw = false;
    try {
      LLMXmlSanitizer.validateValidationRuleFieldTypes('Opportunity', xml);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('multi-select'),
        'Expected message to call out multi-select: ' + e.getMessage()
      );
    }
    System.assert(
      threw,
      'Expected ISNULL() on a multi-select picklist to throw'
    );
  }

  // Direct = comparison against a picklist field must be rejected in favor
  // of ISPICKVAL().
  @isTest
  static void directComparisonOnPicklistFieldThrows() {
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Win_Reason__c',
      'PICKLIST',
      false
    );
    String xml =
      '<validationRules>' +
      '<errorConditionFormula>Win_Reason__c = "Price"</errorConditionFormula>' +
      '</validationRules>';

    Boolean threw = false;
    try {
      LLMXmlSanitizer.validateValidationRuleFieldTypes('Opportunity', xml);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('ISPICKVAL'),
        'Expected message to suggest ISPICKVAL(): ' + e.getMessage()
      );
    }
    System.assert(threw, 'Expected direct = comparison on a picklist to throw');
  }

  // Correctly-wrapped formulas must NOT be flagged — TEXT()-wrapped
  // ISBLANK() and ISPICKVAL() are exactly the fix we're steering toward,
  // so they must pass clean or the validator would fight its own advice.
  @isTest
  static void correctlyWrappedFormulaDoesNotThrow() {
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Opportunity_Source__c',
      'PICKLIST',
      false
    );
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Win_Reason__c',
      'PICKLIST',
      false
    );
    String xml =
      '<validationRules>' +
      '<errorConditionFormula>' +
      'OR(ISBLANK(TEXT(Opportunity_Source__c)), ISPICKVAL(Win_Reason__c, "Price"))' +
      '</errorConditionFormula>' +
      '</validationRules>';

    Boolean threw = false;
    try {
      LLMXmlSanitizer.validateValidationRuleFieldTypes('Opportunity', xml);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
    }
    System.assert(
      !threw,
      'Correctly-wrapped TEXT()/ISPICKVAL() usage must not be flagged'
    );
  }

  // ISBLANK() on a non-picklist field (e.g. a plain text/date field) is
  // legitimate and must keep passing.
  @isTest
  static void isblankOnNonPicklistFieldDoesNotThrow() {
    SchemaFieldValidator.registerPendingField(
      'Opportunity',
      'Next_Action_Date__c',
      'DATE',
      false
    );
    String xml =
      '<validationRules>' +
      '<errorConditionFormula>ISBLANK(Next_Action_Date__c)</errorConditionFormula>' +
      '</validationRules>';

    Boolean threw = false;
    try {
      LLMXmlSanitizer.validateValidationRuleFieldTypes('Opportunity', xml);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
    }
    System.assert(
      !threw,
      'ISBLANK() on a non-picklist field must not be flagged'
    );
  }
}
