@IsTest
private class LwcTemplateBindingValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateTemplateBindingsDeclaredInJs
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void undeclaredGatingPropertyThrows() {
    // Reproduces the real 2026-08-25 opportunityStageInlineEdit
    // incident: HTML gates its entire body on {record}, but the JS
    // never declares `record` anywhere — only currentStage/selectedStage.
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/opportunityStageInlineEdit/opportunityStageInlineEdit.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-card title="Opportunity Stage">\n' +
      '    <template if:true={record}>\n' +
      '      <lightning-input value={currentStage}></lightning-input>\n' +
      '    </template>\n' +
      '  </lightning-card>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/opportunityStageInlineEdit/opportunityStageInlineEdit.js',
      'xmlContent' => 'import { LightningElement, api, track } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @track currentStage;\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('record'),
        'Error should name the undeclared property: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'A template binding to a property the JS never declares must throw'
    );
  }

  @IsTest
  static void allBindingsDeclaredPasses() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/opportunityStageInlineEdit/opportunityStageInlineEdit.html',
      'xmlContent' => '<template>\n' +
      '  <lightning-card title="Opportunity Stage">\n' +
      '    <template if:true={currentStage}>\n' +
      '      <lightning-input value={currentStage}></lightning-input>\n' +
      '      <lightning-button label="Save" onclick={handleSave}></lightning-button>\n' +
      '    </template>\n' +
      '  </lightning-card>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/opportunityStageInlineEdit/opportunityStageInlineEdit.js',
      'xmlContent' => 'import { LightningElement, api, track } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api recordId;\n' +
      '  @track currentStage;\n' +
      '  handleSave() {\n' +
      '    this.currentStage = \'Closed Won\';\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Every binding matching a declared field/method must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void forEachLoopVariableIsNotFlagged() {
    // "item" is a template-local loop variable introduced by for:item —
    // it must never be treated as something the JS needs to declare.
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/dealList/dealList.html',
      'xmlContent' => '<template>\n' +
      '  <template for:each={deals} for:item="item">\n' +
      '    <div key={item.id}>{item.name}</div>\n' +
      '  </template>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/dealList/dealList.js',
      'xmlContent' => 'import { LightningElement, track } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @track deals = [];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A for:item loop variable must not be flagged as undeclared: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void iteratorVariableIsNotFlagged() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/dealList/dealList.html',
      'xmlContent' => '<template>\n' +
      '  <template iterator:it={deals}>\n' +
      '    <div key={it.value.id}>{it.value.name} - {it.index}</div>\n' +
      '  </template>\n' +
      '</template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/dealList/dealList.js',
      'xmlContent' => 'import { LightningElement, track } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @track deals = [];\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'An iterator: variable must not be flagged as undeclared: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void onlyHtmlPresentIsSkipped() {
    // The .js is not part of this generation response — can't verify,
    // must not throw.
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/someBundle/someBundle.html',
      'xmlContent' => '<template><div if:true={whoKnows}></div></template>'
    };
    List<Object> files = new List<Object>{ htmlFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A bundle with no paired .js in this response must be skipped, ' +
          'not throw: ' +
          e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void getterBackedBindingPasses() {
    Map<String, Object> htmlFile = new Map<String, Object>{
      'filePath' => 'lwc/badgeCard/badgeCard.html',
      'xmlContent' => '<template><p>{formattedLabel}</p></template>'
    };
    Map<String, Object> jsFile = new Map<String, Object>{
      'filePath' => 'lwc/badgeCard/badgeCard.js',
      'xmlContent' => 'import { LightningElement, api } from \'lwc\';\n' +
      'export default class Foo extends LightningElement {\n' +
      '  @api label;\n' +
      '  get formattedLabel() {\n' +
      '    return this.label ? this.label.toUpperCase() : \'\';\n' +
      '  }\n' +
      '}'
    };
    List<Object> files = new List<Object>{ htmlFile, jsFile };

    Test.startTest();
    try {
      LwcCodeValidator.validateTemplateBindingsDeclaredInJs(files);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A binding backed by a getter must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }
}
