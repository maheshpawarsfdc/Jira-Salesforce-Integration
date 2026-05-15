public class FunctionHelper {

    // DML QUEUES
    // Records queued here during XML processing. DML runs AFTER all
    // callouts finish in LLMService (callout-after-DML restriction).
    public static List<SObject> recordsToInsert        = new List<SObject>();
    public static List<SObject> recordsToDelete        = new List<SObject>();
    public static List<String>  permissionSetsToDelete = new List<String>();
    public static Boolean hadError = false;
    public static Boolean deferErrorLogDml = false;

    public static void clearQueues() {
        recordsToInsert.clear();
        recordsToDelete.clear();
        permissionSetsToDelete.clear();
    }

    public static void flushNonMetadataDmlQueues() {
        if (!recordsToInsert.isEmpty()) {
            insert recordsToInsert;
            recordsToInsert.clear();
        }
        if (!recordsToDelete.isEmpty()) {
            delete recordsToDelete;
            recordsToDelete.clear();
        }
    }
}
