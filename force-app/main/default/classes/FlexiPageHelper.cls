/**
 * FlexiPageHelper — appends a generated LWC to an EXISTING Lightning page
 *
 * Scope is deliberately narrow: this helper only ever APPENDS one
 * componentInstance to a page that already exists in the org. It never
 * creates a FlexiPage and never touches page assignment (actionOverrides),
 * because activating a new page means rewriting object metadata.
 *
 * Covers all three page types the ticket text can name:
 *   - RecordPage — "the Account record page" — resolved by object (needs a
 *     recognizable object name in the ticket; multiple pages on the same
 *     object require the ticket to name which one).
 *   - AppPage    — "the Sales App page" — resolved by name/label match when
 *     more than one exists, otherwise the only one wins.
 *   - HomePage   — "the home page" / "the homepage" — same resolution as AppPage.
 * Defaults to RecordPage when the ticket says "record page" or is otherwise
 * non-specific — that has been this helper's only behavior until now, so
 * every ticket tested against it keeps working unchanged.
 *
 * HOW IT WORKS
 * 1. Ticket text is checked for an explicit placement request — nothing
 *    happens unless the ticket actually asks for it.
 * 2. Tooling API locates the target page (RecordPage/AppPage/HomePage) and
 *    resolves region/object — all fast, no Metadata API callout involved.
 * 3. port.retrieve() STARTS the real Metadata API retrieve job (one quick
 *    callout) and hands off waiting for it to a FlexiPagePlacementPoller —
 *    see below for why. This method returns immediately after that handoff;
 *    the LWC component itself deploys in ZIP1 as normal, without waiting on
 *    placement at all.
 * 4. FlexiPagePlacementPoller polls the retrieve to completion across real
 *    async hops (same enqueueJob-then-System.schedule-fallback pattern
 *    DeployPoller uses for deploy-status polling), modifies the retrieved
 *    XML in place so untouched regions/components survive verbatim, then
 *    deploys JUST the modified FlexiPage as its own follow-up ZIP via
 *    ZipDeployQueueable.forZip2 + the existing DeployPoller — reused
 *    unmodified — which posts its own follow-up Jira comment once that
 *    resolves.
 *
 * WHY ASYNC: retrieveFlexiPageXml() used to poll checkRetrieveStatus in a
 * tight synchronous loop with no real delay between attempts — Apex has no
 * synchronous sleep, so the only elapsed time was whatever the callouts
 * themselves took, nowhere near enough real wall-clock time for a large
 * page's retrieve job to finish (confirmed failing repeatedly against
 * Account_Record_Page — see flexipage-retrieve-timeout-followup memory).
 * Async polling gets genuine elapsed time across hops instead.
 *
 * Placement never fails the ticket: if the page can't be found, retrieved,
 * or parsed, the reason is logged and/or posted as a follow-up Jira comment,
 * and the component deploys without placement either way. A deployable
 * component that isn't on a page beats no component at all.
 */
public class FlexiPageHelper {
  public class FlexiPageException extends Exception {
  }

  private static final String DEFAULT_REGION = 'sidebar';
  private static final String FALLBACK_REGION = 'main';
  private static final String ITEM_CLOSE = '</itemInstances>';

  // ─────────────────────────────────────────────────────────────
  // PORT — same MetadataPort the rest of the system uses
  // ─────────────────────────────────────────────────────────────
  private static MetadataPort port {
    get {
      if (port == null) {
        System.debug('FlexiPageHelper: initializing MetadataPort...');
        port = new MetadataPort();
        port.endpoint_x =
          'https://' +
          DomainCreator.getOrgMyDomainHostname() +
          '/services/Soap/m/61.0';
        port.SessionHeader = new MetadataService.SessionHeader_element();
        port.SessionHeader.sessionId = UserInfo.getSessionId();
        System.debug('FlexiPageHelper: MetadataPort ready.');
      }
      return port;
    }
    set;
  }

  // Outcome of the most recent backstopLwcPagePlacement() call, in
  // plain language ready to append to the Jira status message — e.g.
  // "✅ Added to the sidebar of Account_Record_Page." or
  // "⚠️ Not added to a page: no Case Lightning Record Page exists yet."
  // Null when placement was never requested (nothing to say).
  // Read by LLMResponseProcessor right after the call; same transaction,
  // no async boundary to cross.
  public static String lastPlacementNote;

