/**
 * CsvProcessor.cls
 *
 * Generic bulk processor for CSV attachments on Jira tickets.
 *
 * HOW IT WORKS:
 * 1. LLM calls csv_list_files  → confirms CSV file name
 * 2. LLM calls csv_read        → Apex parses CSV, caches rows SERVER-SIDE,
 *                                returns ONLY column names + row count to LLM
 *                                (NOT the actual rows — saves thousands of tokens)
 * 3. LLM calls csv_bulk_process with fileName + type
 *    → Apex reads rows from cache, builds all XML, stages single deploy
 *
 * WHY THE CACHE?
 * Without it: csv_read returns all rows to LLM → LLM sends them all back
 * in csv_bulk_process → doubles token usage → hits TPM rate limit on iteration 3.
 * With cache: LLM only sees column names. Rows never leave Apex. No token bloat.
 *
 * TOTAL LLM TOOL CALLS: exactly 3 regardless of CSV size.
 *
 * SUPPORTED TYPES (LLM identifies from column names):
 *   translation          — columns: language, labelName, translation
 *   custom_label         — columns: name, value (optional: language, shortDescription, protected)
 *   custom_metadata      — columns: apiName, recordName, label, [field columns]
 *   validation_rule      — columns: objectName, ruleName, errorConditionFormula, errorMessage
 *   custom_setting_field — columns: apiName, fieldName, fieldLabel, fieldType
 */
public class CsvProcessor {
  private static final Integer MAX_ROWS = 500;
  private static final Integer MAX_COLUMNS = 50;

  // ─────────────────────────────────────────────────────────────
  // SERVER-SIDE ROW CACHE
  //
  // Rows are stored here after csv_read.
  // The LLM only receives column names + row count — not the rows.
  // csv_bulk_process reads from this cache using the fileName as key.
  //
  // Key   = fileName (e.g. "translations_Csv.csv")
  // Value = parsed rows
  // ─────────────────────────────────────────────────────────────
  @TestVisible
  private static Map<String, List<Map<String, Object>>> rowCache = new Map<String, List<Map<String, Object>>>();

  // ─────────────────────────────────────────────────────────────
  // READ CSV
  //
  // Decodes base64 attachment, parses into rows, stores in rowCache.
  // Returns ONLY a summary to the LLM — column names + row count.
  // The actual row data stays in Apex memory (rowCache).
  //
  // This is the key token-saving change:
  //   BEFORE: returned all rows → LLM echoed them back → rate limit hit
  //   AFTER:  returns 3 fields → LLM calls csv_bulk_process with fileName only
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> readCsv(Map<String, Object> args) {
    String fileName = getRequiredArg(args, 'fileName');
    String delimiter = getOptionalArg(args, 'delimiter', ',');

    System.debug(
      'CsvProcessor.readCsv(): fileName=' +
        fileName +
        ', delimiter=[' +
        delimiter +
        ']'
    );

    // ── Find attachment ──
    Map<String, String> attachment = StaticResourceHelper.currentAttachments.get(
      fileName
    );
    if (attachment == null) {
      for (String key : StaticResourceHelper.currentAttachments.keySet()) {
        if (key.equalsIgnoreCase(fileName)) {
          attachment = StaticResourceHelper.currentAttachments.get(key);
          fileName = key;
          break;
        }
      }
    }
    if (attachment == null) {
      throw new CsvException(
        'Attachment not found: [' +
          fileName +
          ']. ' +
          'Available: ' +
          StaticResourceHelper.currentAttachments.keySet()
      );
    }

    String base64Content = attachment.get('base64Content');
    if (String.isBlank(base64Content)) {
      throw new CsvException('Attachment [' + fileName + '] has no content.');
    }

    // ── Decode ──
    String csvText;
    try {
      csvText = EncodingUtil.base64Decode(base64Content).toString();
    } catch (Exception e) {
      throw new CsvException(
        'Failed to decode [' + fileName + ']: ' + e.getMessage()
      );
    }

    if (String.isBlank(csvText)) {
      throw new CsvException('Attachment [' + fileName + '] is empty.');
    }

    System.debug(
      'CsvProcessor.readCsv(): decoded CSV length=' + csvText.length()
    );

    // ── Parse ──
    ParseResult parsed = parseCsv(csvText, fileName, delimiter);

    // ── Cache rows server-side — do NOT return them to LLM ──
    rowCache.put(fileName, parsed.rows);
    System.debug(
      'CsvProcessor.readCsv(): cached ' +
        parsed.rows.size() +
        ' rows under key [' +
        fileName +
        ']'
    );

    // ── Return only the summary — keeps LLM token usage minimal ──
    return new Map<String, Object>{
      'success' => true,
      'fileName' => fileName,
      'totalRows' => parsed.rows.size(),
      'columns' => parsed.columns,
      'instructions' => 'Rows are cached server-side. Call csv_bulk_process with fileName="' +
      fileName +
      '" and the correct type based on the column names above. ' +
      'Do NOT pass any rows argument — Apex reads them from cache automatically.'
    };
  }

  // ─────────────────────────────────────────────────────────────
  // GET CACHED ROWS
  // Used by LLMResponseProcessor for the custom_object LLM path.
  // ─────────────────────────────────────────────────────────────
  public static List<Map<String, Object>> getCachedRows(String fileName) {
    return rowCache.get(fileName);
  }

