/**
 * PermissionSetHelper.cls
 *
 * Performs Salesforce Permission Set operations.
 * Follows the exact same pattern as MetadataHelper.
 *
 * WHAT IS A PERMISSION SET?
 * A Permission Set grants additional access to users on top of their profile.
 * e.g. "Sales Team" permission set can give read/edit access to Reservation__c
 *
 * HOW IT WORKS:
 * 1. Build a MetadataService.PermissionSet object
 * 2. Add objectPermissions / fieldPermissions to it
 * 3. Pass it to port.upsertMetadata()
 * 4. MetadataPort sends it to Salesforce as SOAP
 */
public class PermissionSetHelper {
  // NOTE:
  // In the LLMService XML-generation flow, this helper is clone-only:
  // - The clone flow (resolveSourcePermissionSetApiName/startCloneRetrieve
  //   + PermissionSetClonePoller) is used for permission set cloning.
  // - Create/update/delete are generated as PermissionSet XML in files[]
  //   and deployed via ZipBuilder/metadata deploy.
  // Existing non-clone methods remain for legacy/manual tool paths.

  // Same gating pattern as StaticResourceHelper.pendingToolingOps: a
  // PermissionSetClonePoller enqueue is genuinely async — it hasn't run
  // yet by the time LLMService reaches its sync-result Jira post, so that
  // post must not claim success/error for a clone that's still in
  // progress. Reset per ticket in LLMService.processJiraTicket, same as
  // StaticResourceHelper.pendingToolingOps.
  public static Integer pendingCloneOps = 0;

