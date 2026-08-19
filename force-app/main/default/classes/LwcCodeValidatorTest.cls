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
}
