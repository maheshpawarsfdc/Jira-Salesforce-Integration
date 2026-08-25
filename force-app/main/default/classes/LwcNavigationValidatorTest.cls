@IsTest
private class LwcNavigationValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateNavigationMixinExtendsClause
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void navigateCallWithMixinExtendedPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { NavigationMixin } from \'lightning/navigation\';\n' +
      'export default class Foo extends NavigationMixin(LightningElement) {\n' +
      '  handleClick() {\n' +
      '    this[NavigationMixin.Navigate]({\n' +
      '      type: \'standard__recordPage\',\n' +
      '      attributes: { recordId: this.recordId, actionName: \'view\' }\n' +
      '    });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Navigate call on a NavigationMixin-extended class must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void navigateCallWithoutMixinExtendedThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleClick() {\n' +
      '    this[NavigationMixin.Navigate]({ type: \'standard__recordPage\' });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('NavigationMixin(LightningElement)'),
        'Error should point at the required extends clause: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'Navigate call without extending NavigationMixin must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateNavigationMixinImported
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void navigationMixinExtendedAndImportedPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { NavigationMixin } from \'lightning/navigation\';\n' +
      'export default class Foo extends NavigationMixin(LightningElement) {}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'NavigationMixin extended and imported must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void navigationMixinExtendedWithoutImportThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'export default class Foo extends NavigationMixin(LightningElement) {}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('lightning/navigation'),
        'Error should point at the missing import: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'NavigationMixin extended without an import must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateWriteActionHasToastFeedback
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void ldsWriteWithToastFeedbackPasses() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { ShowToastEvent } from \'lightning/platformShowToastEvent\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  handleSave() {\n' +
      '    updateRecord({ fields: { Id: this.recordId } })\n' +
      '      .then(() => {\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Success\', variant: \'success\' }));\n' +
      '      })\n' +
      '      .catch((err) => {\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Error\', variant: \'error\' }));\n' +
      '      });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'LDS write with toast feedback must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void ldsWriteWithoutToastFeedbackThrows() {
    String js =
      'import { LightningElement } from \'lwc\';\n' +
      'import { updateRecord } from \'lightning/uiRecordApi\';\n' +
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
        e.getMessage().contains('ShowToastEvent'),
        'Error should point at the missing ShowToastEvent: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'A write action without toast feedback must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateSpinnerResetOnError
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void spinnerResetInFinallyPasses() {
    String js =
      'import { LightningElement, track } from \'lwc\';\n' +
      'import { ShowToastEvent } from \'lightning/platformShowToastEvent\';\n' +
      'import updateInvoiceStatus from \'@salesforce/apex/InvoiceController.updateInvoiceStatus\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @track isLoading = false;\n' +
      '  handleClick() {\n' +
      '    this.isLoading = true;\n' +
      '    updateInvoiceStatus({ id: this.recordId })\n' +
      '      .then(() => {\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Success\', variant: \'success\' }));\n' +
      '      })\n' +
      '      .catch((err) => {\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Error\', variant: \'error\' }));\n' +
      '      })\n' +
      '      .finally(() => {\n' +
      '        this.isLoading = false;\n' +
      '      });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'isLoading reset inside .finally() must not throw (this is the ' +
          'project\'s own recommended pattern): ' +
          e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void spinnerNeverResetOnErrorThrows() {
    String js =
      'import { LightningElement, track } from \'lwc\';\n' +
      'import { ShowToastEvent } from \'lightning/platformShowToastEvent\';\n' +
      'import updateInvoiceStatus from \'@salesforce/apex/InvoiceController.updateInvoiceStatus\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @track isLoading = false;\n' +
      '  handleClick() {\n' +
      '    this.isLoading = true;\n' +
      '    updateInvoiceStatus({ id: this.recordId })\n' +
      '      .then(() => {\n' +
      '        this.isLoading = false;\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Success\', variant: \'success\' }));\n' +
      '      })\n' +
      '      .catch((err) => {\n' +
      '        this.dispatchEvent(new ShowToastEvent({ title: \'Error\', variant: \'error\' }));\n' +
      '      });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('isLoading'),
        'Error should mention isLoading: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'isLoading reset only on the success path (never in catch/finally) ' +
      'must throw'
    );
  }
}
