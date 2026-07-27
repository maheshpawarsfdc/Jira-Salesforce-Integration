public with sharing class ExistingCodeService {
  public static ExistingCodeContext build(StoryAnalysis analysis) {
    ExistingCodeContext context = new ExistingCodeContext();

    loadTriggers(context, analysis);

    loadClasses(context, analysis);

    return context;
  }

  private static void loadTriggers(
    ExistingCodeContext context,
    StoryAnalysis analysis
  ) {
    List<ApexTrigger> triggers = [
      SELECT Name, Body
      FROM ApexTrigger
      WHERE Name LIKE :('%' + analysis.objectName + '%')
    ];

    if (!triggers.isEmpty()) {
      context.triggerExists = true;

      context.triggerName = triggers[0].Name;

      context.triggerBody = triggers[0].Body;
    }
  }

  private static void loadClasses(
    ExistingCodeContext context,
    StoryAnalysis analysis
  ) {
    List<ApexClass> classes = [
      SELECT Name, Body
      FROM ApexClass
    ];

    for (ApexClass cls : classes) {
      context.existingClasses.add(cls.Name);

      if (cls.Name == analysis.objectName + 'TriggerHandler') {
        context.handlerExists = true;

        context.handlerName = cls.Name;

        context.handlerBody = cls.Body;
      }

      if (cls.Name == analysis.objectName + 'Service') {
        context.serviceExists = true;

        context.serviceName = cls.Name;

        context.serviceBody = cls.Body;
      }

      if (cls.Name == analysis.objectName + 'Selector') {
        context.selectorExists = true;

        context.selectorName = cls.Name;

        context.selectorBody = cls.Body;
      }

      if (cls.Name == analysis.objectName + 'Test') {
        context.testClassExists = true;

        context.testClassName = cls.Name;

        context.testClassBody = cls.Body;
      }
    }
  }
}
