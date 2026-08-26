@IsTest
private class LwcLdsValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateLdsWriteFunctionsImported
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void ldsFunctionUsedAndImportedPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId } });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'updateRecord used and imported must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void ldsFunctionUsedWithoutImportThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId } });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('lightning/uiRecordApi'),
        'Error should point at the missing import: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'updateRecord used without an import from lightning/uiRecordApi must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateUpdateRecordHasIdField
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void updateRecordWithIdFieldPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId, Name: this.name } });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'updateRecord with Id in fields must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void updateRecordMissingIdFieldThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Name: this.name } });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Id'),
        'Error should mention the missing Id field: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'updateRecord with a literal fields object missing Id must throw'
    );
  }

  @IsTest
  static void updateRecordWithVariableArgumentIsSkipped() {
    // Not a literal object — can't be statically verified, so this must
    // never throw regardless of whether recordInput actually has Id.
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    const recordInput = this.buildInput();\n' +
      '    updateRecord(recordInput);\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'updateRecord called with a variable (not a literal) must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // validateCreateRecordHasApiName
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void createRecordWithApiNamePasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { createRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleCreate() {\n' +
      '    createRecord({ apiName: \'Contact\', fields: { LastName: this.lastName } });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'createRecord with apiName must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void createRecordMissingApiNameThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { createRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleCreate() {\n' +
      '    createRecord({ fields: { LastName: this.lastName } });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('apiName'),
        'Error should mention the missing apiName: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'createRecord with a literal record-input missing apiName must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateGetRecordWireHasFieldsOrLayoutTypes
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void getRecordWireWithFieldsPasses() {
    String js =
      'import { LightningElement, api, wire } from \'lwc\';\n' +
      'import { getRecord } from \'lightning/uiRecordApi\';\n' +
      'import NAME_FIELD from \'@salesforce/schema/Contact.Name\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @wire(getRecord, { recordId: \'$recordId\', fields: [NAME_FIELD] })\n' +
      '  contact;\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        '@wire(getRecord) with fields must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void getRecordWireWithLayoutTypesPasses() {
    String js =
      'import { LightningElement, api, wire } from \'lwc\';\n' +
      'import { getRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @wire(getRecord, { recordId: \'$recordId\', layoutTypes: [\'Full\'] })\n' +
      '  contact;\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        '@wire(getRecord) with layoutTypes must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void getRecordWireMissingFieldsAndLayoutTypesThrows() {
    String js =
      'import { LightningElement, api, wire } from \'lwc\';\n' +
      'import { getRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @wire(getRecord, { recordId: \'$recordId\' })\n' +
      '  contact;\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('layoutTypes'),
        'Error should mention fields/layoutTypes: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      '@wire(getRecord) missing fields, optionalFields, and layoutTypes must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateNoLayoutsAccessOnGetRecordWire
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void getRecordWireAccessingLayoutsThrows() {
    // Reproduces the real 2026-08-25 caseFullLayoutPanel incident:
    // getRecord + layoutTypes, then reading record.layouts — always
    // undefined, since getRecord never returns a layouts property.
    String js =
      'import { LightningElement, api, wire, track } from \'lwc\';\n' +
      'import { getRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @track layoutData;\n' +
      '  @wire(getRecord, { recordId: \'$recordId\', layoutTypes: [\'Full\'] })\n' +
      '  wiredRecord({ data, error }) {\n' +
      '    if (data) {\n' +
      '      const fullLayout = data.layouts.Full;\n' +
      '      this.layoutData = fullLayout;\n' +
      '    }\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('getRecordUi'),
        'Error should point at getRecordUi as the correct adapter: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      '.layouts accessed on a getRecord wire result (no getRecordUi in ' +
      'the file) must throw'
    );
  }

  @IsTest
  static void getRecordUiAccessingLayoutsPasses() {
    // The SAME .layouts access is legitimate off a getRecordUi result.
    String js =
      'import { LightningElement, api, wire } from \'lwc\';\n' +
      'import { getRecordUi } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @wire(getRecordUi, { recordIds: [\'$recordId\'], layoutTypes: [\'Full\'], modes: [\'View\'] })\n' +
      '  wiredRecordUi({ data, error }) {\n' +
      '    if (data) {\n' +
      '      const record = data.records[this.recordId];\n' +
      '      const sections = data.layouts[record.apiName].View.Full.sections;\n' +
      '    }\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        '.layouts accessed via getRecordUi must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void getRecordWireWithoutLayoutsAccessPasses() {
    String js =
      'import { LightningElement, api, wire } from \'lwc\';\n' +
      'import { getRecord, getFieldValue } from \'lightning/uiRecordApi\';\n' +
      'import NAME_FIELD from \'@salesforce/schema/Contact.Name\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @wire(getRecord, { recordId: \'$recordId\', fields: [NAME_FIELD] })\n' +
      '  contact;\n' +
      '  get name() {\n' +
      '    return getFieldValue(this.contact.data, NAME_FIELD);\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A plain getRecord wire with no .layouts access must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // validateNoRedundantLdsAndApexDml (cross-file, WARN-ONLY — never throws)
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void redundantLdsAndApexDmlNeverThrows() {
    Map<String, Object> apexFile = new Map<String, Object>{
      'metadataType' => 'ApexClass',
      'memberName' => 'ContactController',
      'filePath' => 'classes/ContactController.cls',
      'xmlContent' => 'public class ContactController {\n' +
      '  @AuraEnabled\n' +
      '  public static void saveContact(Contact c) {\n' +
      '    update c;\n' +
      '  }\n' +
      '}'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'metadataType' => 'LightningComponentBundle',
      'memberName' => 'contactEditor',
      'filePath' => 'lwc/contactEditor/contactEditor.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'import saveContact from \'@salesforce/apex/ContactController.saveContact\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId } });\n' +
      '    saveContact({ c: this.contact });\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ apexFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateNoRedundantLdsAndApexDml(files);
    } catch (Exception e) {
      System.assert(
        false,
        'The redundant-LDS-and-Apex-DML detector is warn-only and must ' +
          'never throw: ' +
          e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void nonRedundantFilesDoNotThrow() {
    Map<String, Object> jsFile = new Map<String, Object>{
      'metadataType' => 'LightningComponentBundle',
      'memberName' => 'contactEditor',
      'filePath' => 'lwc/contactEditor/contactEditor.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId } });\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateNoRedundantLdsAndApexDml(files);
    } catch (Exception e) {
      System.assert(
        false,
        'A component using only LDS (no Apex DML in the batch) must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }
}
