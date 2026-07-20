public with sharing class StoryAnalyzer {
  public static StoryAnalysis analyze(String summary, String description) {
    StoryAnalysis result = new StoryAnalysis();

    String text = (summary + ' ' + description).toLowerCase();

    detectObject(result, text);

    detectArtifacts(result, text);

    detectTrigger(result, text);

    detectOperation(result, text);

    return result;
  }

  private static void detectArtifacts(StoryAnalysis result, String text) {
    if (text.contains('trigger')) {
      result.needTrigger = true;
      result.needHandler = true;
      result.needTestClass = true;
      result.artifactType = 'Trigger';
    }

    if (text.contains('lwc') || text.contains('lightning web component')) {
      result.needLwc = true;
      result.artifactType = 'LWC';
    }

    if (text.contains('flow')) {
      result.needFlow = true;
      result.artifactType = 'Flow';
    }
  }

  private static void detectTrigger(StoryAnalysis result, String text) {
    if (text.contains('before insert'))
      result.triggerEvent = 'before insert';
    else if (text.contains('before update'))
      result.triggerEvent = 'before update';
    else if (text.contains('before delete'))
      result.triggerEvent = 'before delete';
    else if (text.contains('after insert'))
      result.triggerEvent = 'after insert';
    else if (text.contains('after update'))
      result.triggerEvent = 'after update';
    else if (text.contains('after delete'))
      result.triggerEvent = 'after delete';
  }

  private static void detectOperation(StoryAnalysis result, String text) {
    if (text.contains('create'))
      result.operation = 'Create';
    else if (text.contains('update'))
      result.operation = 'Update';
    else if (text.contains('delete'))
      result.operation = 'Delete';
  }

  private static void detectObject(StoryAnalysis result, String text) {
    Map<String, Schema.SObjectType> objects = Schema.getGlobalDescribe();

    for (String objectName : objects.keySet()) {
      if (text.contains(objectName.toLowerCase())) {
        result.objectName = objectName;

        result.detectedObjects.add(objectName);

        break;
      }
    }
  }
}
