public class FunctionHelper {
  // DML QUEUES
  // Records queued here during XML processing. DML runs AFTER all
  // callouts finish in LLMService (callout-after-DML restriction).
  public static List<SObject> recordsToInsert = new List<SObject>();
  public static List<SObject> recordsToDelete = new List<SObject>();
  public static List<String> permissionSetsToDelete = new List<String>();
  public static Boolean hadError = false;
  public static Boolean deferErrorLogDml = false;

  public static void clearQueues() {
    recordsToInsert.clear();
    recordsToDelete.clear();
    permissionSetsToDelete.clear();
  }

  public static void flushNonMetadataDmlQueues() {
    if (!recordsToInsert.isEmpty()) {
      List<Database.SaveResult> insertResults = Database.insert(
        recordsToInsert,
        false
      );
      for (Integer i = 0; i < insertResults.size(); i++) {
        if (!insertResults[i].isSuccess()) {
          String recLabel = recordsToInsert[i].getSObjectType() + '[' + i + ']';
          for (Database.Error err : insertResults[i].getErrors()) {
            System.debug(
              'flushNonMetadataDmlQueues: INSERT failed for [' +
                recLabel +
                ']: ' +
                err.getStatusCode() +
                ' — ' +
                err.getMessage() +
                ' | fields=' +
                err.getFields()
            );
          }
          hadError = true;
        }
      }
      recordsToInsert.clear();
    }
    if (!recordsToDelete.isEmpty()) {
      List<Database.DeleteResult> deleteResults = Database.delete(
        recordsToDelete,
        false
      );
      for (Integer i = 0; i < deleteResults.size(); i++) {
        if (!deleteResults[i].isSuccess()) {
          String recLabel = recordsToDelete[i].getSObjectType() + '[' + i + ']';
          for (Database.Error err : deleteResults[i].getErrors()) {
            System.debug(
              'flushNonMetadataDmlQueues: DELETE failed for [' +
                recLabel +
                ']: ' +
                err.getStatusCode() +
                ' — ' +
                err.getMessage()
            );
          }
          hadError = true;
        }
      }
      recordsToDelete.clear();
    }
  }
}
