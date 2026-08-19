public class LLMService {
  public class LLMException extends Exception {
  }

  // ─────────────────────────────────────────────────────────────
  // ENTRY POINT — called from JiraInboundController
  // ─────────────────────────────────────────────────────────────
  public static String processJiraTicket(
    String issueKey,
    String summary,
    String description
  ) {
    // Hard reset per ticket to prevent stale metadata from any previous run
    LLMResponseProcessor.pendingZip2DataJson = null;
    LLMResponseProcessor.pendingApexClassNames = null;
    LLMResponseProcessor.pendingApexClassContents = null;
    LLMResponseProcessor.pendingTestClassNames = null;
    LLMResponseProcessor.pendingTestClassContents = null;
    LLMResponseProcessor.pendingPostDeployActionsJson = null;
    ZipBuilder.clear();
    StaticResourceHelper.pendingToolingOps = 0;
    FunctionHelper.clearQueues();

    // Ambient ticket context so any ErrorLogger.log() in deep helpers tags this key.
    ErrorLogger.currentJiraKey = issueKey;
    FunctionHelper.deferErrorLogDml = true;
    LLMGroqClient.resetTokenCounters();

    Long t0 = Datetime.now().getTime();

    System.debug('JIRA AI ASSISTANT — NEW REQUEST');
    System.debug('► Issue Key  : ' + issueKey);
    System.debug('► Summary    : ' + summary);
    System.debug('► Description: ' + description);

    // ── STAGE 1: Read org state ────────────────────────────
    System.debug('── STAGE 1: Reading org state...');
    Map<String, Object> orgState = LLMOrgStateService.runOrgCheck(
      summary,
      description
    );
    System.debug(
      '── Org check complete. orgState: ' + JSON.serialize(orgState)
    );
    System.debug(
      '[LLM-TRACE] org-check | +' + (Datetime.now().getTime() - t0) + 'ms'
    );

    // ── STAGE 1.6: Existence gate — skip if everything already exists ──
    System.debug('── STAGE 1.6: Checking existence gate...');
    Map<String, Object> gateResult = LLMResponseProcessor.runExistenceGateStage(
      summary,
      description,
      orgState
    );
    if (gateResult != null && gateResult.get('allSatisfied') == true) {
      String skipMsg = (String) gateResult.get('summary');
      System.debug(
        '── STAGE 1.6: All requested metadata already exists — skipping deploy. ' +
        skipMsg
      );
      System.debug(
        '[LLM-TRACE] gate-skip-exit | +' +
          (Datetime.now().getTime() - t0) +
          'ms'
      );
      try {
        JiraCallbackService.storeDeploymentStatus(
          issueKey,
          'skipped',
          skipMsg,
          null
        );
      } catch (Exception e) {
        System.debug(
          'LLMService: storeDeploymentStatus (skipped) FAILED — ' +
          e.getMessage()
        );
        ErrorLogger.log(e);
      }
      FunctionHelper.deferErrorLogDml = false;
      LLMGroqClient.logTokenSummary();
      LLMGroqClient.resetTokenCounters();
      return 'Skipped: ' + skipMsg;
    }
    System.debug('── STAGE 1.6 complete. ' + gateResult.get('summary'));
    System.debug(
      '[LLM-TRACE] gate | +' + (Datetime.now().getTime() - t0) + 'ms'
    );

    // ── STAGE 1.5: Route — select relevant prompt sections ──
    System.debug('── STAGE 1.5: Routing prompt sections...');
    String systemPrompt = LLMResponseProcessor.runRouterStage(
      summary,
      description
    );
    System.debug(
      '[LLM-TRACE] router | +' + (Datetime.now().getTime() - t0) + 'ms'
    );
    StoryAnalysis analysis;
    MetadataContext metadata;
    ExistingCodeContext existingCode;
    String finalPrompt;

    try {
      analysis = StoryAnalyzer.analyze(summary, description);

      metadata = MetadataContextService.buildContext(analysis);

      // Future enhancement:
      // ExistingCodeService.build(analysis, orgState)
      existingCode = ExistingCodeService.build(analysis);

      GenerationContext context = new GenerationContext();

      context.summary = summary;
      context.description = description;
      context.systemPrompt = systemPrompt;
      context.story = analysis;
      context.metadata = metadata;
      context.existingCode = existingCode;
      context.orgState = orgState;

      finalPrompt = PromptBuilder.build(context);

      System.debug('========== STORY ANALYSIS ==========');
      System.debug(JSON.serializePretty(analysis));

      System.debug('========== METADATA CONTEXT ==========');
      System.debug(JSON.serializePretty(metadata));

      System.debug('========== EXISTING CODE CONTEXT ==========');
      System.debug(JSON.serializePretty(existingCode));
    } catch (Exception ex) {
      throw new LLMException('Prompt preparation failed: ' + ex.getMessage());
    }
    System.debug(
      '[LLM-TRACE] context-build | +' + (Datetime.now().getTime() - t0) + 'ms'
    );

    // ── STAGE 2: Generate XML files ────────────────────────
    System.debug('── STAGE 2: Generating XML...');
    String result = LLMResponseProcessor.runXmlGenerationStage(
      issueKey,
      summary,
      description,
      orgState,
      finalPrompt
    );
    System.debug('── STAGE 2 complete.');
    System.debug(
      '[LLM-TRACE] xml-generation | +' + (Datetime.now().getTime() - t0) + 'ms'
    );
    System.debug('========== XML GENERATION RESULT ==========');
    System.debug('XML GENERATION RESULT==' + result);
    System.debug('===========================================');
    /*
   List<AIFile> generatedFiles =
    LLMResponseProcessor.getGeneratedFiles();
    System.debug('========== GENERATED FILES ==========');
System.debug(JSON.serializePretty(generatedFiles));

AIValidationResult validation =
    ResponseValidator.validate(
        generatedFiles
    );
    System.debug('========== VALIDATION RESULT ==========');
System.debug(JSON.serializePretty(validation));

if(!validation.success){

    throw new LLMException(
        String.join(
            validation.errors,
            '\n'
        )
    );

} 
// ── STAGE 3: AI Code Review ─────────────────────────────
CodeReviewRequest reviewRequest =
    new CodeReviewRequest();

reviewRequest.issueKey =
    issueKey;

reviewRequest.storySummary =
    summary;

reviewRequest.storyDescription =
    description;

CodeReviewResult review =
    AICodeReviewService.review(
        reviewRequest
    );
System.debug('========== AI REVIEW RESULT ==========');
System.debug(JSON.serializePretty(review));

if(!review.approved){

    throw new LLMException(

        'AI Review Failed\n' +

        String.join(
            review.issues,
            '\n'
        )

    );

} */

    // ── ZIP DEPLOY (async) ─────────────────────────────────────────
    // Flush DML first — enqueue follows immediately, no callout after
    if (ZipBuilder.hasFiles()) {
      flushDmlQueues();
      FunctionHelper.deferErrorLogDml = false;
      String zip2Json = LLMResponseProcessor.pendingZip2DataJson;
      List<String> apxNames = LLMResponseProcessor.pendingApexClassNames;
      List<String> apxCont = LLMResponseProcessor.pendingApexClassContents;
      List<String> tstNames = LLMResponseProcessor.pendingTestClassNames;
      List<String> tstCont = LLMResponseProcessor.pendingTestClassContents;
      String postDeployActionsJson = LLMResponseProcessor.pendingPostDeployActionsJson;
      String deploySummary = LLMResponseProcessor.pendingDeploySummary;

      System.debug(
        '[LLM-TRACE] deploy-handoff | +' +
          (Datetime.now().getTime() - t0) +
          'ms'
      );

      if (
        apxNames != null &&
        !apxNames.isEmpty() &&
        tstNames != null &&
        !tstNames.isEmpty()
      ) {
        // Apex-first deploy: test validation before ZIP2
        ApexTestRunQueueable testJob = ApexTestRunQueueable.forFirstRun(
          issueKey,
          apxNames,
          apxCont,
          tstNames,
          tstCont,
          zip2Json,
          postDeployActionsJson
        );
        // Set before toJson() so the note survives the round-trip through
        // ZipDeployQueueable's apexTestContextJson and back out again.
        testJob.deploySummaryNote = deploySummary;
        System.debug(
          'LLMService: Apex-first deploy detected — chaining to ApexTestRunQueueable'
        );
        System.enqueueJob(
          new ZipDeployQueueable(issueKey, null, testJob.toJson())
        );
      } else {
        System.debug(
          'LLMService: standard deploy — enqueueing ZipDeployQueueable'
        );
        ZipDeployQueueable zdq = new ZipDeployQueueable(
          issueKey,
          zip2Json,
          null,
          postDeployActionsJson
        );
        zdq.deploySummaryNote = deploySummary;
        System.enqueueJob(zdq);
      }

      LLMResponseProcessor.pendingZip2DataJson = null;
      LLMResponseProcessor.pendingApexClassNames = null;
      LLMResponseProcessor.pendingApexClassContents = null;
      LLMResponseProcessor.pendingTestClassNames = null;
      LLMResponseProcessor.pendingTestClassContents = null;
      LLMResponseProcessor.pendingPostDeployActionsJson = null;
      LLMResponseProcessor.pendingDeploySummary = null;
      ZipBuilder.clear();
      LLMGroqClient.logTokenSummary();
      LLMGroqClient.resetTokenCounters();
      return result + '\n⏳ Deploying...';
    }

    // ── SYNC RESULT (DML-only path) ────────────────────────
    // storeDeploymentStatus makes an HTTP callout.
    // Salesforce forbids callouts after DML in the same transaction,
    // so the callout MUST happen before flushDmlQueues().
    //
    // Skip this immediate post if a StaticResourceToolingQueueable is
    // pending — that queueable hasn't actually run yet (Queueable
    // execution is genuinely async, not "later in this same
    // transaction"), so posting "success" here would tell Jira the
    // static resource op finished before the real Tooling API callout
    // even happened. The queueable posts its own status once it
    // actually completes; let that be the one true answer instead of
    // racing it with a premature — and possibly wrong — one here.
    if (StaticResourceHelper.pendingToolingOps == 0) {
      try {
        JiraCallbackService.storeDeploymentStatus(
          issueKey,
          FunctionHelper.hadError ? 'error' : 'success',
          result,
          'sync-' + DateTime.now().getTime()
        );
      } catch (Exception e) {
        System.debug(
          'LLMService: storeDeploymentStatus FAILED — ' + e.getMessage()
        );
        ErrorLogger.log(e);
      }
    } else {
      System.debug(
        'LLMService: skipping sync storeDeploymentStatus — ' +
          StaticResourceHelper.pendingToolingOps +
          ' StaticResourceToolingQueueable job(s) pending; they will ' +
          'post the real status once they actually run'
      );
    }

    // DML flush comes AFTER the callout — safe now
    flushDmlQueues();
    FunctionHelper.deferErrorLogDml = false;
    FunctionHelper.hadError = false;

    LLMGroqClient.logTokenSummary();
    LLMGroqClient.resetTokenCounters();

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // FLUSH DML QUEUES
  // Extracted so each exit path can call it at the right moment:
  //   ZIP path  → flush BEFORE enqueue (no callout follows)
  //   Sync path → flush AFTER storeDeploymentStatus callout
  // ─────────────────────────────────────────────────────────────
  private static void flushDmlQueues() {
    if (!FunctionHelper.recordsToInsert.isEmpty()) {
      System.debug(
        'LLMService: inserting ' +
          FunctionHelper.recordsToInsert.size() +
          ' queued record(s)'
      );
      insert FunctionHelper.recordsToInsert;
      FunctionHelper.recordsToInsert.clear();
    }
    if (!FunctionHelper.recordsToDelete.isEmpty()) {
      System.debug(
        'LLMService: deleting ' +
          FunctionHelper.recordsToDelete.size() +
          ' queued record(s)'
      );
      delete FunctionHelper.recordsToDelete;
      FunctionHelper.recordsToDelete.clear();
    }
    if (!FunctionHelper.permissionSetsToDelete.isEmpty()) {
      for (String psName : FunctionHelper.permissionSetsToDelete) {
        PermissionSetHelper.addDestructiveXml(psName);
      }
      FunctionHelper.permissionSetsToDelete.clear();
    }
  }
}
