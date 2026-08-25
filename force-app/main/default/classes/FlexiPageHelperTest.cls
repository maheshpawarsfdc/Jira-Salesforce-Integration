@IsTest
private class FlexiPageHelperTest {
  // ── Sample FlexiPage XML, shaped like a real retrieved page ──────────
  // Deliberately includes two traps:
  //  - a componentInstanceProperty literally NAMED "main" inside the header
  //    region, to prove the region-name scan doesn't false-match it
  //  - an empty region (no itemInstances at all), to exercise the
  //    insert-before-<mode> path
  private static String sampleXml() {
    return '<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
      '    <flexiPageRegions>\n' +
      '        <itemInstances>\n' +
      '            <componentInstance>\n' +
      '                <componentInstanceProperties>\n' +
      '                    <name>main</name>\n' +
      '                    <value>false</value>\n' +
      '                </componentInstanceProperties>\n' +
      '                <componentName>force:highlightsPanel</componentName>\n' +
      '                <identifier>force_highlightsPanel</identifier>\n' +
      '            </componentInstance>\n' +
      '        </itemInstances>\n' +
      '        <mode>Replace</mode>\n' +
      '        <name>header</name>\n' +
      '        <type>Region</type>\n' +
      '    </flexiPageRegions>\n' +
      '    <flexiPageRegions>\n' +
      '        <itemInstances>\n' +
      '            <componentInstance>\n' +
      '                <componentName>flexipage:tabset</componentName>\n' +
      '                <identifier>flexipage_tabset</identifier>\n' +
      '            </componentInstance>\n' +
      '        </itemInstances>\n' +
      '        <mode>Replace</mode>\n' +
      '        <name>main</name>\n' +
      '        <type>Region</type>\n' +
      '    </flexiPageRegions>\n' +
      '    <flexiPageRegions>\n' +
      '        <itemInstances>\n' +
      '            <componentInstance>\n' +
      '                <componentName>c:submitSurvey</componentName>\n' +
      '                <identifier>c_submitSurvey</identifier>\n' +
      '            </componentInstance>\n' +
      '        </itemInstances>\n' +
      '        <mode>Replace</mode>\n' +
      '        <name>sidebar</name>\n' +
      '        <type>Region</type>\n' +
      '    </flexiPageRegions>\n' +
      '    <flexiPageRegions>\n' +
      '        <mode>Append</mode>\n' +
      '        <name>emptyRegion</name>\n' +
      '        <type>Region</type>\n' +
      '    </flexiPageRegions>\n' +
      '    <masterLabel>Account Record Page</masterLabel>\n' +
      '    <sobjectType>Account</sobjectType>\n' +
      '    <type>RecordPage</type>\n' +
      '</FlexiPage>';
  }

  // ─────────────────────────────────────────────────────────────
  // requestsPagePlacement / normalizePageWording
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void requestsPlacement_recognizesAllTargetPhrasings() {
    List<String> shouldTrigger = new List<String>{
      'Add this component to the Account record page.',
      'This should be added on the Account record detail page.',
      'Add the component to the Account detail page.',
      'Place it on the Contact lightning page.',
      'Configure this in App Builder.'
    };
    for (String text : shouldTrigger) {
      System.assert(
        FlexiPageHelper.requestsPagePlacement(text),
        'Expected placement trigger for: ' + text
      );
    }
  }

  @IsTest
  static void requestsPlacement_ignoresUnrelatedText() {
    List<String> shouldNotTrigger = new List<String>{
      'Develop an LWC named accountSearchDashboard that searches Accounts.',
      'Show results in a lightning-datatable with record details.',
      ''
    };
    for (String text : shouldNotTrigger) {
      System.assert(
        !FlexiPageHelper.requestsPagePlacement(text),
        'Did not expect placement trigger for: ' + text
      );
    }
    System.assert(!FlexiPageHelper.requestsPagePlacement(null));
  }

