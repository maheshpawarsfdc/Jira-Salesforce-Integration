@IsTest
private class ApexCodeValidatorTest {
  // ─────────────────────────────────────────────────────────────
  // validateCacheableMethodHasNoDml
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void cacheableMethodWithoutDmlPasses() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static List<Account> getAccounts() {\n' +
      '    return [SELECT Id, Name FROM Account LIMIT 10];\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Cacheable read-only method must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void cacheableMethodWithDmlThrows() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static void badMethod(Id accId) {\n' +
      '    update new Account(Id = accId, Name = \'x\');\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('cacheable=true'),
        'Error should mention cacheable: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'Cacheable method with DML must throw');
  }

  @IsTest
  static void nonCacheableMethodWithDmlPasses() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled\n' +
      '  public static void updateAccount(Id accId) {\n' +
      '    update new Account(Id = accId, Name = \'x\');\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Plain @AuraEnabled DML method must not throw: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─────────────────────────────────────────────────────────────
  // validateSecurityEnforcedOrdering
  // ─────────────────────────────────────────────────────────────
  @IsTest
  static void withSecurityEnforcedCorrectlyPlacedPasses() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static List<Contact> getContacts(Id accId) {\n' +
      '    return [SELECT Id, Name FROM Contact WHERE AccountId = :accId WITH SECURITY_ENFORCED ORDER BY Name LIMIT 50];\n' +
      '  }\n' +
      '}';

    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      System.assert(
        false,
        'Correctly ordered WITH SECURITY_ENFORCED must not throw: ' +
        e.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void withSecurityEnforcedAfterOrderByThrows() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static List<Contact> getContacts(Id accId) {\n' +
      '    return [SELECT Id, Name FROM Contact WHERE AccountId = :accId ORDER BY Name WITH SECURITY_ENFORCED];\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('out of order'),
        'Error should mention ordering: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'WITH SECURITY_ENFORCED after ORDER BY must throw');
  }

  @IsTest
  static void withSecurityEnforcedAfterLimitThrows() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static List<Contact> getContacts(Id accId) {\n' +
      '    return [SELECT Id, Name FROM Contact WHERE AccountId = :accId LIMIT 50 WITH SECURITY_ENFORCED];\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('out of order'),
        'Error should mention ordering: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'WITH SECURITY_ENFORCED after LIMIT must throw');
  }

  @IsTest
  static void duplicateWithClauseThrows() {
    String cls =
      'public with sharing class Foo {\n' +
      '  @AuraEnabled(cacheable=true)\n' +
      '  public static List<Contact> getContacts(Id accId) {\n' +
      '    return [SELECT Id, Name FROM Contact WHERE AccountId = :accId WITH SECURITY_ENFORCED WITH USER_MODE];\n' +
      '  }\n' +
      '}';

    Boolean threw = false;
    Test.startTest();
    try {
      ApexCodeValidator.validate('Foo.cls', cls);
    } catch (ApexCodeValidator.ValidationException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('More than one WITH'),
        'Error should mention duplicate WITH: ' + e.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'Duplicate WITH clause must throw');
  }
}
