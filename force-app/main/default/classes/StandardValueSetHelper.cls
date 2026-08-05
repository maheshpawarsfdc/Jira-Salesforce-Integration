/**
 * StandardValueSetHelper.cls
 *
 * Deterministic helper for adding new values to a STANDARD picklist field's
 * StandardValueSet (Lead Status, Case Status, Opportunity Stage, Solution
 * Status) — invoked via a dmlOperations op, never hand-authored by the LLM.
 *
 * WHY THIS EXISTS: deploying a StandardValueSet REPLACES its entire value
 * list — it does not merge like Profile/PermissionSet permissions do. If the
 * LLM freehand-generated the full <standardValue> list, any existing value
 * it didn't know about (or forgot) would be silently dropped from the org,
 * potentially deactivating something other users/processes still depend on.
 *
 * This helper removes that risk structurally: it reads the field's LIVE
 * picklist values via Schema describe (no callout), always re-emits every
 * existing value exactly as it is today, and appends only the newly
 * requested values. The LLM's only input is WHICH new values to add — it
 * never touches the "don't drop anything existing" guarantee.
 */
public class StandardValueSetHelper {
  private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

  // Known StandardValueSet fullName per standard object.field — this is
  // Salesforce's own fixed naming and isn't derivable generically via Apex
  // describe. Add more process-driven objects here as needed.
  private static final Map<String, String> STANDARD_VALUE_SET_NAMES = new Map<String, String>{
    'lead.status' => 'LeadStatus',
    'case.status' => 'CaseStatus',
    'opportunity.stagename' => 'OpportunityStage',
    'solution.status' => 'SolutionStatus'
  };

  // ─────────────────────────────────────────────────────────────
  // ADD VALUES
  // args:
  //   objectApiName (required) — e.g. 'Lead'
  //   fieldApiName  (required) — e.g. 'Status'
  //   newValues     (required) — List of either plain strings (fullName ==
  //                 label) or Maps {fullName, label} for a custom label.
  //                 For Opportunity StageName only, a value Map may also
  //                 include probability (Integer), forecastCategory
  //                 (String), closed (Boolean), won (Boolean) — all
  //                 optional, safely defaulted otherwise.
  // ─────────────────────────────────────────────────────────────
  public static void addValues(Map<String, Object> args) {
    String objectApiName = getRequired(args, 'objectApiName');
    String fieldApiName = getRequired(args, 'fieldApiName');
    Object rawNewValues = args?.get('newValues');
    if (
      !(rawNewValues instanceof List<Object>) ||
      ((List<Object>) rawNewValues).isEmpty()
    ) {
      throw new StandardValueSetException(
        'addStandardPicklistValues: newValues must be a non-empty list'
      );
    }
    List<Object> newValuesRaw = (List<Object>) rawNewValues;

    String lookupKey =
      objectApiName.toLowerCase() +
      '.' +
      fieldApiName.toLowerCase();
    String valueSetName = STANDARD_VALUE_SET_NAMES.get(lookupKey);
    if (String.isBlank(valueSetName)) {
      throw new StandardValueSetException(
        'addStandardPicklistValues: [' +
          objectApiName +
          '.' +
          fieldApiName +
          '] is not a supported standard picklist. Supported: ' +
          String.join(new List<String>(STANDARD_VALUE_SET_NAMES.keySet()), ', ')
      );
    }
    Boolean isOpportunityStage = valueSetName == 'OpportunityStage';

    // ── Read the field's LIVE picklist values ──────────────────
    Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectApiName);
    if (objType == null) {
      throw new StandardValueSetException(
        'addStandardPicklistValues: object [' + objectApiName + '] not found'
      );
    }
    Schema.SObjectField fieldToken = objType.getDescribe()
      .fields.getMap()
      .get(fieldApiName);
    if (fieldToken == null) {
      throw new StandardValueSetException(
        'addStandardPicklistValues: field [' +
          objectApiName +
          '.' +
          fieldApiName +
          '] not found'
      );
    }
    List<Schema.PicklistEntry> liveEntries = fieldToken.getDescribe()
      .getPicklistValues();

    Set<String> existingValues = new Set<String>();
    List<String> standardValueBlocks = new List<String>();
    Boolean anyExistingIsDefault = false;
    for (Schema.PicklistEntry pe : liveEntries) {
      if (pe.isDefaultValue()) {
        anyExistingIsDefault = true;
      }
      existingValues.add(pe.getValue().toLowerCase());
      standardValueBlocks.add(
        buildStandardValueXml(
          pe.getValue(),
          pe.getLabel(),
          pe.isDefaultValue(),
          pe.isActive(),
          null // preserve exactly as-is — no opportunity-stage overrides for existing values
        )
      );
    }