  // ─────────────────────────────────────────────────────────────
  // ENTRY POINT — called from LLMResponseProcessor backstop section
  //
  // Staged LWC component names in, modified FlexiPage in ZipBuilder out.
  // Every failure path is a no-op — never an exception — a component that
  // can't be placed still deploys; it just isn't on a page. The REASON is
  // always captured into lastPlacementNote so it reaches the Jira status
  // message instead of only a debug log.
  // ─────────────────────────────────────────────────────────────
  public static void backstopLwcPagePlacement(
    String issueKey,
    String ticketSummary,
    String ticketDescription,
    List<String> lwcComponentNames
  ) {
    lastPlacementNote = null;

    if (lwcComponentNames == null || lwcComponentNames.isEmpty()) {
      return;
    }

    String ticketText =
      (ticketSummary == null ? '' : ticketSummary) +
      ' ' +
      (ticketDescription == null ? '' : ticketDescription);

    if (!requestsPagePlacement(ticketText)) {
      System.debug(
        '[FLEXIPAGE] ticket does not request page placement — ' +
          'component(s) will deploy without being added to a page: ' +
          lwcComponentNames
      );
      // Not requested — nothing to say about placement at all.
      return;
    }

    String pageType = extractTargetPageType(ticketText);
    String objectApiName = null;

    if (pageType == 'RecordPage') {
      objectApiName = extractTargetObject(ticketText);
      if (String.isBlank(objectApiName)) {
        recordPlacementGap(
          issueKey,
          lwcComponentNames,
          'Could not tell which object\'s record page to use from the ' +
            'ticket text. Name the object explicitly, e.g. "add it to the ' +
            'Account record page".'
        );
        return;
      }
    }

    String regionName = extractRegionName(ticketText);
    System.debug(
      '[FLEXIPAGE] placement requested — type=[' +
        pageType +
        '] object=[' +
        objectApiName +
        '] region=[' +
        regionName +
        '] components=' +
        lwcComponentNames
    );

    String pageName;
    try {
      pageName = (pageType == 'RecordPage')
        ? findRecordPageForObject(objectApiName, ticketText)
        : findNonRecordPage(pageType, ticketText);
    } catch (Exception e) {
      System.debug('[FLEXIPAGE] page lookup failed: ' + e.getMessage());
      ErrorLogger.log(e);
      recordPlacementGap(
        issueKey,
        lwcComponentNames,
        'Looking up the ' +
          describeTarget(pageType, objectApiName) +
          ' failed: ' +
          e.getMessage()
      );
      return;
    }

    if (String.isBlank(pageName)) {
      System.debug(
        '[FLEXIPAGE] no existing ' +
          pageType +
          ' found for [' +
          describeTarget(pageType, objectApiName) +
          ']. This helper only appends to existing pages. Skipping placement.'
      );
      recordPlacementGap(
        issueKey,
        lwcComponentNames,
        'No existing ' +
          describeTarget(pageType, objectApiName) +
          ' — create/activate one via App Builder, then re-run this ticket.'
      );
      return;
    }

    // Any-region last resort only applies to AppPage/HomePage: their
    // templates don't follow the record-page sidebar/main convention this
    // helper's default region names are based on, so falling back to
    // WHATEVER region exists is more useful than giving up. RecordPage
    // keeps the stricter behavior — falling back to an arbitrary region
    // like "header" there tends to land a component somewhere strange
    // (e.g. next to the record's name/photo).
    Boolean allowAnyRegionFallback = pageType != 'RecordPage';

    // Fast pre-check — independent of the slow Metadata API retrieve below.
    // isComponentOnPageFresh() is a single lightweight Tooling API GET, not
    // the big SOAP retrieve/poll. If every requested component is already
    // on the page (a re-run of a ticket that already placed successfully,
    // or a retry after a previous timeout that actually did land), there is
    // nothing to do and no reason to kick off an async retrieve at all.
    List<String> stillNeeded = new List<String>();
    for (String componentName : lwcComponentNames) {
      if (String.isBlank(componentName)) {
        continue;
      }
      if (isComponentOnPageFresh(pageName, componentName)) {
        continue;
      }
      stillNeeded.add(componentName);
    }
    if (stillNeeded.isEmpty()) {
      lastPlacementNote =
        '✅ Already present on the ' +
        describeTarget(pageType, objectApiName) +
        ' (' +
        pageName +
        ').';
      return;
    }

    // ── ASYNC HANDOFF ────────────────────────────────────────────────
    // startFlexiPageRetrieve() only STARTS the retrieve job (one quick
    // callout) — waiting for it to finish is handed off to
    // FlexiPagePlacementPoller, which gets genuine async elapsed time
    // across hops instead of a tight synchronous poll loop. This method
    // returns right after handoff; the component itself still deploys in
    // ZIP1 as normal, without waiting on placement.
    String asyncId;
    try {
      asyncId = startFlexiPageRetrieve(pageName);
    } catch (Exception e) {
      System.debug(
        '[FLEXIPAGE] retrieve kickoff failed for [' +
          pageName +
          ']: ' +
          e.getMessage()
      );
      ErrorLogger.log(e);
      recordPlacementGap(
        issueKey,
        lwcComponentNames,
        'Starting the retrieve for the ' +
          pageName +
          ' page failed: ' +
          e.getMessage()
      );
      return;
    }

    FlexiPagePlacementPoller poller = new FlexiPagePlacementPoller();
    poller.asyncId = asyncId;
    poller.pageName = pageName;
    poller.pageType = pageType;
    poller.objectApiName = objectApiName;
    poller.regionName = regionName;
    poller.allowAnyRegionFallback = allowAnyRegionFallback;
    poller.lwcComponentNames = stillNeeded;
    poller.issueKey = issueKey;
    poller.attempt = 1;
    System.enqueueJob(poller);

    lastPlacementNote =
      '⏳ Placing on the ' +
      describeTarget(pageType, objectApiName) +
      ' (' +
      pageName +
      ') — will confirm in a follow-up comment shortly; large pages can ' +
      'take up to ~2 minutes.';
    System.debug(
      '[DEPLOY-TRACE] FlexiPage placement handed off async | issue=' +
        issueKey +
        ' | page=' +
        pageName +
        ' | asyncId=' +
        asyncId +
        ' | components=' +
        stillNeeded
    );
  }

