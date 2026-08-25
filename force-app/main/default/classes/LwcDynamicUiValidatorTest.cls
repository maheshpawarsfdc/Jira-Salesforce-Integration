@IsTest
private class LwcDynamicUiValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateNoMixedConditionalAndIteratorOnSameTemplate
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void separateConditionalAndIteratorTemplatesPasses() {
    String html =
      '<template>\n' +
      '  <template lwc:if={showList}>\n' +
      '    <template for:each={items} for:item="item">\n' +
      '      <div key={item.Id}>{item.Name}</div>\n' +
      '    </template>\n' +
      '  </template>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Separate lwc:if / for:each templates must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void mixedConditionalAndIteratorOnSameTemplateThrows() {
    String html =
      '<template>\n' +
      '  <template lwc:if={showList} for:each={items} for:item="item">\n' +
      '    <div key={item.Id}>{item.Name}</div>\n' +
      '  </template>\n' +
      '</template>';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('combines a conditional directive'),
        'Error should explain the illegal combination: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(
      threw,
      'lwc:if + for:each on the same <template> tag must throw'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // validateForEachHasKeyAttribute
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void forEachWithKeyPasses() {
    String html =
      '<template>\n' +
      '  <template for:each={items} for:item="item">\n' +
      '    <div key={item.Id}>{item.Name}</div>\n' +
      '  </template>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'for:each with a key attribute must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void forEachWithoutKeyThrows() {
    String html =
      '<template>\n' +
      '  <template for:each={items} for:item="item">\n' +
      '    <div>{item.Name}</div>\n' +
      '  </template>\n' +
      '</template>';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('key={'),
        'Error should point at the missing key attribute: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'for:each without a key attribute must throw');
  }

  // ─────────────────────────────────────────────────────────────
  // validateLwcElseChainingOrder
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void lwcIfElseifElseChainPasses() {
    String html =
      '<template>\n' +
      '  <template lwc:if={isOpen}>\n' +
      '    <p>Open</p>\n' +
      '  </template>\n' +
      '  <template lwc:elseif={isPending}>\n' +
      '    <p>Pending</p>\n' +
      '  </template>\n' +
      '  <template lwc:else>\n' +
      '    <p>Closed</p>\n' +
      '  </template>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'A full lwc:if/lwc:elseif/lwc:else chain must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void lwcElseifWithoutPrecedingIfThrows() {
    String html =
      '<template>\n' +
      '  <template lwc:elseif={isPending}>\n' +
      '    <p>Pending</p>\n' +
      '  </template>\n' +
      '</template>';

    Boolean threw = false;
    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('lwc:elseif') &&
        e.getMessage().contains('lwc:if'),
        'Error should name the orphaned directive and the missing lwc:if: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'lwc:elseif without a preceding lwc:if must throw');
  }

  // Regression for a real 2026-08-24 false positive: a nested per-row
  // lwc:if/lwc:else INSIDE a for:each, which itself is inside an outer
  // lwc:elseif branch, must not corrupt tracking for the OUTER chain's
  // trailing lwc:else. The outer chain here (isLoading → hasData → else)
  // is completely valid and must not throw even though the nested chain's
  // last directive is 'else' at the point the outer lwc:else is reached.
  @IsTest
  static void nestedElseChainInsideOuterBranchDoesNotBreakOuterChain() {
    String html =
      '<template>\n' +
      '  <template lwc:if={isLoading}>\n' +
      '    <lightning-spinner></lightning-spinner>\n' +
      '  </template>\n' +
      '  <template lwc:elseif={hasData}>\n' +
      '    <table>\n' +
      '      <template for:each={rows} for:item="row">\n' +
      '        <tr key={row.Id}>\n' +
      '          <template lwc:if={row.isPriority}>\n' +
      '            <td>High</td>\n' +
      '          </template>\n' +
      '          <template lwc:else>\n' +
      '            <td>Normal</td>\n' +
      '          </template>\n' +
      '        </tr>\n' +
      '      </template>\n' +
      '    </table>\n' +
      '  </template>\n' +
      '  <template lwc:else>\n' +
      '    <p>No records found.</p>\n' +
      '  </template>\n' +
      '</template>';

    Test.startTest();
    try {
      LwcCodeValidator.validate('foo.html', html);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'An unrelated nested if/else chain inside a branch must not break ' +
          'the outer chain\'s own valid elseif/else sequencing: ' +
          e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // isSlotOnlyReusableComponent
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void slotWrappedInSingleElementIsDetectedAsShell() {
    String html =
      '<template>\n' +
      '    <lightning-card title={title} icon-name={iconName}>\n' +
      '        <slot></slot>\n' +
      '    </lightning-card>\n' +
      '</template>';

    System.assertEquals(
      true,
      LwcCodeValidator.isSlotOnlyReusableComponent(html),
      'A single wrapper around a bare <slot> must be detected as a shell'
    );
  }

  @IsTest
  static void bareSlotWithNoWrapperIsDetectedAsShell() {
    String html = '<template>\n' + '    <slot></slot>\n' + '</template>';

    System.assertEquals(
      true,
      LwcCodeValidator.isSlotOnlyReusableComponent(html),
      'A bare <slot> with no wrapper element must be detected as a shell'
    );
  }

  @IsTest
  static void slotAlongsideRealContentIsNotAShell() {
    String html =
      '<template>\n' +
      '    <div class="wrapper">\n' +
      '        <h2>{title}</h2>\n' +
      '        <slot></slot>\n' +
      '    </div>\n' +
      '</template>';

    System.assertEquals(
      false,
      LwcCodeValidator.isSlotOnlyReusableComponent(html),
      'A slot alongside other real markup must NOT be detected as a shell'
    );
  }

  @IsTest
  static void slotInsideALoopIsNotAShell() {
    String html =
      '<template>\n' +
      '    <template for:each={items} for:item="item">\n' +
      '        <div key={item.Id}><slot></slot></div>\n' +
      '    </template>\n' +
      '</template>';

    System.assertEquals(
      false,
      LwcCodeValidator.isSlotOnlyReusableComponent(html),
      'A component using for:each must NOT be detected as a shell, even ' +
      'with a slot inside'
    );
  }

  @IsTest
  static void componentWithNoSlotIsNotAShell() {
    String html =
      '<template>\n' +
      '    <lightning-card title={title}>\n' +
      '        <p>{message}</p>\n' +
      '    </lightning-card>\n' +
      '</template>';

    System.assertEquals(
      false,
      LwcCodeValidator.isSlotOnlyReusableComponent(html),
      'A component with no <slot> at all must NOT be detected as a shell'
    );
  }
}