  // ─────────────────────────────────────────────────────────────
  // PORT — same MetadataPort the rest of the system uses
  // ─────────────────────────────────────────────────────────────
  private static MetadataPort port {
    get {
      if (port == null) {
        System.debug('PermissionSetHelper: initializing MetadataPort...');
        port = new MetadataPort();
        port.endpoint_x =
          'https://' +
          DomainCreator.getOrgMyDomainHostname() +
          '/services/Soap/m/61.0';
        port.SessionHeader = new MetadataService.SessionHeader_element();
        port.SessionHeader.sessionId = UserInfo.getSessionId();
        // See CustomMetadataHelper.port for why this is set explicitly.
        port.timeout_x = 120000;
        System.debug('PermissionSetHelper: MetadataPort ready.');
      }
      return port;
    }
    set;
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — CLONE
  //
  // Uses SOAP Metadata API port.retrieve() to get the full deployed
  // ZIP of the source PS, then extracts and reuses its raw XML.
  //
  // Why not readMetadata (SOAP)?
  // readMetadata silently returns empty objectPermissions/fieldPermissions
  // for permission sets deployed via ZIP. port.retrieve() returns the
  // actual deployed XML file with all permissions intact.
  // ─────────────────────────────────────────────────────────────
  // ASYNC REWRITE (2026-09-28): this used to run the whole clone —
  // resolve, retrieve, POLL SYNCHRONOUSLY, extract, patch — inline during
  // STAGE 2, staging straight into ZIP1. The synchronous poll was a tight
  // loop with no real delay between attempts (Apex has no sleep); even
  // raised to 30 attempts it still timed out under real load (confirmed:
  // QATEST-PS2 and a direct isolated retry both timed out). This is the
  // exact same class of problem FlexiPagePlacementPoller's doc comment
  // already documents for page-placement retrieves, and it needs the same
  // fix: start the retrieve with one quick callout, then hand off waiting
  // for it to an async poller (PermissionSetClonePoller) that gets real
  // elapsed time across enqueueJob/System.schedule hops. The clone now
  // deploys as its OWN small follow-up ZIP once the poller's retrieve
  // actually completes — mirroring exactly how FlexiPagePlacementPoller
  // hands its own finished retrieve off to ZipDeployQueueable.forZip2().
  //
  // Call sequence for a caller (see LLMResponseProcessor's
  // 'permissionSetClone' dmlOperation handling):
  //   1. resolveSourcePermissionSetApiName(sourceName) — fails fast,
  //      synchronously, before spending an async round-trip on a typo'd
  //      source name.
  //   2. startCloneRetrieve(sourceApiName) — one quick callout, returns
  //      asyncId.
  //   3. Enqueue a PermissionSetClonePoller with that asyncId and the
  //      clone's target params (newApiName/newLabel/description/
  //      objectPermissionOverrides).

  // ── STEP 1: Resolve + verify the source PS exists, via SOQL ──
  public static String resolveSourcePermissionSetApiName(String sourceName) {
    // Salesforce Permission Set API names never have spaces — the label
    // might have spaces but the API name passed here should already be
    // the API name (e.g. Car_Manager).
    String candidateApiName = sourceName.replace(' ', '_');

    List<PermissionSet> sourcePsList = [
      SELECT Id, Name, Label
      FROM PermissionSet
      WHERE Name = :candidateApiName AND IsOwnedByProfile = FALSE
      LIMIT 1
    ];
    if (sourcePsList.isEmpty()) {
      // Try original name too in case caller passed label
      sourcePsList = [
        SELECT Id, Name, Label
        FROM PermissionSet
        WHERE Label = :sourceName AND IsOwnedByProfile = FALSE
        LIMIT 1
      ];
    }
    if (sourcePsList.isEmpty()) {
      throw new PermissionSetException(
        'Source permission set not found: ' + sourceName
      );
    }
    // Always use the actual API Name for retrieve — never the label
    String resolvedApiName = sourcePsList[0].Name;
    System.debug(
      'PermissionSetHelper.resolveSourcePermissionSetApiName(): [' +
        sourceName +
        '] -> [' +
        resolvedApiName +
        ']'
    );
    return resolvedApiName;
  }

  // ── STEP 2: Start the async retrieve — one quick callout, no polling ──
  public static String startCloneRetrieve(String sourceApiName) {
    MetadataService.RetrieveRequest retrieveRequest = new MetadataService.RetrieveRequest();
    retrieveRequest.apiVersion = 61.0;
    retrieveRequest.singlePackage = true;
    MetadataService.PackageTypeMembers ptm = new MetadataService.PackageTypeMembers();
    ptm.name = 'PermissionSet';
    ptm.members = new List<String>{ sourceApiName };
    MetadataService.Package_x pkg = new MetadataService.Package_x();
    pkg.types = new List<MetadataService.PackageTypeMembers>{ ptm };
    pkg.version = '61.0';
    retrieveRequest.unpackaged = pkg;

    MetadataService.AsyncResult asyncResult = port.retrieve(retrieveRequest);
    System.debug(
      'PermissionSetHelper.startCloneRetrieve(): [' +
        sourceApiName +
        '] retrieve started, asyncId=' +
        asyncResult.id
    );
    return asyncResult.id;
  }

  // ── STEP 3 (poller's job, not this class's) — thin status-check wrapper
  // so PermissionSetClonePoller doesn't need direct access to `port`. ──
  public static MetadataService.RetrieveResult checkCloneRetrieveStatus(
    String asyncId
  ) {
    return port.checkRetrieveStatus(asyncId, true);
  }

  // ── STEP 4 + 5 + 5b: extract, swap label/description, sanitize, apply
  // overrides — called by PermissionSetClonePoller once its retrieve is
  // actually done. Returns the final XML; does NOT touch ZipBuilder —
  // the caller decides how/when to stage and deploy it. ──
  public static String buildClonedPermissionSetXml(
    String sourceApiName,
    String zipBase64,
    String newApiName,
    String newLabel,
    String description,
    List<Object> objectPermissionOverrides
  ) {
    Blob zipBlob = EncodingUtil.base64Decode(zipBase64);

    // SOAP retrieve returns old-style format: Car_Manager.permissionset (no -meta.xml suffix)
    String sourceXml = ZipBuilder.extractFileFromZip(
      zipBlob,
      'permissionsets/' + sourceApiName + '.permissionset'
    );

    // Fallback: try DX-style suffix just in case
    if (String.isBlank(sourceXml)) {
      sourceXml = ZipBuilder.extractFileFromZip(
        zipBlob,
        'permissionsets/' + sourceApiName + '.permissionset-meta.xml'
      );
    }

    if (String.isBlank(sourceXml)) {
      throw new PermissionSetException(
        'Could not extract permission set XML from retrieve ZIP for: ' +
          sourceApiName +
          '. Check debug logs for ZIP contents.'
      );
    }
    System.debug(
      'PermissionSetHelper.buildClonedPermissionSetXml(): source XML extracted, length=' +
      sourceXml.length()
    );

    String effectiveDesc = String.isNotBlank(description)
      ? description
      : 'Cloned from ' + sourceApiName + '.';

    String xml = sourceXml;

    // Replace <label> — required field, must be present
    if (xml.contains('<label>')) {
      xml = xml.replaceAll(
        '<label>[^<]*</label>',
        '<label>' + escapeXml(newLabel) + '</label>'
      );
    } else {
      // Inject label right after the opening <PermissionSet> tag
      xml = xml.replace(
        '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">',
        '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">' +
          '<label>' +
          escapeXml(newLabel) +
          '</label>'
      );
    }

    // Replace or inject <description>
    if (xml.contains('<description>')) {
      xml = xml.replaceAll(
        '<description>[^<]*</description>',
        '<description>' + escapeXml(effectiveDesc) + '</description>'
      );
    } else {
      xml = xml.replace(
        '</label>',
        '</label><description>' + escapeXml(effectiveDesc) + '</description>'
      );
    }

    // Strip fieldPermissions on non-deployable compound-address sub-fields
    // (e.g. BillingPostalCode) — retrieve() returns them but deployMetadata
    // rejects them with "Invalid field permission field name".
    xml = LLMXmlSanitizer.stripNonDeployableCompoundFieldPermissions(xml);

    // Confirmed real gap (QATEST-PS4): a "clone X but make it read-only"
    // ticket has nowhere to express that — permissionSetClone's args used
    // to be only name/label/description, so the model stuffed the
    // restriction into the unused description text and the clone silently
    // kept every permission exactly as copied from the source. A separate
    // files[] entry for the same PermissionSet can't fix this either: it
    // would land at the SAME ZipBuilder path as this clone and completely
    // overwrite it (ZipBuilder.files is a flat path->content map, not a
    // merge), losing everything else the clone copied. Patching the
    // already-cloned XML in place, in this same method, is the only safe
    // way to apply both at once.
    xml = applyObjectPermissionOverrides(xml, objectPermissionOverrides);

    return xml;
  }

  // Applies optional per-object CRUD overrides to an already-cloned
  // PermissionSet XML. Op shape (all fields under each override optional
  // except "object" — an omitted allow* flag leaves that permission
  // exactly as cloned from the source):
  //   "objectPermissionOverrides": [
  //     { "object": "Equipment_Asset__c", "allowRead": true,
  //       "allowCreate": false, "allowEdit": false, "allowDelete": false }
  //   ]
  // No-op (returns xml unchanged) when the op didn't provide any —
  // the common "plain clone, no changes" case is untouched.
  @TestVisible
  private static String applyObjectPermissionOverrides(
    String xml,
    List<Object> overrides
  ) {
    if (overrides == null || overrides.isEmpty()) {
      return xml;
    }

    for (Object rawOverrideEntry : overrides) {
      if (!(rawOverrideEntry instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> overrideEntry = (Map<String, Object>) rawOverrideEntry;
      String objectApiName = (String) overrideEntry.get('object');
      if (String.isBlank(objectApiName)) {
        continue;
      }

      // Confirmed real bug (QATEST-PS7): plain non-greedy .*? here has no
      // boundary stopping it from skipping PAST other complete
      // <objectPermissions>...</objectPermissions> blocks to reach a LATER
      // block's <object> tag — a PermissionSet with objectPermissions for
      // Account, DandBCompany, Equipment_Asset__c (in that order) matched
      // from Account's opening tag all the way through to
      // Equipment_Asset__c's closing tag, and the allow* patches below
      // then hit the FIRST <allowCreate>/etc. in that huge span — i.e.
      // Account's, not Equipment_Asset__c's. (?:(?!</objectPermissions>).)*?
      // is the same "any char not starting the closing tag" idiom used to
      // stay within a single tag's content elsewhere — it makes crossing a
      // block boundary impossible, so a non-matching starting block just
      // fails to match and find() advances to the next real
      // <objectPermissions> occurrence instead of overshooting.
      Pattern blockPat = Pattern.compile(
        '(?is)<objectPermissions>(?:(?!</objectPermissions>).)*?<object>\\s*' +
          Pattern.quote(objectApiName) +
          '\\s*</object>(?:(?!</objectPermissions>).)*?</objectPermissions>'
      );
      Matcher m = blockPat.matcher(xml);
      if (!m.find()) {
        System.debug(
          'applyObjectPermissionOverrides: no objectPermissions block found for [' +
            objectApiName +
            '] — override skipped (was it actually cloned from the source?)'
        );
        continue;
      }
      String block = m.group(0);
      String patchedBlock = block;
      patchedBlock = applyAllowFlag(
        patchedBlock,
        'allowCreate',
        overrideEntry.get('allowCreate')
      );
      patchedBlock = applyAllowFlag(
        patchedBlock,
        'allowDelete',
        overrideEntry.get('allowDelete')
      );
      patchedBlock = applyAllowFlag(
        patchedBlock,
        'allowEdit',
        overrideEntry.get('allowEdit')
      );
      patchedBlock = applyAllowFlag(
        patchedBlock,
        'allowRead',
        overrideEntry.get('allowRead')
      );
      if (patchedBlock != block) {
        xml = xml.replace(block, patchedBlock);
        System.debug(
          'applyObjectPermissionOverrides: patched objectPermissions for [' +
            objectApiName +
            ']'
        );
      }
    }
    return xml;
  }

  private static String applyAllowFlag(
    String block,
    String tagName,
    Object rawValue
  ) {
    if (!(rawValue instanceof Boolean)) {
      return block; // not specified — leave exactly as cloned
    }
    String newValue = String.valueOf((Boolean) rawValue);
    return Pattern.compile('(?is)<' + tagName + '>[^<]*</' + tagName + '>')
      .matcher(block)
      .replaceFirst('<' + tagName + '>' + newValue + '</' + tagName + '>');
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — ENSURE PARENT READ ACCESS
  // Applies parent-object read dependency handling to a raw PermissionSet XML.
  // Used by LLMService when PermissionSet XML is generated directly in files[].
  // ─────────────────────────────────────────────────────────────
  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — DEDUPLICATE objectPermissions
  // Salesforce rejects a PermissionSet where the same object appears in
  // more than one <objectPermissions> block.  The LLM sometimes emits two
  // blocks for the same object (e.g. one for CRUD access and a second one
  // triggered by a field-permission request on the same object).
  // This method merges duplicate blocks by OR-ing all boolean flags so
  // the most-permissive value for each flag is preserved.
  // ─────────────────────────────────────────────────────────────
  public static String deduplicateObjectPermissions(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }
    if (!xml.contains('<objectPermissions>')) {
      return xml;
    }

    // Strategy: keep the first block for each object in place, merge later
    // duplicate blocks into it (OR boolean flags), and remove only duplicates.
    // This preserves XML element ordering required by PermissionSet metadata.
    List<Integer> starts = new List<Integer>();
    List<Integer> ends = new List<Integer>();
    List<String> blocks = new List<String>();
    List<String> objectNames = new List<String>();

    Integer cursor = 0;
    while (true) {
      Integer bs = xml.indexOf('<objectPermissions>', cursor);
      if (bs < 0) {
        break;
      }
      Integer be = xml.indexOf('</objectPermissions>', bs);
      if (be < 0) {
        break;
      }
      be += '</objectPermissions>'.length();

      String block = xml.substring(bs, be);
      Integer os = block.indexOf('<object>');
      Integer oe = block.indexOf('</object>');
      String objName = (os >= 0 &&
        oe > os)
        ? block.substring(os + '<object>'.length(), oe).trim()
        : block;

      starts.add(bs);
      ends.add(be);
      blocks.add(block);
      objectNames.add(objName);
      cursor = be;
    }

    if (blocks.isEmpty()) {
      return xml;
    }

    Map<String, Integer> firstIndexByObject = new Map<String, Integer>();
    Set<Integer> duplicateIdx = new Set<Integer>();

    for (Integer i = 0; i < blocks.size(); i++) {
      String obj = objectNames[i];
      if (!firstIndexByObject.containsKey(obj)) {
        firstIndexByObject.put(obj, i);
        continue;
      }

      Integer firstIdx = firstIndexByObject.get(obj);
      String merged = blocks[firstIdx];
      String dup = blocks[i];

      for (
        String perm : new List<String>{
          'allowRead',
          'allowCreate',
          'allowEdit',
          'allowDelete',
          'viewAllRecords',
          'modifyAllRecords'
        }
      ) {
        if (
          dup.contains('<' + perm + '>true</' + perm + '>') &&
          merged.contains('<' + perm + '>false</' + perm + '>')
        ) {
          merged = merged.replace(
            '<' + perm + '>false</' + perm + '>',
            '<' + perm + '>true</' + perm + '>'
          );
        }
      }
      blocks[firstIdx] = merged;
      duplicateIdx.add(i);
    }

    if (duplicateIdx.isEmpty()) {
      return xml;
    }

    String result = '';
    Integer pos = 0;
    for (Integer i = 0; i < blocks.size(); i++) {
      result += xml.substring(pos, starts[i]);
      if (!duplicateIdx.contains(i)) {
        result += blocks[i];
      }
      pos = ends[i];
    }
    result += xml.substring(pos);

    System.debug(
      'PermissionSetHelper.deduplicateObjectPermissions(): ' +
        blocks.size() +
        ' blocks -> ' +
        (blocks.size() - duplicateIdx.size()) +
        ' unique object(s)'
    );
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — STRIP REQUIRED FIELD PERMISSIONS
  //
  // Salesforce rejects fieldPermissions entries for fields that are
  // marked Required on the object definition, throwing:
  //   "You cannot deploy to a required field: Object__c.Field__c"
  //
  // Required fields always have implicit read/edit access granted
  // via object permissions, so they must be absent from fieldPermissions.
  //
  // This method removes every <fieldPermissions> block whose target
  // field resolves as required via Schema describe.
  // ─────────────────────────────────────────────────────────────
  public static String stripRequiredFieldPermissions(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fieldPermissions>')) {
      return xml;
    }

    List<Integer> removeStarts = new List<Integer>();
    List<Integer> removeEnds = new List<Integer>();
    Integer cursor = 0;

    while (true) {
      Integer bs = xml.indexOf('<fieldPermissions>', cursor);
      if (bs < 0) {
        break;
      }
      Integer be = xml.indexOf('</fieldPermissions>', bs);
      if (be < 0) {
        break;
      }
      be += '</fieldPermissions>'.length();

      String block = xml.substring(bs, be);
      Integer fs = block.indexOf('<field>');
      Integer fe = block.indexOf('</field>');
      if (fs >= 0 && fe > fs) {
        String qualifiedField = block.substring(fs + '<field>'.length(), fe)
          .trim();
        if (qualifiedField.contains('.')) {
          String objectName = qualifiedField.substringBefore('.');
          String fieldName = qualifiedField.substringAfter('.');
          if (isRequiredField(objectName, fieldName)) {
            removeStarts.add(bs);
            removeEnds.add(be);
            System.debug(
              'PermissionSetHelper.stripRequiredFieldPermissions(): removing required field [' +
                qualifiedField +
                ']'
            );
          }
        }
      }
      cursor = be;
    }

    if (removeStarts.isEmpty()) {
      return xml;
    }

    // Remove in reverse order so earlier indices stay valid
    String result = xml;
    for (Integer i = removeStarts.size() - 1; i >= 0; i--) {
      result =
        result.substring(0, removeStarts[i]) + result.substring(removeEnds[i]);
    }
    return result;
  }

  private static Boolean isRequiredField(String objectName, String fieldName) {
    try {
      // Some fields (e.g. OwnerId) are implicitly-controlled and rejected
      // by deploy ("You cannot deploy to a required field: ...") even
      // though Schema describe doesn't flag them as required — OwnerId
      // reports isDefaultedOnCreate()=true, which the describe-based check
      // below treats as "not required". Check the curated list first.
      if (LLMXmlSanitizer.isSystemManagedField(fieldName)) {
        return true;
      }
      // Delegates to SchemaFieldValidator so a field being created in this
      // same deploy (not yet in live schema) is still recognized as
      // required — its <required> flag was parsed straight from the
      // generated XML via registerPendingFieldsFromResponse().
      return SchemaFieldValidator.isFieldRequired(objectName, fieldName);
    } catch (Exception e) {
      System.debug(
        'PermissionSetHelper.isRequiredField(): [' +
          objectName +
          '.' +
          fieldName +
          ']: ' +
          e.getMessage()
      );
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — MERGE
  //
  // Merges permission blocks from additionalXml into baseXml.
  // Used when clonePermissionSet() has already staged a cloned PS
  // and files[] also contains a PermissionSet entry for the same
  // API name (e.g. to add new object permissions to the clone).
  //
  // Strategy: extract every known permission block type from
  // additionalXml and append them to baseXml, then deduplicate.
  // ─────────────────────────────────────────────────────────────
  public static String mergePermissionXml(
    String baseXml,
    String additionalXml
  ) {
    if (String.isBlank(additionalXml)) {
      return baseXml;
    }
    if (String.isBlank(baseXml)) {
      return additionalXml;
    }

    List<String> blockTypes = new List<String>{
      'objectPermissions',
      'fieldPermissions',
      'userPermissions',
      'classAccesses',
      'pageAccesses',
      'recordTypeVisibilities',
      'tabSettings',
      'applicationVisibilities',
      'connectedAppAccesses',
      'customPermissions',
      'customMetadataTypeAccesses',
      'customSettingAccesses',
      'externalDataSourceAccesses',
      'externalCredentialPrincipalAccesses',
      'flowAccesses',
      'namedCredentialAccesses',
      'organizationWideEmailAddressAccesses',
      'servicePresenceStatusAccesses',
      'standardInvocableActionAccesses',
      'agentAccesses'
    };

    String merged = baseXml;
    for (String blockType : blockTypes) {
      String openTag = '<' + blockType + '>';
      String closeTag = '</' + blockType + '>';
      if (!additionalXml.contains(openTag)) {
        continue;
      }

      Integer cursor = 0;
      while (true) {
        Integer bs = additionalXml.indexOf(openTag, cursor);
        if (bs < 0) {
          break;
        }
        Integer be = additionalXml.indexOf(closeTag, bs);
        if (be < 0) {
          break;
        }
        be += closeTag.length();
        String block = additionalXml.substring(bs, be);
        merged = merged.replace(
          '</PermissionSet>',
          block + '\n</PermissionSet>'
        );
        cursor = be;
      }
    }

    System.debug(
      'PermissionSetHelper.mergePermissionXml(): merge complete, running dedup'
    );
    return deduplicateObjectPermissions(merged);
  }

  public static String ensureParentReadAccessForXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    xml = deduplicateObjectPermissions(xml);

    String updatedXml = xml;
    Set<String> objectsInXml = new Set<String>();
    Integer cursor = 0;

    while (true) {
      Integer blockStart = updatedXml.indexOf('<objectPermissions>', cursor);
      if (blockStart < 0) {
        break;
      }

      Integer blockEnd = updatedXml.indexOf('</objectPermissions>', blockStart);
      if (blockEnd < 0) {
        break;
      }
      blockEnd += '</objectPermissions>'.length();

      String block = updatedXml.substring(blockStart, blockEnd);
      Boolean hasAnyAccess =
        block.contains('<allowRead>true</allowRead>') ||
        block.contains('<allowCreate>true</allowCreate>') ||
        block.contains('<allowEdit>true</allowEdit>') ||
        block.contains('<allowDelete>true</allowDelete>') ||
        block.contains('<viewAllRecords>true</viewAllRecords>') ||
        block.contains('<modifyAllRecords>true</modifyAllRecords>');

      if (hasAnyAccess) {
        Integer objStart = block.indexOf('<object>');
        Integer objEnd = block.indexOf(
          '</object>',
          objStart + '<object>'.length()
        );
        if (objStart >= 0 && objEnd > objStart) {
          String objectName = block.substring(
            objStart + '<object>'.length(),
            objEnd
          );
          if (String.isNotBlank(objectName)) {
            objectsInXml.add(objectName.trim());
          }
        }
      }

      cursor = blockEnd;
    }

    for (String objectName : objectsInXml) {
      updatedXml = injectParentReadAccess(
        updatedXml,
        objectName,
        new Set<String>()
      );
    }

    // Parent injection can add extra objectPermission blocks in edge cases.
    // Run a final in-place dedup pass to keep metadata deploy-safe.
    return deduplicateObjectPermissions(updatedXml);
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — BUILD ASSIGNMENT (no DML)
  //
  // Returns a PermissionSetAssignment record ready to insert.
  // Actual DML happens in LLMService AFTER all callouts finish.
  // This avoids the callout-after-DML Salesforce restriction.
  //
  // Required args: permissionSetName, username
  // ─────────────────────────────────────────────────────────────
  public static SObject buildAssignment(Map<String, Object> args) {
    String permSetName = getRequired(args, 'permissionSetName');
    String userIdentifier = getRequired(args, 'username');
    String normalizedPermSetName = normalizeIdentifier(permSetName);
    String normalizedUserIdentifier = normalizeIdentifier(userIdentifier);

    System.debug('PermissionSetHelper.buildAssignment() called');
    System.debug(
      'permSet=' + normalizedPermSetName + ', user=' + normalizedUserIdentifier
    );

    PermissionSet resolvedPermSet = resolvePermissionSet(normalizedPermSetName);
    User resolvedUser = resolveActiveUser(normalizedUserIdentifier);

    System.debug(
      'PermissionSetHelper: found user [' + resolvedUser.Username + ']'
    );

    List<PermissionSetAssignment> existing = [
      SELECT Id
      FROM PermissionSetAssignment
      WHERE
        PermissionSetId = :resolvedPermSet.Id
        AND AssigneeId = :resolvedUser.Id
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      throw new PermissionSetException(
        resolvedPermSet.Name +
          ' is already assigned to ' +
          resolvedUser.Username
      );
    }

    // Build record — NO DML — return to caller
    PermissionSetAssignment assignment = new PermissionSetAssignment();
    assignment.PermissionSetId = resolvedPermSet.Id;
    assignment.AssigneeId = resolvedUser.Id;
    System.debug(
      'PermissionSetHelper.buildAssignment(): record built, queued for insert'
    );
    return assignment;
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — FIND ASSIGNMENT (no DML)
  //
  // Returns the PermissionSetAssignment record to delete.
  // Actual DML happens in LLMService AFTER all callouts finish.
  //
  // Required args: permissionSetName, username
  // ─────────────────────────────────────────────────────────────
  public static SObject findAssignment(Map<String, Object> args) {
    String permSetName = getRequired(args, 'permissionSetName');
    String userIdentifier = getRequired(args, 'username');
    String normalizedPermSetName = normalizeIdentifier(permSetName);
    String normalizedUserIdentifier = normalizeUserIdentifier(userIdentifier);

    System.debug('PermissionSetHelper.findAssignment() called');
    System.debug(
      'permSet=' + normalizedPermSetName + ', user=' + normalizedUserIdentifier
    );

    PermissionSet resolvedPermSet = resolvePermissionSet(normalizedPermSetName);

    List<PermissionSetAssignment> assignments = [
      SELECT Id, Assignee.Username, Assignee.Name, Assignee.Alias
      FROM PermissionSetAssignment
      WHERE
        PermissionSetId = :resolvedPermSet.Id
        AND (Assignee.Username = :normalizedUserIdentifier
        OR Assignee.Alias = :normalizedUserIdentifier
        OR Assignee.Name = :normalizedUserIdentifier)
      LIMIT 5
    ];
    if (assignments.isEmpty()) {
      throw new PermissionSetException(
        resolvedPermSet.Name + ' is not assigned to ' + normalizedUserIdentifier
      );
    }
    if (assignments.size() > 1) {
      List<String> candidates = new List<String>();
      for (PermissionSetAssignment psa : assignments) {
        candidates.add((String) psa.getSObject('Assignee').get('Username'));
      }
      throw new PermissionSetException(
        'Multiple assignees matched [' +
          normalizedUserIdentifier +
          '] for permission set [' +
          resolvedPermSet.Name +
          ']. Use exact Username. Candidates: ' +
          String.join(candidates, ', ')
      );
    }

    System.debug(
      'PermissionSetHelper.findAssignment(): record found, queued for delete'
    );
    return assignments[0];
  }

  private static PermissionSet resolvePermissionSet(
    String permissionSetIdentifier
  ) {
    String normalized = normalizeIdentifier(permissionSetIdentifier);
    Set<String> apiCandidates = new Set<String>{ normalized };
    if (normalized.contains(' ')) {
      apiCandidates.add(normalized.replace(' ', '_'));
    }

    List<PermissionSet> candidates = [
      SELECT Id, Name, Label
      FROM PermissionSet
      WHERE
        IsOwnedByProfile = FALSE
        AND (Name IN :apiCandidates
        OR Label = :normalized)
      LIMIT 5
    ];

    if (candidates.isEmpty()) {
      throw new PermissionSetException(
        'Permission Set not found: ' + permissionSetIdentifier
      );
    }

    for (PermissionSet ps : candidates) {
      if (ps.Name == normalized) {
        return ps;
      }
    }

    String underscored = normalized.replace(' ', '_');
    for (PermissionSet ps : candidates) {
      if (ps.Name == underscored) {
        return ps;
      }
    }

    for (PermissionSet ps : candidates) {
      if (ps.Label == normalized) {
        return ps;
      }
    }

    return candidates[0];
  }

  private static User resolveActiveUser(String userIdentifier) {
    String normalized = normalizeUserIdentifier(userIdentifier);

    List<User> usersByUsername = [
      SELECT Id, Username, Name, Alias
      FROM User
      WHERE IsActive = TRUE AND Username = :normalized
      LIMIT 1
    ];
    if (!usersByUsername.isEmpty()) {
      return usersByUsername[0];
    }

    List<User> usersByAlias = [
      SELECT Id, Username, Name, Alias
      FROM User
      WHERE IsActive = TRUE AND Alias = :normalized
      LIMIT 1
    ];
    if (!usersByAlias.isEmpty()) {
      return usersByAlias[0];
    }

    List<User> usersByName = [
      SELECT Id, Username, Name, Alias
      FROM User
      WHERE IsActive = TRUE AND Name = :normalized
      LIMIT 2
    ];
    if (usersByName.isEmpty()) {
      throw new PermissionSetException(
        'Active user not found: ' + userIdentifier
      );
    }
    if (usersByName.size() > 1) {
      throw new PermissionSetException(
        'Multiple active users match name [' +
          normalized +
          ']. Use exact Username in the ticket.'
      );
    }
    return usersByName[0];
  }

  private static String normalizeUserIdentifier(String rawValue) {
    String normalized = normalizeIdentifier(rawValue);
    if (String.isBlank(normalized)) {
      return normalized;
    }

    String lower = normalized.toLowerCase();
    List<String> prefixes = new List<String>{
      'username:',
      'user name:',
      'user:',
      'assignee:'
    };
    for (String prefix : prefixes) {
      if (lower.startsWith(prefix)) {
        normalized = normalizeIdentifier(normalized.substring(prefix.length()));
        lower = normalized != null ? normalized.toLowerCase() : null;
        break;
      }
    }

    while (String.isNotBlank(normalized)) {
      String last = normalized.substring(normalized.length() - 1);
      if (last == '.' || last == ',' || last == ';' || last == ':') {
        normalized = normalized.substring(0, normalized.length() - 1).trim();
      } else {
        break;
      }
    }

    return normalized;
  }

  private static String normalizeIdentifier(String rawValue) {
    if (String.isBlank(rawValue)) {
      return rawValue;
    }

    String normalized = rawValue.trim();
    while (normalized.length() >= 2) {
      String first = normalized.substring(0, 1);
      String last = normalized.substring(normalized.length() - 1);
      if (isWrappingQuote(first) && isWrappingQuote(last)) {
        normalized = normalized.substring(1, normalized.length() - 1).trim();
      } else {
        break;
      }
    }
    return normalized;
  }

  private static Boolean isWrappingQuote(String ch) {
    return ch == '\'' ||
      ch == '"' ||
      ch == '`' ||
      ch == '‘' ||
      ch == '’' ||
      ch == '“' ||
      ch == '”';
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET — ADD DESTRUCTIVE XML
  //
  // Called by LLMService after DML assignments are deleted.
  // Adds destructiveChanges.xml to ZipBuilder.
  // ─────────────────────────────────────────────────────────────
  public static void addDestructiveXml(String permSetName) {
    System.debug(
      'PermissionSetHelper.addDestructiveXml() called for [' + permSetName + ']'
    );

    String destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>';
    destructiveXml += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">';
    destructiveXml += '    <types>';
    destructiveXml += '        <members>' + permSetName + '</members>';
    destructiveXml += '        <name>PermissionSet</name>';
    destructiveXml += '    </types>';
    destructiveXml += '    <version>61.0</version>';
    destructiveXml += '</Package>';

    ZipBuilder.addFile(
      '__destructive__',
      permSetName,
      'destructiveChangesPost.xml',
      destructiveXml
    );
    System.debug(
      'PermissionSetHelper.addDestructiveXml(): [' +
        permSetName +
        '] added to destructive deploy'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — RECURSIVE PARENT READ ACCESS INJECTOR
  //
  // Walks the full ancestor chain of lookup/master-detail fields
  // on the given object and ensures Read access is present for every
  // parent (and their parents, etc.) in the XML.
  //
  // This prevents deploy failures caused by transitive lookup
  // dependencies, e.g.:
  //   Reservation__c → AI_Message__c → AI_Conversation__c
  // where Salesforce requires Read on ALL objects in the chain.
  //
  // visited — tracks already-processed objects to prevent infinite loops
  // ─────────────────────────────────────────────────────────────
  private static String injectParentReadAccess(
    String xml,
    String objectName,
    Set<String> visited
  ) {
    if (visited.contains(objectName)) {
      return xml;
    }

    visited.add(objectName);

    Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
    if (objType == null) {
      return xml;
    }

    for (
      Schema.SObjectField field : objType.getDescribe().fields.getMap().values()
    ) {
      Schema.DescribeFieldResult f = field.getDescribe();
      if (f.getType() != Schema.DisplayType.REFERENCE) {
        continue;
      }

      for (Schema.SObjectType ref : f.getReferenceTo()) {
        String parentName = ref.getDescribe().getName();

        // Skip self-lookups and standard non-permissionable objects
        if (parentName == objectName) {
          continue;
        }
        if (parentName == 'User' || parentName == 'RecordType') {
          continue;
        }
        if (visited.contains(parentName)) {
          continue;
        }

        if (!xml.contains('<object>' + parentName + '</object>')) {
          System.debug(
            'PermissionSetHelper: auto-injecting Read access for [' +
              parentName +
              ']'
          );
          String parentBlock = '    <objectPermissions>';
          parentBlock += '        <allowCreate>false</allowCreate>';
          parentBlock += '        <allowDelete>false</allowDelete>';
          parentBlock += '        <allowEdit>false</allowEdit>';
          parentBlock += '        <allowRead>true</allowRead>';
          parentBlock += '        <modifyAllRecords>false</modifyAllRecords>';
          parentBlock += '        <object>' + parentName + '</object>';
          parentBlock += '        <viewAllRecords>false</viewAllRecords>';
          parentBlock += '    </objectPermissions>';
          xml = insertObjectPermissionsBlock(xml, parentBlock);
        } else {
          xml = ensureObjectReadPermission(xml, parentName);
        }

        // Recurse — inject parents of this parent too
        xml = injectParentReadAccess(xml, parentName, visited);
      }
    }

    return xml;
  }

  private static String ensureObjectReadPermission(
    String xml,
    String objectName
  ) {
    String objectMarker = '<object>' + objectName + '</object>';
    if (xml.contains(objectMarker)) {
      Integer objectIndex = xml.indexOf(objectMarker);
      Integer blockStart = xml.lastIndexOf('<objectPermissions>', objectIndex);
      Integer blockEnd = xml.indexOf('</objectPermissions>', objectIndex);
      if (blockStart >= 0 && blockEnd >= 0) {
        blockEnd += '</objectPermissions>'.length();
        String block = xml.substring(blockStart, blockEnd);
        if (!block.contains('<allowRead>true</allowRead>')) {
          if (block.contains('<allowRead>false</allowRead>')) {
            block = block.replace(
              '<allowRead>false</allowRead>',
              '<allowRead>true</allowRead>'
            );
          } else if (block.contains('<allowRead>')) {
            block = block.replace('<allowRead>', '<allowRead>true</allowRead>');
          } else {
            block = block.replace(
              '</objectPermissions>',
              '        <allowRead>true</allowRead></objectPermissions>'
            );
          }
          xml = xml.substring(0, blockStart) + block + xml.substring(blockEnd);
        }
        return xml;
      }
    }

    String parentBlock = '    <objectPermissions>';
    parentBlock += '        <allowCreate>false</allowCreate>';
    parentBlock += '        <allowDelete>false</allowDelete>';
    parentBlock += '        <allowEdit>false</allowEdit>';
    parentBlock += '        <allowRead>true</allowRead>';
    parentBlock += '        <modifyAllRecords>false</modifyAllRecords>';
    parentBlock += '        <object>' + objectName + '</object>';
    parentBlock += '        <viewAllRecords>false</viewAllRecords>';
    parentBlock += '    </objectPermissions>';
    return insertObjectPermissionsBlock(xml, parentBlock);
  }

  // Insert new objectPermissions in a schema-safe location:
  // 1) after the last existing objectPermissions block when present
  // 2) otherwise right after <label> when present
  // 3) otherwise before </PermissionSet> as fallback
  private static String insertObjectPermissionsBlock(String xml, String block) {
    Integer posLastObjPermClose = xml.lastIndexOf('</objectPermissions>');
    if (posLastObjPermClose >= 0) {
      Integer insertAt = posLastObjPermClose + '</objectPermissions>'.length();
      return xml.substring(0, insertAt) + block + xml.substring(insertAt);
    }

    Integer posLabelClose = xml.indexOf('</label>');
    if (posLabelClose >= 0) {
      Integer insertAt = posLabelClose + '</label>'.length();
      return xml.substring(0, insertAt) + block + xml.substring(insertAt);
    }

    return xml.replace('</PermissionSet>', block + '</PermissionSet>');
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

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Parameter helpers
  // ─────────────────────────────────────────────────────────────
  private static String getRequired(Map<String, Object> args, String key) {
    Object val = args?.get(key);
    if (val == null || String.isBlank(String.valueOf(val))) {
      throw new PermissionSetException('Required parameter missing: ' + key);
    }
    return String.valueOf(val).trim();
  }

  private static String getOptional(
    Map<String, Object> args,
    String key,
    String defaultValue
  ) {
    Object val = args?.get(key);
    if (val == null) {
      return defaultValue;
    }
    String strVal = String.valueOf(val).trim();
    if (String.isBlank(strVal) || strVal == 'null') {
      return defaultValue;
    }
    return strVal;
  }

  // ─────────────────────────────────────────────────────────────
  // EXCEPTION
  // ─────────────────────────────────────────────────────────────
  public class PermissionSetException extends Exception {
  }
}
