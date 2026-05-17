public class ApexTestRunQueueable implements Queueable, Database.AllowsCallouts {
  private static final Integer MAX_RETRIES = 3;
  private static final Integer MAX_POLL_ATTS = 20;
  private static final Decimal COVERAGE_FLOOR = 75.0;

  // ── All fields are public so JSON.serialize/deserialize round-trips cleanly ──
  public String issueKey;
  public String phase; // SUBMIT | POLL | RETRY_LLM
  public Integer attempt; // 1..MAX_RETRIES
  public Integer pollAttempt; // 0..MAX_POLL_ATTS
  public String asyncApexJobId; // AsyncApexJob Id (set after SUBMIT, polled in POLL)
  public String zip2DataJson; // held-back metadata — deployed after tests pass

  // Parallel arrays: index N of names matches index N of contents
  public List<String> apexClassNames; // production class names
  public List<String> apexClassContents; // production class Apex source
  public List<String> testClassNames; // test class names
  public List<String> testClassContents; // test class Apex source (updated on retry)

  // Populated in POLL → used in RETRY_LLM
  public String coverageReport;
  public List<String> failedMethods;

  // ─────────────────────────────────────────────────────────────
  // CONSTRUCTORS
  // ─────────────────────────────────────────────────────────────
  public ApexTestRunQueueable() {
  }

  public static ApexTestRunQueueable forFirstRun(
    String issueKey,
    List<String> apexClassNames,
    List<String> apexClassContents,
    List<String> testClassNames,
    List<String> testClassContents,
    String zip2DataJson
  ) {
    ApexTestRunQueueable q = new ApexTestRunQueueable();
    q.issueKey = issueKey;
    q.phase = 'SUBMIT';
    q.attempt = 1;
    q.pollAttempt = 0;
    q.apexClassNames = apexClassNames;
    q.apexClassContents = apexClassContents;
    q.testClassNames = testClassNames;
    q.testClassContents = testClassContents;
    q.zip2DataJson = zip2DataJson;
    return q;
  }

  public static ApexTestRunQueueable fromJson(
    String issueKey,
    String contextJson
  ) {
    ApexTestRunQueueable q = (ApexTestRunQueueable) JSON.deserialize(
      contextJson,
      ApexTestRunQueueable.class
    );
    if (String.isBlank(q.issueKey))
      q.issueKey = issueKey;
    return q;
  }

  public String toJson() {
    return JSON.serialize(this);
  }

  // ─────────────────────────────────────────────────────────────
  // EXECUTE
  // ─────────────────────────────────────────────────────────────
  public void execute(QueueableContext ctx) {
    System.debug(
      '[APEX-TEST] execute phase=' +
        phase +
        ' attempt=' +
        attempt +
        ' pollAttempt=' +
        pollAttempt +
        ' issue=' +
        issueKey
    );
    try {
      if (phase == 'SUBMIT') {
        submitTests();
      } else if (phase == 'POLL') {
        pollTests();
      } else if (phase == 'RETRY_LLM') {
        retryWithLlm();
      } else {
        System.debug('[APEX-TEST] Unknown phase [' + phase + '] — aborting');
        postStatus(
          'error',
          'Apex test runner internal error: unknown phase ' + phase
        );
      }
    } catch (Exception ex) {
      System.debug(
        '[APEX-TEST] Unhandled error — ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      ErrorLogger.log(ex, issueKey);
      postStatus('error', 'Apex test validation error: ' + ex.getMessage());
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PHASE: SUBMIT — insert ApexTestQueueItem, transition to POLL
  // ─────────────────────────────────────────────────────────────
  private void submitTests() {
    System.debug('[APEX-TEST] SUBMIT — test classes: ' + testClassNames);

    List<ApexClass> found = [
      SELECT Id, Name
      FROM ApexClass
      WHERE Name IN :new Set<String>(testClassNames)
    ];

    if (found.isEmpty()) {
      // Class may not be queryable yet — wait up to 5 SUBMIT retries
      pollAttempt++;
      System.debug(
        '[APEX-TEST] Test class(es) not yet queryable — SUBMIT retry ' +
          pollAttempt +
          '/5'
      );
      if (pollAttempt > 5) {
        postStatus(
          'error',
          'Apex test class(es) not found after deploy: ' +
          String.join(testClassNames, ', ')
        );
        return;
      }
      scheduleNext(this.toJson(), 5);
      return;
    }

    List<ApexTestQueueItem> items = new List<ApexTestQueueItem>();
    for (ApexClass cls : found) {
      items.add(new ApexTestQueueItem(ApexClassId = cls.Id));
    }
    insert items;

    // Re-query to get ParentJobId (populated after insert)
    Set<Id> itemIds = (new Map<Id, ApexTestQueueItem>(items)).keySet();
    List<ApexTestQueueItem> reQueried = [
      SELECT ParentJobId
      FROM ApexTestQueueItem
      WHERE Id IN :itemIds
      LIMIT 1
    ];
    if (!reQueried.isEmpty() && reQueried[0].ParentJobId != null) {
      asyncApexJobId = reQueried[0].ParentJobId;
    }

    System.debug(
      '[APEX-TEST] Test job submitted. asyncApexJobId=' + asyncApexJobId
    );
    phase = 'POLL';
    pollAttempt = 0;
    scheduleNext(this.toJson(), 5);
  }

  // ─────────────────────────────────────────────────────────────
  // PHASE: POLL — check AsyncApexJob, route on completion
  // ─────────────────────────────────────────────────────────────
  private void pollTests() {
    System.debug(
      '[APEX-TEST] POLL — pollAttempt=' +
        pollAttempt +
        ' asyncApexJobId=' +
        asyncApexJobId
    );

    if (String.isBlank(asyncApexJobId)) {
      phase = 'SUBMIT';
      pollAttempt = 0;
      System.enqueueJob(this);
      return;
    }

    List<AsyncApexJob> jobs = [
      SELECT Status, NumberOfErrors
      FROM AsyncApexJob
      WHERE Id = :asyncApexJobId
    ];
    if (jobs.isEmpty()) {
      postStatus('error', 'Apex test job not found: ' + asyncApexJobId);
      return;
    }

    String status = jobs[0].Status;
    System.debug('[APEX-TEST] AsyncApexJob status=' + status);

    if (status == 'Completed' || status == 'Failed' || status == 'Aborted') {
      checkCoverageAndProceed();
    } else if (pollAttempt >= MAX_POLL_ATTS) {
      postStatus(
        'error',
        'Apex test run timed out after ' +
          MAX_POLL_ATTS +
          ' poll attempts. Last status: ' +
          status
      );
    } else {
      pollAttempt++;
      scheduleNext(this.toJson(), 5);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // COVERAGE CHECK — called after tests complete
  // ApexCodeCoverageAggregate is Tooling API-only; query via MetadataHelper.
  // ─────────────────────────────────────────────────────────────
  private void checkCoverageAndProceed() {
    // ── Query test failures via standard SOQL ─────────────
    List<ApexTestResult> failures = [
      SELECT MethodName, Outcome, Message
      FROM ApexTestResult
      WHERE AsyncApexJobId = :asyncApexJobId AND Outcome != 'Pass'
    ];

    // ── Query coverage via Tooling API ────────────────────
    List<String> quotedNames = new List<String>();
    for (String n : apexClassNames) {
      quotedNames.add('\'' + String.escapeSingleQuotes(n) + '\'');
    }
    String covSoql =
      'SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered' +
      ' FROM ApexCodeCoverageAggregate' +
      ' WHERE ApexClassOrTrigger.Name IN (' +
      String.join(quotedNames, ',') +
      ')';

    List<Map<String, Object>> coverages = new List<Map<String, Object>>();
    try {
      Map<String, Object> covResult = MetadataHelper.runToolingApiQuery(
        covSoql
      );
      List<Object> records = (List<Object>) covResult.get('records');
      if (records != null) {
        for (Object r : records) {
          coverages.add((Map<String, Object>) r);
        }
      }
    } catch (Exception ex) {
      System.debug(
        '[APEX-TEST] Coverage Tooling API query failed: ' + ex.getMessage()
      );
      ErrorLogger.log(ex, issueKey);
    }

    // ── Build coverage report ──────────────────────────────
    String report = 'Coverage Report (attempt ' + attempt + '):\n';
    Boolean allPass = true;
    List<String> below = new List<String>();

    for (Map<String, Object> cov : coverages) {
      Map<String, Object> classRef = (Map<String, Object>) cov.get(
        'ApexClassOrTrigger'
      );
      String covName = (String) classRef.get('Name');
      Integer covered = cov.get('NumLinesCovered') != null
        ? Integer.valueOf(String.valueOf(cov.get('NumLinesCovered')))
        : 0;
      Integer uncovered = cov.get('NumLinesUncovered') != null
        ? Integer.valueOf(String.valueOf(cov.get('NumLinesUncovered')))
        : 0;
      Integer total = covered + uncovered;
      Decimal pct = total > 0
        ? (Decimal.valueOf(covered) / total * 100).setScale(1)
        : 0;
      report +=
        '- ' +
        covName +
        ': ' +
        pct +
        '% (' +
        covered +
        '/' +
        total +
        ' lines)\n';
      if (pct < COVERAGE_FLOOR) {
        allPass = false;
        below.add(covName + ' (' + pct + '%)');
      }
    }

    // Classes with no coverage entry at all = 0%
    for (String cn : apexClassNames) {
      Boolean found = false;
      for (Map<String, Object> cov : coverages) {
        Map<String, Object> classRef = (Map<String, Object>) cov.get(
          'ApexClassOrTrigger'
        );
        if (cn == (String) classRef.get('Name')) {
          found = true;
          break;
        }
      }
      if (!found) {
        allPass = false;
        below.add(cn + ' (0% — no coverage data)');
        report += '- ' + cn + ': 0% (no coverage data found)\n';
      }
    }

    List<String> failedMethodNames = new List<String>();
    if (!failures.isEmpty()) {
      report += '\nFailed test methods:\n';
      for (ApexTestResult r : failures) {
        report +=
          '- ' +
          r.MethodName +
          ': ' +
          r.Outcome +
          (String.isNotBlank(r.Message) ? ' — ' + r.Message : '') +
          '\n';
        failedMethodNames.add(r.MethodName);
      }
    }

    System.debug('[APEX-TEST] ' + report);
    coverageReport = report;
    failedMethods = failedMethodNames;

    if (allPass) {
      System.debug(
        '[APEX-TEST] Coverage PASSED — chaining to ZIP2 or final success'
      );
      String successMsg = 'Apex test validation PASSED.\n' + report;
      if (String.isNotBlank(zip2DataJson)) {
        try {
          JiraCallbackService.storeDeploymentStatus(
            issueKey,
            'success',
            successMsg + '\n⏳ Deploying remaining metadata...',
            null
          );
        } catch (Exception e) {
          System.debug(
            '[APEX-TEST] Interim status post failed: ' + e.getMessage()
          );
        }
        System.enqueueJob(ZipDeployQueueable.forZip2(issueKey, zip2DataJson));
      } else {
        postStatus('success', successMsg);
      }
    } else {
      System.debug(
        '[APEX-TEST] Coverage FAILED — below=' +
          below +
          ' attempt=' +
          attempt +
          '/' +
          MAX_RETRIES
      );
      if (attempt < MAX_RETRIES) {
        phase = 'RETRY_LLM';
        System.enqueueJob(this);
      } else {
        postStatus(
          'error',
          'Apex test validation FAILED after ' +
            MAX_RETRIES +
            ' attempts.\n' +
            'Classes below 75%: ' +
            String.join(below, ', ') +
            '\n' +
            report
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PHASE: RETRY_LLM — ask LLM to fix the test class, re-deploy
  // ─────────────────────────────────────────────────────────────
  private void retryWithLlm() {
    System.debug(
      '[APEX-TEST] RETRY_LLM — attempt ' + attempt + '/' + MAX_RETRIES
    );

    String systemPrompt = LLMGroqClient.buildXmlGenerationSystemPrompt();
    String userPrompt = buildRetryPrompt();

    List<Map<String, Object>> messages = new List<Map<String, Object>>{
      new Map<String, Object>{ 'role' => 'system', 'content' => systemPrompt },
      new Map<String, Object>{ 'role' => 'user', 'content' => userPrompt }
    };

    Map<String, Object> response = LLMGroqClient.callGroq(
      messages,
      new List<Map<String, Object>>(),
      null
    );

    if (response == null || !response.containsKey('choices')) {
      System.debug(
        '[APEX-TEST] LLM retry returned null/no-choices — giving up'
      );
      postStatus(
        'error',
        'Apex test retry: LLM call failed on attempt ' +
          attempt +
          '.\n' +
          coverageReport
      );
      return;
    }

    List<Object> choices = (List<Object>) response.get('choices');
    Map<String, Object> choice = (Map<String, Object>) choices[0];
    Map<String, Object> msg = (Map<String, Object>) choice.get('message');
    String newTestContent = LLMGroqClient.cleanJsonResponse(
      (String) msg.get('content')
    );

    System.debug(
      '[APEX-TEST] Received fixed test class from LLM. length=' +
      newTestContent.length()
    );

    // Update first test class content (covers single-test-class case; extend if needed)
    if (testClassContents != null && !testClassContents.isEmpty()) {
      testClassContents.set(0, newTestContent);
    }

    // Stage Apex class + fixed test class for re-deploy
    ZipBuilder.clear();
    String metaXml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">' +
      '<apiVersion>65.0</apiVersion><status>Active</status></ApexClass>';

    for (Integer i = 0; i < apexClassNames.size(); i++) {
      String name = apexClassNames[i];
      String content = apexClassContents[i];
      ZipBuilder.addFile(
        'ApexClass',
        name,
        'classes/' + name + '.cls',
        content
      );
      ZipBuilder.addFile(
        'ApexClass',
        name,
        'classes/' + name + '.cls-meta.xml',
        metaXml
      );
    }
    for (Integer i = 0; i < testClassNames.size(); i++) {
      String name = testClassNames[i];
      String content = testClassContents[i];
      ZipBuilder.addFile(
        'ApexClass',
        name,
        'classes/' + name + '.cls',
        content
      );
      ZipBuilder.addFile(
        'ApexClass',
        name,
        'classes/' + name + '.cls-meta.xml',
        metaXml
      );
    }

    // Advance attempt, reset poll state, transition back to SUBMIT
    attempt++;
    phase = 'SUBMIT';
    pollAttempt = 0;
    asyncApexJobId = null;

    String nextContextJson = this.toJson();
    System.debug(
      '[APEX-TEST] Enqueueing ZipDeployQueueable for retry attempt ' + attempt
    );
    System.enqueueJob(new ZipDeployQueueable(issueKey, null, nextContextJson));
  }

  // ─────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────
  private String buildRetryPrompt() {
    String prompt =
      'Apex test class validation FAILED (attempt ' +
      attempt +
      ' of ' +
      MAX_RETRIES +
      ').\n' +
      'Fix the test class to achieve >=75% code coverage on every class listed.\n\n';

    for (Integer i = 0; i < apexClassNames.size(); i++) {
      prompt +=
        '=== Apex Class: ' +
        apexClassNames[i] +
        '.cls ===\n' +
        apexClassContents[i] +
        '\n\n';
    }
    for (Integer i = 0; i < testClassNames.size(); i++) {
      prompt +=
        '=== Current Test Class (FAILING): ' +
        testClassNames[i] +
        '.cls ===\n' +
        testClassContents[i] +
        '\n\n';
    }

    prompt += '=== Coverage Report ===\n' + coverageReport + '\n';

    if (failedMethods != null && !failedMethods.isEmpty()) {
      prompt +=
        '=== Failed Test Methods ===\n' +
        String.join(failedMethods, '\n') +
        '\n\n';
    }

    prompt +=
      'Return ONLY the corrected Apex test class source code for ' +
      (testClassNames.isEmpty()
        ? 'the test class'
        : testClassNames[0] + '.cls') +
      '.\nNo JSON, no XML, no explanation — just the Apex @isTest class code.';
    return prompt;
  }

  private void scheduleNext(String contextJson, Integer delaySecs) {
    Datetime dt = Datetime.now().addSeconds(delaySecs);
    String cronExp =
      dt.second() +
      ' ' +
      dt.minute() +
      ' ' +
      dt.hour() +
      ' ' +
      dt.day() +
      ' ' +
      dt.month() +
      ' ? ' +
      dt.year();
    String jobName =
      'ApexTestPoll_' +
      issueKey +
      '_a' +
      attempt +
      '_p' +
      pollAttempt +
      '_' +
      Datetime.now().getTime();
    System.schedule(jobName, cronExp, new ApexTestPollScheduler(contextJson));
    System.debug('[APEX-TEST] Scheduled next poll: job=' + jobName);
  }

  private void postStatus(String status, String message) {
    try {
      JiraCallbackService.storeDeploymentStatus(
        issueKey,
        status,
        message,
        null
      );
    } catch (Exception e) {
      System.debug('[APEX-TEST] postStatus failed: ' + e.getMessage());
      ErrorLogger.log(e, issueKey);
    }
  }
}