  // ─────────────────────────────────────────────────────────────
  // BULK PROCESS
  //
  // Called by LLM after csv_read. Reads rows from rowCache using
  // fileName — the LLM does NOT need to pass the rows themselves.
  //
  // args:
  //   fileName — same fileName passed to csv_read
  //   type     — one of: translation, custom_label, custom_metadata,
  //                      validation_rule, custom_setting_field
  // ─────────────────────────────────────────────────────────────
  public static Map<String, Object> process(Map<String, Object> args) {
    String type = getRequiredArg(args, 'type')
      .toLowerCase()
      .trim()
      .replace('settings', 'setting')
      .replace('rules', 'rule')
      .replace('labels', 'label')
      .replaceAll('[^a-z_]', '');
    String fileName = getRequiredArg(args, 'fileName');

    System.debug(
      'CsvProcessor.process(): type=' + type + ', fileName=' + fileName
    );

    // ── Read rows from cache ──
    List<Map<String, Object>> cachedRows = rowCache.get(fileName);

    // Fallback: if cache was cleared (e.g. different transaction), try to re-parse
    if (cachedRows == null || cachedRows.isEmpty()) {
      System.debug(
        'CsvProcessor.process(): cache miss for [' +
          fileName +
          '] — attempting re-parse'
      );
      Map<String, String> attachment = StaticResourceHelper.currentAttachments.get(
        fileName
      );
      if (attachment == null) {
        for (String key : StaticResourceHelper.currentAttachments.keySet()) {
          if (key.equalsIgnoreCase(fileName)) {
            attachment = StaticResourceHelper.currentAttachments.get(key);
            break;
          }
        }
      }
      if (
        attachment == null || String.isBlank(attachment.get('base64Content'))
      ) {
        throw new CsvException(
          'No cached rows found for [' +
            fileName +
            '] and attachment is not available. ' +
            'Please call csv_read first.'
        );
      }
      String csvText = EncodingUtil.base64Decode(
          attachment.get('base64Content')
        )
        .toString();
      ParseResult parsed = parseCsv(csvText, fileName, ',');
      cachedRows = parsed.rows;
    }

    if (cachedRows.isEmpty()) {
      throw new CsvException(
        'No rows found for [' + fileName + ']. CSV file may be empty.'
      );
    }

    System.debug(
      'CsvProcessor.process(): processing ' +
        cachedRows.size() +
        ' rows of type [' +
        type +
        ']'
    );

    // Wrap rows as List<Object> for handler methods
    List<Object> rawRows = new List<Object>();
    rawRows.addAll(cachedRows);

    Integer processed = 0;

    if (type == 'translation')
      processed = processTranslations(rawRows);
    else if (type == 'custom_label')
      processed = processCustomLabels(rawRows);
    else if (type == 'custom_metadata')
      processed = processCustomMetadataRecords(rawRows);
    else if (type == 'validation_rule')
      processed = processValidationRules(rawRows);
    else if (type == 'custom_setting_field')
      processed = processCustomSettingFields(rawRows);
    else if (type == 'custom_setting')
      processed = processCustomSettings(rawRows);
    else if (type == 'custom_metadata_type')
      processed = processCustomMetadataTypes(rawRows);
    else if (type == 'group_member')
      processed = processGroupMembers(rawRows);
    else {
      throw new CsvException(
        'Unknown type: [' +
          type +
          ']. ' +
          'Supported: translation, custom_label, custom_metadata, validation_rule, custom_setting_field'
      );
    }

    // Clear cache for this file — no longer needed
    rowCache.remove(fileName);

    System.debug(
      'CsvProcessor.process(): staged ' + processed + ' records for deploy'
    );

    return new Map<String, Object>{
      'success' => true,
      'status' => 'queued_for_deploy',
      'type' => type,
      'processed' => processed,
      'note' => processed +
      ' records staged. All will deploy together after this conversation ends.'
    };
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: TRANSLATIONS
  // Columns: language, labelName, translation
  // ─────────────────────────────────────────────────────────────
  private static Integer processTranslations(List<Object> rawRows) {
    Map<String, Map<String, String>> byLanguage = new Map<String, Map<String, String>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String language = getRowValue(row, 'language');
      String labelName = getRowValue(row, 'labelName');
      String translation = getRowValue(row, 'translation');

      if (
        String.isBlank(language) ||
        String.isBlank(labelName) ||
        String.isBlank(translation)
      ) {
        System.debug(
          'CsvProcessor: skipping incomplete translation row: ' + row
        );
        continue;
      }

      if (!byLanguage.containsKey(language)) {
        byLanguage.put(language, new Map<String, String>());
      }
      byLanguage.get(language).put(labelName, translation);
    }

    if (byLanguage.isEmpty()) {
      throw new CsvException(
        'No valid translation rows. Required columns: language, labelName, translation'
      );
    }

    Integer total = 0;
    for (String language : byLanguage.keySet()) {
      Map<String, String> labelMap = byLanguage.get(language);
      String filePath = 'translations/' + language + '.translation';

      // Merge with any already-staged file for this language
      String existingXml = ZipBuilder.files.get(filePath);
      Map<String, String> mergedMap = new Map<String, String>();
      if (String.isNotBlank(existingXml)) {
        mergedMap = parseExistingTranslationXml(existingXml);
      }
      mergedMap.putAll(labelMap);

      ZipBuilder.addFile(
        'Translations',
        language,
        filePath,
        buildTranslationXml(mergedMap)
      );
      System.debug(
        'CsvProcessor: staged translation [' +
          filePath +
          '] with ' +
          mergedMap.size() +
          ' entries'
      );
      total += labelMap.size();
    }

    return total;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: CUSTOM LABELS
  // Columns: name, value (optional: language, shortDescription, protected)
  // ─────────────────────────────────────────────────────────────
  private static Integer processCustomLabels(List<Object> rawRows) {
    List<Map<String, String>> labels = new List<Map<String, String>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String name = getRowValue(row, 'name');
      String value = getRowValue(row, 'value');

      if (String.isBlank(name) || String.isBlank(value)) {
        System.debug(
          'CsvProcessor: skipping incomplete custom label row: ' + row
        );
        continue;
      }

      labels.add(
        new Map<String, String>{
          'name' => name,
          'value' => value,
          'language' => getRowValueDefault(row, 'language', 'en_US'),
          'shortDescription' => getRowValueDefault(
            row,
            'shortDescription',
            name
          ),
          'protected' => getRowValueDefault(row, 'protected', 'false')
        }
      );
    }

    if (labels.isEmpty()) {
      throw new CsvException(
        'No valid custom label rows. Required columns: name, value'
      );
    }

    String filePath = 'labels/CustomLabels.labels';
    String existingXml = ZipBuilder.files.get(filePath);
    String xml = buildCustomLabelsXml(labels, existingXml);

    for (Map<String, String> lbl : labels) {
      ZipBuilder.addFile('CustomLabel', lbl.get('name'), filePath, xml);
    }

    System.debug(
      'CsvProcessor: staged CustomLabels.labels with ' +
        labels.size() +
        ' labels'
    );
    return labels.size();
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: CUSTOM METADATA TYPE + FIELDS
  // Columns: apiName, label, pluralLabel, fieldName, fieldLabel, fieldType
  // Optional: description, visibility, length, precision, scale, required
  // One row per field — type info repeated across rows for same apiName
  // ─────────────────────────────────────────────────────────────
  private static Integer processCustomMetadataTypes(List<Object> rawRows) {
    Map<String, List<Map<String, Object>>> byApiName = new Map<String, List<Map<String, Object>>>();
    Map<String, Map<String, Object>> typeMeta = new Map<String, Map<String, Object>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String apiName = getRowValue(row, 'apiName');
      if (String.isBlank(apiName)) {
        continue;
      }

      String fullApiName = apiName.endsWith('__mdt')
        ? apiName
        : apiName + '__mdt';

      if (!byApiName.containsKey(fullApiName)) {
        byApiName.put(fullApiName, new List<Map<String, Object>>());
        typeMeta.put(
          fullApiName,
          new Map<String, Object>{
            'label' => getRowValueDefault(
              row,
              'label',
              apiName.replace('__mdt', '').replace('_', ' ')
            ),
            'pluralLabel' => getRowValueDefault(
              row,
              'pluralLabel',
              apiName.replace('__mdt', '').replace('_', ' ') + 's'
            ),
            'description' => getRowValue(row, 'description'),
            'visibility' => getRowValueDefault(row, 'visibility', 'Public')
          }
        );
      }

      if (String.isNotBlank(getRowValue(row, 'fieldName'))) {
        byApiName.get(fullApiName).add(row);
      }
    }

    if (byApiName.isEmpty()) {
      throw new CsvException(
        'No valid custom metadata type rows. Required columns: apiName, fieldName, fieldLabel, fieldType'
      );
    }

    Integer count = 0;
    for (String fullApiName : byApiName.keySet()) {
      Map<String, Object> meta = typeMeta.get(fullApiName);

      // Step 1 — create type ONLY if it doesn't exist in org
      Boolean typeExists = false;
      try {
        String query =
          'SELECT QualifiedApiName FROM EntityDefinition ' +
          'WHERE QualifiedApiName = \'' +
          fullApiName +
          '\'';
        String endpoint =
          'https://' +
          DomainCreator.getOrgMyDomainHostname() +
          '/services/data/v61.0/query?q=' +
          EncodingUtil.urlEncode(query, 'UTF-8');
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setTimeout(15000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 200) {
          Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            res.getBody()
          );
          typeExists = ((Integer) resp.get('totalSize')) > 0;
        }
      } catch (Exception e) {
        System.debug(
          'CsvProcessor: could not check type existence: ' + e.getMessage()
        );
      }

      if (!typeExists) {
        Map<String, Object> createArgs = new Map<String, Object>{
          'apiName' => fullApiName,
          'label' => (String) meta.get('label'),
          'pluralLabel' => (String) meta.get('pluralLabel'),
          'visibility' => (String) meta.get('visibility')
        };
        if (String.isNotBlank((String) meta.get('description'))) {
          createArgs.put('description', (String) meta.get('description'));
        }
        CustomMetadataHelper.createCustomMetadataType(createArgs);
        System.debug(
          'CsvProcessor: created NEW metadata type [' + fullApiName + ']'
        );
      } else {
        System.debug(
          'CsvProcessor: type [' +
            fullApiName +
            '] already exists — adding fields only'
        );
      }

      // Step 2 — add each field
      for (Map<String, Object> row : byApiName.get(fullApiName)) {
        Map<String, Object> fieldArgs = new Map<String, Object>{
          'apiName' => fullApiName,
          'fieldName' => getRowValue(row, 'fieldName'),
          'fieldLabel' => getRowValue(row, 'fieldLabel'),
          'fieldType' => normalizeCmtFieldType(getRowValue(row, 'fieldType')),
          'length' => getRowValue(row, 'length'),
          'precision' => getRowValue(row, 'precision'),
          'scale' => getRowValue(row, 'scale'),
          'required' => getRowValue(row, 'required'),
          'picklistValues' => getRowValue(row, 'picklistValues'),
          'defaultValue' => getRowValue(row, 'defaultValue')
        };
        CustomMetadataHelper.addFieldToCustomMetadataType(fieldArgs);
        System.debug(
          'CsvProcessor: staged field [' +
            fullApiName +
            '.' +
            getRowValue(row, 'fieldName') +
            ']'
        );
        count++;
      }
    }

    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: PUBLIC GROUP MEMBERS
  // Columns: groupDeveloperName, username
  // Queries Group + User records in bulk, checks existing membership,
  // then queues net-new GroupMember records into FunctionHelper.recordsToInsert.
  // ─────────────────────────────────────────────────────────────
  private static Integer processGroupMembers(List<Object> rawRows) {
    Set<String> groupDevNames = new Set<String>();
    Set<String> usernames = new Set<String>();

    List<Map<String, String>> memberRows = new List<Map<String, String>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String groupDeveloperName = getRowValue(row, 'groupDeveloperName');
      String username = getRowValue(row, 'username');

      if (String.isBlank(groupDeveloperName) || String.isBlank(username)) {
        System.debug(
          'CsvProcessor: skipping incomplete group member row: ' + row
        );
        continue;
      }

      groupDevNames.add(groupDeveloperName);
      usernames.add(username);
      memberRows.add(
        new Map<String, String>{
          'groupDeveloperName' => groupDeveloperName,
          'username' => username
        }
      );
    }

