public class GenerationResult {
  // Basic Information
  public Boolean success = true;

  public String issueKey;

  public String message;

  public String rawLLMResponse;

  // Generated Files
  public List<AIFile> files = new List<AIFile>();

  // Validation
  public AIValidationResult validationResult;

  // AI Review
  public CodeReviewResult reviewResult;

  // Deployment
  public Boolean readyForDeployment = false;

  public List<String> deploymentPackages = new List<String>();
}