    // Salesforce requires exactly one <default>true</default> entry in a
    // StandardValueSet deploy — same rule as BusinessProcess/RecordType.
    // Live org data can currently have zero (nothing enforces it until you
    // actually redeploy), so if that's the case here, force the FIRST
    // existing value to default rather than leave the deploy invalid or
    // silently default one of the brand-new values instead.
    if (!anyExistingIsDefault && !standardValueBlocks.isEmpty()) {
      standardValueBlocks[0] = standardValueBlocks[0]
        .replace('<default>false</default>', '<default>true</default>');
      System.debug(
        '[DEPLOY-TRACE] StandardValueSetHelper.addValues: no existing value ' +
          'was marked default — forcing the first existing value to ' +
          'default=true so the deploy satisfies "exactly one default" ' +
          'without picking one of the new values.'
      );
    }

    // ── Append the new values (skip any that already exist) ────
    Integer added = 0;
    for (Object rawVal : newValuesRaw) {
      String newFullName;
      String newLabel;
      Map<String, Object> extras = null;
      if (rawVal instanceof Map<String, Object>) {
        Map<String, Object> valMap = (Map<String, Object>) rawVal;
        newFullName = String.valueOf(valMap.get('fullName'));
        Object labelRaw = valMap.get('label');
        newLabel = labelRaw != null ? String.valueOf(labelRaw) : newFullName;
        extras = valMap;
      } else {
        newFullName = String.valueOf(rawVal);
        newLabel = newFullName;
      }
      if (
        String.isBlank(newFullName) ||
        newFullName == 'null' ||
        existingValues.contains(newFullName.toLowerCase())
      ) {
        System.debug(
          '[DEPLOY-TRACE] StandardValueSetHelper.addValues: skipping [' +
            newFullName +
            '] — blank or already exists'
        );
        continue;
      }
      standardValueBlocks.add(
        buildStandardValueXml(
          newFullName,
          newLabel,
          false, // a brand-new value never silently becomes the default
          true,
          isOpportunityStage ? extras : null
        )
      );
      existingValues.add(newFullName.toLowerCase());
      added++;
    }

    String xml =
      '<?xml version="1.0" encoding="UTF-8"?>' +
      '<StandardValueSet xmlns="' +
      NAMESPACE +
      '">' +
      String.join(standardValueBlocks, '') +
      '</StandardValueSet>';

    String filePath =
      'standardValueSets/' +
      valueSetName +
      '.standardValueSet-meta.xml';
    ZipBuilder.addFile('StandardValueSet', valueSetName, filePath, xml);

    System.debug(
      '[DEPLOY-TRACE] StandardValueSetHelper.addValues: [' +
        valueSetName +
        '] staged with ' +
        standardValueBlocks.size() +
        ' total value(s) — ' +
        added +
        ' newly added, ' +
        (standardValueBlocks.size() - added) +
        ' preserved unchanged from the live org'
    );
  }

  // Element order verified against MetadataService.cls StandardValue
  // field_order_type_info: fullName, [color], default, [description],
  // isActive, label, [allowEmail, closed, converted, cssExposed,
  // forecastCategory, groupingString, highPriority, probability,
  // reverseRole, reviewed, won]. Optional elements are only emitted when
  // actually provided.
  private static String buildStandardValueXml(
    String fullName,
    String label,
    Boolean isDefault,
    Boolean isActive,
    Map<String, Object> opportunityExtras
  ) {
    String xml =
      '<standardValue>' +
      '<fullName>' +
      escapeXml(fullName) +
      '</fullName>' +
      '<default>' +
      (isDefault == true) +
      '</default>' +
      '<isActive>' +
      (isActive != false) +
      '</isActive>' +
      '<label>' +
      escapeXml(String.isNotBlank(label) ? label : fullName) +
      '</label>';

    if (opportunityExtras != null) {
      if (opportunityExtras.get('closed') != null) {
        xml += '<closed>' + opportunityExtras.get('closed') + '</closed>';
      }
      if (opportunityExtras.get('forecastCategory') != null) {
        xml +=
          '<forecastCategory>' +
          escapeXml(String.valueOf(opportunityExtras.get('forecastCategory'))) +
          '</forecastCategory>';
      }
      if (opportunityExtras.get('probability') != null) {
        xml +=
          '<probability>' +
          opportunityExtras.get('probability') +
          '</probability>';
      }
      if (opportunityExtras.get('won') != null) {
        xml += '<won>' + opportunityExtras.get('won') + '</won>';
      }
    }

    xml += '</standardValue>';
    return xml;
  }

  private static String escapeXml(String val) {
    if (String.isBlank(val)) {
      return '';
    }
    return val.replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
      .replace('"', '&quot;')
      .replace('\'', '&apos;');
  }

  private static String getRequired(Map<String, Object> args, String key) {
    Object val = args?.get(key);
    if (val == null || String.isBlank(String.valueOf(val))) {
      throw new StandardValueSetException('Required parameter missing: ' + key);
    }
    return String.valueOf(val).trim();
  }

  public class StandardValueSetException extends Exception {
  }
}
