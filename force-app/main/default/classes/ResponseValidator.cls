public with sharing class ResponseValidator {
  public static AIValidationResult validate(List<AIFile> files) {
    AIValidationResult result = new AIValidationResult();
    result.success = true;

    validateFiles(files, result);
    validateNaming(files, result);
    validateArtifacts(files, result);
    validateSalesforceBestPractices(files, result);

    return result;
  }

  /*
   * ---------------------------------------------------------
   * Validate Files
   * ---------------------------------------------------------
   */
  private static void validateFiles(
    List<AIFile> files,
    AIValidationResult result
  ) {
    if (files == null || files.isEmpty()) {
      result.success = false;
      result.errors.add('No files were generated.');

      return;
    }

    for (AIFile file : files) {
      if (String.isBlank(file.fileName)) {
        result.success = false;
        result.errors.add('File name is missing.');
      }

      if (String.isBlank(file.metadataType)) {
        result.success = false;
        result.errors.add('Metadata type missing for ' + file.fileName);
      }

      if (String.isBlank(file.xmlContent)) {
        result.success = false;
        result.errors.add('Content missing for ' + file.fileName);
      }
    }
  }

  /*
   * ---------------------------------------------------------
   * Validate Naming
   * ---------------------------------------------------------
   */
  private static void validateNaming(
    List<AIFile> files,
    AIValidationResult result
  ) {
    Set<String> names = new Set<String>();

    for (AIFile file : files) {
      if (names.contains(file.fileName)) {
        result.success = false;

        result.errors.add('Duplicate file : ' + file.fileName);
      }

      names.add(file.fileName);

      if (file.metadataType == 'ApexClass' && !file.fileName.endsWith('.cls')) {
        result.success = false;

        result.errors.add(file.fileName + ' should end with .cls');
      }

      if (
        file.metadataType == 'ApexTrigger' &&
        !file.fileName.endsWith('.trigger')
      ) {
        result.success = false;

        result.errors.add(file.fileName + ' should end with .trigger');
      }
    }
  }

  /*
   * ---------------------------------------------------------
   * Validate Required Artifacts
   * ---------------------------------------------------------
   */
  private static void validateArtifacts(
    List<AIFile> files,
    AIValidationResult result
  ) {
    Set<String> fileNames = new Set<String>();

    for (AIFile file : files) {
      fileNames.add(file.fileName);
    }

    for (AIFile file : files) {
      if (file.metadataType == 'ApexClass') {
        String meta = file.fileName + '-meta.xml';

        if (!fileNames.contains(meta)) {
          result.success = false;

          result.errors.add('Missing Apex Meta File : ' + meta);
        }
      }

      if (file.metadataType == 'ApexTrigger') {
        String meta = file.fileName + '-meta.xml';

        if (!fileNames.contains(meta)) {
          result.success = false;

          result.errors.add('Missing Trigger Meta File : ' + meta);
        }
      }

      if (file.metadataType == 'LightningComponentBundle') {
        String base = file.fileName.replace('.html', '');

        Boolean hasJs = false;
        Boolean hasMeta = false;

        for (AIFile f : files) {
          if (f.fileName == base + '.js') {
            hasJs = true;
          }

          if (f.fileName == base + '.js-meta.xml') {
            hasMeta = true;
          }
        }

        if (!hasJs) {
          result.success = false;

          result.errors.add(base + ' missing JS file.');
        }

        if (!hasMeta) {
          result.success = false;

          result.errors.add(base + ' missing js-meta.xml');
        }
      }
    }
  }

  /*
   * ---------------------------------------------------------
   * Salesforce Best Practices
   * ---------------------------------------------------------
   */
  private static void validateSalesforceBestPractices(
    List<AIFile> files,
    AIValidationResult result
  ) {
    for (AIFile file : files) {
      if (file.metadataType != 'ApexClass') {
        continue;
      }

      String body = file.xmlContent;

      if (String.isBlank(body)) {
        continue;
      }

      // with sharing

      if (!body.contains('with sharing')) {
        result.warnings.add(file.fileName + ' : Consider using WITH SHARING.');
      }

      // class keyword

      if (!body.contains('class')) {
        result.success = false;

        result.errors.add(file.fileName + ' : Invalid Apex Class.');
      }

      // SOQL inside loop

      if (body.contains('for (') && body.contains('SELECT')) {
        result.warnings.add(file.fileName + ' : Possible SOQL inside loop.');
      }

      // DML inside loop

      if (
        body.contains('for (') &&
        (body.contains('insert ') ||
        body.contains('update ') ||
        body.contains('delete '))
      ) {
        result.warnings.add(file.fileName + ' : Possible DML inside loop.');
      }

      // Hardcoded Id

      if (
        body.contains('001') ||
        body.contains('005') ||
        body.contains('00Q')
      ) {
        result.warnings.add(
          file.fileName + ' : Possible hardcoded Salesforce Id.'
        );
      }

      // SeeAllData=true

      if (body.contains('@IsTest') && body.contains('SeeAllData=true')) {
        result.warnings.add(file.fileName + ' : Avoid SeeAllData=true.');
      }
    }
  }
}
