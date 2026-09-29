/**
 * PermissionSetClonePollerScheduler.cls
 *
 * Schedulable wrapper for PermissionSetClonePoller — mirrors
 * DeployPollerScheduler/FlexiPagePlacementPollerScheduler exactly.
 *
 * WHY THIS EXISTS:
 * PermissionSetClonePoller re-enqueues itself using System.schedule()
 * instead of System.enqueueJob() to avoid Salesforce's queueable stack
 * depth limit (max 5). Each scheduled job fires in a fresh transaction
 * with no stack depth, allowing polling to continue indefinitely without
 * hitting the limit.
 */
public class PermissionSetClonePollerScheduler implements Schedulable {
  private String asyncId;
  private String sourceApiName;
  private String newApiName;
  private String newLabel;
  private String description;
  private String objectPermissionOverridesJson;
  private String issueKey;
  private Integer attempt;

  public PermissionSetClonePollerScheduler(
    String asyncId,
    String sourceApiName,
    String newApiName,
    String newLabel,
    String description,
    String objectPermissionOverridesJson,
    String issueKey,
    Integer attempt
  ) {
    this.asyncId = asyncId;
    this.sourceApiName = sourceApiName;
    this.newApiName = newApiName;
    this.newLabel = newLabel;
    this.description = description;
    this.objectPermissionOverridesJson = objectPermissionOverridesJson;
    this.issueKey = issueKey;
    this.attempt = attempt;
  }

  public void execute(SchedulableContext ctx) {
    System.debug(
      'PermissionSetClonePollerScheduler.execute(): enqueuing PermissionSetClonePoller attempt ' +
        attempt +
        ' for asyncId=' +
        asyncId
    );

    // Delete this scheduled job so it doesn't linger
    try {
      System.abortJob(ctx.getTriggerId());
    } catch (Exception e) {
      System.debug(
        'PermissionSetClonePollerScheduler: could not abort scheduled job: ' +
        e.getMessage()
      );
      ErrorLogger.log(e, issueKey);
    }

    // Enqueue the next poller — fresh queueable stack, depth = 1
    PermissionSetClonePoller poller = new PermissionSetClonePoller();
    poller.asyncId = asyncId;
    poller.sourceApiName = sourceApiName;
    poller.newApiName = newApiName;
    poller.newLabel = newLabel;
    poller.description = description;
    poller.objectPermissionOverridesJson = objectPermissionOverridesJson;
    poller.issueKey = issueKey;
    poller.attempt = attempt;
    // Fresh transaction — reset the fast-path hop budget for the next segment.
    poller.queueableHops = 0;
    System.enqueueJob(poller);
  }
}
