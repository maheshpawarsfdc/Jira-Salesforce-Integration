public with sharing class AICodeReviewService {
  public static CodeReviewResult review(CodeReviewRequest request) {
    CodeReviewResult result = new CodeReviewResult();

    result.issues = new List<String>();
    result.suggestions = new List<String>();

    if (request == null) {
      result.approved = false;
      result.issues.add('Request is null.');
      return result;
    }

    if (request.files == null || request.files.isEmpty()) {
      result.approved = false;
      result.issues.add('No generated files found.');
      return result;
    }

    for (AIFile file : request.files) {
      if (String.isBlank(file.fileName)) {
        result.issues.add('Missing file name.');
      }

      if (String.isBlank(file.xmlContent)) {
        result.issues.add('Empty content in ' + file.fileName);
      }
    }

    result.approved = result.issues.isEmpty();

    result.score = result.approved ? 100 : 0;

    return result;
  }
}