    if (memberRows.isEmpty()) {
      throw new CsvException(
        'No valid group member rows. Required columns: groupDeveloperName, username'
      );
    }

    // ── Bulk-query all referenced groups ──────────────────────
    Map<String, Id> groupIdByDevName = new Map<String, Id>();
    for (Group g : [
      SELECT Id, DeveloperName
      FROM Group
      WHERE DeveloperName IN :groupDevNames AND Type = 'Regular'
    ]) {
      groupIdByDevName.put(g.DeveloperName, g.Id);
    }

    // ── Bulk-query all referenced users ───────────────────────
    Map<String, Id> userIdByUsername = new Map<String, Id>();
    for (User u : [
      SELECT Id, Username
      FROM User
      WHERE Username IN :usernames AND IsActive = TRUE
    ]) {
      userIdByUsername.put(u.Username, u.Id);
    }

    // ── Fetch existing memberships to skip duplicates ─────────
    Set<String> existingKeys = new Set<String>();
    if (!groupIdByDevName.isEmpty() && !userIdByUsername.isEmpty()) {
      for (GroupMember gm : [
        SELECT GroupId, UserOrGroupId
        FROM GroupMember
        WHERE
          GroupId IN :groupIdByDevName.values()
          AND UserOrGroupId IN :userIdByUsername.values()
      ]) {
        existingKeys.add(
          String.valueOf(gm.GroupId) + '_' + String.valueOf(gm.UserOrGroupId)
        );
      }
    }

