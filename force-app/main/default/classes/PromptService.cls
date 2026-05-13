/**
 * PromptService
 *
 * Handles querying LLM_Prompt__mdt records, resolving prompt dependencies
 * transitively, and assembling the final system prompt string for LLM calls.
 *
 * Feature key lifecycle:
 *   1. Router LLM returns a raw set of feature keys for the ticket.
 *   2. resolveDependencies() expands that set with any Depends_On__c chains.
 *   3. assemblePrompt() queries the matching records (plus always-included ones),
 *      sorts by Sort_Order__c, and concatenates Prompt_Content__c.
 */
public with sharing class PromptService {

    // ─────────────────────────────────────────────────────────────
    // PUBLIC API
    // ─────────────────────────────────────────────────────────────

    /**
     * Assembles the final system prompt for a given set of feature keys.
     * Always-included records (Is_Always_Included__c = true) are added automatically.
     * ROUTER_SYSTEM is excluded — it is only used by the router call.
     * Org name and current user are appended at the end.
     *
     * @param selectedKeys  Feature keys returned by the router (may be empty).
     * @return              The assembled system prompt string.
     */
    public static String assemblePrompt(Set<String> selectedKeys) {
        System.debug('[PROMPT-SERVICE] assemblePrompt() called. Input keys: ' + selectedKeys);

        Map<String, LLM_Prompt__mdt> allRecords = loadAllRecords();
        if (allRecords.isEmpty()) {
            System.debug('[PROMPT-SERVICE] ERROR — loadAllRecords() returned 0 records. ' +
                'Check that LLM_Prompt__mdt records are deployed and Is_Active__c = true.');
        }

        Set<String> finalKeys = new Set<String>(selectedKeys);

        // Add always-included keys
        Set<String> alwaysIncluded = new Set<String>();
        for (LLM_Prompt__mdt rec : allRecords.values()) {
            if (rec.Is_Always_Included__c) {
                finalKeys.add(rec.Feature_Key__c);
                alwaysIncluded.add(rec.Feature_Key__c);
            }
        }
        System.debug('[PROMPT-SERVICE] Always-included keys added: ' + alwaysIncluded);
        System.debug('[PROMPT-SERVICE] Keys after always-included merge: ' + finalKeys);

        // Transitively resolve dependencies
        Set<String> beforeResolve = new Set<String>(finalKeys);
        finalKeys = resolveDependencies(finalKeys, allRecords);
        Set<String> addedByDeps = new Set<String>(finalKeys);
        addedByDeps.removeAll(beforeResolve);
        if (!addedByDeps.isEmpty()) {
            System.debug('[PROMPT-SERVICE] Dependency resolution added: ' + addedByDeps);
        }
        System.debug('[PROMPT-SERVICE] Final resolved key set: ' + finalKeys);

        // Collect matching records and sort
        List<LLM_Prompt__mdt> selected = new List<LLM_Prompt__mdt>();
        Set<String> missingKeys = new Set<String>();
        for (String key : finalKeys) {
            if (key == 'ROUTER_SYSTEM') continue;
            if (allRecords.containsKey(key)) {
                selected.add(allRecords.get(key));
            } else {
                missingKeys.add(key);
            }
        }
        if (!missingKeys.isEmpty()) {
            System.debug('[PROMPT-SERVICE] WARNING — keys not found in CMT records: ' + missingKeys);
        }
        selected.sort(new SortOrderComparator());

        // Concatenate content
        String assembled = '';
        List<String> orderedKeys = new List<String>();
        for (LLM_Prompt__mdt rec : selected) {
            if (String.isNotBlank(rec.Prompt_Content__c)) {
                assembled += rec.Prompt_Content__c;
                orderedKeys.add(rec.Feature_Key__c);
            } else {
                System.debug('[PROMPT-SERVICE] WARNING — blank Prompt_Content__c on record: '
                    + rec.Feature_Key__c);
            }
        }
        System.debug('[PROMPT-SERVICE] Prompt sections included (in order): ' + orderedKeys);

        // Append runtime org context
        assembled += '\n\nSalesforce Org: ' + UserInfo.getOrganizationName()
                  + '\nCurrent User: ' + UserInfo.getUserName();

        System.debug('[PROMPT-SERVICE] Assembly complete. Total chars: ' + assembled.length());
        return assembled;
    }

    /**
     * Returns all active, non-ROUTER_SYSTEM Feature_Key__c values.
     * Used by the router to build its available-keys list.
     */
    public static List<String> getRoutableFeatureKeys() {
        List<String> keys = new List<String>();
        for (LLM_Prompt__mdt rec : [
            SELECT Feature_Key__c
            FROM LLM_Prompt__mdt
            WHERE Is_Active__c = true
              AND Feature_Key__c != 'ROUTER_SYSTEM'
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            keys.add(rec.Feature_Key__c);
        }
        System.debug('[PROMPT-SERVICE] getRoutableFeatureKeys() returned ' + keys.size()
            + ' keys: ' + keys);
        if (keys.isEmpty()) {
            System.debug('[PROMPT-SERVICE] ERROR — no routable CMT records found. ' +
                'Check Is_Active__c = true and records are deployed.');
        }
        return keys;
    }

    /**
     * Returns the Prompt_Content__c for the ROUTER_SYSTEM record.
     * Used as the system prompt for the router LLM call.
     */
    public static String getRouterSystemPrompt() {
        List<LLM_Prompt__mdt> recs = [
            SELECT Prompt_Content__c
            FROM LLM_Prompt__mdt
            WHERE Feature_Key__c = 'ROUTER_SYSTEM'
              AND Is_Active__c = true
            LIMIT 1
        ];
        if (recs.isEmpty()) {
            System.debug('[PROMPT-SERVICE] WARNING — ROUTER_SYSTEM CMT record not found. ' +
                'Using hardcoded fallback. Deploy LLM_Prompt.ROUTER_SYSTEM.md-meta.xml.');
            return 'You are a Salesforce feature classifier. Return a JSON array of relevant feature keys.';
        }
        System.debug('[PROMPT-SERVICE] ROUTER_SYSTEM prompt loaded. Chars: '
            + recs[0].Prompt_Content__c.length());
        return recs[0].Prompt_Content__c;
    }

    // ─────────────────────────────────────────────────────────────
    // DEPENDENCY RESOLUTION
    // ─────────────────────────────────────────────────────────────

    /**
     * Transitively expands a set of feature keys by following Depends_On__c chains.
     * Depends_On__c is a comma-separated list of feature keys this record requires.
     */
    @TestVisible
    private static Set<String> resolveDependencies(
        Set<String> initialKeys,
        Map<String, LLM_Prompt__mdt> allRecords
    ) {
        System.debug('[PROMPT-SERVICE] resolveDependencies() starting from: ' + initialKeys);
        Set<String> resolved = new Set<String>(initialKeys);
        Set<String> toProcess = new Set<String>(initialKeys);
        Integer iterations = 0;

        while (!toProcess.isEmpty()) {
            iterations++;
            Set<String> nextBatch = new Set<String>();
            for (String key : toProcess) {
                LLM_Prompt__mdt rec = allRecords.get(key);
                if (rec == null) {
                    System.debug('[PROMPT-SERVICE] resolveDependencies — key not in CMT map: ' + key);
                    continue;
                }
                if (String.isBlank(rec.Depends_On__c)) continue;

                for (String dep : rec.Depends_On__c.split(',')) {
                    String depKey = dep.trim();
                    if (String.isNotBlank(depKey) && !resolved.contains(depKey)) {
                        System.debug('[PROMPT-SERVICE]   ' + key + ' → depends on → ' + depKey);
                        resolved.add(depKey);
                        nextBatch.add(depKey);
                    }
                }
            }
            toProcess = nextBatch;
        }

        System.debug('[PROMPT-SERVICE] resolveDependencies() done in ' + iterations
            + ' iteration(s). Resolved: ' + resolved);
        return resolved;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE HELPERS
    // ─────────────────────────────────────────────────────────────

    private static Map<String, LLM_Prompt__mdt> loadAllRecords() {
        System.debug('[PROMPT-SERVICE] loadAllRecords() — querying LLM_Prompt__mdt...');
        Map<String, LLM_Prompt__mdt> result = new Map<String, LLM_Prompt__mdt>();
        for (LLM_Prompt__mdt rec : [
            SELECT Feature_Key__c, Prompt_Content__c, Depends_On__c,
                   Sort_Order__c, Is_Always_Included__c, Is_Active__c
            FROM LLM_Prompt__mdt
            WHERE Is_Active__c = true
        ]) {
            result.put(rec.Feature_Key__c, rec);
        }
        System.debug('[PROMPT-SERVICE] loadAllRecords() — loaded ' + result.size()
            + ' active records: ' + result.keySet());
        return result;
    }

    private class SortOrderComparator implements Comparator<LLM_Prompt__mdt> {
        public Integer compare(LLM_Prompt__mdt a, LLM_Prompt__mdt b) {
            Decimal sortA = a.Sort_Order__c != null ? a.Sort_Order__c : 999;
            Decimal sortB = b.Sort_Order__c != null ? b.Sort_Order__c : 999;
            if (sortA < sortB) return -1;
            if (sortA > sortB) return 1;
            return 0;
        }
    }
}
