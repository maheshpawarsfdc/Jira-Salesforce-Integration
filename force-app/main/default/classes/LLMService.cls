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
    ZipBuilder.clear();
    FunctionHelper.clearQueues();

    // Ambient ticket context so any ErrorLogger.log() in deep helpers tags this key.
    ErrorLogger.currentJiraKey = issueKey;
    FunctionHelper.deferErrorLogDml = true;
    LLMGroqClient.resetTokenCounters();

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

    // ── STAGE 1.5: Route — select relevant prompt sections ──
    System.debug('── STAGE 1.5: Routing prompt sections...');
    String systemPrompt = LLMResponseProcessor.runRouterStage(
      summary,
      description
    );
    System.debug(
      '── STAGE 1.5 complete. System prompt length: ' + systemPrompt.length()
    );

    // ── STAGE 2: Generate XML files ────────────────────────
    System.debug('── STAGE 2: Generating XML...');
    String result = LLMResponseProcessor.runXmlGenerationStage(
      issueKey,
      summary,
      description,
      orgState,
      systemPrompt
    );
    System.debug('── STAGE 2 complete.');

    // ── ZIP DEPLOY (async) ─────────────────────────────────
    // Flush DML first — enqueue follows immediately, no callout after
    if (ZipBuilder.hasFiles()) {
      flushDmlQueues();
      FunctionHelper.deferErrorLogDml = false;
      System.debug('LLMService: ZipBuilder has files, enqueueing deploy...');
      System.enqueueJob(
        new ZipDeployQueueable(
          issueKey,
          LLMResponseProcessor.pendingZip2DataJson
        )
      );
      LLMResponseProcessor.pendingZip2DataJson = null;
      ZipBuilder.clear();
      LLMGroqClient.logTokenSummary();
      LLMGroqClient.resetTokenCounters();
      return result + '\n⏳ Deploying...';
    }

    // ── SYNC RESULT (DML-only path) ────────────────────────
    // storeDeploymentStatus makes an HTTP callout.
    // Salesforce forbids callouts after DML in the same transaction,
    // so the callout MUST happen before flushDmlQueues().
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