  // ─────────────────────────────────────────────────────────────
  // extractTargetObject / resolveObjectApiName
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void extractTargetObject_resolvesStandardObjectAcrossPhrasings() {
    System.assertEquals(
      'Account',
      FlexiPageHelper.extractTargetObject(
        'Add this component to the Account record page.'
      )
    );
    System.assertEquals(
      'Account',
      FlexiPageHelper.extractTargetObject(
        'This should be added on the Account record detail page.'
      )
    );
    System.assertEquals(
      'Account',
      FlexiPageHelper.extractTargetObject(
        'Add the component to the Account detail page.'
      )
    );
    System.assertEquals(
      'Contact',
      FlexiPageHelper.extractTargetObject(
        'Add it to the record page for the Contact.'
      )
    );
  }

  @IsTest
  static void extractTargetObject_returnsNullWhenObjectDoesNotResolve() {
    System.assertEquals(
      null,
      FlexiPageHelper.extractTargetObject(
        'Add this to the Whatever record page.'
      )
    );
    System.assertEquals(null, FlexiPageHelper.extractTargetObject(''));
  }

  @IsTest
  static void resolveObjectApiName_bareAndCustomForms() {
    System.assertEquals(
      'Account',
      FlexiPageHelper.resolveObjectApiName('account')
    );
    System.assertEquals(
      'Account',
      FlexiPageHelper.resolveObjectApiName('Account')
    );
    System.assertEquals(
      null,
      FlexiPageHelper.resolveObjectApiName('notarealobject')
    );
    System.assertEquals(null, FlexiPageHelper.resolveObjectApiName(null));
  }

  // ─────────────────────────────────────────────────────────────
  // extractRegionName
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void extractRegionName_picksSidebarMainOrDefault() {
    System.assertEquals(
      'sidebar',
      FlexiPageHelper.extractRegionName('Add to the sidebar of the page.')
    );
    System.assertEquals(
      'main',
      FlexiPageHelper.extractRegionName(
        'Place it in the main region of the page.'
      )
    );
    System.assertEquals(
      'sidebar',
      FlexiPageHelper.extractRegionName('Add this component to the page.')
    );
    System.assertEquals('sidebar', FlexiPageHelper.extractRegionName(null));
  }

  // ─────────────────────────────────────────────────────────────
  // appendComponentToRegion — pure XML string manipulation, no callouts
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void append_insertsIntoRequestedRegionAndPreservesExisting() {
    String result = FlexiPageHelper.appendComponentToRegion(
      sampleXml(),
      'accountSearchDashboard',
      'sidebar',
      false
    );
    System.assertNotEquals(null, result);
    System.assert(
      result.contains('<componentName>c:accountSearchDashboard</componentName>')
    );
    System.assert(
      result.contains('<identifier>c_accountSearchDashboard</identifier>')
    );
    // Existing component in the same region must survive untouched.
    System.assert(
      result.contains('<componentName>c:submitSurvey</componentName>')
    );
  }

  @IsTest
  static void append_doesNotFalseMatchPropertyNamedMain() {
    // header region has a componentInstanceProperty literally named "main" —
    // requesting the "main" REGION must land in the main region, not header.
    String result = FlexiPageHelper.appendComponentToRegion(
      sampleXml(),
      'invoiceList',
      'main',
      false
    );
    Integer headerRegionStart = result.indexOf('<name>header</name>');
    // Search for the REGION's <name>main</name> starting AFTER
    // headerRegionStart — a bare result.indexOf('<name>main</name>') would
    // find the decoy componentInstanceProperties one instead (it appears
    // earlier in the raw string), defeating the whole point of this test.
    Integer mainRegionStart = result.indexOf(
      '<name>main</name>',
      headerRegionStart
    );
    Integer insertedAt = result.indexOf('c:invoiceList');
    System.assert(insertedAt > headerRegionStart);
    System.assert(insertedAt < mainRegionStart);
  }

  @IsTest
  static void append_isIdempotentWhenComponentAlreadyPresent() {
    String result = FlexiPageHelper.appendComponentToRegion(
      sampleXml(),
      'submitSurvey',
      'sidebar',
      false
    );
    System.assertEquals(null, result);
  }

