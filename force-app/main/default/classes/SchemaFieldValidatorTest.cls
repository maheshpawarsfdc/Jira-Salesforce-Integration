@isTest
private class SchemaFieldValidatorTest {
  // Every field/object CRUD check in the pipeline (validation rules, LWC
  // schema-import checks, SOQL field-existence checks, etc.) ultimately
  // depends on this class answering "does it exist" and "what type is it"
  // correctly — including for fields being created in the SAME generation
  // response, which don't exist in live schema yet. No dedicated test
  // class existed for it before this one.
  //
  // Live-schema assertions below use standard objects/fields (Account,
  // Contact) rather than this app's own custom objects, so this test does
  // not depend on org-specific data having been deployed first.

  @isTest
  static void objectExists_trueForRealObject_falseForBogus() {
    System.assert(
      SchemaFieldValidator.objectExists('Account'),
      'Account is a standard object and must resolve as existing'
    );
    System.assert(
      !SchemaFieldValidator.objectExists('No_Such_Object__xyz'),
      'A made-up object API name must not resolve as existing'
    );
  }

  @isTest
  static void resolveObjectApiName_isCaseInsensitive() {
    System.assertEquals(
      'Account',
      SchemaFieldValidator.resolveObjectApiName('account'),
      'Lowercase input must resolve to the real, correctly-cased API name'
    );
    System.assertEquals(
      null,
      SchemaFieldValidator.resolveObjectApiName('No_Such_Object__xyz'),
      'A made-up object API name must resolve to null, not throw'
    );
  }

  @isTest
  static void getFieldType_returnsRealTypesForLiveFields() {
    System.assertEquals(
      'PICKLIST',
      SchemaFieldValidator.getFieldType('Account', 'Industry'),
      'Account.Industry is a standard picklist field'
    );
    System.assertEquals(
      'STRING',
      SchemaFieldValidator.getFieldType('Account', 'Name'),
      'Account.Name is a standard text field'
    );
    System.assertEquals(
      'DATETIME',
      SchemaFieldValidator.getFieldType('Account', 'CreatedDate'),
      'Account.CreatedDate is a standard datetime field'
    );
  }

  @isTest
  static void getFieldType_returnsNullForUnknownFieldOrObject() {
    System.assertEquals(
      null,
      SchemaFieldValidator.getFieldType('Account', 'No_Such_Field__xyz'),
      'An unknown field on a real object must return null, not throw'
    );
    System.assertEquals(
      null,
      SchemaFieldValidator.getFieldType('No_Such_Object__xyz', 'Name'),
      'A field lookup on an unknown object must return null, not throw'
    );
  }

  @isTest
  static void fieldExists_matchesLiveSchema() {
    System.assert(
      SchemaFieldValidator.fieldExists('Account', 'Name'),
      'Account.Name must be reported as existing'
    );
    System.assert(
      SchemaFieldValidator.fieldExistsInSchema('Account', 'Name'),
      'Account.Name must be reported as existing in live schema'
    );
    System.assert(
      !SchemaFieldValidator.fieldExists('Account', 'No_Such_Field__xyz'),
      'A made-up field must not be reported as existing'
    );
  }

  @isTest
  static void isLayoutReadOnlyField_trueForIdType() {
    // Id-type fields (e.g. the object's own Id) must always be layout
    // read-only — this is what backstops layouts for newly-generated
    // fields from ever marking an Id-shaped field editable.
    System.assert(
      SchemaFieldValidator.isLayoutReadOnlyField('Account', 'Id'),
      'An Id-type field must be reported as layout-readonly'
    );
    System.assert(
      !SchemaFieldValidator.isLayoutReadOnlyField('Account', 'Name'),
      'An ordinary editable text field must not be reported as layout-readonly'
    );
  }

  @isTest
  static void getKnownFieldNames_includesRealFieldForErrorMessages() {
    String known = SchemaFieldValidator.getKnownFieldNames('Account');
    System.assert(
      known.contains('Name'),
      'getKnownFieldNames must list real fields so error messages are factual: ' +
      known
    );
  }

  // ── Pending fields — the mechanism that lets a ticket create a field
  // and reference it (e.g. in a validation rule) in the SAME response,
  // before it exists in live schema. Every picklist-misuse / type-mismatch
  // check in LLMXmlSanitizer depends on this working correctly. ──

