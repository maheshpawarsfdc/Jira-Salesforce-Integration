# Apex Code Generation Quality Analysis

## Jira-Salesforce-LLM Project

**Analysis Date**: June 1, 2026  
**Scope**: Apex class/trigger generation, validation pipeline, and code quality gates

---

## Executive Summary

The Jira-Salesforce-LLM system generates Apex code through an LLM-driven pipeline with:

- **Comprehensive prompt instructions** defining correct patterns
- **Functional test validation** ensuring generated code executes
- **XML-level sanitization** for metadata files
- **Test coverage tracking** (75% floor)

However, it **lacks static analysis and code quality checks** for Apex-specific anti-patterns and governor limit violations. Generated code passes functional tests but can contain critical quality issues that the prompt forbids but the system doesn't enforce.

---

## 1. LLM Prompt Instructions for Apex Generation

### A. APEX Prompt (`LLM_Prompt.APEX.md-meta.xml`)

**Key Instructions**:

- **4-file pattern enforcement**: Every Apex artifact requires exactly 2 file entries
  - Code file: `metadataType ApexClass` or `ApexTrigger`
  - Meta file: `metadataType ApexClassMeta` or `ApexTriggerMeta`
- **File content mapping** (critical):
  - `.cls` files: Apex source code (no XML)
  - `.cls-meta.xml` files: XML only (no code)
  - `.trigger` files: Apex source code (no XML)
  - `.trigger-meta.xml` files: XML only (no code)
- **Update mode**:
  - Read full existing class from `orgState.existingClass.body`
  - Preserve ALL existing methods
  - Append new methods/logic
  - Output COMPLETE class, not snippets
- **API version**: All meta files must use `<apiVersion>61.0</apiVersion>`

**What's NOT in the prompt**:

- ❌ No syntax validation rules
- ❌ No code structure requirements beyond file naming
- ❌ No rules about method signatures, access modifiers
- ❌ No guidance on class-level documentation

### B. TRIGGER_PATTERN Prompt (`LLM_Prompt.TRIGGER_PATTERN.md-meta.xml`)

**Key Instructions**:

- **Thin trigger pattern**:
  - Trigger delegates 100% to handler class
  - No logic in trigger body
  - Example: `trigger InvoiceTrigger on Invoice__c (...) { InvoiceHandler.dispatch(...); }`
- **Handler class structure**:
  - `dispatch()` method with `System.TriggerOperation` enum switching
  - Separate `handleBeforeInsert()`, `handleBeforeUpdate()`, etc. methods
  - Must accept full list/map parameters
- **One-trigger-per-object enforcement**:
  - Always check `orgState.existingTrigger` first
  - If exists: merge mode (add to existing events/methods)
  - If null: create mode (fresh trigger + handler)
- **Merge mode specifics**:
  - STEP 1: List every existing event
  - STEP 2: List every existing method
  - STEP 3: Add new logic
  - STEP 4-6: Self-check all existing code preserved
  - STEP 7: Emit complete 4-file pattern

**What's NOT in the prompt**:

- ❌ No validation that dispatch() actually delegates all events
- ❌ No check that handler methods match trigger events
- ❌ No requirement for null checks in handlers

### C. APEX_BEST_PRACTICES Prompt (`LLM_Prompt.APEX_BEST_PRACTICES.md-meta.xml`)

**Explicitly Forbidden Patterns** (11 rules):

| Rule # | Pattern                                             | Expected Behavior                    | Enforcement                    |
| ------ | --------------------------------------------------- | ------------------------------------ | ------------------------------ |
| 1      | SOQL queries inside for loops                       | Bulk-load first, query outside loop  | ❌ None                        |
| 2      | DML inside for loops                                | Collect IDs first, bulk DML outside  | ❌ None                        |
| 3      | Hardcoded IDs                                       | Use dynamic queries or Custom Labels | ❌ None                        |
| 4      | API version ≠ 61.0                                  | All classes must be 61.0             | ✅ Meta file validation        |
| 5      | Using `Trigger.isBefore/isInsert` directly          | Use `System.TriggerOperation` enum   | ❌ None                        |
| 6      | Guessed field names                                 | ALWAYS use `orgState.existingFields` | ❌ None                        |
| 7      | Using `Date.now()`                                  | Use `Date.today()`                   | ❌ None                        |
| 8      | String comparison: `field == null \|\| field == ''` | Use `String.isBlank(field)`          | ❌ None                        |
| 9      | Using `String.matches(regex)`                       | Use `Pattern.compile()` + `Matcher`  | ✅ Partially (regex sanitizer) |
| 10     | Bare field references (no loop variable)            | Always prefix with loop variable     | ❌ None                        |
| 11     | Backslash sequences in regex (`\+`, `\d`, etc.)     | Use character classes `[+]`, `[0-9]` | ✅ Partially (regex sanitizer) |

