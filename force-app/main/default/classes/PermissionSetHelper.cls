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

        // Read existing permission set to get current state + label
        MetadataService.IReadResult readResult = port.readMetadata(
            'PermissionSet', new List<String>{ permSetName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }
        MetadataService.PermissionSet permSet = (MetadataService.PermissionSet) records[0];

        // Merge into existing XML in ZipBuilder if already queued, else start fresh
        String existingXml = ZipBuilder.files.get('permissionsets/' + permSetName + '.permissionset-meta.xml');
        String xml = buildPermissionSetXml(permSet, existingXml,
            objectName, allowRead, allowCreate, allowEdit, allowDelete, viewAllRecords, modifyAllRecords,
            null, null, null);

        String filePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
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

        MetadataService.IReadResult readResult = port.readMetadata(
            'PermissionSet', new List<String>{ permSetName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }
        MetadataService.PermissionSet permSet = (MetadataService.PermissionSet) records[0];

        String existingXml = ZipBuilder.files.get('permissionsets/' + permSetName + '.permissionset-meta.xml');
        String xml = buildPermissionSetXml(permSet, existingXml,
            null, null, null, null, null, null, null,
            fullFieldName, readable, editable);

        String filePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
        ZipBuilder.addFile('PermissionSet', permSetName, filePath, xml);
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

        System.debug('PermissionSetHelper.grantAllFieldsAccess() called');
        System.debug('permSet=' + permSetName + ', object=' + objectName);

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw new PermissionSetException('Object not found: ' + objectName);
        }

        MetadataService.IReadResult readResult = port.readMetadata(
            'PermissionSet', new List<String>{ permSetName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new PermissionSetException('Permission Set not found: ' + permSetName);
        }
        MetadataService.PermissionSet permSet = (MetadataService.PermissionSet) records[0];

        // Start from existing ZIP file if already modified this session
        String existingXml = ZipBuilder.files.get('permissionsets/' + permSetName + '.permissionset-meta.xml');
        String xml = existingXml != null ? existingXml : buildBasePermissionSetXml(permSet);

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

        String filePath = 'permissionsets/' + permSetName + '.permissionset-meta.xml';
        ZipBuilder.addFile('PermissionSet', permSetName, filePath, xml);
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