public with sharing class MetadataContextService {
  public static MetadataContext buildContext(StoryAnalysis analysis) {
    MetadataContext context = new MetadataContext();

    if (String.isBlank(analysis.objectName)) {
      return context;
    }

    Map<String, Schema.SObjectType> objects = Schema.getGlobalDescribe();

    if (!objects.containsKey(analysis.objectName)) {
      return context;
    }

    Schema.DescribeSObjectResult describe = objects.get(analysis.objectName)
      .getDescribe();

    context.objectName = analysis.objectName;
    context.label = describe.getLabel();
    context.customObject = describe.isCustom();

    Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();

    for (String fieldName : fieldMap.keySet()) {
      Schema.DescribeFieldResult field = fieldMap.get(fieldName).getDescribe();

      FieldInfo info = new FieldInfo();

      info.apiName = field.getName();
      info.label = field.getLabel();
      info.type = String.valueOf(field.getType());
      info.required = !field.isNillable();

      info.createable = field.isCreateable();

      info.updateable = field.isUpdateable();

      context.fields.add(info);
    }

    return context;
  }
}