    // ── Build net-new GroupMember records ─────────────────────
    Integer skipped = 0;
    Integer queued = 0;

    for (Map<String, String> row : memberRows) {
      String devName = row.get('groupDeveloperName');
      String username = row.get('username');

      Id groupId = groupIdByDevName.get(devName);
      Id userId = userIdByUsername.get(username);

      if (groupId == null) {
        System.debug(
          'CsvProcessor: public group not found [' +
            devName +
            '] — skipping row'
        );
        skipped++;
        continue;
      }
      if (userId == null) {
        System.debug(
          'CsvProcessor: active user not found [' +
            username +
            '] — skipping row'
        );
        skipped++;
        continue;
      }

      String key = String.valueOf(groupId) + '_' + String.valueOf(userId);
      if (existingKeys.contains(key)) {
        System.debug(
          'CsvProcessor: [' +
            username +
            '] already member of [' +
            devName +
            '] — skipping'
        );
        skipped++;
        continue;
      }

      GroupMember gm = new GroupMember();
      gm.GroupId = groupId;
      gm.UserOrGroupId = userId;
      FunctionHelper.recordsToInsert.add(gm);

      existingKeys.add(key); // guard against duplicate rows in the same CSV
      queued++;
    }

    System.debug(
      'CsvProcessor: queued ' +
        queued +
        ' GroupMember record(s), skipped ' +
        skipped
    );

    if (queued == 0 && skipped > 0) {
      System.debug(
        'CsvProcessor: all rows were skipped — groups/users not found or already members'
      );
    }

    return queued;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: CUSTOM METADATA RECORDS
  // Columns: apiName, recordName, label, [any field columns]
  // ─────────────────────────────────────────────────────────────
  private static Integer processCustomMetadataRecords(List<Object> rawRows) {
    Integer count = 0;
    Set<String> reservedColumns = new Set<String>{
      'apiname',
      'recordname',
      'label',
      'protected'
    };

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String apiName = getRowValue(row, 'apiName');
      String recordName = getRowValue(row, 'recordName');
      String label = getRowValueDefault(row, 'label', recordName);

      if (String.isBlank(apiName) || String.isBlank(recordName)) {
        System.debug('CsvProcessor: skipping incomplete metadata row: ' + row);
        continue;
      }

      String fullApiName = apiName.endsWith('__mdt')
        ? apiName
        : apiName + '__mdt';
      String cleanRecord = recordName.replaceAll('[^a-zA-Z0-9_]', '_');
      Boolean isProtected =
        getRowValueDefault(row, 'protected', 'false') == 'true';

      Map<String, String> fieldValues = new Map<String, String>();
      for (String col : row.keySet()) {
        if (!reservedColumns.contains(col.toLowerCase())) {
          String val = getRowValue(row, col);
          if (String.isNotBlank(val))
            fieldValues.put(col, val);
        }
      }

      String memberName = fullApiName + '.' + cleanRecord;
      ZipBuilder.addFile(
        'CustomMetadata',
        memberName,
        'customMetadata/' + memberName + '.md',
        buildCustomMetadataRecordXml(label, fieldValues, isProtected)
      );

      System.debug('CsvProcessor: staged metadata record [' + memberName + ']');
      count++;
    }

