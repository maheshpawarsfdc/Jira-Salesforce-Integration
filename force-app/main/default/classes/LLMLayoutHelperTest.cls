@IsTest
private class LLMLayoutHelperTest {
  // ─────────────────────────────────────────────────────────────
  // rebuildLayoutXmlWithNewFields — primary field duplication regression
  // Real incident 2026-08-21: "Account (Marketing)" layout has Name in an
  // "Account Information" section, plus a SEPARATE, later section that
  // happens to be labeled literally "Information" (holding only a custom
  // field). The rebuild function used to check only that one section's own
  // fields for the primary field's presence, concluded it was missing, and
  // injected a SECOND <field>Name</field> — a real deploy failure ("Field:
  // field, value:Name appears more than once").
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void primaryFieldNotDuplicatedWhenSeparateInformationSectionExists() {
    Map<String, Object> layoutStructure = new Map<String, Object>{
      'fullName' => 'Account-Account (Marketing) Layout',
      'sections' => new List<Object>{
        new Map<String, Object>{
          'label' => 'Account Information',
          'leftFields' => new List<String>{ 'OwnerId', 'Name' },
          'leftBehaviors' => new List<String>{ 'Edit', 'Required' },
          'rightFields' => new List<String>{ 'ParentId' },
          'rightBehaviors' => new List<String>{ 'Edit' }
        },
        new Map<String, Object>{
          'label' => 'Information',
          'leftFields' => new List<String>{ 'Contact_Count__c' },
          'leftBehaviors' => new List<String>{ 'Edit' },
          'rightFields' => new List<String>(),
          'rightBehaviors' => new List<String>()
        }
      }
    };

    Test.startTest();
    String xml = LLMLayoutHelper.rebuildLayoutXmlWithNewFields(
      layoutStructure,
      new List<String>{ 'Approval_Status__c' }
    );
    Test.stopTest();

    System.assertEquals(
      1,
      countOccurrences(xml, '<field>Name</field>'),
      'Name must appear exactly once even when a LATER, unrelated section ' +
        'is also literally labeled "Information": ' +
        xml
    );
    System.assert(
      xml.contains('<field>Approval_Status__c</field>'),
      'New field must still be injected into the Information section: ' + xml
    );
    System.assert(
      xml.contains('<field>Contact_Count__c</field>'),
      'Pre-existing field in the Information section must be preserved: ' + xml
    );
  }

  @IsTest
  static void primaryFieldAddedWhenNoSectionAlreadyHasIt() {
    Map<String, Object> layoutStructure = new Map<String, Object>{
      'fullName' => 'Merchandise__c-Merchandise Layout',
      'sections' => new List<Object>{
        new Map<String, Object>{
          'label' => 'Information',
          'leftFields' => new List<String>{ 'Price__c' },
          'leftBehaviors' => new List<String>{ 'Edit' },
          'rightFields' => new List<String>(),
          'rightBehaviors' => new List<String>()
        }
      }
    };

    Test.startTest();
    String xml = LLMLayoutHelper.rebuildLayoutXmlWithNewFields(
      layoutStructure,
      new List<String>{ 'SKU__c' }
    );
    Test.stopTest();

    System.assertEquals(
      1,
      countOccurrences(xml, '<field>Name</field>'),
      'Name must be added exactly once when no section already has it: ' + xml
    );
    System.assert(
      xml.contains('<field>SKU__c</field>'),
      'New field must be injected: ' + xml
    );
    System.assert(
      xml.contains('<field>Price__c</field>'),
      'Pre-existing field must be preserved: ' + xml
    );
  }

  private static Integer countOccurrences(String haystack, String needle) {
    if (String.isBlank(haystack)) {
      return 0;
    }
    Integer count = 0;
    Integer idx = haystack.indexOf(needle);
    while (idx >= 0) {
      count++;
      idx = haystack.indexOf(needle, idx + needle.length());
    }
    return count;
  }
}
