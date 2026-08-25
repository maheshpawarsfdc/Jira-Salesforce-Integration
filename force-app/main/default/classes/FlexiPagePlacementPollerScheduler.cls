/**
 * FlexiPagePlacementPollerScheduler.cls
 *
 * Schedulable wrapper for FlexiPagePlacementPoller — mirrors
 * DeployPollerScheduler exactly, just for the retrieve-polling chain
 * instead of the deploy-status one.
 *
 * WHY THIS EXISTS:
 * FlexiPagePlacementPoller re-enqueues itself using System.schedule()
 * instead of System.enqueueJob() once it exhausts its fast-path hop budget,
 * to avoid Salesforce's queueable stack depth limit (max 5). Each scheduled
 * job fires in a fresh transaction with no stack depth, allowing polling to
 * continue for the full MAX_ATTEMPTS budget without hitting the limit —
 * and, just as importantly, each scheduled hop is genuinely spaced out in
 * real wall-clock time, which is the whole point of this async redesign.
 *
 * FLOW:
 * FlexiPagePlacementPoller (Queueable) → not done → schedules this
 * FlexiPagePlacementPollerScheduler (Schedulable) → execute() → enqueues a
 * new FlexiPagePlacementPoller → ...
 */
public class FlexiPagePlacementPollerScheduler implements Schedulable {
  private String asyncId;
  private String pageName;
  private String pageType;
  private String objectApiName;
  private String regionName;
  private Boolean allowAnyRegionFallback;
  private String lwcComponentNamesJson;
  private String issueKey;
  private Integer attempt;

  public FlexiPagePlacementPollerScheduler(
    String asyncId,
    String pageName,
    String pageType,
    String objectApiName,
    String regionName,
    Boolean allowAnyRegionFallback,
    String lwcComponentNamesJson,
    String issueKey,
    Integer attempt
  ) {
    this.asyncId = asyncId;
    this.pageName = pageName;
    this.pageType = pageType;
    this.objectApiName = objectApiName;
    this.regionName = regionName;
    this.allowAnyRegionFallback = allowAnyRegionFallback;
    this.lwcComponentNamesJson = lwcComponentNamesJson;
    this.issueKey = issueKey;
    this.attempt = attempt;
  }

  public void execute(SchedulableContext ctx) {
    System.debug(
      'FlexiPagePlacementPollerScheduler.execute(): enqueuing ' +
        'FlexiPagePlacementPoller attempt ' +
        attempt +
        ' for asyncId=' +
        asyncId
    );

    // Delete this scheduled job so it doesn't linger
    try {
      System.abortJob(ctx.getTriggerId());
    } catch (Exception e) {
      System.debug(
        'FlexiPagePlacementPollerScheduler: could not abort scheduled job: ' +
        e.getMessage()
      );
      ErrorLogger.log(e, issueKey);
    }

    // Enqueue the next poller — fresh queueable stack, depth = 1
    FlexiPagePlacementPoller poller = new FlexiPagePlacementPoller();
    poller.asyncId = asyncId;
    poller.pageName = pageName;
    poller.pageType = pageType;
    poller.objectApiName = objectApiName;
    poller.regionName = regionName;
    poller.allowAnyRegionFallback = allowAnyRegionFallback;
    poller.lwcComponentNames = String.isBlank(lwcComponentNamesJson)
      ? new List<String>()
      : (List<String>) JSON.deserialize(
          lwcComponentNamesJson,
          List<String>.class
        );
    poller.issueKey = issueKey;
    poller.attempt = attempt;
    // Fresh transaction — reset the fast-path hop budget for the next segment.
    poller.queueableHops = 0;
    System.enqueueJob(poller);
  }
}