  /**
   * Human-readable description of the placement target, for gap messages
   * and the success note. RecordPage needs the object name; AppPage/HomePage
   * don't have one.
   */
  public static String describeTarget(String pageType, String objectApiName) {
    if (pageType == 'RecordPage') {
      return objectApiName + ' record page';
    }
    if (pageType == 'AppPage') {
      return 'App Page';
    }
    return 'Home Page';
  }

  /**
   * Records a placement gap — the ticket asked for placement and it could
   * not happen. Sets lastPlacementNote (surfaces in the Jira status
   * message) and debug-logs the same reason for traceability.
   */
  private static void recordPlacementGap(
    String issueKey,
    List<String> lwcComponentNames,
    String reason
  ) {
    lastPlacementNote = '⚠️ Not added to a page: ' + reason;
    System.debug(
      '[FLEXIPAGE] GAP for issue [' +
        issueKey +
        '] — LWC ' +
        String.join(lwcComponentNames, ', ') +
        ' deployed, but was NOT added to a page as requested. ' +
        reason
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TICKET PARSING — does the ticket actually ask for placement?
  //
  // Placement is opt-in. An LWC ticket that never mentions a page must not
  // have an existing Lightning page rewritten underneath it as a side effect.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private static Boolean requestsPagePlacement(String ticketText) {
    if (String.isBlank(ticketText)) {
      return false;
    }
    String t = normalizePageWording(ticketText);
    return t.contains('record page') ||
      t.contains('lightning page') ||
      t.contains('app builder') ||
      t.contains('app page') ||
      t.contains('home page') ||
      t.contains('homepage');
  }

  /**
   * Which FlexiPage Type the ticket is asking for. "app page"/"home page"
   * are checked first since they're the more specific, less ambiguous asks;
   * everything else (including a bare "record page"/"lightning page"/
   * "app builder" mention) defaults to RecordPage — this helper's only
   * behavior before AppPage/HomePage support existed, so every previously
   * tested ticket wording keeps resolving exactly as it did before.
   */
  @TestVisible
  private static String extractTargetPageType(String ticketText) {
    if (String.isBlank(ticketText)) {
      return 'RecordPage';
    }
    String t = ticketText.toLowerCase();
    if (t.contains('home page') || t.contains('homepage')) {
      return 'HomePage';
    }
    if (t.contains('app page')) {
      return 'AppPage';
    }
    return 'RecordPage';
  }

  /**
   * Folds the phrasings people actually write onto the one form the parsers
   * look for. "Account record detail page" and "Account detail page" both mean
   * the Account record page; matching only the literal words "record page"
   * would silently skip placement on a ticket that plainly asked for it.
   */
  @TestVisible
  private static String normalizePageWording(String ticketText) {
    if (String.isBlank(ticketText)) {
      return '';
    }
    String t = ticketText.toLowerCase();
    t = t.replaceAll('record\\s+detail\\s+page', 'record page');
    t = t.replaceAll('detail\\s+page', 'record page');
    return t;
  }

  // ─────────────────────────────────────────────────────────────
  // TICKET PARSING — which object's record page?
  //
  // Only accepts a name that actually resolves against live schema, so a
  // loose word match can never send a retrieve after a nonexistent object.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private static String extractTargetObject(String ticketText) {
    if (String.isBlank(ticketText)) {
      return null;
    }

    // Parse against the normalized text so "Account record detail page" and
    // "Account detail page" resolve the same way "Account record page" does.
    String normalized = normalizePageWording(ticketText);

    List<String> candidates = new List<String>();

    // "... the Contact record page ..." / "... Invoice__c record page ..."
    Matcher m1 = Pattern.compile(
        '([a-z][a-z0-9_]*(?:__c)?)\\s+(?:lightning\\s+)?record page'
      )
      .matcher(normalized);
    while (m1.find()) {
      candidates.add(m1.group(1));
    }

    // "... record page for/of the Contact ..."
    Matcher m2 = Pattern.compile(
        'record page\\s+(?:for|of|on)\\s+(?:the\\s+)?([a-z][a-z0-9_]*(?:__c)?)'
      )
      .matcher(normalized);
    while (m2.find()) {
      candidates.add(m2.group(1));
    }

    for (String candidate : candidates) {
      String resolved = resolveObjectApiName(candidate);
      if (String.isNotBlank(resolved)) {
        System.debug(
          '[FLEXIPAGE] target object resolved: [' +
            candidate +
            '] → [' +
            resolved +
            ']'
        );
        return resolved;
      }
    }

    System.debug(
      '[FLEXIPAGE] no target object resolved from candidates: ' + candidates
    );
    return null;
  }

