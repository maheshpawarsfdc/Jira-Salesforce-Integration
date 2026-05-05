@IsTest
private class ErrorLoggerTest {

    @IsTest
    static void logsDmlException() {
        ErrorLogger.currentJiraKey = 'PROJ-123';
        Test.startTest();
        try {
            // Force a DML exception.
            Account a = new Account();
            insert a; // missing required Name
        } catch (Exception e) {
            ErrorLogger.log(e);
        }
        Test.stopTest();

        List<Error_Log__c> logs = [
            SELECT Apex_Class__c, Method_Name__c, Line_Number__c,
                   Type_Name__c, Error_Message__c, Stack_Trace__c,
                   Jira_Ticket_Key__c
            FROM Error_Log__c
        ];
        System.assertEquals(1, logs.size(), 'Exactly one log expected');
        Error_Log__c log = logs[0];
        System.assert(log.Type_Name__c.contains('DmlException'),
            'Type should be DmlException, was ' + log.Type_Name__c);
        System.assertNotEquals(null, log.Error_Message__c);
        System.assertNotEquals(null, log.Stack_Trace__c);
        System.assertEquals('ErrorLoggerTest', log.Apex_Class__c);
        System.assertEquals('PROJ-123', log.Jira_Ticket_Key__c);
    }

    @IsTest
    static void explicitJiraKeyOverridesAmbient() {
        ErrorLogger.currentJiraKey = 'AMBIENT-1';
        Test.startTest();
        try {
            throw new CalloutException('boom');
        } catch (Exception e) {
            ErrorLogger.log(e, 'EXPLICIT-1');
        }
        Test.stopTest();

        Error_Log__c log = [SELECT Jira_Ticket_Key__c, Type_Name__c FROM Error_Log__c LIMIT 1];
        System.assertEquals('EXPLICIT-1', log.Jira_Ticket_Key__c);
        System.assert(log.Type_Name__c.contains('CalloutException'));
    }

    @IsTest
    static void logMessageCreatesRecord() {
        Test.startTest();
        ErrorLogger.logMessage('MyClass', 'myMethod', 42, 'ValidationError', 'bad input');
        Test.stopTest();

        Error_Log__c log = [
            SELECT Apex_Class__c, Method_Name__c, Line_Number__c,
                   Type_Name__c, Error_Message__c
            FROM Error_Log__c LIMIT 1
        ];
        System.assertEquals('MyClass',        log.Apex_Class__c);
        System.assertEquals('myMethod',       log.Method_Name__c);
        System.assertEquals(42,               log.Line_Number__c);
        System.assertEquals('ValidationError', log.Type_Name__c);
        System.assertEquals('bad input',      log.Error_Message__c);
    }

    @IsTest
    static void parseFrameHandlesClass() {
        Map<String, String> f = ErrorLogger.parseFirstFrame(
            'Class.FooService.doStuff: line 10, column 1\nClass.Bar.baz: line 2, column 3');
        System.assertEquals('FooService', f.get('className'));
        System.assertEquals('doStuff',    f.get('methodName'));
    }

    @IsTest
    static void parseFrameHandlesTrigger() {
        Map<String, String> f = ErrorLogger.parseFirstFrame(
            'Trigger.AccountTrigger: line 5, column 1');
        System.assertEquals('Trigger.AccountTrigger', f.get('className'));
        System.assertEquals(null, f.get('methodName'));
    }

    @IsTest
    static void parseFrameHandlesAnonymousBlock() {
        Map<String, String> f = ErrorLogger.parseFirstFrame(
            'AnonymousBlock: line 1, column 1');
        System.assertEquals('AnonymousBlock', f.get('className'));
    }

    @IsTest
    static void parseFrameHandlesBlank() {
        Map<String, String> f = ErrorLogger.parseFirstFrame(null);
        System.assertEquals(null, f.get('className'));
        System.assertEquals(null, f.get('methodName'));
    }

    @IsTest
    static void nullExceptionIsSafe() {
        Test.startTest();
        ErrorLogger.log(null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Error_Log__c]);
    }

    @IsTest
    static void truncatesLongMessage() {
        String huge = 'x'.repeat(40000);
        Test.startTest();
        ErrorLogger.logMessage('C', 'm', 1, 'T', huge);
        Test.stopTest();
        Error_Log__c log = [SELECT Error_Message__c FROM Error_Log__c LIMIT 1];
        System.assertEquals(32768, log.Error_Message__c.length());
    }
}
