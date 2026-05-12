/**
 * Centralised error logging utility.
 * Persists every caught exception into Error_Log__c so any failure during
 * Jira ticket execution can be investigated from the UI.
 *
 * Captured fields:
 *   Apex_Class__c, Method_Name__c, Line_Number__c,
 *   Type_Name__c, Error_Message__c, Stack_Trace__c,
 *   Cause__c, Jira_Ticket_Key__c
 *
 * Usage (anywhere in a catch block):
 *     } catch (Exception e) {
 *         ErrorLogger.log(e);            // uses currentJiraKey if set
 *         throw e;                        // or handle as appropriate
 *     }
 *
 * Entry points (JiraInboundController / LLMService.processJiraTicket) should
 * call ErrorLogger.currentJiraKey = issueKey so deep helpers tag logs
 * automatically without plumbing the key through every signature.
 *
 * NEVER throws — a logger failure must not mask the original exception.
 */
public with sharing class ErrorLogger {

    // ─── Field length limits (must match object definition) ─────────────
    private static final Integer LEN_TEXT_100   = 100;
    private static final Integer LEN_TEXT_50    = 50;
    private static final Integer LEN_LONG_TEXT  = 32768;

    // ─── Ambient Jira ticket context ─────────────────────────────────────
    // Set by the entry point (JiraInboundController / LLMService) so deep
    // helpers automatically tag their error logs with the ticket key.
    public static String currentJiraKey { get; set; }

    /** Log an exception using the ambient Jira ticket context. */
    public static void log(Exception e) {
        log(e, currentJiraKey);
    }

    /** Log an exception with an explicit Jira ticket key. */
    public static void log(Exception e, String jiraKey) {
        if (e == null) return;
        try {
            Error_Log__c rec = buildRecord(e, jiraKey);
            persist(rec);
        } catch (Exception ignored) {
            // Logger must never throw — swallow and move on.
            System.debug(LoggingLevel.ERROR,
                'ErrorLogger: failed to persist log — ' + ignored.getMessage());
        }
    }

    /** Manually log a non-exception problem (e.g. validation message). */
    public static void logMessage(String className, String methodName,
                                  Integer lineNumber, String typeName,
                                  String message) {
        try {
            Error_Log__c rec = new Error_Log__c();
            rec.Apex_Class__c     = truncate(className,  LEN_TEXT_100);
            rec.Method_Name__c    = truncate(methodName, LEN_TEXT_100);
            rec.Line_Number__c    = lineNumber;
            rec.Type_Name__c      = truncate(typeName,   LEN_TEXT_100);
            rec.Error_Message__c  = truncate(message,    LEN_LONG_TEXT);
            rec.Jira_Ticket_Key__c = truncate(currentJiraKey, LEN_TEXT_50);
            persist(rec);
        } catch (Exception ignored) {
            System.debug(LoggingLevel.ERROR,
                'ErrorLogger.logMessage: failed — ' + ignored.getMessage());
        }
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    private static Error_Log__c buildRecord(Exception e, String jiraKey) {
        Error_Log__c rec = new Error_Log__c();
        rec.Type_Name__c       = truncate(e.getTypeName(), LEN_TEXT_100);
        rec.Error_Message__c   = truncate(e.getMessage(),  LEN_LONG_TEXT);
        rec.Stack_Trace__c     = truncate(e.getStackTraceString(), LEN_LONG_TEXT);
        rec.Line_Number__c     = e.getLineNumber();
        rec.Cause__c           = e.getCause() == null
                                    ? null
                                    : truncate(String.valueOf(e.getCause()), LEN_LONG_TEXT);
        rec.Jira_Ticket_Key__c = truncate(jiraKey, LEN_TEXT_50);

        Map<String, String> frame = parseFirstFrame(e.getStackTraceString());
        rec.Apex_Class__c  = truncate(frame.get('className'),  LEN_TEXT_100);
        rec.Method_Name__c = truncate(frame.get('methodName'), LEN_TEXT_100);
        return rec;
    }

    /**
     * Parse the first frame of an Apex stack trace.
     * Examples:
     *   "Class.LLMService.processJiraTicket: line 74, column 1"
     *   "Trigger.MyTrigger: line 5, column 1"
     *   "AnonymousBlock: line 1, column 1"
     * Returns a map with keys 'className' and 'methodName' (either may be null).
     */
    @TestVisible
    private static Map<String, String> parseFirstFrame(String stack) {
        Map<String, String> out = new Map<String, String>{
            'className'  => null,
            'methodName' => null
        };
        if (String.isBlank(stack)) return out;

        String firstLine = stack.split('\n')[0];

        // Class.<ClassName>.<methodName>:
        Matcher m = Pattern.compile('^Class\\.([^.]+)\\.([^:]+):').matcher(firstLine);
        if (m.find()) {
            out.put('className',  m.group(1));
            out.put('methodName', m.group(2));
            return out;
        }

        // Trigger.<TriggerName>:
        m = Pattern.compile('^Trigger\\.([^:]+):').matcher(firstLine);
        if (m.find()) {
            out.put('className',  'Trigger.' + m.group(1));
            return out;
        }

        // AnonymousBlock
        if (firstLine.startsWith('AnonymousBlock')) {
            out.put('className', 'AnonymousBlock');
            return out;
        }

        return out;
    }

    private static void persist(Error_Log__c rec) {
        // During Jira execution we defer logger DML so callouts can run first.
        if (FunctionHelper.deferErrorLogDml) {
            FunctionHelper.recordsToInsert.add(rec);
            return;
        }

        Database.SaveResult sr = Database.insert(rec, false);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR,
                'ErrorLogger: insert failed - ' + sr.getErrors());
        }
    }

    private static String truncate(String s, Integer max) {
        if (s == null) return null;
        return s.length() <= max ? s : s.substring(0, max);
    }
}