    if (count == 0) {
      throw new CsvException(
        'No valid custom metadata rows. Required columns: apiName, recordName'
      );
    }
    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: VALIDATION RULES
  // Columns: objectName, ruleName, errorConditionFormula, errorMessage
  // ─────────────────────────────────────────────────────────────
  private static Integer processValidationRules(List<Object> rawRows) {
    Map<String, List<Map<String, String>>> byObject = new Map<String, List<Map<String, String>>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String objectName = getRowValue(row, 'objectName');
      String ruleName = getRowValue(row, 'ruleName');
      String formula = getRowValue(row, 'errorConditionFormula');
      String errorMsg = getRowValue(row, 'errorMessage');

      if (
        String.isBlank(objectName) ||
        String.isBlank(ruleName) ||
        String.isBlank(formula) ||
        String.isBlank(errorMsg)
      ) {
        System.debug(
          'CsvProcessor: skipping incomplete validation rule row: ' + row
        );
        continue;
      }

      if (!byObject.containsKey(objectName))
        byObject.put(objectName, new List<Map<String, String>>());
      byObject.get(objectName)
        .add(
          new Map<String, String>{
            'ruleName' => ruleName,
            'errorConditionFormula' => formula,
            'errorMessage' => errorMsg,
            'description' => getRowValueDefault(row, 'description', ''),
            'active' => getRowValueDefault(row, 'active', 'true')
          }
        );
    }

    if (byObject.isEmpty()) {
      throw new CsvException(
        'No valid validation rule rows. Required columns: objectName, ruleName, errorConditionFormula, errorMessage'
      );
    }

    Integer count = 0;
    for (String objectName : byObject.keySet()) {
      List<Map<String, String>> rules = byObject.get(objectName);
      ZipBuilder.addFile(
        'CustomObject',
        objectName,
        'objects/' + objectName + '.object-meta.xml',
        buildValidationRulesXml(objectName, rules)
      );
      System.debug(
        'CsvProcessor: staged ' +
          rules.size() +
          ' validation rule(s) for [' +
          objectName +
          ']'
      );
      count += rules.size();
    }
    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: CUSTOM SETTINGS (create setting + fields together)
  // Columns: apiName, label, settingType, fieldName, fieldLabel, fieldType
  // Optional: description, length, precision, scale, required
  // One row per field — setting info repeated across rows for same apiName
  // ─────────────────────────────────────────────────────────────

  private static Integer processCustomSettings(List<Object> rawRows) {
    Map<String, List<Map<String, Object>>> byApiName = new Map<String, List<Map<String, Object>>>();
    Map<String, Map<String, Object>> settingMeta = new Map<String, Map<String, Object>>();

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String apiName = getRowValue(row, 'apiName');
      if (String.isBlank(apiName)) {
        System.debug('CsvProcessor: skipping row with blank apiName: ' + row);
        continue;
      }

      // Capture setting-level meta from first row for this apiName
      if (!byApiName.containsKey(apiName)) {
        byApiName.put(apiName, new List<Map<String, Object>>());
        settingMeta.put(
          apiName,
          new Map<String, Object>{
            'label' => getRowValueDefault(
              row,
              'label',
              apiName.replace('__c', '').replace('_', ' ')
            ),
            'type' => getRowValueDefault(row, 'settingType', 'Hierarchy'),
            'description' => getRowValue(row, 'description')
          }
        );
      }

      // Only add row if it has field info
      if (String.isNotBlank(getRowValue(row, 'fieldName'))) {
        byApiName.get(apiName).add(row);
      }
    }

    if (byApiName.isEmpty()) {
      throw new CsvException(
        'No valid custom setting rows. Required columns: apiName, fieldName, fieldLabel, fieldType'
      );
    }