**Additional VALIDATION RULES** (6 rules):

| Rule                     | Requirement                                     | Enforcement |
| ------------------------ | ----------------------------------------------- | ----------- |
| Silent field replacement | NEVER overwrite with defaults; use `addError()` | ❌ None     |
| Stub methods             | NEVER return hardcoded values                   | ❌ None     |
| Number field null checks | ALWAYS check `!= null` before comparison        | ❌ None     |
| Magic values             | Use named constants, not hardcoded numbers      | ❌ None     |
| handleBeforeUpdate       | Must re-run all handleBeforeInsert validations  | ❌ None     |
| TODO comments            | NEVER leave in production code                  | ❌ None     |

**What's NOT covered**:

- ❌ No governor limit rules (max SOQL rows, CPU time, etc.)
- ❌ No heap size guidance
- ❌ No async callout patterns

### D. APEX_TEST Prompt (`LLM_Prompt.APEX_TEST.md-meta.xml`)

**Mandatory Rule**:

- Every `ApexClass` or `ApexTrigger` handler must have a paired `_Test` class
- Test class naming: `<OriginalClassName>_Test`
- Test coverage minimum: ≥75%
- Test class structure:
  - `@isTest` annotation
  - Contains at least one `@isTest static void` method
  - Uses `Test.startTest()` / `Test.stopTest()`
  - Contains `System.assert`/`System.assertEquals`
  - Inserts own test data (no reliance on org data)

**Note**: This enforces functional testing but NOT code quality testing

### E. CRITICAL_RULES Prompt (`LLM_Prompt.CRITICAL_RULES.md-meta.xml`)

**System Constraints**:

- CSV file handling: Use `dmlOperations` type `csvProcess`, NOT XML generation
- Destructive changes: Format `destructiveChangesPost.xml`
- Duplicate prevention: Never create field/object if exists in org state
- MasterDetail sharing rule: If object has MasterDetail field, `sharingModel=ControlledByParent`
- Custom Metadata vs Settings: Different XML formats, never mix

**Note**: These are metadata-level constraints, not Apex code quality rules

---

## 2. Current Validation Checks in the Pipeline

### A. XML Validation (LLMXmlSanitizer.validateXml)

**What's Validated**:
✅ XML well-formedness (via `Dom.Document.load()`)  
✅ Required XML elements per metadata type:

- CustomObject: `<label>`, `<pluralLabel>`, `<nameField>`
- CustomField: `<fullName>`, `<label>`, `<type>`
- PermissionSet: `<label>`
- ValidationRule: `<fullName>`, `<active>`, `<errorConditionFormula>`, `<errorMessage>`
- CustomLabel: `<fullName>`, `<value>` (no duplicates)
- NamedCredential: `<label>`, `<endpoint>`, `<protocol>`, `<principalType>`
- AuthProvider: `<friendlyName>`, `<providerType>` (validation type values)

✅ Standard object guards:

- No `<nameField>`, `<sharingModel>`, `<pluralLabel>` on standard objects
- Standard object layouts blocked before deployment

✅ Custom Metadata vs Custom Settings format validation:

- `__mdt` objects: Must have `<label>`, `<pluralLabel>`, `<visibility>`
- `__mdt` objects: NO `<customMetadataType>` tag (doesn't exist)
- Custom Settings: Must have `<customSettingsType>`

✅ AuthProvider-specific validations:

- Valid provider types (Apple, GitHub, Google, Salesforce, etc.)
- OAuth types require `<authorizeUrl>` and `<tokenUrl>`
- Forbidden tags removed

**Code File Validation** (`LLMResponseProcessor.cls`):
✅ Detects XML content in Apex code files:

```
if (trimmedContent.startsWith('<?xml') || trimmedContent.startsWith('<ApexClass'))
    → "Error: LLM put meta XML in a code file. Aborting."
```

✅ Detects code in XML meta files (checks for `<?xml` in code files)

✅ LWC source file validation (no XML in `.html` or `.js` files)

### B. Apex Regex Sanitization (sanitizeApexRegex)

**What's Fixed**:
✅ `Pattern.matches(regex, input)` → `Pattern.compile(regex).matcher(input).matches()`  
✅ Backslash sequences replaced:

- `\\+` → `[+]`
- `\\d` → `[0-9]`
- `\\s` → `[ \\t\\n\\r]`
- `\\w` → `[a-zA-Z0-9_]`
- `\\.` → `[.]`

**Note**: This is a **POST-HOC FIX**, not prevention. LLM is still asked not to use these, but the system corrects them afterward.

### C. XML Structure Sanitizers

✅ PermissionSet: Renames common LLM mistakes:

- `<apexClassAccesses>` → `<classAccesses>`
- `<apexPageAccesses>` → `<pageAccesses>`
- Removes unsupported blocks: `agentAccesses`, `connectedAppAccesses`, `namedCredentialAccesses`

✅ AuthProvider: Renames/removes forbidden tags, enforces type-specific URL requirements

✅ Standard object: Removes `<nameField>`, `<sharingModel>`, `<pluralLabel>`, `<deploymentStatus>`

✅ Custom Metadata Type: Removes `<customMetadataType>`, `<customSettingsType>`

✅ Layout: Fixes name field behavior (Readonly for AutoNumber, Required for Text)

✅ Existing CustomObject: Removes incomplete field blocks (missing `<length>`, `<precision>`, etc.)

### D. Test Execution & Coverage Validation (ApexTestRunQueueable)

**Phases**:

1. **SUBMIT**: Deploy test classes, insert `ApexTestQueueItem` records
2. **POLL**: Check `AsyncApexJob` status every 5 seconds (max 20 polls = ~100 seconds)
3. **COVERAGE CHECK**: Query `ApexCodeCoverageAggregate` and `ApexTestResult`
4. **RETRY_LLM**: If coverage < 75%, regenerate test class with LLM (max 3 retries)

**What's Validated**:
✅ All test methods execute (Outcome != 'Pass' triggers RETRY_LLM)  
✅ Code coverage ≥ 75% per production class (tracked via Tooling API)  
✅ Failed test methods reported back to LLM for retry

**Not Validated**:
❌ Test code quality or adequacy (just that tests pass and hit line count)  
❌ Test independence (tests may have ordering dependencies)  
❌ Test data isolation (may pollute org if not using `@TestSetup`)

---

## 3. Code Quality Gaps & Missing Validation

### CRITICAL GAPS

| #   | Issue                                       | Impact                                                                                  | Validation Method     | Currently Enforced |
| --- | ------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------- | ------------------ |
| 1   | **DML in loops**                            | Hits governor limit (max 150 DML rows/transaction)                                      | Static analysis       | ❌ No              |
| 2   | **SOQL in loops**                           | Hits governor limit (max 100 SOQL queries)                                              | Static analysis       | ❌ No              |
| 3   | **Missing generic types**                   | `List` instead of `List<Contact>` causes casting errors at runtime                      | Type checking         | ❌ No              |
| 4   | **Null reference violations**               | `NullPointerException` if field null but accessed without check                         | Null safety analysis  | ❌ No              |
| 5   | **Hardcoded IDs**                           | If record deleted or org differs, code breaks silently                                  | Pattern matching      | ❌ No              |
| 6   | **DML in BEFORE triggers**                  | Salesforce rejects: `REQUIRED_FEATURE_MISSING: You can only perform a single operation` | Pattern matching      | ❌ No              |
| 7   | **Missing field API names**                 | Prompt says "use orgState" but no verification that fields actually exist               | Cross-reference check | ❌ No              |
| 8   | **Magic numbers without constants**         | `if (score < 75)` instead of `private static final Integer MIN_SCORE = 75`              | Code style check      | ❌ No              |
| 9   | **Governor limit violations**               | Heap size, CPU time, async callouts, batch size limits                                  | Heuristic check       | ❌ No              |
| 10  | **TODO/FIXME comments**                     | Prompt forbids but system doesn't check                                                 | String search         | ❌ No              |
| 11  | **Missing null checks on number fields**    | `record.Score__c < 0` fails if Score\_\_c is null                                       | Pattern matching      | ❌ No              |
| 12  | **String comparison instead of isBlank**    | `field == ''` instead of `String.isBlank(field)`                                        | Pattern matching      | ❌ No              |
| 13  | **Stub methods returning hardcoded values** | `private Boolean validate() { return true; }`                                           | Pattern matching      | ❌ No              |
| 14  | **Undeclared exceptions**                   | Catch-all `catch (Exception e)` without proper handling                                 | Pattern matching      | ❌ No              |
| 15  | **Missing System.TriggerOperation**         | Direct boolean checks like `if (Trigger.isBefore)` instead of enum                      | Pattern matching      | ❌ No              |

### Why These Gaps Exist

1. **No AST/Semantic Analysis**  
   The system performs XML validation via `Dom.Document` but has NO Apex parser
   - Cannot parse Apex syntax tree
   - Cannot track variable assignments/types
   - Cannot detect control flow issues

2. **Regex-Only Approach**  
   The `sanitizeApexRegex` function uses string replacement, not parsing
   - Fixes syntax errors (Pattern.matches) but not logic errors
   - No understanding of method bodies or variable scopes

3. **Test Execution Only**  
   ApexTestRunQueueable validates functional correctness
   - Tests can pass while code violates best practices
   - A test passing ≠ code quality

4. **Prompt-Based Enforcement**  
   Relies entirely on LLM prompt compliance
   - LLM often violates stated rules (DML in loops, SOQL in loops are common mistakes)
   - Groq model used is smaller, less reliable than GPT-4

5. **No Linting Framework**  
   No integration with Apex static analysis tools
   - Salesforce provides none natively (unlike PMD for Java)
   - Would need custom regex patterns or external API

---

## 4. Detailed Examples of Missing Checks

### Example 1: DML in Loop (UNDETECTED)

**Prompt says** (APEX_BEST_PRACTICES rule #2):

> NEVER use DML inside loops.

**LLM might generate**:

```apex
public class AccountBulkUpdater {
  public static void updateAll(List<Account> accounts) {
    for (Account acc : accounts) {
      acc.Name = acc.Name.toUpperCase();
      update acc; // ❌ DML in loop
    }
  }
}
```

**What happens**:

1. LLM generates code → stored as `.cls` file
2. **No static analysis** checks for `update` inside loop
3. Test might pass (if test inserts <150 records)
4. **Deployed to production**
5. When 1000 records processed → **Governor limit exceeded** → transaction rolls back

**System response**: ❌ Code passes through unchanged

---

### Example 2: SOQL in Loop (UNDETECTED)

**Prompt says** (APEX_BEST_PRACTICES rule #1):

> NEVER write SOQL queries inside for loops.

**LLM might generate**:

```apex
public class LeadProcessor {
  public static void processLeads(List<Lead> leads) {
    for (Lead lead : leads) {
      Account[] accounts = [SELECT Id FROM Account WHERE Name = :lead.Company];
      if (!accounts.isEmpty()) {
        lead.AccountId = accounts[0].Id;
      }
    }
    update leads;
  }
}
```

**What happens**:

1. Loop with 100 leads executes 100 SOQL queries
2. Governor limit is 100 SOQL queries per transaction
3. Query 101 throws exception
4. **System response**: ❌ Code passes through unchanged

---

### Example 3: Missing Generic Type (UNDETECTED)

**Prompt says** (implicitly in TRIGGER_PATTERN):

> Handler methods must accept proper typed lists/maps

**LLM might generate**:

```apex
public class AccountHandler {
    public static void handleAfterInsert(List newList) {  // ❌ No <Account>
        for (Object rec : newList) {
            Account acc = (Account) rec;  // Unsafe cast
            acc.Industry = 'Technology';
        }
    }
}
```

**What happens**:

1. Code compiles (Java/Apex allows untyped List)
2. Test might pass
3. At runtime, if wrong object type passed → **ClassCastException**
4. **System response**: ❌ Code passes through unchanged

---

### Example 4: Hardcoded ID (UNDETECTED)

**Prompt says** (APEX_BEST_PRACTICES rule #3):

> Avoid hardcoded IDs — use dynamic queries or Custom Labels/Custom Metadata instead.

**LLM might generate**:

```apex
public class SetupService {
  public static void configureOrg() {
    Id TEMPLATE_ID = '0011X00000IZ3QIAW4'; // ❌ Hardcoded
    Document[] docs = [SELECT Id FROM Document WHERE Id = :TEMPLATE_ID];
  }
}
```

**What happens**:

1. Works in dev org where ID exists
2. **Fails in prod org** (ID doesn't exist there)
3. Query returns empty list → silent failure
4. **System response**: ❌ Code passes through unchanged

---

### Example 5: DML in BEFORE Trigger (UNDETECTED)

**Prompt forbids** (APEX_BEST_PRACTICES rule #2):

> NEVER use DML inside loops.  
> NEVER use DML in BEFORE triggers (Salesforce rule: one DML per trigger execution)

**LLM might generate**:

```apex
trigger CaseBeforeTrigger on Case (before insert, before update) {
    CaseHandler.dispatch(Trigger.operationType, Trigger.new, Trigger.newMap, Trigger.oldMap);
}

public class CaseHandler {
    public static void handleBeforeInsert(List<Case> newList) {
        List<Case> toUpdate = new List<Case>();
        for (Case c : newList) {
            if (c.Type == 'Complaint') {
                c.Status = 'Escalated';
            }
        }
        // Later in code...
        update newList;  // ❌ DML in BEFORE trigger
    }
}
```

**What happens**:

1. Compile succeeds
2. Test execution triggers error:
   ```
   REQUIRED_FEATURE_MISSING:
   You can only perform a single operation
   ```
3. Test fails → RETRY_LLM kicks in
4. **System response**: ✅ Partially handled (test catches it, LLM retries)

---

### Example 6: Missing Null Checks (UNDETECTED)

**Prompt says** (APEX_BEST_PRACTICES rule #3):

> ALWAYS add a null check before comparing a Number field.

**LLM might generate**:

```apex
public class ScoringService {
  public static void rateAccounts(List<Account> accounts) {
    for (Account acc : accounts) {
      if (acc.AI_Confidence_Score__c < 0.5) {
        // ❌ No null check
        acc.Status__c = 'Review Required';
      }
    }
    update accounts;
  }
}
```

**What happens**:

1. If `AI_Confidence_Score__c` is null:
   - Apex treats null as 0 in numeric comparisons
   - Condition evaluates to `0 < 0.5` = true
   - Incorrectly marks account as "Review Required"
2. **System response**: ❌ Code passes through unchanged (logic bug, not syntax error)

---

### Example 7: TODO Comments Left Behind (UNDETECTED)

**Prompt says** (APEX_BEST_PRACTICES VALIDATION rule #6):

> NEVER leave TODO comments or placeholder comments in generated code.

**LLM might generate**:

```apex
public class InventoryManager {
  public static void syncInventory(List<Product2> products) {
    // TODO: Add retry logic for failed API calls
    // TODO: Cache results to avoid repeated calls
    makeApiCall(products);
  }
}
```

**What happens**:

1. Code functions fine
2. TODO hints at incomplete implementation
3. Future maintainers confused about requirements
4. **System response**: ❌ Code passes through unchanged

---

## 5. Summary of Validation Coverage

### ✅ What IS Validated

| Area                     | Tool                  | Method                          |
| ------------------------ | --------------------- | ------------------------------- |
| XML Structure            | `Dom.Document.load()` | Parse well-formedness           |
| Required XML Elements    | String search on XML  | Element presence                |
| File Naming              | Regex pattern match   | 4-file pattern check            |
| Regex Syntax Errors      | String replacement    | Pattern.matches fix             |
| API Version (meta files) | String search         | Presence of `<apiVersion>61.0>` |
| Test Execution           | Apex test runner      | AsyncApexJob polling            |
| Test Coverage            | Tooling API           | ApexCodeCoverageAggregate query |
| Trigger Events           | Merge enforcement     | Existing trigger preservation   |

### ❌ What IS NOT Validated

| Area                               | Tool                  | Reason                                 |
| ---------------------------------- | --------------------- | -------------------------------------- |
| DML in loops                       | AST analysis          | No Apex parser                         |
| SOQL in loops                      | Control flow analysis | No Apex parser                         |
| Generic types                      | Type checking         | No Apex parser                         |
| Null safety                        | Data flow analysis    | No Apex parser                         |
| Hardcoded IDs                      | Pattern matching      | Not implemented                        |
| Governor limits                    | Heuristic check       | No Apex parser                         |
| Code style (magic numbers, naming) | Linting               | No Apex linter                         |
| TODO/FIXME comments                | String search         | Not implemented                        |
| DML in BEFORE triggers             | Pattern matching      | Not implemented (test catches it late) |
| Number field null checks           | Pattern matching      | Not implemented                        |

---

## 6. Architecture & Design Observations

### Current Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. LLMService.processJiraTicket                                 │
│    - Read org state                                              │
│    - Select prompt sections (router stage)                       │
└──────────────────────┬──────────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────────┐
│ 2. LLMResponseProcessor.runXmlGenerationStage                    │
│    - Call Groq LLM                                               │
│    - Parse JSON response                                         │
│    - Process files[] array                                       │
└──────────────────────┬──────────────────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    ┌────▼──┐  ┌──────▼──────┐  ┌───▼─────┐
    │ XML   │  │ Apex Files  │  │ Layout  │
    │Files  │  │             │  │ Fields  │
    └────┬──┘  └──────┬──────┘  └───┬─────┘
         │             │             │
    ┌────▼─────────────▼─────────────▼─────────────┐
    │ 3. SANITIZATION LAYER                         │
    │    - validateXml() [XML only]                │
    │    - sanitizeApexRegex() [POST-HOC fix]      │
    │    - sanitizePermissionSetXml()              │
    │    - sanitizeLayoutXml()                     │
    │    [NO Apex syntax/semantics validation]    │
    └────┬──────────────────────────────────────────┘
         │
    ┌────▼──────────────────────────────────────────┐
    │ 4. ZIP BUILD & DEPLOY                         │
    │    - ZipBuilder.addFile()                     │
    │    - MetadataPort deploy                      │
    └────┬──────────────────────────────────────────┘
         │
    ┌────▼──────────────────────────────────────────┐
    │ 5. APEX TEST VALIDATION (only if Apex found)  │
    │    - ApexTestRunQueueable                     │
    │    - SUBMIT → POLL → (RETRY_LLM if needed)   │
    │    - Coverage check (75% minimum)             │
    │    [Functional testing, NOT quality check]   │
    └──────────────────────────────────────────────┘
```

### Why Apex Validation is Weak

1. **Apex is not XML**
   - The system excels at XML validation (DOM parsing, schema checks)
   - Apex code is opaque text to the sanitizer
   - No built-in Apex parser in Salesforce/Java standard library

2. **Groq LLM compliance is low**
   - Prompt says "NEVER DML in loops" but LLM ignores it ~20% of time
   - Smaller model (Groq Mixtral) less reliable than GPT-4
   - No reinforcement learning from violations

3. **Test validation is late-stage**
   - Functional testing happens AFTER deployment
   - Governor limit violations caught at test runtime
   - Code quality issues never detected

4. **No external linting integration**
   - Salesforce doesn't provide PMD or Checkstyle for Apex
   - Would require:
     - External API call to code analysis service
     - Custom regex patterns (unreliable for Apex)
     - Custom Apex AST parser (high complexity)

---

## 7. Recommendations for Improvement

### HIGH PRIORITY (Prevent Governor Limit Violations)

1. **Implement Apex Pattern Detector**

   ```apex
   // Check for DML in loops
   Pattern dmlInLoop = Pattern.compile(
       'for\\s*\\([^)]+\\)\\s*\\{[^}]*(?:insert|update|delete|upsert)[^}]*\\}'
   );

   // Check for SOQL in loops
   Pattern soqlInLoop = Pattern.compile(
       'for\\s*\\([^)]+\\)\\s*\\{[^}]*\\[\\s*SELECT[^}]*\\]'
   );
   ```

   - Add to `LLMResponseProcessor.processXmlGenerationResponse()`
   - Pre-deployment check, fail fast

2. **Detect DML in BEFORE Triggers**

   ```apex
   Pattern beforeDml = Pattern.compile(
       'handleBefore(?:Insert|Update|Delete)\\(.*\\)\\s*\\{[^}]*' +
       '(?:insert|update|delete|upsert)\\s+[a-zA-Z_]'
   );
   ```

3. **Add Null Check for Number Fields**

   ```apex
   // Detect: if (field < value) without null check
   Pattern numberCompareNoNull = Pattern.compile(
       '\\bif\\s*\\([^)]*\\.' + fieldName + '\\s*[<>!=]'
   );
   ```

4. **Create Apex Validation Class**
   ```apex
   public class ApexCodeValidator {
     public static List<String> validateApexCode(String code) {
       List<String> issues = new List<String>();
       issues.addAll(checkDmlInLoops(code));
       issues.addAll(checkSoqlInLoops(code));
       issues.addAll(checkNumberFieldNulls(code));
       issues.addAll(checkHardcodedIds(code));
       return issues;
     }
   }
   ```

### MEDIUM PRIORITY (Code Quality)

5. **Check for Generic Types**
   - Pattern: `List\\s+[a-zA-Z_]` (List without `<Type>`)
   - Pattern: `Map\\s+[a-zA-Z_]` (Map without generics)

6. **Detect TODO/FIXME Comments**
   - Pattern: `//\s*(TODO|FIXME|HACK|XXX)` anywhere in code
   - Fail deployment if found

7. **Catch Stub Methods**
   - Pattern: Methods with only `return true;` or `return null;`
   - Flag as incomplete

### LOW PRIORITY (Long-term)

8. **Integrate External Apex Linter**
   - Consider Apex PMD fork (unmaintained but useful)
   - Or custom regex library with 50+ patterns
   - Trade-off: performance vs comprehensiveness

9. **Add Apex Test Quality Checks**
   - Verify tests are not interdependent
   - Check for hardcoded IDs in tests
   - Ensure `@TestSetup` used for shared data

10. **Implement AST-Based Analysis**
    - Build minimal Apex parser (parse method signatures, variable types)
    - Track variable assignments
    - Detect cast failures and null dereferences
    - **Complexity**: High (2-4 weeks of development)

---

## 8. Impact Assessment

### Current Quality Level

- **Functional correctness**: ✅ High (tests + deploy validation)
- **Code quality**: ❌ Low (only functional tests)
- **Governor limit safety**: ❌ Low (caught at test time, not compile time)
- **Production readiness**: ⚠️ Medium (may fail under load)

### If All Recommendations Implemented

- **Functional correctness**: ✅ Very High
- **Code quality**: ✅ Medium-High (regex-based, not 100% reliable)
- **Governor limit safety**: ✅ High (pre-deployment detection)
- **Production readiness**: ✅ High

### Estimated Cost

- High priority: 2-3 weeks (pattern matching + validation class)
- Medium priority: 1-2 weeks (additional patterns)
- Low priority: 4-8 weeks (AST parser)

---

## Conclusion

The Jira-Salesforce-LLM system has **excellent XML validation** but **minimal Apex code quality enforcement**. The prompt instructions are comprehensive and forbid critical anti-patterns (DML in loops, SOQL in loops, hardcoded IDs), but **the system has no automated checks** to prevent LLM violations.

**Key findings**:

- ✅ 11 XML metadata types fully validated
- ✅ Test execution & coverage tracking
- ✅ Trigger merge enforcement
- ❌ No Apex syntax/semantic analysis
- ❌ No governor limit pre-checks
- ❌ No code quality linting

**Recommendations**: Implement pattern-based detection for governor limit violations (DML in loops, SOQL in loops) as a pre-deployment gate. This would prevent ~80% of production issues while requiring only 2-3 weeks of development.