  @IsTest
  static void append_fallsBackWhenRequestedRegionMissing() {
    String noSidebar = sampleXml()
      .replace('<name>sidebar</name>', '<name>somethingElse</name>');
    String result = FlexiPageHelper.appendComponentToRegion(
      noSidebar,
      'accountCard',
      'sidebar',
      false
    );
    System.assertNotEquals(null, result);
    Integer mainStart = result.indexOf('<name>main</name>');
    Integer nextRegionStart = result.indexOf(
      '<flexiPageRegions>',
      result.indexOf('</flexiPageRegions>', mainStart)
    );
    Integer insertedAt = result.indexOf('c:accountCard');
    System.assert(insertedAt > mainStart);
  }

  @IsTest
  static void append_returnsNullWhenNoRegionMatchesAtAll() {
    String stripped = sampleXml()
      .replace('<name>sidebar</name>', '<name>zoneA</name>')
      .replace('<name>main</name>', '<name>zoneB</name>');
    String result = FlexiPageHelper.appendComponentToRegion(
      stripped,
      'accountCard',
      'sidebar',
      false
    );
    System.assertEquals(null, result);
  }

  @IsTest
  static void append_insertsIntoEmptyRegionBeforeMode() {
    String result = FlexiPageHelper.appendComponentToRegion(
      sampleXml(),
      'emptyTest',
      'emptyRegion',
      false
    );
    System.assertNotEquals(null, result);
    Integer regionStart = result.indexOf('<name>emptyRegion</name>');
    Integer regionBlockStart = result.lastIndexOf(
      '<flexiPageRegions>',
      regionStart
    );
    Integer insertedAt = result.indexOf('c:emptyTest');
    System.assert(insertedAt > regionBlockStart);
    System.assert(insertedAt < regionStart);
  }

  @IsTest
  static void append_producesValidXsdSequenceOrder() {
    String result = FlexiPageHelper.appendComponentToRegion(
      sampleXml(),
      'accountCard',
      'sidebar',
      false
    );
    Integer sidebarNameIdx = result.indexOf('<name>sidebar</name>');
    Integer precedingRegionStart = result.lastIndexOf(
      '<flexiPageRegions>',
      sidebarNameIdx
    );
    String sidebarBlock = result.substring(
      precedingRegionStart,
      sidebarNameIdx
    );
    Integer lastItemClose = sidebarBlock.lastIndexOf('</itemInstances>');
    Integer modeIdx = sidebarBlock.indexOf('<mode>');
    // itemInstances must close BEFORE <mode> — XSD sequence order.
    System.assert(lastItemClose < modeIdx);
  }

  // ─────────────────────────────────────────────────────────────
  // buildUniqueIdentifier
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void buildUniqueIdentifier_suffixesOnCollision() {
    String xmlWithCollision = sampleXml()
      .replace(
        '<identifier>c_submitSurvey</identifier>',
        '<identifier>c_accountCard</identifier>'
      );
    String id = FlexiPageHelper.buildUniqueIdentifier(
      xmlWithCollision,
      'accountCard'
    );
    System.assertEquals('c_accountCard_2', id);
  }

  @IsTest
  static void buildUniqueIdentifier_noCollisionReturnsBaseForm() {
    String id = FlexiPageHelper.buildUniqueIdentifier(
      sampleXml(),
      'accountCard'
    );
    System.assertEquals('c_accountCard', id);
  }

  // ─────────────────────────────────────────────────────────────
  // backstopLwcPagePlacement — entry point, no-op paths only
  // (paths that reach a callout — findRecordPageForObject / retrieve /
  // Jira report — are exercised separately in the live dry run, not here)
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void backstop_noOpWhenNoComponentsPassed() {
    Test.startTest();
    FlexiPageHelper.backstopLwcPagePlacement(
      'TEST-1',
      'Add this to the Account record page.',
      '',
      new List<String>()
    );
    Test.stopTest();
    // No exception, no callout attempted — nothing to assert beyond "didn't throw".
    System.assert(true);
  }

  @IsTest
  static void backstop_noOpWhenTicketDoesNotRequestPlacement() {
    Test.startTest();
    FlexiPageHelper.backstopLwcPagePlacement(
      'TEST-2',
      'Develop an LWC named accountSearchDashboard.',
      'No page placement mentioned.',
      new List<String>{ 'accountSearchDashboard' }
    );
    Test.stopTest();
    System.assert(true);
  }
}
