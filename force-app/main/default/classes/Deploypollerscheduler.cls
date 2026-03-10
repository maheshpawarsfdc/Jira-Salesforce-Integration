/**
 * DeployPollerScheduler.cls
 *
 * Schedulable wrapper for DeployPoller.
 *
 * WHY THIS EXISTS:
 * DeployPoller re-enqueues itself using System.schedule() instead of
 * System.enqueueJob() to avoid Salesforce's queueable stack depth limit (max 5).
 * Each scheduled job fires in a fresh transaction with no stack depth,
 * allowing polling to continue indefinitely without hitting the limit.
 *
 * FLOW:
 * DeployPoller (Queueable) → not done → schedules DeployPollerScheduler
 * DeployPollerScheduler (Schedulable) → execute() → enqueues new DeployPoller
 * DeployPoller (Queueable) → not done → schedules DeployPollerScheduler → ...
 */
public class Deploypollerscheduler implements Schedulable {

    private String  jobId;
    private String  issueKey;
    private Integer attempt;

    public DeployPollerScheduler(String jobId, String issueKey, Integer attempt) {
        this.jobId    = jobId;
        this.issueKey = issueKey;
        this.attempt  = attempt;
    }

    public void execute(SchedulableContext ctx) {
        System.debug('DeployPollerScheduler.execute(): enqueuing DeployPoller attempt ' + attempt
            + ' for jobId=' + jobId);

        // Delete this scheduled job so it doesn't linger
        try {
            System.abortJob(ctx.getTriggerId());
        } catch (Exception e) {
            System.debug('DeployPollerScheduler: could not abort scheduled job: ' + e.getMessage());
        }

        // Enqueue the next DeployPoller — fresh queueable stack, depth = 1
        System.enqueueJob(new DeployPoller(jobId, issueKey, attempt));
    }
}