    Integer count = 0;
    for (String apiName : byApiName.keySet()) {
      Map<String, Object> meta = settingMeta.get(apiName);

      // Step 1 — create the setting shell ONLY if it doesn't exist in org
      Boolean settingExists = Schema.getGlobalDescribe()
        .containsKey(apiName.toLowerCase());

      if (!settingExists) {
        Map<String, Object> createArgs = new Map<String, Object>{
          'apiName' => apiName,
          'label' => (String) meta.get('label'),
          'type' => (String) meta.get('type')
        };
        if (String.isNotBlank((String) meta.get('description'))) {
          createArgs.put('description', (String) meta.get('description'));
        }
        CustomSettingHelper.createCustomSetting(createArgs);
        System.debug(
          'CsvProcessor: created NEW setting shell [' + apiName + ']'
        );
      } else {
        System.debug(
          'CsvProcessor: setting [' +
            apiName +
            '] already exists — skipping create, adding fields only'
        );
      }

      // Step 2 — add each field (either way)
      for (Map<String, Object> row : byApiName.get(apiName)) {
        Map<String, Object> fieldArgs = new Map<String, Object>{
          'apiName' => apiName,
          'fieldName' => getRowValue(row, 'fieldName'),
          'fieldLabel' => getRowValue(row, 'fieldLabel'),
          'fieldType' => getRowValue(row, 'fieldType'),
          'length' => getRowValue(row, 'length'),
          'precision' => getRowValue(row, 'precision'),
          'scale' => getRowValue(row, 'scale'),
          'required' => getRowValue(row, 'required')
        };
        CustomSettingHelper.addFieldToCustomSetting(fieldArgs);
        System.debug(
          'CsvProcessor: staged field [' +
            apiName +
            '.' +
            getRowValue(row, 'fieldName') +
            ']'
        );
        count++;
      }
    }

    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // HANDLER: CUSTOM SETTING FIELDS
  // Delegates to CustomSettingHelper — reads label + type from org,
  // preserves existing fields, builds correct XML with all required tags.
  // ─────────────────────────────────────────────────────────────
  private static Integer processCustomSettingFields(List<Object> rawRows) {
    Integer count = 0;

    for (Object raw : rawRows) {
      Map<String, Object> row = (Map<String, Object>) raw;
      String apiName = getRowValue(row, 'apiName');
      String fieldName = getRowValue(row, 'fieldName');
      String fieldLabel = getRowValue(row, 'fieldLabel');
      String fieldType = getRowValue(row, 'fieldType');

      if (
        String.isBlank(apiName) ||
        String.isBlank(fieldName) ||
        String.isBlank(fieldLabel) ||
        String.isBlank(fieldType)
      ) {
        System.debug(
          'CsvProcessor: skipping incomplete custom setting field row: ' + row
        );
        continue;
      }

      // Build args map matching what CustomSettingHelper.addFieldToCustomSetting() expects
      Map<String, Object> args = new Map<String, Object>{
        'apiName' => apiName,
        'fieldName' => fieldName,
        'fieldLabel' => fieldLabel,
        'fieldType' => fieldType,
        'length' => getRowValue(row, 'length'),
        'precision' => getRowValue(row, 'precision'),
        'scale' => getRowValue(row, 'scale'),
        'required' => getRowValue(row, 'required')
      };

      CustomSettingHelper.addFieldToCustomSetting(args);
      System.debug(
        'CsvProcessor: delegated field [' +
          apiName +
          '.' +
          fieldName +
          '] to CustomSettingHelper'
      );
      count++;
    }

    if (count == 0) {
      throw new CsvException(
        'No valid custom setting field rows. Required columns: apiName, fieldName, fieldLabel, fieldType'
      );
    }

    return count;
  }

  // ─────────────────────────────────────────────────────────────
  // XML BUILDERS
  // ─────────────────────────────────────────────────────────────

  // Correct Salesforce Translations XML: <n> = API name, <label> = translation
  private static String buildTranslationXml(Map<String, String> labelMap) {
    String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
    xml += '<Translations xmlns="http://soap.sforce.com/2006/04/metadata">\n';
    for (String labelName : labelMap.keySet()) {
      xml += '    <customLabels>\n';
      xml += '        <name>' + escapeXml(labelName) + '</name>\n';
      xml +=
        '        <label>' +
        escapeXml(labelMap.get(labelName)) +
        '</label>\n';
      xml += '    </customLabels>\n';
    }
    xml += '</Translations>';
    return xml;
  }

  // Correct element order: fullName → language → protected → shortDescription → value
  private static String buildCustomLabelsXml(
    List<Map<String, String>> labels,
    String existingXml
  ) {
    String fileXml = existingXml;
    if (fileXml != null) {
      for (Map<String, String> lbl : labels) {
        String fullNameTag = '<fullName>' + lbl.get('name') + '</fullName>';
        if (fileXml.contains(fullNameTag)) {
          Integer fnIdx = fileXml.indexOf(fullNameTag);
          Integer blockStart = fileXml.lastIndexOf('<labels>', fnIdx);
          Integer blockEnd =
            fileXml.indexOf('</labels>', fnIdx) + '</labels>'.length();
          if (blockStart >= 0 && blockEnd > '</labels>'.length()) {
            fileXml =
              fileXml.substring(0, blockStart) + fileXml.substring(blockEnd);
          }
        }
      }
      String blocks = '';
      for (Map<String, String> lbl : labels) {
        blocks += buildLabelBlock(lbl);
      }
      fileXml = fileXml.replace('</CustomLabels>', blocks + '</CustomLabels>');
    } else {
      String blocks = '';
      for (Map<String, String> lbl : labels) {
        blocks += buildLabelBlock(lbl);
      }
      fileXml =
        '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<CustomLabels xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
        blocks +
        '</CustomLabels>';
    }
    return fileXml;
  }

  private static String buildLabelBlock(Map<String, String> lbl) {
    String xml = '    <labels>\n';
    xml += '        <fullName>' + escapeXml(lbl.get('name')) + '</fullName>\n';
    xml +=
      '        <language>' +
      escapeXml(lbl.get('language')) +
      '</language>\n';
    xml += '        <protected>' + lbl.get('protected') + '</protected>\n';
    xml +=
      '        <shortDescription>' +
      escapeXml(lbl.get('shortDescription')) +
      '</shortDescription>\n';
    xml += '        <value>' + escapeXml(lbl.get('value')) + '</value>\n';
    xml += '    </labels>\n';
    return xml;
  }

  private static String buildCustomMetadataRecordXml(
    String label,
    Map<String, String> fieldValues,
    Boolean isProtected
  ) {
    String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
    xml +=
      '<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"' +
      ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"' +
      ' xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n';
    xml += '    <label>' + escapeXml(label) + '</label>\n';
    xml += '    <protected>' + isProtected + '</protected>\n';
    for (String fieldApi : fieldValues.keySet()) {
      String val = fieldValues.get(fieldApi);
      String xsiType = getXsiTypeForValue(fieldApi, val);
      xml += '    <values>\n';
      xml += '        <field>' + escapeXml(fieldApi) + '</field>\n';
      xml +=
        '        <value xsi:type="' +
        xsiType +
        '">' +
        escapeXml(val) +
        '</value>\n';
      xml += '    </values>\n';
    }
    xml += '</CustomMetadata>';
    return xml;
  }

