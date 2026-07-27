public class StoryAnalysis {
  public String objectName;
  public String artifactType;
  public String triggerEvent;
  public String operation;

  public Boolean needTrigger = false;
  public Boolean needHandler = false;
  public Boolean needTestClass = false;
  public Boolean needLwc = false;
  public Boolean needFlow = false;

  public List<String> detectedObjects = new List<String>();
  public List<String> detectedFields = new List<String>();
}
