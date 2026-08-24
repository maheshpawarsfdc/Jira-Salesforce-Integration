@IsTest
private class LwcCodeValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateCustomEventNameLowercase
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void lowercaseCustomEventNamePasses() {
    String js =
      'export default class Foo {\n' +
      '  handleClick() {\n' +
      '    this.dispatchEvent(new CustomEvent("contactselect", { detail: {} }));\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Lowercase event name must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void mixedCaseCustomEventNameThrows() {
    String js =
      'export default class Foo {\n' +
      '  handleClick() {\n' +
      '    this.dispatchEvent(new CustomEvent("contactSelect", { detail: {} }));\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('contactSelect'),
        'Error should name the offending event: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'Mixed-case event name must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateLmsSubscribeHasUnsubscribe
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void subscribeWithUnsubscribePasses() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import { subscribe, unsubscribe, MessageContext } from "lightning/messageService";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  subscription;\n' +
      '  @wire(MessageContext) messageContext;\n' +
      '  connectedCallback() {\n' +
      '    this.subscription = subscribe(this.messageContext, CHANNEL, (m) => {});\n' +
      '  }\n' +
      '  disconnectedCallback() {\n' +
      '    unsubscribe(this.subscription);\n' +
      '    this.subscription = null;\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'subscribe+unsubscribe pair must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void subscribeWithoutUnsubscribeThrows() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import { subscribe, MessageContext } from "lightning/messageService";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(MessageContext) messageContext;\n' +
      '  connectedCallback() {\n' +
      '    subscribe(this.messageContext, CHANNEL, (m) => {});\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('unsubscribe'),
        'Error should mention unsubscribe: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'subscribe without unsubscribe must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateLmsMessageContextWired
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void publishWithWiredMessageContextPasses() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import { publish, MessageContext } from "lightning/messageService";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(MessageContext) messageContext;\n' +
      '  handleClick() {\n' +
      '    publish(this.messageContext, CHANNEL, { recordId: this.recordId });\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'publish with wired MessageContext must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void publishWithoutWiredMessageContextThrows() {
    String js =
      'import { publish } from "lightning/messageService";\n' +
      'export default class Foo {\n' +
      '  handleClick() {\n' +
      '    publish(this.messageContext, CHANNEL, { recordId: this.recordId });\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('MessageContext'),
        'Error should mention MessageContext: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'publish without wired MessageContext must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateRefreshApexImported
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void refreshApexImportedPasses() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import { refreshApex } from "@salesforce/apex";\n' +
      'import getInvoices from "@salesforce/apex/InvoiceController.getInvoices";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(getInvoices) wiredInvoices;\n' +
      '  handleRefresh() {\n' +
      '    refreshApex(this.wiredInvoices);\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'refreshApex imported correctly must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void refreshApexNotImportedThrows() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import getInvoices from "@salesforce/apex/InvoiceController.getInvoices";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(getInvoices) wiredInvoices;\n' +
      '  handleRefresh() {\n' +
      '    refreshApex(this.wiredInvoices);\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('refreshApex'),
        'Error should mention refreshApex: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'refreshApex called without import must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateNoDirectWiredResultMutation
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void wiredResultNotMutatedPasses() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import getInvoices from "@salesforce/apex/InvoiceController.getInvoices";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(getInvoices) wiredInvoices;\n' +
      '  get invoices() {\n' +
      '    return this.wiredInvoices.data;\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(false, 'Reading .data must not throw: ' + e.getMessage());
    }
    Test.stopTest();
  }

  @IsTest
  static void wiredResultDirectlyMutatedThrows() {
    String js =
      'import { LightningElement, wire } from "lwc";\n' +
      'import getInvoices from "@salesforce/apex/InvoiceController.getInvoices";\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @wire(getInvoices) wiredInvoices;\n' +
      '  handleHack() {\n' +
      '    this.wiredInvoices.data = [];\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.js', js);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('refreshApex'),
        'Error should point at refreshApex as the fix: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'Direct mutation of a wired result must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateLightningBadgeVariant
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void lightningBadgeBaseVariantPasses() {
    String html =
      '<template>\n' +
      '  <lightning-badge label="Closed" variant="base"></lightning-badge>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'lightning-badge variant="base" must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void lightningBadgeInverseVariantPasses() {
    String html =
      '<template>\n' +
      '  <lightning-badge label="Closed" variant="inverse"></lightning-badge>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'lightning-badge variant="inverse" must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void lightningBadgeInvalidVariantThrows() {
    String html =
      '<template>\n' +
      '  <lightning-badge label="Closed" variant="success"></lightning-badge>\n' +
      '</template>';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('success') &&
        e.getMessage().contains('slds-badge'),
        'Error should name the invalid variant and point at the SLDS fix: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'lightning-badge with an unsupported variant must throw'
    );
  }
}