  private static String getXsiTypeForValue(String fieldApiName, String val) {
    // Detect by field name suffix or value pattern
    //String lower = fieldApiName.toLowerCase();

    // Checkbox fields — value is true/false
    if (
      val != null &&
      (val.toLowerCase() == 'true' ||
      val.toLowerCase() == 'false')
    ) {
      return 'xsd:boolean';
    }

    // Number fields — pure numeric value
    if (val != null && val.isNumeric()) {
      return 'xsd:double';
    }

    // Default — string
    return 'xsd:string';
  }

  private static String buildValidationRulesXml(
    String objectName,
    List<Map<String, String>> rules
  ) {
    String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
    xml += '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n';
    for (Map<String, String> rule : rules) {
      xml += '    <validationRules>\n';
      xml +=
        '        <fullName>' +
        escapeXml(rule.get('ruleName')) +
        '</fullName>\n';
      xml += '        <active>' + rule.get('active') + '</active>\n';
      xml +=
        '        <errorConditionFormula>' +
        escapeXml(rule.get('errorConditionFormula')) +
        '</errorConditionFormula>\n';
      xml +=
        '        <errorMessage>' +
        escapeXml(rule.get('errorMessage')) +
        '</errorMessage>\n';
      if (String.isNotBlank(rule.get('description'))) {
        xml +=
          '        <description>' +
          escapeXml(rule.get('description')) +
          '</description>\n';
      }
      xml += '    </validationRules>\n';
    }
    xml += '</CustomObject>';
    return xml;
  }

  // private static String buildCustomSettingFieldsXml(String settingName, List<Map<String, String>> fields) {
  //     String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
  //     xml += '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n';
  //     for (Map<String, String> field : fields) {
  //         String fieldName = field.get('fieldName');
  //         if (!fieldName.endsWith('__c')) fieldName += '__c';
  //         String fieldType = field.get('fieldType');
  //         xml += '    <fields>\n';
  //         xml += '        <fullName>' + escapeXml(fieldName)               + '</fullName>\n';
  //         xml += '        <label>'    + escapeXml(field.get('fieldLabel'))  + '</label>\n';
  //         xml += '        <type>'     + escapeXml(fieldType)               + '</type>\n';
  //         if (fieldType == 'Checkbox') {
  //             xml += '        <defaultValue>false</defaultValue>\n';
  //         } else {
  //             xml += '        <required>' + field.get('required') + '</required>\n';
  //             if (fieldType == 'Text' || fieldType == 'TextArea') {
  //                 xml += '        <length>'    + field.get('length')    + '</length>\n';
  //             } else if (fieldType == 'Number' || fieldType == 'Currency' || fieldType == 'Percent') {
  //                 xml += '        <precision>' + field.get('precision') + '</precision>\n';
  //                 xml += '        <scale>'     + field.get('scale')     + '</scale>\n';
  //             }
  //         }
  //         xml += '    </fields>\n';
  //     }
  //     xml += '</CustomObject>';
  //     return xml;
  // }

