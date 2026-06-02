# Apex Class & Trigger Testing - 12 Test Scenarios

## Test Ticket Templates

### TICKET 1: Simple Utility Class

**Title:** Create utility class for string manipulation
**Description:** Create a utility class `StringUtility` with static methods:

- `capitalizeWords(String input)` - capitalize each word
- `removeSpecialCharacters(String input)` - remove non-alphanumeric chars
- `truncateString(String input, Integer length)` - truncate to length
  Test with common strings.

**Expected:** ✅ Should generate clean utility class with 3+ methods

---

### TICKET 2: Batch Apex Class

**Title:** Batch job to update all Account records
**Description:** Create a batch Apex class `UpdateAccountStatusBatch` that:

- Queries all Accounts with Status = 'Inactive'
- Changes their Status to 'Active'
- Logs all updated account IDs
- Set batch size to 100 records
- Include exception handling

**Expected:** ✅ Should generate batch class with start(), execute(), finish() methods

---

### TICKET 3: Scheduled Apex Class

**Title:** Scheduled job to run daily
**Description:** Create a schedulable class `DailyMaintenanceScheduler` that:

- Implements Schedulable interface
- Runs every day at 2 AM
- Cleans up old records (delete records older than 90 days)
- Sends summary email of records deleted
- Schedule it: `String jobId = System.schedule('Daily Maintenance', '0 0 2 * * ?', new DailyMaintenanceScheduler());`

**Expected:** ✅ Should generate Schedulable class with execute() method

---

### TICKET 4: AFTER INSERT Trigger (Simple)

**Title:** Auto-assign new opportunities
**Description:** Create a trigger on Opportunity (after insert):

- When new opportunity is created, if no owner assigned, assign to queue: 'Sales_Queue'
- If amount >= $100,000, mark as 'High Value' stage
- Log the action to OpportunityLog\_\_c custom object

**Expected:** ✅ Should generate AFTER trigger (not BEFORE)

---

### TICKET 5: BEFORE UPDATE Trigger (Complex)

**Title:** Prevent backdating of invoice dates
**Description:** Create a trigger on Invoice\_\_c (before update):

- If InvoiceDate\_\_c is being changed to an earlier date than original, show error
- If Amount**c > 50000 and Status changed to 'Paid', require approval (set Requires_Approval**c = true)
- Auto-update LastModifiedByIntegration\_\_c with user name

**Expected:** ✅ Should generate BEFORE trigger with addError() validation

---

### TICKET 6: After Update Trigger (Multiple events)

**Title:** Sync Contact changes to Account
**Description:** Create trigger on Contact (after insert, after update):

- When Contact.Email is changed, update parent Account.Primary_Contact_Email\_\_c
- Count total contacts per account, update Account.Total_Contacts\_\_c
- If contact count > 10, mark Account as 'Enterprise' tier
- Prevent duplicate contact emails within same account

**Expected:** ✅ Should handle both after insert and after update

---

### TICKET 7: Cross-Object Relationship Update (Batching)

**Title:** Update all related records
**Description:** Create trigger on Order (after update):

- When Order.Status changes to 'Completed', update all related OrderItems:
  - Set Item.Fulfillment_Date\_\_c = TODAY()
  - Set Item.Status\_\_c = 'Shipped'
- Update parent Account.Last_Order_Date\_\_c
- Batch DML operations (update all items in one statement, not in loop)

**Expected:** ✅ Should batch DML outside loop (code validator check)

---

### TICKET 8: Rollup Summation Trigger

**Title:** Calculate running totals
**Description:** Create trigger on Payment\_\_c (after insert, after update, after delete):

- When payment created/updated/deleted on a Case
- Recalculate Case.Total_Payments\_\_c (sum of all payments)
- Calculate Case.Average_Payment_Amount\_\_c (average of payments)
- Update Case.Last_Payment_Date\_\_c
- Use Map to avoid SOQL in loops

**Expected:** ✅ Should demonstrate map-based aggregation patterns

---

### TICKET 9: Deduplication Trigger

**Title:** Prevent duplicate records
**Description:** Create trigger on Lead (before insert, before update):

- Check if Lead with same Email already exists
- If yes, throw addError: "Lead with this email already exists"
- Also check Company + Phone combination for duplicates
- If duplicate found, log to DuplicateLog\_\_c object
- Case-insensitive email check

**Expected:** ✅ Should validate duplicates before insert/update

---

### TICKET 10: Workflow Integration Trigger

**Title:** Auto-escalate high-priority cases
**Description:** Create trigger on Case (after update):

- If Priority changes to 'High' or 'Critical', assign to 'Executive_Support' queue
- If SLA_Violated\_\_c = true, set Status to 'Escalated'
- Auto-create a Task for case owner: "Review escalated case"
- Send email notification to queue members
- Store escalation timestamp in Escalation_Time\_\_c

**Expected:** ✅ Should create related records (Task) atomically

---

### TICKET 11: Metadata-Driven Trigger

**Title:** Create generic account audit trigger
**Description:** Create trigger on Account (after update):

- For each field changed (Name, Industry, Phone, etc.):
  - Create AccountAuditTrail\_\_c record with:
    - Field_Name\_\_c = field name
    - Old_Value\_\_c = previous value
    - New_Value\_\_c = current value
    - Changed_By\_\_c = current user name
    - Changed_At\_\_c = NOW
- Only log specific fields: Name, Industry, Phone, Website, BillingCity
- Include error handling if audit creation fails

**Expected:** ✅ Should detect field changes and log them

---

### TICKET 12: Recursive Prevention Trigger

**Title:** Update parent status when all children complete
**Description:** Create trigger on Task (after update):

- When Task.Status changes to 'Completed' on a Case
- Count completed tasks on that Case: if ALL tasks completed, set Case.Status = 'Complete'
- Prevent infinite recursion: use static flag to track if already updated parent
- If this is called again on same Case, skip processing
- Log processing count to prevent accidental loops

**Expected:** ✅ Should handle recursion prevention with static variables

---

## Test Execution Plan

**Phase 1:** Run tickets 1-4 (basic classes and simple triggers)
**Phase 2:** Run tickets 5-8 (complex triggers, batching patterns)
**Phase 3:** Run tickets 9-12 (validation, audit, recursion handling)

After each phase, verify:

- ✅ No EOF truncation errors
- ✅ Proper generic types (List<T>, Map<K,V>)
- ✅ DML batched outside loops
- ✅ No DML in BEFORE triggers (where applicable)
- ✅ Triggers use AFTER where needed
- ✅ No hardcoded IDs
- ✅ Error handling present
