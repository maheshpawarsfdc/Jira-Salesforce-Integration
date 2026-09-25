@IsTest
private class LwcDatatableValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateDatatableHasKeyField
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void datatableWithKeyFieldPasses() {
    String html =
      '<template>\n' +
      '  <lightning-datatable\n' +
      '      key-field="Id"\n' +
      '      data={records}\n' +
      '      columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'lightning-datatable with key-field must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void datatableMissingKeyFieldThrows() {
    String html =
      '<template>\n' +
      '  <lightning-datatable\n' +
      '      data={records}\n' +
      '      columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('key-field'),
        'Error should mention the missing key-field: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'lightning-datatable with no key-field attribute must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateDatatableDraftValuesReset
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void draftValuesResetInFinallyPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'import { ShowToastEvent } from \'lightning/platformShowToastEvent\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  draftValues = [];\n' +
      '  async handleSave(event) {\n' +
      '    try {\n' +
      '      const updates = event.detail.draftValues.map((draft) =>\n' +
      '        updateRecord({ fields: draft })\n' +
      '      );\n' +
      '      await Promise.all(updates);\n' +
      '      this.dispatchEvent(new ShowToastEvent({ title: \'Success\', variant: \'success\' }));\n' +
      '    } catch (error) {\n' +
      '      this.dispatchEvent(new ShowToastEvent({ title: \'Error\', variant: \'error\' }));\n' +
      '    } finally {\n' +
      '      this.draftValues = [];\n' +
      '    }\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'draftValues reset to [] must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void draftValuesNeverResetThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'import { ShowToastEvent } from \'lightning/platformShowToastEvent\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  draftValues = [];\n' +
      '  async handleSave(event) {\n' +
      '    const updates = event.detail.draftValues.map((draft) =>\n' +
      '      updateRecord({ fields: draft })\n' +
      '    );\n' +
      '    await Promise.all(updates);\n' +
      '    this.dispatchEvent(new ShowToastEvent({ title: \'Success\', variant: \'success\' }));\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('draftValues'),
        'Error should mention draftValues: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'A file using draftValues that never resets it to [] must throw'
    );
  }

  @IsTest
  static void fileWithoutDraftValuesIsUnaffected() {
    // No inline-edit at all in this file — the rule must not fire.
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  records = [];\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A file never using draftValues must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // validateDatatableRowActionsHaveHandler (cross-file)
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void actionColumnWithOnRowActionHandlerPasses() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable\n' +
      '      key-field="Id"\n' +
      '      data={records}\n' +
      '      columns={columns}\n' +
      '      onrowaction={handleRowAction}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [\n' +
      '    { label: \'Name\', fieldName: \'Name\', type: \'text\' },\n' +
      '    { type: \'action\', typeAttributes: { rowActions: [\n' +
      '      { label: \'Delete\', name: \'delete\' }\n' +
      '    ] } }\n' +
      '  ];\n' +
      '  handleRowAction(event) {\n' +
      '    const actionName = event.detail.action.name;\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableRowActionsHaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'An action column paired with onrowaction must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void actionColumnWithoutOnRowActionHandlerThrows() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable\n' +
      '      key-field="Id"\n' +
      '      data={records}\n' +
      '      columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [\n' +
      '    { label: \'Name\', fieldName: \'Name\', type: \'text\' },\n' +
      '    { type: \'action\', typeAttributes: { rowActions: [\n' +
      '      { label: \'Delete\', name: \'delete\' }\n' +
      '    ] } }\n' +
      '  ];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableRowActionsHaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('onrowaction'),
        'Error should mention onrowaction: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'An action column with no onrowaction handler on the paired HTML must throw'
    );
  }

  @IsTest
  static void noActionColumnIsUnaffected() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable key-field="Id" data={records} columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [ { label: \'Name\', fieldName: \'Name\', type: \'text\' } ];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableRowActionsHaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A bundle with no action column must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // validateDatatableEditableColumnsHaveSaveHandler (cross-file)
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void editableColumnWithOnSaveHandlerPasses() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable\n' +
      '      key-field="Id"\n' +
      '      data={records}\n' +
      '      columns={columns}\n' +
      '      draft-values={draftValues}\n' +
      '      onsave={handleSave}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  draftValues = [];\n' +
      '  columns = [\n' +
      '    { label: \'Name\', fieldName: \'Name\', type: \'text\', editable: true }\n' +
      '  ];\n' +
      '  handleSave(event) {\n' +
      '    this.draftValues = [];\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableEditableColumnsHaveSaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'An editable column paired with onsave must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void editableColumnWithoutOnSaveHandlerThrows() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable\n' +
      '      key-field="Id"\n' +
      '      data={records}\n' +
      '      columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [\n' +
      '    { label: \'Name\', fieldName: \'Name\', type: \'text\', editable: true }\n' +
      '  ];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableEditableColumnsHaveSaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('onsave'),
        'Error should mention onsave: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'An editable column with no onsave handler on the paired HTML must throw'
    );
  }

  @IsTest
  static void noEditableColumnIsUnaffected() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-datatable key-field="Id" data={records} columns={columns}>\n' +
      '  </lightning-datatable>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [ { label: \'Name\', fieldName: \'Name\', type: \'text\' } ];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableEditableColumnsHaveSaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A bundle with no editable column must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void jsOnlyResponseWithoutHtmlIsSkipped() {
    // Only the .js is in this generation batch — can't verify cross-file,
    // must not throw.
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/contactList/contactList.js',
      'xmlContent' => 'import { LightningElement } from \'lwc\';\n' +
      'export default class ContactList extends LightningElement {\n' +
      '  columns = [\n' +
      '    { type: \'action\', typeAttributes: { rowActions: [] } }\n' +
      '  ];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateDatatableRowActionsHaveHandler(files);
      LwcCodeValidator.validateDatatableEditableColumnsHaveSaveHandler(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A response missing the paired HTML must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }
}