  // ─────────────────────────────────────────────────────────────
  // PARSE EXISTING TRANSLATION XML (for merging)
  // ─────────────────────────────────────────────────────────────
  private static Map<String, String> parseExistingTranslationXml(String xml) {
    Map<String, String> result = new Map<String, String>();
    if (String.isBlank(xml)) {
      return result;
    }
    Integer searchFrom = 0;
    while (true) {
      Integer blockStart = xml.indexOf('<customLabels>', searchFrom);
      if (blockStart == -1) {
        break;
      }
      Integer blockEnd = xml.indexOf('</customLabels>', blockStart);
      if (blockEnd == -1) {
        break;
      }
      String block = xml.substring(blockStart, blockEnd);
      Integer nameStart = block.indexOf('<name>') + '<name>'.length();
      Integer nameEnd = block.indexOf('</name>');
      Integer lblStart = block.indexOf('<label>') + '<label>'.length();
      Integer lblEnd = block.indexOf('</label>');
      if (
        nameStart > 5 &&
        nameEnd > nameStart &&
        lblStart > 6 &&
        lblEnd > lblStart
      ) {
        result.put(
          block.substring(nameStart, nameEnd).trim(),
          block.substring(lblStart, lblEnd).trim()
        );
      }
      searchFrom = blockEnd + '</customLabels>'.length();
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // INNER CLASS — CSV parse result
  // ─────────────────────────────────────────────────────────────
  private class ParseResult {
    public List<String> columns;
    public List<Map<String, Object>> rows;
    public ParseResult(List<String> columns, List<Map<String, Object>> rows) {
      this.columns = columns;
      this.rows = rows;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — CSV PARSER
  // ─────────────────────────────────────────────────────────────
  private static ParseResult parseCsv(
    String csvText,
    String fileName,
    String delimiter
  ) {
    csvText = csvText.replace('\r\n', '\n').replace('\r', '\n').trim();
    if (String.isBlank(csvText)) {
      throw new CsvException('CSV file [' + fileName + '] is empty.');
    }

    List<String> lines = csvText.split('\n');
    if (lines.isEmpty()) {
      throw new CsvException('CSV file [' + fileName + '] has no lines.');
    }

    // Parse headers
    List<String> rawCols = splitCsvLine(lines[0], delimiter);
    List<String> cleanCols = new List<String>();
    for (String col : rawCols) {
      String c = col.trim()
        .replace('\uFEFF', '')
        .replace('\u00EF\u00BB\u00BF', '')
        .trim();
      if (String.isNotBlank(c) && cleanCols.size() < MAX_COLUMNS) {
        cleanCols.add(c);
      }
    }
    if (cleanCols.isEmpty()) {
      throw new CsvException(
        'CSV file [' + fileName + '] has no valid column headers.'
      );
    }

    System.debug('CsvProcessor.parseCsv(): columns=' + cleanCols);

    // Parse rows
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    Integer skipped = 0;
    for (Integer i = 1; i < lines.size(); i++) {
      String line = lines[i].trim();
      if (String.isBlank(line)) {
        skipped++;
        continue;
      }
      if (rows.size() >= MAX_ROWS) {
        break;
      }
      List<String> values = splitCsvLine(line, delimiter);
      Map<String, Object> row = new Map<String, Object>();
      for (Integer c = 0; c < cleanCols.size(); c++) {
        row.put(cleanCols[c], c < values.size() ? values[c].trim() : '');
      }
      rows.add(row);
    }

    System.debug(
      'CsvProcessor.parseCsv(): parsed ' +
        rows.size() +
        ' rows, skipped ' +
        skipped +
        ' blank lines'
    );
    return new ParseResult(cleanCols, rows);
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Split a single CSV line respecting quoted fields
  // ─────────────────────────────────────────────────────────────
  private static List<String> splitCsvLine(String line, String delimiter) {
    List<String> result = new List<String>();
    if (String.isBlank(line)) {
      return result;
    }

    if (!line.contains('"')) {
      if (delimiter == ',') {
        for (String v : line.split(',', -1)) {
          result.add(v);
        }
      } else {
        for (String v : line.split(';', -1)) {
          result.add(v);
        }
      }
      return result;
    }

    Boolean inQuotes = false;
    String curr = '';
    Integer idx = 0;
    while (idx < line.length()) {
      String ch = line.substring(idx, idx + 1);
      if (ch == '"') {
        if (
          inQuotes &&
          idx + 1 < line.length() &&
          line.substring(idx + 1, idx + 2) == '"'
        ) {
          curr += '"';
          idx += 2;
        } else {
          inQuotes = !inQuotes;
          idx++;
        }
      } else if (ch == delimiter && !inQuotes) {
        result.add(curr);
        curr = '';
        idx++;
      } else {
        curr += ch;
        idx++;
      }
    }
    result.add(curr);
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Helpers
  // ─────────────────────────────────────────────────────────────
  private static String escapeXml(String val) {
    if (String.isBlank(val))
      return '';
    return val.replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
      .replace('"', '&quot;')
      .replace('\'', '&apos;');
  }

  private static String getRowValue(Map<String, Object> row, String key) {
    Object val = row.get(key);
    if (val == null) {
      for (String k : row.keySet()) {
        if (k.equalsIgnoreCase(key)) {
          val = row.get(k);
          break;
        }
      }
    }
    return val != null ? String.valueOf(val).trim() : '';
  }

  private static String getRowValueDefault(
    Map<String, Object> row,
    String key,
    String defaultVal
  ) {
    String val = getRowValue(row, key);
    return String.isBlank(val) ? defaultVal : val;
  }

  private static String getRequiredArg(Map<String, Object> args, String key) {
    Object val = args?.get(key);
    if (val == null || String.isBlank(String.valueOf(val))) {
      throw new CsvException('Required parameter missing: ' + key);
    }
    return String.valueOf(val).trim();
  }

  private static String getOptionalArg(
    Map<String, Object> args,
    String key,
    String defaultValue
  ) {
    Object val = args?.get(key);
    if (val == null) {
      return defaultValue;
    }
    String strVal = String.valueOf(val).trim();
    return (String.isBlank(strVal) || strVal == 'null') ? defaultValue : strVal;
  }

  // Normalizes a raw field type string to the exact enum value expected by the
  // Metadata API for Custom Metadata Type fields.
  // Fixes: case variants (URL→Url), unsupported types (Currency→Number).
  private static String normalizeCmtFieldType(String raw) {
    if (String.isBlank(raw)) {
      return 'Text';
    }
    String t = raw.trim();

    // Exact-match map: key = lowercase input, value = correct API enum value
    Map<String, String> cmtTypeMap = new Map<String, String>{
      'text' => 'Text',
      'string' => 'Text',
      'textarea' => 'TextArea',
      'longtextarea' => 'LongTextArea',
      'long text area' => 'LongTextArea',
      'richtext' => 'Html',
      'html' => 'Html',
      'checkbox' => 'Checkbox',
      'boolean' => 'Checkbox',
      'date' => 'Date',
      'datetime' => 'DateTime',
      'date/time' => 'DateTime',
      'number' => 'Number',
      'decimal' => 'Number',
      'double' => 'Number',
      'integer' => 'Number',
      'int' => 'Number',
      'currency' => 'Number',
      'percent' => 'Percent',
      'email' => 'Email',
      'phone' => 'Phone',
      'url' => 'Url',
      'picklist' => 'Picklist',
      'multipicklist' => 'Picklist',
      'multiselectpicklist' => 'Picklist',
      'lookup' => 'Lookup',
      'metadatarelationship' => 'MetadataRelationship'
    };

    String mapped = cmtTypeMap.get(t.toLowerCase());
    if (mapped != null) {
      return mapped;
    }

    // Unknown type — return as-is and let the API report the error
    System.debug(
      'CsvProcessor.normalizeCmtFieldType: unknown type [' +
        t +
        '] — passing through'
    );
    return t;
  }

  public class CsvException extends Exception {
  }
}
