public class ExistingCodeContext {
  public Boolean triggerExists = false;
  public Boolean handlerExists = false;
  public Boolean serviceExists = false;
  public Boolean selectorExists = false;
  public Boolean testClassExists = false;

  public String triggerName;
  public String handlerName;
  public String serviceName;
  public String selectorName;
  public String testClassName;

  public String triggerBody;
  public String handlerBody;
  public String serviceBody;
  public String selectorBody;
  public String testClassBody;

  public List<String> existingClasses = new List<String>();
}