  /**
   * Resolves a ticket word to a real SObject API name, trying the bare name
   * then the __c custom-object form. Returns null when neither exists.
   */
  @TestVisible
  private static String resolveObjectApiName(String rawName) {
    if (String.isBlank(rawName)) {
      return null;
    }
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    String lower = rawName.toLowerCase();

    if (globalDescribe.containsKey(lower)) {
      return globalDescribe.get(lower).getDescribe().getName();
    }
    if (!lower.endsWith('__c') && globalDescribe.containsKey(lower + '__c')) {
      return globalDescribe.get(lower + '__c').getDescribe().getName();
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // TICKET PARSING — which region?
  //
  // Defaults to the sidebar: it is where a small custom component
  // conventionally goes, and on a tabbed record page the main region renders
  // BELOW the tab set, which can push the component far down the page.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private static String extractRegionName(String ticketText) {
    if (String.isBlank(ticketText)) {
      return DEFAULT_REGION;
    }
    String t = ticketText.toLowerCase();

    if (
      t.contains('sidebar') ||
      t.contains('side bar') ||
      t.contains('right column') ||
      t.contains('right side')
    ) {
      return 'sidebar';
    }
    if (
      t.contains('main region') ||
      t.contains('main column') ||
      t.contains('main area') ||
      t.contains('main body') ||
      t.contains('body region')
    ) {
      return 'main';
    }
    return DEFAULT_REGION;
  }

  // ─────────────────────────────────────────────────────────────
  // LOOKUP — find the existing RecordPage for an object
  //
  // EntityDefinitionId is filtered in Apex rather than SOQL: it is not
  // reliably filterable on the Tooling FlexiPage object.
  // ─────────────────────────────────────────────────────────────
  public static String findRecordPageForObject(
    String objectApiName,
    String ticketText
  ) {
    Map<String, Object> result = MetadataHelper.runToolingApiQuery(
      'SELECT Id, DeveloperName, MasterLabel, Type, EntityDefinitionId ' +
      'FROM FlexiPage WHERE Type = \'RecordPage\' LIMIT 200'
    );
    List<Object> records = (List<Object>) result.get('records');
    if (records == null || records.isEmpty()) {
      return null;
    }

    // Standard objects report EntityDefinitionId as the API name ('Contact'),
    // custom objects as a durable id ('01I...'). Accept either, resolving the
    // durable id only when the plain-name pass finds nothing.
    Set<String> acceptedEntityIds = new Set<String>{
      objectApiName.toLowerCase()
    };

    List<String> matches = new List<String>();
    List<String> matchLabels = new List<String>();
    for (Integer pass = 0; pass < 2; pass++) {
      for (Object raw : records) {
        Map<String, Object> rec = (Map<String, Object>) raw;
        String entity = (String) rec.get('EntityDefinitionId');
        if (
          String.isBlank(entity) ||
          !acceptedEntityIds.contains(entity.toLowerCase())
        ) {
          continue;
        }
        matches.add((String) rec.get('DeveloperName'));
        matchLabels.add((String) rec.get('MasterLabel'));
      }

      if (!matches.isEmpty() || pass == 1) {
        break;
      }

      String durableId = resolveEntityDurableId(objectApiName);
      if (String.isBlank(durableId)) {
        break;
      }
      acceptedEntityIds.add(durableId.toLowerCase());
      System.debug(
        '[FLEXIPAGE] no page matched [' +
          objectApiName +
          '] by name — retrying with durable id [' +
          durableId +
          ']'
      );
    }

    return pickPageFromCandidates(
      matches,
      matchLabels,
      ticketText,
      'RecordPage',
      objectApiName
    );
  }

  // ─────────────────────────────────────────────────────────────
  // LOOKUP — find the existing AppPage or HomePage
  //
  // No object concept applies to these types — every page of the requested
  // type is a candidate, disambiguated purely by whether the ticket names
  // one (same rule as the multi-record-page case).
  // ─────────────────────────────────────────────────────────────
  private static String findNonRecordPage(String pageType, String ticketText) {
    Map<String, Object> result = MetadataHelper.runToolingApiQuery(
      'SELECT Id, DeveloperName, MasterLabel, Type FROM FlexiPage WHERE Type = \'' +
        pageType +
        '\' LIMIT 200'
    );
    List<Object> records = (List<Object>) result.get('records');
    if (records == null || records.isEmpty()) {
      return null;
    }

    List<String> matches = new List<String>();
    List<String> matchLabels = new List<String>();
    for (Object raw : records) {
      Map<String, Object> rec = (Map<String, Object>) raw;
      matches.add((String) rec.get('DeveloperName'));
      matchLabels.add((String) rec.get('MasterLabel'));
    }

    return pickPageFromCandidates(
      matches,
      matchLabels,
      ticketText,
      pageType,
      null
    );
  }

  /**
   * Shared disambiguation: a single match wins outright; multiple matches
   * only resolve when the ticket names one of them by DeveloperName or
   * MasterLabel — otherwise picking would be a guess, so it's left
   * unresolved (reported as a gap) rather than guessed at.
   */
  private static String pickPageFromCandidates(
    List<String> devNames,
    List<String> labels,
    String ticketText,
    String pageType,
    String context
  ) {
    if (devNames.isEmpty()) {
      return null;
    }
    if (devNames.size() == 1) {
      System.debug('[FLEXIPAGE] matched ' + pageType + ' page: ' + devNames[0]);
      return devNames[0];
    }

    String lowerTicket = ticketText == null ? '' : ticketText.toLowerCase();
    for (Integer i = 0; i < devNames.size(); i++) {
      String devName = devNames[i];
      String label = labels[i];
      if (
        (String.isNotBlank(devName) &&
        lowerTicket.contains(devName.toLowerCase())) ||
        (String.isNotBlank(label) && lowerTicket.contains(label.toLowerCase()))
      ) {
        System.debug(
          '[FLEXIPAGE] ' +
            devNames.size() +
            ' ' +
            pageType +
            ' pages' +
            (context != null ? ' for [' + context + ']' : '') +
            ' — ticket names [' +
            devName +
            ']'
        );
        return devName;
      }
    }

    System.debug(
      '[FLEXIPAGE] AMBIGUOUS — ' +
        devNames.size() +
        ' ' +
        pageType +
        ' pages exist' +
        (context != null ? ' for [' + context + ']' : '') +
        ': ' +
        devNames +
        '. Ticket names none of them, so no page was modified. ' +
        'Name the page in the ticket to disambiguate.'
    );
    return null;
  }

  /**
   * Looks up EntityDefinition.DurableId for an object API name. Custom-object
   * FlexiPages reference their object by durable id rather than by name.
   * Returns null when the object cannot be resolved.
   */
  private static String resolveEntityDurableId(String objectApiName) {
    try {
      Map<String, Object> result = MetadataHelper.runToolingApiQuery(
        'SELECT DurableId, QualifiedApiName FROM EntityDefinition ' +
          'WHERE QualifiedApiName = \'' +
          String.escapeSingleQuotes(objectApiName) +
          '\' LIMIT 1'
      );
      List<Object> records = (List<Object>) result.get('records');
      if (records == null || records.isEmpty()) {
        return null;
      }
      return (String) ((Map<String, Object>) records[0]).get('DurableId');
    } catch (Exception e) {
      System.debug(
        '[FLEXIPAGE] durable id lookup failed for [' +
          objectApiName +
          ']: ' +
          e.getMessage()
      );
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // FETCH — an existing LWC bundle's full file content, via Tooling API
  // SOQL (LightningComponentBundle → LightningComponentResource), not a
  // Metadata API retrieve. Fast and synchronous — a bundle is a handful of
  // small files, nothing like the size/latency of a FlexiPage retrieve.
  //
  // WHY THIS EXISTS: deploying a FlexiPage that references a Lightning
  // component NOT included in that SAME deploy package can fail with
  // "We couldn't retrieve the design time component information for
  // component c:X" — confirmed as a real incident 2026-08-24, caseNoteList/
  // Case_Record_Page, right after FlexiPagePlacementPoller started
  // deploying the modified page as its own separate follow-up ZIP (see
  // that class). The component had already deployed successfully moments
  // earlier in ZIP1, in a separate transaction — Salesforce's deploy-time
  // design-info lookup for a referenced component doesn't reliably see it
  // unless the component is ALSO part of the deploy that touches the page
  // referencing it, even though nothing about the component actually
  // needs to change. FlexiPagePlacementPoller re-includes the bundle
  // (unmodified) in its placement ZIP using this method, purely to satisfy
  // that requirement.
  //
  // Returns Map<filePath, content> (FilePath from the resource IS already
  // the exact zip-relative path ZipBuilder.addFile expects, e.g.
  // "lwc/caseNoteList/caseNoteList.js") — empty map if the bundle isn't
  // found or has no resources; never throws.
  // ─────────────────────────────────────────────────────────────
  public static Map<String, String> fetchLwcBundleFiles(String componentName) {
    Map<String, String> files = new Map<String, String>();
    try {
      Map<String, Object> bundleResult = MetadataHelper.runToolingApiQuery(
        'SELECT Id FROM LightningComponentBundle WHERE DeveloperName = \'' +
          String.escapeSingleQuotes(componentName) +
          '\' AND NamespacePrefix = null LIMIT 1'
      );
      List<Object> bundleRecords = (List<Object>) bundleResult.get('records');
      if (bundleRecords == null || bundleRecords.isEmpty()) {
        System.debug(
          '[FLEXIPAGE] fetchLwcBundleFiles: no bundle found for [' +
            componentName +
            ']'
        );
        return files;
      }
      String bundleId = (String) ((Map<String, Object>) bundleRecords[0])
        .get('Id');

      Map<String, Object> resourceResult = MetadataHelper.runToolingApiQuery(
        'SELECT FilePath, Source FROM LightningComponentResource ' +
          'WHERE LightningComponentBundleId = \'' +
          bundleId +
          '\''
      );
      List<Object> resourceRecords = (List<Object>) resourceResult.get(
        'records'
      );
      if (resourceRecords != null) {
        for (Object raw : resourceRecords) {
          Map<String, Object> rec = (Map<String, Object>) raw;
          String filePath = (String) rec.get('FilePath');
          String source = (String) rec.get('Source');
          if (String.isNotBlank(filePath) && source != null) {
            files.put(filePath, source);
          }
        }
      }
      System.debug(
        '[FLEXIPAGE] fetchLwcBundleFiles: [' +
          componentName +
          '] → ' +
          files.size() +
          ' file(s)'
      );
    } catch (Exception e) {
      System.debug(
        '[FLEXIPAGE] fetchLwcBundleFiles failed for [' +
          componentName +
          ']: ' +
          e.getMessage()
      );
    }
    return files;
  }

  // ─────────────────────────────────────────────────────────────
  // FRESH EXISTENCE CHECK — Tooling API GET, independent of the SOAP
  // retrieve above. Read-only cross-check: never throws, never blocks
  // placement on its own failure — a failed/unavailable check just means
  // this safety net didn't fire, not that placement should stop.
  // ─────────────────────────────────────────────────────────────
  private static Boolean isComponentOnPageFresh(
    String pageName,
    String componentName
  ) {
    try {
      Map<String, Object> idResult = MetadataHelper.runToolingApiQuery(
        'SELECT Id FROM FlexiPage WHERE DeveloperName = \'' +
          String.escapeSingleQuotes(pageName) +
          '\' LIMIT 1'
      );
      List<Object> idRecords = (List<Object>) idResult.get('records');
      if (idRecords == null || idRecords.isEmpty()) {
        return false;
      }
      String pageId = (String) ((Map<String, Object>) idRecords[0]).get('Id');

      String endpoint =
        'https://' +
        DomainCreator.getOrgMyDomainHostname() +
        '/services/data/v61.0/tooling/sobjects/FlexiPage/' +
        pageId;
      HttpRequest req = new HttpRequest();
      req.setEndpoint(endpoint);
      req.setMethod('GET');
      req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
      req.setHeader('Content-Type', 'application/json');
      req.setTimeout(20000);

      HttpResponse res = new Http().send(req);
      if (res.getStatusCode() != 200) {
        System.debug(
          '[FLEXIPAGE] fresh existence check for [c:' +
            componentName +
            '] on [' +
            pageName +
            '] failed (' +
            res.getStatusCode() +
            ') — proceeding without it'
        );
        return false;
      }

      Boolean present = res.getBody()
        .contains('"componentName":"c:' + componentName + '"');
      System.debug(
        '[FLEXIPAGE] fresh existence check for [c:' +
          componentName +
          '] on [' +
          pageName +
          ']: ' +
          present
      );
      return present;
    } catch (Exception e) {
      System.debug(
        '[FLEXIPAGE] fresh existence check errored — proceeding without it: ' +
        e.getMessage()
      );
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RETRIEVE — start the async retrieve job (ASYNC-SAFE)
  //
  // One quick callout that only STARTS the Metadata API retrieve job and
  // returns its asyncId. Waiting for it to finish is FlexiPagePlacementPoller's
  // job (real async elapsed time across hops), not this method's — see the
  // class doc comment for why. Public so the poller can call it from a fresh
  // transaction after being enqueued.
  // ─────────────────────────────────────────────────────────────
  public static String startFlexiPageRetrieve(String developerName) {
    MetadataService.RetrieveRequest retrieveRequest = new MetadataService.RetrieveRequest();
    retrieveRequest.apiVersion = 61.0;
    retrieveRequest.singlePackage = true;

    MetadataService.PackageTypeMembers ptm = new MetadataService.PackageTypeMembers();
    ptm.name = 'FlexiPage';
    ptm.members = new List<String>{ developerName };

    MetadataService.Package_x pkg = new MetadataService.Package_x();
    pkg.types = new List<MetadataService.PackageTypeMembers>{ ptm };
    pkg.version = '61.0';
    retrieveRequest.unpackaged = pkg;

    MetadataService.AsyncResult asyncResult = port.retrieve(retrieveRequest);
    String asyncId = asyncResult.id;
    System.debug(
      '[FLEXIPAGE] retrieve started for [' +
        developerName +
        '], asyncId=' +
        asyncId
    );
    return asyncId;
  }

  // ─────────────────────────────────────────────────────────────
  // RETRIEVE — check status of an already-started retrieve (ASYNC-SAFE)
  //
  // Thin wrapper so FlexiPagePlacementPoller doesn't need direct access to
  // this class's private `port` property. One callout per call — the
  // poller decides how many times and how far apart to call this.
  // ─────────────────────────────────────────────────────────────
  public static MetadataService.RetrieveResult checkFlexiPageRetrieveStatus(
    String asyncId
  ) {
    return port.checkRetrieveStatus(asyncId, true);
  }

  // ─────────────────────────────────────────────────────────────
  // RETRIEVE — extract the page XML from a completed retrieve's ZIP
  // ─────────────────────────────────────────────────────────────
  public static String extractXmlFromRetrieveZip(
    String developerName,
    String zipBase64
  ) {
    if (String.isBlank(zipBase64)) {
      throw new FlexiPageException(
        'Retrieve for FlexiPage ' + developerName + ' returned no ZIP content.'
      );
    }

    Blob zipBlob = EncodingUtil.base64Decode(zipBase64);

    // SOAP retrieve returns old-style format: Contact_Record_Page.flexipage
    String xml = ZipBuilder.extractFileFromZip(
      zipBlob,
      'flexipages/' + developerName + '.flexipage'
    );

    // Fallback: DX-style suffix
    if (String.isBlank(xml)) {
      xml = ZipBuilder.extractFileFromZip(
        zipBlob,
        'flexipages/' + developerName + '.flexipage-meta.xml'
      );
    }

    if (String.isBlank(xml)) {
      throw new FlexiPageException(
        'Could not extract FlexiPage XML from retrieve ZIP for: ' +
          developerName +
          '. Check debug logs for ZIP contents.'
      );
    }

    System.debug(
      '[FLEXIPAGE] retrieved [' + developerName + '], length=' + xml.length()
    );
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // APPLY — run every requested component through appendComponentToRegion
  // against an already-retrieved page XML (ASYNC-SAFE)
  //
  // Called by FlexiPagePlacementPoller once its retrieve completes. Returns
  // a small result bag rather than a custom type to keep this callable
  // without exposing another public inner class:
  //   'modifiedXml'         → String, or null if nothing changed
  //   'appliedCount'        → Integer
  //   'alreadyPresentCount' → Integer
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> applyComponentsToXml(
    String pageXml,
    String pageName,
    String regionName,
    Boolean allowAnyRegionFallback,
    List<String> lwcComponentNames
  ) {
    String workingXml = pageXml;
    Integer appliedCount = 0;
    Integer alreadyPresentCount = 0;

    for (String componentName : lwcComponentNames) {
      if (String.isBlank(componentName)) {
        continue;
      }
      // Belt-and-suspenders re-check against the just-retrieved XML itself,
      // on top of whatever pre-filtering the caller already did (e.g. the
      // isComponentOnPageFresh() pre-check in backstopLwcPagePlacement) —
      // see flexipage-retrieve-timeout-followup memory for why a single
      // check isn't enough. A duplicate is worse than an occasional
      // needless skip.
      if (
        workingXml.contains(
          '<componentName>c:' + componentName + '</componentName>'
        )
      ) {
        alreadyPresentCount++;
        continue;
      }
      String updated = appendComponentToRegion(
        workingXml,
        componentName,
        regionName,
        allowAnyRegionFallback
      );
      if (updated == null) {
        continue;
      }
      workingXml = updated;
      appliedCount++;
    }

    return new Map<String, Object>{
      'modifiedXml' => appliedCount > 0 ? workingXml : null,
      'appliedCount' => appliedCount,
      'alreadyPresentCount' => alreadyPresentCount
    };
  }

  // ─────────────────────────────────────────────────────────────
  // APPEND — insert one componentInstance into a named region
  //
  // Returns the modified XML, or null when nothing changed (component already
  // on the page, or region absent).
  //
  // Done by positional string insert rather than Dom.Document on purpose:
  // FlexiPageRegion is an XSD sequence (itemInstances, mode, name, type), and
  // Apex's Dom API can only append children to the END of a node — which would
  // put itemInstances after <type> and make the file fail to deploy.
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private static String appendComponentToRegion(
    String xml,
    String componentName,
    String regionName,
    Boolean allowAnyRegionFallback
  ) {
    String fullName = 'c:' + componentName;

    if (xml.contains('<componentName>' + fullName + '</componentName>')) {
      System.debug(
        '[FLEXIPAGE] [' +
          fullName +
          '] already present on the page — no change made.'
      );
      return null;
    }

    // Requested region first, then the other standard region. An explicit
    // candidate list (rather than a fallback recursion) is what guarantees
    // termination: whole-document region-name checks and the precise
    // per-region scan below can disagree, and a recursive fallback would
    // then bounce between the two names forever.
    List<String> candidates = new List<String>{ regionName };
    String alternate = (regionName == DEFAULT_REGION)
      ? FALLBACK_REGION
      : DEFAULT_REGION;
    if (alternate != regionName) {
      candidates.add(alternate);
    }

    for (String candidate : candidates) {
      String updated = insertIntoRegion(
        xml,
        fullName,
        componentName,
        candidate
      );
      if (updated != null) {
        if (candidate != regionName) {
          System.debug(
            '[FLEXIPAGE] region [' +
              regionName +
              '] not found on this page — used [' +
              candidate +
              '] instead.'
          );
        }
        return updated;
      }
    }

    // Last resort for AppPage/HomePage only: their templates don't follow
    // the sidebar/main convention the two named candidates above assume, so
    // land in WHATEVER region exists rather than give up. RecordPage never
    // reaches here with allowAnyRegionFallback=true — see the caller.
    if (allowAnyRegionFallback == true) {
      String anyRegionResult = insertIntoRegion(
        xml,
        fullName,
        componentName,
        null
      );
      if (anyRegionResult != null) {
        System.debug(
          '[FLEXIPAGE] neither named region ' +
            candidates +
            ' found — used the first available region on the page instead.'
        );
        return anyRegionResult;
      }
    }

    System.debug(
      '[FLEXIPAGE] neither region ' +
        candidates +
        ' found on this page — page unmodified.'
    );
    return null;
  }

  /**
   * Inserts the component into one region. regionName == null means "match
   * the first region found, whatever it's named" — used only by the
   * AppPage/HomePage any-region fallback above. Returns null when no
   * matching region is present — never recurses.
   */
  private static String insertIntoRegion(
    String xml,
    String fullName,
    String componentName,
    String regionName
  ) {
    Integer searchFrom = 0;
    while (true) {
      Integer blockStart = xml.indexOf('<flexiPageRegions>', searchFrom);
      if (blockStart < 0) {
        break;
      }
      Integer blockEnd = xml.indexOf('</flexiPageRegions>', blockStart);
      if (blockEnd < 0) {
        break;
      }

      String block = xml.substring(blockStart, blockEnd);
      Integer lastItemEnd = block.lastIndexOf(ITEM_CLOSE);

      // The region's OWN <name> is a direct child that appears after every
      // itemInstances block. Searching only that tail avoids matching a
      // <name> belonging to a nested componentInstanceProperty.
      Integer tailStart = (lastItemEnd >= 0)
        ? lastItemEnd + ITEM_CLOSE.length()
        : 0;
      String tail = block.substring(tailStart);

      Boolean isMatch =
        (regionName == null) ||
        tail.contains('<name>' + regionName + '</name>');

      if (isMatch) {
        Integer insertAt;
        if (lastItemEnd >= 0) {
          // Append after the region's last existing item.
          insertAt = blockStart + lastItemEnd + ITEM_CLOSE.length();
        } else {
          // Empty region — insert before the first trailing element so the
          // XSD sequence order is preserved.
          Integer modeIdx = tail.indexOf('<mode>');
          Integer nameIdx = tail.indexOf('<name>');
          Integer anchor = (modeIdx >= 0) ? modeIdx : nameIdx;
          insertAt = blockStart + tailStart + anchor;
        }

        String snippet = buildItemInstanceXml(
          fullName,
          buildUniqueIdentifier(xml, componentName)
        );
        System.debug(
          '[FLEXIPAGE] appending [' +
            fullName +
            '] to region [' +
            regionName +
            ']'
        );
        return xml.substring(0, insertAt) + snippet + xml.substring(insertAt);
      }

      searchFrom = blockEnd + 1;
    }

    return null;
  }

  /**
   * Builds the itemInstances block. Indentation matches the 8-space depth
   * Salesforce uses for region children in retrieved FlexiPage XML.
   */
  private static String buildItemInstanceXml(
    String fullComponentName,
    String identifier
  ) {
    return '\n        <itemInstances>' +
      '\n            <componentInstance>' +
      '\n                <componentName>' +
      fullComponentName +
      '</componentName>' +
      '\n                <identifier>' +
      identifier +
      '</identifier>' +
      '\n            </componentInstance>' +
      '\n        </itemInstances>';
  }

  /**
   * identifier must be unique within the page. Salesforce's own convention is
   * the component name with ':' replaced by '_' (c:submitSurvey → c_submitSurvey);
   * a numeric suffix is added only if that is somehow already taken.
   */
  @TestVisible
  private static String buildUniqueIdentifier(
    String xml,
    String componentName
  ) {
    String base = 'c_' + componentName;
    String candidate = base;
    Integer suffix = 2;
    while (
      xml.contains('<identifier>' + candidate + '</identifier>') && suffix < 100
    ) {
      candidate = base + '_' + suffix;
      suffix++;
    }
    return candidate;
  }
}
