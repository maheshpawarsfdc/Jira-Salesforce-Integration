public with sharing class PostDeployApexExecutor {
  private static final String API_VERSION = '67.0';

  public static String execute(String actionJson) {
    if (String.isBlank(actionJson)) {
      return '';
    }

    List<Object> actions = (List<Object>) JSON.deserializeUntyped(actionJson);
    List<String> results = new List<String>();
    for (Object rawAction : actions) {
      Map<String, Object> action = (Map<String, Object>) rawAction;
      String className = (String) action.get('className');
      String methodName = (String) action.get('methodName');
      if (String.isBlank(className) || String.isBlank(methodName)) {
        results.add('Invalid post-deploy action was skipped.');
        continue;
      }

      String validationError = validateIdentifier(className, methodName);
      if (String.isNotBlank(validationError)) {
        results.add(validationError);
        continue;
      }

      String anonymousBody = className + '.' + methodName + '();';
      String endpoint =
        URL.getOrgDomainUrl().toExternalForm() +
        '/services/data/v' +
        API_VERSION +
        '/tooling/executeAnonymous/?anonymousBody=' +
        EncodingUtil.urlEncode(anonymousBody, 'UTF-8');

      HttpRequest request = new HttpRequest();
      request.setEndpoint(endpoint);
      request.setMethod('GET');
      request.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
      request.setHeader('Content-Type', 'application/json');
      request.setTimeout(30000);

      HttpResponse response = new Http().send(request);
      if (response.getStatusCode() != 200) {
        results.add(
          className + '.' + methodName + ' failed: HTTP ' + response.getStatusCode() +
          ' ' + response.getBody().abbreviate(500)
        );
        continue;
      }

      Map<String, Object> responseBody = (Map<String, Object>) JSON.deserializeUntyped(
        response.getBody()
      );
      Boolean success = responseBody.get('success') == true;
      if (success) {
        results.add(className + '.' + methodName + ' executed successfully.');
      } else {
        String problem = (String) responseBody.get('compileProblem');
        if (String.isBlank(problem)) {
          problem = (String) responseBody.get('exceptionMessage');
        }
        results.add(
          className + '.' + methodName + ' failed: ' +
          (String.isBlank(problem) ? 'unknown execution error' : problem)
        );
      }
    }
    return String.join(results, '\n');
  }

  private static String validateIdentifier(String className, String methodName) {
    if (!Pattern.matches('[A-Za-z][A-Za-z0-9_]*', className)) {
      return 'Invalid post-deploy class name was skipped: ' + className;
    }
    if (!Pattern.matches('[A-Za-z][A-Za-z0-9_]*', methodName)) {
      return 'Invalid post-deploy method name was skipped: ' + methodName;
    }
    return '';
  }
}
