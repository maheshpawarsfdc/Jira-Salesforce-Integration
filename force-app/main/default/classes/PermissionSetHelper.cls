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

    // ─────────────────────────────────────────────────────────────
    // PORT — same MetadataPort the rest of the system uses
    // ─────────────────────────────────────────────────────────────
    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('PermissionSetHelper: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('PermissionSetHelper: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — LIST
    // Returns all permission sets using Tooling API
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listPermissionSets() {
        System.debug('PermissionSetHelper.listPermissionSets() called');

        String query = 'SELECT Id, Name, Label, Description FROM PermissionSet '
            + 'WHERE IsOwnedByProfile = false ORDER BY Label';

        String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
            + '/services/data/v61.0/tooling/query?q='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            throw new PermissionSetException(
                'Failed to list permission sets. Status: ' + res.getStatusCode()
            );
        }

        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) response.get('records');

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rec : records) {
            Map<String, Object> r = (Map<String, Object>) rec;
            result.add(new Map<String, Object>{
                'id'          => r.get('Id'),
                'name'        => r.get('Name'),
                'label'       => r.get('Label'),
                'description' => r.get('Description')
            });
        }

        System.debug('PermissionSetHelper.listPermissionSets(): found ' + result.size() + ' permission sets');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — CREATE
    //
    // Required args: apiName, label
    // Optional args: description
    // ─────────────────────────────────────────────────────────────
    public static void createPermissionSet(Map<String, Object> args) {
        String apiName    = getRequired(args, 'apiName');
        String label      = getRequired(args, 'label');
        String psDesc     = getOptional(args, 'description', null);

        System.debug('PermissionSetHelper.createPermissionSet() called');
        System.debug('apiName = ' + apiName + ', label = ' + label);

        String xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml += '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">';
        xml += '    <label>' + escapeXml(label) + '</label>';
        if (String.isNotBlank(psDesc)) {
            xml += '    <description>' + escapeXml(psDesc) + '</description>';
        }
        xml += '</PermissionSet>';

        String filePath = 'permissionsets/' + apiName + '.permissionset-meta.xml';
        ZipBuilder.addFile('PermissionSet', apiName, filePath, xml);
        System.debug('PermissionSetHelper.createPermissionSet(): [' + apiName + '] queued for deploy');
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
    public static void clonePermissionSet(Map<String, Object> args) {
        String sourceName  = getRequired(args, 'sourcePermissionSetName');
        String newApiName  = getRequired(args, 'newApiName');
        String newLabel    = getRequired(args, 'newLabel');
        String description = getOptional(args, 'description', null);

        System.debug('PermissionSetHelper.clonePermissionSet() called');
        System.debug('source=' + sourceName + ', newApiName=' + newApiName);

        // Normalize sourceName to API name format (spaces → underscores, no __c suffix needed)
        // Salesforce Permission Set API names never have spaces — the label might have spaces
        // but the API name passed here should already be the API name (e.g. Car_Manager)
        String sourceApiName = sourceName.replace(' ', '_');
        System.debug('PermissionSetHelper.clonePermissionSet(): sourceApiName=' + sourceApiName);

        // ── STEP 1: Verify source PS exists and get its label via SOQL ──
        List<PermissionSet> sourcePsList = [
            SELECT Id, Name, Label, Description
            FROM PermissionSet
            WHERE Name = :sourceApiName
            AND IsOwnedByProfile = false
            LIMIT 1
        ];
        if (sourcePsList.isEmpty()) {
            // Try original name too in case caller passed label
            sourcePsList = [
                SELECT Id, Name, Label, Description
                FROM PermissionSet
                WHERE Label = :sourceName
                AND IsOwnedByProfile = false
                LIMIT 1
            ];
        }
        if (sourcePsList.isEmpty()) {
            throw new PermissionSetException('Source permission set not found: ' + sourceName);
        }
        PermissionSet sourcePs = sourcePsList[0];
        // Always use the actual API Name for retrieve — never the label
        sourceApiName = sourcePs.Name;
        System.debug('PermissionSetHelper.clonePermissionSet(): resolved sourceApiName=' + sourceApiName + ', label=' + sourcePs.Label);

        // ── STEP 2: Start SOAP retrieve using the correct API name ──
        MetadataService.RetrieveRequest retrieveRequest = new MetadataService.RetrieveRequest();
        retrieveRequest.apiVersion = 61.0;
        retrieveRequest.singlePackage = true;
        MetadataService.PackageTypeMembers ptm = new MetadataService.PackageTypeMembers();
        ptm.name    = 'PermissionSet';
        ptm.members = new List<String>{ sourceApiName };
        MetadataService.Package_x pkg = new MetadataService.Package_x();
        pkg.types   = new List<MetadataService.PackageTypeMembers>{ ptm };
        pkg.version = '61.0';
        retrieveRequest.unpackaged = pkg;

        MetadataService.AsyncResult asyncResult = port.retrieve(retrieveRequest);
        String asyncId = asyncResult.id;
        System.debug('PermissionSetHelper.clonePermissionSet(): retrieve started, asyncId=' + asyncId);

        // ── STEP 3: Poll until retrieve is done ──
        String zipBase64 = null;
        for (Integer attempt = 0; attempt < 10; attempt++) {
            Long waitUntil = DateTime.now().getTime() + 2500;
            while (DateTime.now().getTime() < waitUntil) { /* spin */ }

            MetadataService.RetrieveResult retrieveResult = port.checkRetrieveStatus(asyncId, true);
            System.debug('PermissionSetHelper.clonePermissionSet(): poll attempt=' + attempt
                + ', done=' + retrieveResult.done + ', status=' + retrieveResult.status);

            if (retrieveResult.done) {
                if (retrieveResult.status == 'Failed') {
                    throw new PermissionSetException(
                        'Retrieve failed for ' + sourceApiName + ': ' + retrieveResult.errorMessage
                    );
                }
                zipBase64 = retrieveResult.zipFile;
                break;
            }
        }

        if (String.isBlank(zipBase64)) {
            throw new PermissionSetException('Retrieve timed out for source permission set: ' + sourceApiName);
        }

        // ── STEP 4: Extract the permission set XML from the ZIP ──
        Blob zipBlob = EncodingUtil.base64Decode(zipBase64);

        // SOAP retrieve returns old-style format: Car_Manager.permissionset (no -meta.xml suffix)
        String sourceXml = ZipBuilder.extractFileFromZip(zipBlob,
            'permissionsets/' + sourceApiName + '.permissionset');

        // Fallback: try DX-style suffix just in case
        if (String.isBlank(sourceXml)) {
            sourceXml = ZipBuilder.extractFileFromZip(zipBlob,
                'permissionsets/' + sourceApiName + '.permissionset-meta.xml');
        }

        if (String.isBlank(sourceXml)) {
            throw new PermissionSetException(
                'Could not extract permission set XML from retrieve ZIP for: ' + sourceApiName
                + '. Check debug logs for ZIP contents.'
            );
        }
        System.debug('PermissionSetHelper.clonePermissionSet(): source XML extracted, length=' + sourceXml.length());
        System.debug('PermissionSetHelper.clonePermissionSet(): source XML preview: ' + sourceXml.left(500));

        // ── STEP 5: Build new PS XML — swap label/description, keep all permissions ──
        String effectiveDesc = String.isNotBlank(description)
            ? description
            : 'Cloned from ' + sourceApiName + '.';

        String xml = sourceXml;

        // Replace <label> — required field, must be present
        if (xml.contains('<label>')) {
            xml = xml.replaceAll('<label>[^<]*</label>', '<label>' + escapeXml(newLabel) + '</label>');
        } else {
            // Inject label right after the opening <PermissionSet> tag
            xml = xml.replace('<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">',
                '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">'
                + '<label>' + escapeXml(newLabel) + '</label>');
        }

        // Replace or inject <description>
        if (xml.contains('<description>')) {
            xml = xml.replaceAll('<description>[^<]*</description>',
                '<description>' + escapeXml(effectiveDesc) + '</description>');
        } else {
            xml = xml.replace('</label>', '</label><description>' + escapeXml(effectiveDesc) + '</description>');
        }

        String filePath = 'permissionsets/' + newApiName + '.permissionset-meta.xml';
        ZipBuilder.addFile('PermissionSet', newApiName, filePath, xml);
        System.debug('PermissionSetHelper.clonePermissionSet(): [' + newApiName + '] queued with full source permissions');
    }


    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — GRANT OBJECT ACCESS
    //
    // Reads existing permission set, adds object permissions, saves back
    //
    // Required args: permissionSetName, objectName
    // Optional args: allowRead, allowCreate, allowEdit, allowDelete,
    //                viewAllRecords, modifyAllRecords
    //                (all default to false if not provided)
    // ─────────────────────────────────────────────────────────────
    public static void grantObjectAccess(Map<String, Object> args) {
        String permSetName = getRequired(args, 'permissionSetName');
        String objectName  = addSuffix(getRequired(args, 'objectName'));

        System.debug('PermissionSetHelper.grantObjectAccess() called');
        System.debug('permSet = ' + permSetName + ', object = ' + objectName);

        Boolean allowRead        = Boolean.valueOf(getOptional(args, 'allowRead',        'false'));
        Boolean allowCreate      = Boolean.valueOf(getOptional(args, 'allowCreate',      'false'));
        Boolean allowEdit        = Boolean.valueOf(getOptional(args, 'allowEdit',        'false'));
        Boolean allowDelete      = Boolean.valueOf(getOptional(args, 'allowDelete',      'false'));
        Boolean viewAllRecords   = Boolean.valueOf(getOptional(args, 'viewAllRecords',   'false'));
        Boolean modifyAllRecords = Boolean.valueOf(getOptional(args, 'modifyAllRecords', 'false'));

        // If ZipBuilder already has XML for this PS (e.g. freshly cloned this session),
        // use it directly — no readMetadata needed (PS may not exist in org yet).
        String filePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
        String existingXml = ZipBuilder.files.get(filePath);
        MetadataService.PermissionSet permSet = null;

        if (existingXml == null) {
            // PS not yet in ZipBuilder — read from org
            MetadataService.IReadResult readResult = port.readMetadata(
                'PermissionSet', new List<String>{ permSetName }
            );
            MetadataService.Metadata[] records = readResult.getRecords();
            if (records == null || records.isEmpty() || records[0] == null) {
                throw new PermissionSetException('Permission Set not found: ' + permSetName);
            }
            permSet = (MetadataService.PermissionSet) records[0];
        }

        // Use ZipBuilder XML if available (preserves cloned permissions), else build from org metadata
        String xml = existingXml != null ? existingXml : buildBasePermissionSetXml(permSet);

        // ── AUTO-INJECT PARENT OBJECT READ ACCESS (recursive) ──────
        xml = injectParentReadAccess(xml, objectName, new Set<String>());
        // ───────────────────────────────────────────────────────────

        xml = buildPermissionSetXml(permSet, xml,
            objectName, allowRead, allowCreate, allowEdit, allowDelete, viewAllRecords, modifyAllRecords,
            null, null, null);

        ZipBuilder.addFile('PermissionSet', permSetName, filePath, xml);
        System.debug('PermissionSetHelper.grantObjectAccess(): SUCCESS - queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — GRANT FIELD ACCESS
    //
    // Required args: permissionSetName, objectName, fieldName
    // Optional args: readable (default true), editable (default false)
    // ─────────────────────────────────────────────────────────────
    public static void grantFieldAccess(Map<String, Object> args) {
        String permSetName   = getRequired(args, 'permissionSetName');
        String objectName    = addSuffix(getRequired(args, 'objectName'));
        String fieldName     = addSuffix(getRequired(args, 'fieldName'));
        String fullFieldName = objectName + '.' + fieldName;
        Boolean readable     = Boolean.valueOf(getOptional(args, 'readable', 'true'));
        Boolean editable     = Boolean.valueOf(getOptional(args, 'editable', 'false'));

        System.debug('PermissionSetHelper.grantFieldAccess() called');
        System.debug('permSet=' + permSetName + ', field=' + fullFieldName);

        // If ZipBuilder already has XML for this PS (e.g. freshly cloned this session),
        // use it directly — no readMetadata needed (PS may not exist in org yet).
        String fieldFilePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
        String existingXml = ZipBuilder.files.get(fieldFilePath);
        MetadataService.PermissionSet permSet = null;

        if (existingXml == null) {
            MetadataService.IReadResult readResult = port.readMetadata(
                'PermissionSet', new List<String>{ permSetName }
            );
            MetadataService.Metadata[] records = readResult.getRecords();
            if (records == null || records.isEmpty() || records[0] == null) {
                throw new PermissionSetException('Permission Set not found: ' + permSetName);
            }
            permSet = (MetadataService.PermissionSet) records[0];
        }

        String xml = buildPermissionSetXml(permSet, existingXml,
            null, null, null, null, null, null, null,
            fullFieldName, readable, editable);

        // ── AUTO-INJECT PARENT OBJECT READ ACCESS (recursive) ──────
        xml = injectParentReadAccess(xml, objectName, new Set<String>());
        // ───────────────────────────────────────────────────────────

        ZipBuilder.addFile('PermissionSet', permSetName, fieldFilePath, xml);
        System.debug('PermissionSetHelper.grantFieldAccess(): SUCCESS for [' + fullFieldName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — GRANT ALL FIELDS ON OBJECT
    //
    // Convenience method — grants field access to ALL fields on an object
    //
    // Required args: permissionSetName, objectName
    // Optional args: readable (default true), editable (default false)
    // ─────────────────────────────────────────────────────────────
    public static void grantAllFieldsAccess(Map<String, Object> args) {
        String permSetName = getRequired(args, 'permissionSetName');
        String objectName  = addSuffix(getRequired(args, 'objectName'));
        Boolean readable   = Boolean.valueOf(getOptional(args, 'readable', 'true'));
        Boolean editable   = Boolean.valueOf(getOptional(args, 'editable', 'false'));

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw new PermissionSetException('Object not found: ' + objectName);
        }

        // If ZipBuilder already has XML for this PS (e.g. freshly cloned this session),
        // use it directly — no readMetadata needed (PS may not exist in org yet).
        String allFieldsFilePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
        String existingXml = ZipBuilder.files.get(allFieldsFilePath);
        MetadataService.PermissionSet permSet = null;

        if (existingXml == null) {
            MetadataService.IReadResult readResult = port.readMetadata(
                'PermissionSet', new List<String>{ permSetName }
            );
            MetadataService.Metadata[] records = readResult.getRecords();
            if (records == null || records.isEmpty() || records[0] == null) {
                throw new PermissionSetException('Permission Set not found: ' + permSetName);
            }
            permSet = (MetadataService.PermissionSet) records[0];
        }

        String xml = existingXml != null ? existingXml : buildBasePermissionSetXml(permSet);

        // ── AUTO-INJECT PARENT OBJECT READ ACCESS (recursive) ──────
        xml = injectParentReadAccess(xml, objectName, new Set<String>());
        // ───────────────────────────────────────────────────────────

        // Add each custom field
        Integer fieldsAdded = 0;
        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult f = field.getDescribe();
            if (!f.isCustom()) continue;
            String fullFieldName = objectName + '.' + f.getName();
            // Only add if not already in XML
            if (!xml.contains('<field>' + fullFieldName + '</field>')) {
                String fieldBlock = '    <fieldPermissions>';
                fieldBlock += '        <editable>' + editable + '</editable>';
                fieldBlock += '        <field>' + fullFieldName + '</field>';
                fieldBlock += '        <readable>' + readable + '</readable>';
                fieldBlock += '    </fieldPermissions>';
                xml = xml.replace('</PermissionSet>', fieldBlock + '</PermissionSet>');
                fieldsAdded++;
            }
        }

        ZipBuilder.addFile('PermissionSet', permSetName, allFieldsFilePath, xml);
        System.debug('PermissionSetHelper.grantAllFieldsAccess(): SUCCESS - ' + fieldsAdded + ' fields queued for deploy');
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
        String permSetName    = getRequired(args, 'permissionSetName');
        String userIdentifier = getRequired(args, 'username');

        System.debug('PermissionSetHelper.buildAssignment() called');
        System.debug('permSet=' + permSetName + ', user=' + userIdentifier);

        List<PermissionSet> permSets = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName LIMIT 1
        ];
        if (permSets.isEmpty()) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }

        List<User> users = [
            SELECT Id, Username FROM User
            WHERE (Username = :userIdentifier OR Name = :userIdentifier)
            AND IsActive = true LIMIT 1
        ];
        if (users.isEmpty()) {
            throw new PermissionSetException('Active user not found: ' + userIdentifier);
        }

        System.debug('PermissionSetHelper: found user [' + users[0].Username + ']');

        List<PermissionSetAssignment> existing = [
            SELECT Id FROM PermissionSetAssignment
            WHERE PermissionSetId = :permSets[0].Id
            AND AssigneeId = :users[0].Id LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw new PermissionSetException(
                permSetName + ' is already assigned to ' + userIdentifier
            );
        }

        // Build record — NO DML — return to caller
        PermissionSetAssignment assignment = new PermissionSetAssignment();
        assignment.PermissionSetId = permSets[0].Id;
        assignment.AssigneeId      = users[0].Id;
        System.debug('PermissionSetHelper.buildAssignment(): record built, queued for insert');
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
        String permSetName    = getRequired(args, 'permissionSetName');
        String userIdentifier = getRequired(args, 'username');

        System.debug('PermissionSetHelper.findAssignment() called');
        System.debug('permSet=' + permSetName + ', user=' + userIdentifier);

        List<PermissionSet> permSets = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName LIMIT 1
        ];
        if (permSets.isEmpty()) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }

        List<User> users = [
            SELECT Id, Username FROM User
            WHERE (Username = :userIdentifier OR Name = :userIdentifier)
            AND IsActive = true LIMIT 1
        ];
        if (users.isEmpty()) {
            throw new PermissionSetException('Active user not found: ' + userIdentifier);
        }

        List<PermissionSetAssignment> assignments = [
            SELECT Id FROM PermissionSetAssignment
            WHERE PermissionSetId = :permSets[0].Id
            AND AssigneeId = :users[0].Id LIMIT 1
        ];
        if (assignments.isEmpty()) {
            throw new PermissionSetException(
                permSetName + ' is not assigned to ' + userIdentifier
            );
        }

        System.debug('PermissionSetHelper.findAssignment(): record found, queued for delete');
        return assignments[0];
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — QUEUE DELETE
    //
    // Two steps:
    // 1. Queues all user assignments for DML deletion (FunctionHelper.recordsToDelete)
    // 2. Adds destructiveChanges XML to ZipBuilder for the permission set itself
    //
    // Required args: permissionSetName
    // ─────────────────────────────────────────────────────────────
    public static void queuePermissionSetDelete(Map<String, Object> args) {
        String permSetName = getRequired(args, 'permissionSetName');

        System.debug('PermissionSetHelper.queuePermissionSetDelete() called');
        System.debug('permSetName = ' + permSetName);

        // Verify permission set exists
        List<PermissionSet> permSets = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName LIMIT 1
        ];
        if (permSets.isEmpty()) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }

        // Queue all user assignments for DML deletion first
        List<PermissionSetAssignment> assignments = [
            SELECT Id FROM PermissionSetAssignment
            WHERE PermissionSetId = :permSets[0].Id
        ];
        if (!assignments.isEmpty()) {
            System.debug('PermissionSetHelper: queuing ' + assignments.size() + ' assignment(s) for delete');
            FunctionHelper.recordsToDelete.addAll(assignments);
        }

        // Queue permission set for ZIP destructive deploy
        FunctionHelper.permissionSetsToDelete.add(permSetName);
        System.debug('PermissionSetHelper: [' + permSetName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PERMISSION SET — ADD DESTRUCTIVE XML
    //
    // Called by LLMService after DML assignments are deleted.
    // Adds destructiveChanges.xml to ZipBuilder.
    // ─────────────────────────────────────────────────────────────
    public static void addDestructiveXml(String permSetName) {
        System.debug('PermissionSetHelper.addDestructiveXml() called for [' + permSetName + ']');

        String destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>';
        destructiveXml += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">';
        destructiveXml += '    <types>';
        destructiveXml += '        <members>' + permSetName + '</members>';
        destructiveXml += '        <name>PermissionSet</name>';
        destructiveXml += '    </types>';
        destructiveXml += '    <version>61.0</version>';
        destructiveXml += '</Package>';

        ZipBuilder.addFile('__destructive__', permSetName, 'destructiveChangesPost.xml', destructiveXml);
        System.debug('PermissionSetHelper.addDestructiveXml(): [' + permSetName + '] added to destructive deploy');
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
    private static String injectParentReadAccess(String xml, String objectName, Set<String> visited) {
        if (visited.contains(objectName)) return xml;
        visited.add(objectName);

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return xml;

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult f = field.getDescribe();
            if (f.getType() != Schema.DisplayType.REFERENCE) continue;

            for (Schema.SObjectType ref : f.getReferenceTo()) {
                String parentName = ref.getDescribe().getName();

                // Skip self-lookups and standard non-permissionable objects
                if (parentName == objectName) continue;
                if (parentName == 'User' || parentName == 'RecordType') continue;
                if (visited.contains(parentName)) continue;

                if (!xml.contains('<object>' + parentName + '</object>')) {
                    System.debug('PermissionSetHelper: auto-injecting Read access for [' + parentName + ']');
                    String parentBlock = '    <objectPermissions>';
                    parentBlock += '        <allowCreate>false</allowCreate>';
                    parentBlock += '        <allowDelete>false</allowDelete>';
                    parentBlock += '        <allowEdit>false</allowEdit>';
                    parentBlock += '        <allowRead>true</allowRead>';
                    parentBlock += '        <modifyAllRecords>false</modifyAllRecords>';
                    parentBlock += '        <object>' + parentName + '</object>';
                    parentBlock += '        <viewAllRecords>false</viewAllRecords>';
                    parentBlock += '    </objectPermissions>';
                    xml = xml.replace('</PermissionSet>', parentBlock + '</PermissionSet>');
                } else {
                    xml = ensureObjectReadPermission(xml, parentName);
                }

                // Recurse — inject parents of this parent too
                xml = injectParentReadAccess(xml, parentName, visited);
            }
        }

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — XML BUILDERS
    // ─────────────────────────────────────────────────────────────

    // Build base XML from existing PermissionSet metadata object
    private static String buildBasePermissionSetXml(MetadataService.PermissionSet permSet) {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml += '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">';
        xml += '    <label>' + escapeXml(permSet.label) + '</label>';
        if (String.isNotBlank(permSet.description)) {
            xml += '    <description>' + escapeXml(permSet.description) + '</description>';
        }

        // Preserve existing object permissions
        if (permSet.objectPermissions != null) {
            for (MetadataService.PermissionSetObjectPermissions op : permSet.objectPermissions) {
                xml += '    <objectPermissions>';
                xml += '        <allowCreate>' + op.allowCreate + '</allowCreate>';
                xml += '        <allowDelete>' + op.allowDelete + '</allowDelete>';
                xml += '        <allowEdit>' + op.allowEdit + '</allowEdit>';
                xml += '        <allowRead>' + op.allowRead + '</allowRead>';
                xml += '        <modifyAllRecords>' + op.modifyAllRecords + '</modifyAllRecords>';
                xml += '        <object>' + op.object_x + '</object>';
                xml += '        <viewAllRecords>' + op.viewAllRecords + '</viewAllRecords>';
                xml += '    </objectPermissions>';
            }
        }

        // Preserve existing field permissions
        if (permSet.fieldPermissions != null) {
            for (MetadataService.PermissionSetFieldPermissions fp : permSet.fieldPermissions) {
                xml += '    <fieldPermissions>';
                xml += '        <editable>' + fp.editable + '</editable>';
                xml += '        <field>' + fp.field + '</field>';
                xml += '        <readable>' + fp.readable + '</readable>';
                xml += '    </fieldPermissions>';
            }
        }

        xml += '</PermissionSet>';
        return xml;
    }

    // Build/merge XML — adds new object OR field permission to existing XML
    private static String buildPermissionSetXml(
        MetadataService.PermissionSet permSet,
        String existingXml,
        String objectName,
        Boolean allowRead,
        Boolean allowCreate,
        Boolean allowEdit,
        Boolean allowDelete,
        Boolean viewAllRecords,
        Boolean modifyAllRecords,
        String fieldName,
        Boolean readable,
        Boolean editable
    ) {
        // Start from existing ZIP XML if already modified, else build from metadata
        String xml = existingXml != null ? existingXml : buildBasePermissionSetXml(permSet);

        if (String.isNotBlank(objectName)) {
            // Remove existing object block if present to avoid duplicates
            while (xml.contains('<object>' + objectName + '</object>')) {
                Integer start = xml.lastIndexOf('<objectPermissions>', xml.indexOf('<object>' + objectName + '</object>'));
                Integer endIdx = xml.indexOf('</objectPermissions>', start) + '</objectPermissions>'.length();
                xml = xml.substring(0, start) + xml.substring(endIdx);
            }
            // Add new object block
            String objBlock = '    <objectPermissions>';
            objBlock += '        <allowCreate>' + allowCreate + '</allowCreate>';
            objBlock += '        <allowDelete>' + allowDelete + '</allowDelete>';
            objBlock += '        <allowEdit>' + allowEdit + '</allowEdit>';
            objBlock += '        <allowRead>' + allowRead + '</allowRead>';
            objBlock += '        <modifyAllRecords>' + modifyAllRecords + '</modifyAllRecords>';
            objBlock += '        <object>' + objectName + '</object>';
            objBlock += '        <viewAllRecords>' + viewAllRecords + '</viewAllRecords>';
            objBlock += '    </objectPermissions>';
            xml = xml.replace('</PermissionSet>', objBlock + '</PermissionSet>');
        }

        if (String.isNotBlank(fieldName)) {
            // Remove existing field block if present
            while (xml.contains('<field>' + fieldName + '</field>')) {
                Integer start = xml.lastIndexOf('<fieldPermissions>', xml.indexOf('<field>' + fieldName + '</field>'));
                Integer endIdx = xml.indexOf('</fieldPermissions>', start) + '</fieldPermissions>'.length();
                xml = xml.substring(0, start) + xml.substring(endIdx);
            }
            // Add new field block
            String fieldBlock = '    <fieldPermissions>';
            fieldBlock += '        <editable>' + editable + '</editable>';
            fieldBlock += '        <field>' + fieldName + '</field>';
            fieldBlock += '        <readable>' + readable + '</readable>';
            fieldBlock += '    </fieldPermissions>';
            xml = xml.replace('</PermissionSet>', fieldBlock + '</PermissionSet>');
        }

        return xml;
    }

    private static String ensureObjectReadPermission(String xml, String objectName) {
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
                        block = block.replace('<allowRead>false</allowRead>', '<allowRead>true</allowRead>');
                    } else if (block.contains('<allowRead>')) {
                        block = block.replace('<allowRead>', '<allowRead>true</allowRead>');
                    } else {
                        block = block.replace('</objectPermissions>', '        <allowRead>true</allowRead></objectPermissions>');
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
        return xml.replace('</PermissionSet>', parentBlock + '</PermissionSet>');
    }

    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Result checkers (same pattern as MetadataHelper)
    // ─────────────────────────────────────────────────────────────
    private static void checkUpsertResults(MetadataService.UpsertResult[] results) {
        if (results == null || results.isEmpty()) {
            throw new PermissionSetException('No results returned from Metadata API');
        }
        for (MetadataService.UpsertResult result : results) {
            if (!result.success) {
                String errors = '';
                if (result.errors != null) {
                    for (MetadataService.Error err : result.errors) {
                        errors += err.message + ' (' + err.statusCode + '). ';
                    }
                }
                System.debug('PermissionSetHelper: FAILED for [' + result.fullName + ']: ' + errors);
                throw new PermissionSetException(
                    'Permission Set error on ' + result.fullName + ': ' + errors
                );
            }
            System.debug('PermissionSetHelper: Salesforce confirmed success for [' + result.fullName + ']');
        }
    }

    private static void checkDeleteResults(MetadataService.DeleteResult[] results) {
        if (results == null || results.isEmpty()) {
            throw new PermissionSetException('No results returned from Metadata API');
        }
        for (MetadataService.DeleteResult result : results) {
            if (!result.success) {
                String errors = '';
                if (result.errors != null) {
                    for (MetadataService.Error err : result.errors) {
                        errors += err.message + ' (' + err.statusCode + '). ';
                    }
                }
                System.debug('PermissionSetHelper: DELETE FAILED for [' + result.fullName + ']: ' + errors);
                throw new PermissionSetException(
                    'Delete error on ' + result.fullName + ': ' + errors
                );
            }
            System.debug('PermissionSetHelper: Salesforce confirmed delete for [' + result.fullName + ']');
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Session ID
    // ─────────────────────────────────────────────────────────────
    private static String getSessionId() {
        if (Test.isRunningTest()) return UserInfo.getSessionId();
        try {
            PageReference vfPage = Page.SessionId;
            String content = vfPage.getContent().toString();
            Integer s = content.indexOf('Start_Of_Session_Id') + 'Start_Of_Session_Id'.length();
            Integer e = content.indexOf('End_Of_Session_Id');
            return content.substring(s, e);
        } catch (Exception ex) {
            return UserInfo.getSessionId();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Parameter helpers (same as MetadataHelper)
    // ─────────────────────────────────────────────────────────────
    private static String addSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new PermissionSetException('Required parameter missing: ' + key);
        }
        return String.valueOf(val).trim();
    }

    private static String getOptional(Map<String, Object> args, String key, String defaultValue) {
        Object val = args?.get(key);
        if (val == null) return defaultValue;
        String strVal = String.valueOf(val).trim();
        if (String.isBlank(strVal) || strVal == 'null') return defaultValue;
        return strVal;
    }

    // ─────────────────────────────────────────────────────────────
    // EXCEPTION
    // ─────────────────────────────────────────────────────────────
    public class PermissionSetException extends Exception {}
}