  @isTest
  static void pendingField_isVisibleToTypeAndRequiredAndExistsChecks() {
    SchemaFieldValidator.reset();
    SchemaFieldValidator.registerPendingField(
      'New_Object__c',
      'Status__c',
      'PICKLIST',
      true,
      false
    );

    System.assertEquals(
      'PICKLIST',
      SchemaFieldValidator.getFieldType('New_Object__c', 'Status__c'),
      'A pending (not-yet-deployed) field must still resolve its declared type'
    );
    System.assert(
      SchemaFieldValidator.fieldExists('New_Object__c', 'Status__c'),
      'A pending field must be reported as existing'
    );
    System.assert(
      SchemaFieldValidator.isFieldRequired('New_Object__c', 'Status__c'),
      'A pending field\'s required flag must come from the generated XML, not live schema'
    );
  }

  @isTest
  static void pendingField_layoutReadOnlyFlagIsRespected() {
    SchemaFieldValidator.reset();
    SchemaFieldValidator.registerPendingField(
      'New_Object__c',
      'Total__c',
      'SUMMARY',
      false,
      true
    );

    System.assert(
      SchemaFieldValidator.isLayoutReadOnlyField('New_Object__c', 'Total__c'),
      'A pending roll-up/formula field must be reported as layout-readonly ' +
      'even though live schema can\'t see it yet'
    );
  }

  @isTest
  static void reset_clearsPendingFieldsBetweenAttempts() {
    SchemaFieldValidator.registerPendingField(
      'New_Object__c',
      'Temp__c',
      'TEXT',
      false
    );
    SchemaFieldValidator.reset();

    System.assertEquals(
      null,
      SchemaFieldValidator.getFieldType('New_Object__c', 'Temp__c'),
      'reset() must clear pending fields left over from a previous repair attempt'
    );
  }

  // ── registerPendingFieldsFromResponse — the pre-pass that scans a whole
  // generated response (embedded <fields> blocks on a CustomObject file,
  // and standalone CustomField files) and registers everything it declares
  // as pending, before any single file is validated. ──

  @isTest
  static void registerPendingFieldsFromResponse_parsesEmbeddedFieldsBlock() {
    SchemaFieldValidator.reset();
    String objectXml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">' +
      '<fields><fullName>Priority__c</fullName><type>Picklist</type>' +
      '<required>true</required></fields>' +
      '</CustomObject>';
    List<Object> files = new List<Object>{
      new Map<String, Object>{
        'metadataType' => 'CustomObject',
        'memberName' => 'Ticket__c',
        'xmlContent' => objectXml
      }
    };

    SchemaFieldValidator.registerPendingFieldsFromResponse(files);

    System.assertEquals(
      'PICKLIST',
      SchemaFieldValidator.getFieldType('Ticket__c', 'Priority__c'),
      'A field declared inside a CustomObject file\'s embedded <fields> ' +
      'block must be registered as pending'
    );
    System.assert(
      SchemaFieldValidator.isFieldRequired('Ticket__c', 'Priority__c'),
      'The pending field\'s required flag must come from the embedded XML'
    );
  }

  @isTest
  static void registerPendingFieldsFromResponse_parsesStandaloneCustomFieldFile() {
    SchemaFieldValidator.reset();
    String fieldXml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">' +
      '<fullName>Due_Date__c</fullName><type>Date</type>' +
      '</CustomField>';
    List<Object> files = new List<Object>{
      new Map<String, Object>{
        'metadataType' => 'CustomField',
        'memberName' => 'Ticket__c.Due_Date__c',
        'xmlContent' => fieldXml
      }
    };

    SchemaFieldValidator.registerPendingFieldsFromResponse(files);

    System.assertEquals(
      'DATE',
      SchemaFieldValidator.getFieldType('Ticket__c', 'Due_Date__c'),
      'A standalone decomposed CustomField file must be registered as pending'
    );
  }

  @isTest
  static void registerPendingFieldsFromResponse_ignoresBlankOrNullSafely() {
    // Must not throw on an empty/null response — every caller runs this as
    // an unconditional pre-pass before per-file validation.
    SchemaFieldValidator.registerPendingFieldsFromResponse(null);
    SchemaFieldValidator.registerPendingFieldsFromResponse(new List<Object>());
    System.assert(true, 'Must not throw for null or empty file lists');
  }
}
