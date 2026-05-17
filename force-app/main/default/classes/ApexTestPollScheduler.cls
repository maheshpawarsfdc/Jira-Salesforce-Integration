/**
 * ApexTestPollScheduler.cls
 *
 * Schedulable wrapper for ApexTestRunQueueable.
 * Used by ApexTestRunQueueable.scheduleNext() to re-enqueue itself
 * after a delay without hitting Salesforce's queueable stack depth limit.
 *
 * Pattern mirrors DeployPollerScheduler.
 */
public class ApexTestPollScheduler implements Schedulable {
  private String contextJson;

  public ApexTestPollScheduler(String contextJson) {
    this.contextJson = contextJson;
  }

  public void execute(SchedulableContext ctx) {
    System.debug(
      'ApexTestPollScheduler.execute(): re-enqueueing ApexTestRunQueueable'
    );

    try {
      System.abortJob(ctx.getTriggerId());
    } catch (Exception e) {
      System.debug(
        'ApexTestPollScheduler: could not abort scheduled job: ' +
        e.getMessage()
      );
    }

    Map<String, Object> ctxMap = (Map<String, Object>) JSON.deserializeUntyped(
      contextJson
    );
    String issueKey = (String) ctxMap.get('issueKey');

    ApexTestRunQueueable job = ApexTestRunQueueable.fromJson(
      issueKey,
      contextJson
    );
    System.enqueueJob(job);
  }
}
