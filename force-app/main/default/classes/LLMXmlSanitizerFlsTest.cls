@IsTest
private class LLMXmlSanitizerFlsTest {
  // ─────────────────────────────────────────────────────────────
  // injectDefaultFieldPermissions — new field on an EXISTING object
  // Real incident 2026-08-21: adding Approval_Status__c to the standard
  // Account object came back invisible to every profile. Root cause: this
  // backstop only ever collected fields nested inside a brand-new
  // CustomObject file's <fields> blocks — a field added to an object that
  // already exists (standard like Account, or a pre-existing custom
  // object) arrives as a standalone CustomField file instead, which the
  // old code silently skipped entirely.
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void newFieldOnExistingStandardObjectGetsFlsGranted() {
    ZipBuilder.clear();

    List<Object> files = new List<Object>{
      new Map<String, Object>{
        'metadataType' => 'CustomField',
        'memberName' => 'Account.Approval_Status__c',
        'filePath' => 'objects/Account/fields/Approval_Status__c.field-meta.xml',
        'xmlContent' => '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
        '    <fullName>Approval_Status__c</fullName>\n' +
        '    <type>Picklist</type>\n' +
        '    <required>false</required>\n' +
        '</CustomField>'
      }
    };

    Test.startTest();
    LLMXmlSanitizer.injectDefaultFieldPermissions(files);
    Test.stopTest();

    Boolean foundGrant = false;
    for (String path : ZipBuilder.files.keySet()) {
      if (path.startsWith('profiles/') && path.endsWith('.profile')) {
        String xml = ZipBuilder.files.get(path);
        if (
          xml.contains('<field>Account.Approval_Status__c</field>') &&
          xml.contains('<editable>true</editable>')
        ) {
          foundGrant = true;
        }
      }
    }
    System.assert(
      foundGrant,
      'A new field on an EXISTING object (standalone CustomField shape, ' +
        'not nested inside a CustomObject) must still get FLS granted on a ' +
        'default profile — found files: ' +
        ZipBuilder.files.keySet()
    );
  }

  @IsTest
  static void requiredFieldOnExistingObjectGetsNoExplicitFls() {
    ZipBuilder.clear();

    List<Object> files = new List<Object>{
      new Map<String, Object>{
        'metadataType' => 'CustomField',
        'memberName' => 'Account.Mandatory_Note__c',
        'filePath' => 'objects/Account/fields/Mandatory_Note__c.field-meta.xml',
        'xmlContent' => '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
        '    <fullName>Mandatory_Note__c</fullName>\n' +
        '    <type>Text</type>\n' +
        '    <required>true</required>\n' +
        '</CustomField>'
      }
    };

    Test.startTest();
    LLMXmlSanitizer.injectDefaultFieldPermissions(files);
    Test.stopTest();

    for (String path : ZipBuilder.files.keySet()) {
      if (path.startsWith('profiles/') && path.endsWith('.profile')) {
        String xml = ZipBuilder.files.get(path);
        System.assert(
          !xml.contains('Mandatory_Note__c'),
          'A required field has implicit access — Salesforce rejects an ' +
            'explicit fieldPermissions entry for it: ' +
            xml
        );
      }
    }
  }
}
