/**
 * RecordTypeHelper.cls
 *
 * Handles Record Type metadata operations.
 * Record types are deployed as part of the parent object's .object-meta.xml file.
 *
 * CRITICAL PATTERN:
 * Unlike fields (which have separate files), record types are embedded in the
 * CustomObject XML. This means:
 * 1. We need to read existing object XML (if it exists)
 * 2. Parse it to find existing record types
 * 3. Add/update/remove the record type
 * 4. Re-write the entire object XML
 *
 * We use MetadataHelper.retrieveObject() to get current state, then modify it.
 */
public class RecordTypeHelper {

    // ─────────────────────────────────────────────────────────────
    // LIST RECORD TYPES
    // Uses Tooling API to query RecordType SObject
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listRecordTypes(Map<String, Object> args) {
        String objectApiName = (String) args.get('objectApiName');
        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.listRecordTypes() for object: ' + objectApiName);

        // Query via Tooling API
        String query = 'SELECT Id, DeveloperName, Name, Description, IsActive, SobjectType '
            + 'FROM RecordType '
            + 'WHERE SobjectType = \'' + objectApiName + '\' '
            + 'AND IsActive = true';

        Map<String, Object> response = MetadataHelper.runToolingApiQuery(query);
        List<Object> records = (List<Object>) response.get('records');

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rec : records) {
            Map<String, Object> rt = (Map<String, Object>) rec;
            result.add(new Map<String, Object>{
                'developerName' => rt.get('DeveloperName'),
                'label'         => rt.get('Name'),
                'description'   => rt.get('Description'),
                'isActive'      => rt.get('IsActive'),
                'objectType'    => rt.get('SobjectType')
            });
        }

        System.debug('RecordTypeHelper: found ' + result.size() + ' record type(s)');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE RECORD TYPE
    // Adds <recordTypes> block to object XML
    // ─────────────────────────────────────────────────────────────
    public static void createRecordType(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');
        String label          = (String) args.get('label');
        String description    = (String) args.get('description');
        String active         = String.valueOf(args.get('active'));
        String businessProcess = (String) args.get('businessProcess');

        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.createRecordType(): ' + objectApiName + '.' + recordTypeName);

        // Default active = true if not specified
        if (String.isBlank(active) || active == 'null') {
            active = 'true';
        }

        // Build record type XML block
        String recordTypeXml = buildRecordTypeXml(
            recordTypeName, 
            label, 
            description, 
            active, 
            businessProcess
        );

        // Add to ZipBuilder
        // CRITICAL: Record types are part of the object XML, not separate files
        // We'll use a special pattern: stage the record type fragment,
        // then in MetadataHelper.finalizeObjectXml() we'll merge all fragments
        String fragmentKey = 'recordTypes.' + objectApiName + '.' + recordTypeName;
        ZipBuilder.addFile(
            '__record_type_fragment__',  // special type marker
            fragmentKey,
            fragmentKey,  // path is also the key
            recordTypeXml
        );

        System.debug('RecordTypeHelper: record type fragment staged: ' + fragmentKey);
    }

    // ─────────────────────────────────────────────────────────────
    // UPDATE RECORD TYPE
    // Re-stages record type XML with updated values
    // ─────────────────────────────────────────────────────────────
    public static void updateRecordType(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');
        
        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.updateRecordType(): ' + objectApiName + '.' + recordTypeName);

        // Get current record type via Tooling API
        String query = 'SELECT DeveloperName, Name, Description, IsActive '
            + 'FROM RecordType '
            + 'WHERE SobjectType = \'' + objectApiName + '\' '
            + 'AND DeveloperName = \'' + recordTypeName + '\' LIMIT 1';

        Map<String, Object> response = MetadataHelper.runToolingApiQuery(query);
        List<Object> records = (List<Object>) response.get('records');

        if (records.isEmpty()) {
            throw new RecordTypeHelperException(
                'Record type ' + recordTypeName + ' not found on ' + objectApiName
            );
        }

        Map<String, Object> current = (Map<String, Object>) records[0];

        // Merge updates (only override if provided)
        String label       = args.containsKey('label') && args.get('label') != null
            ? (String) args.get('label')
            : (String) current.get('Name');
        
        String description = args.containsKey('description') && args.get('description') != null
            ? (String) args.get('description')
            : (String) current.get('Description');
        
        String active      = args.containsKey('active') && args.get('active') != null
            ? String.valueOf(args.get('active'))
            : String.valueOf(current.get('IsActive'));

        // Re-create with updated values
        String recordTypeXml = buildRecordTypeXml(
            recordTypeName,
            label,
            description,
            active,
            null  // businessProcess not updatable
        );

        String fragmentKey = 'recordTypes.' + objectApiName + '.' + recordTypeName;
        ZipBuilder.addFile(
            '__record_type_fragment__',
            fragmentKey,
            fragmentKey,
            recordTypeXml
        );

        System.debug('RecordTypeHelper: record type update staged: ' + fragmentKey);
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE RECORD TYPE
    // Removes from object XML via destructive deploy
    // ─────────────────────────────────────────────────────────────
    public static void deleteRecordType(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');

        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.deleteRecordType(): ' + objectApiName + '.' + recordTypeName);

        // Add to destructiveChangesPost.xml
        String fullName = objectApiName + '.' + recordTypeName;
        
        ZipBuilder.addFile(
            '__destructive__RecordType',
            fullName,
            '__destructive__RecordType__' + fullName,
            '<members>' + fullName + '</members>'
        );

        System.debug('RecordTypeHelper: record type queued for destructive deploy: ' + fullName);
    }

    // ─────────────────────────────────────────────────────────────
    // ASSIGN TO PROFILES
    // Modifies profile XML to include record type visibility
    // ─────────────────────────────────────────────────────────────
    public static void assignToProfiles(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');
        String profilesArg    = (String) args.get('profiles');
        String isDefault      = String.valueOf(args.get('default'));

        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.assignToProfiles(): RT=' + recordTypeName 
            + ', profiles=' + profilesArg + ', default=' + isDefault);

        // Default to false if not specified
        if (String.isBlank(isDefault) || isDefault == 'null') {
            isDefault = 'false';
        }

        List<String> profileNames;
        if (profilesArg == 'All') {
            // Get all profiles
            profileNames = ProfileHelper.getAllProfileNames();
        } else {
            // Parse JSON array
            profileNames = (List<String>) JSON.deserialize(profilesArg, List<String>.class);
        }

        System.debug('RecordTypeHelper: assigning to ' + profileNames.size() + ' profile(s)');

        for (String profileName : profileNames) {
            // Use ProfileHelper to add record type visibility
            ProfileHelper.addRecordTypeVisibility(
                profileName,
                objectApiName,
                recordTypeName,
                Boolean.valueOf(isDefault)
            );
        }

        System.debug('RecordTypeHelper: profile assignments staged');
    }

    // ─────────────────────────────────────────────────────────────
    // REMOVE FROM PROFILES
    // Removes record type visibility from profile XML
    // ─────────────────────────────────────────────────────────────
    public static void removeFromProfiles(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');
        String profilesArg    = (String) args.get('profiles');

        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);

        System.debug('RecordTypeHelper.removeFromProfiles(): RT=' + recordTypeName 
            + ', profiles=' + profilesArg);

        List<String> profileNames = (List<String>) JSON.deserialize(profilesArg, List<String>.class);

        for (String profileName : profileNames) {
            ProfileHelper.removeRecordTypeVisibility(
                profileName,
                objectApiName,
                recordTypeName
            );
        }

        System.debug('RecordTypeHelper: profile removals staged');
    }

    // ─────────────────────────────────────────────────────────────
    // SET PICKLIST VALUES
    // Controls which picklist values are available for this record type
    // ─────────────────────────────────────────────────────────────
    public static void setPicklistValues(Map<String, Object> args) {
        String objectApiName  = (String) args.get('objectApiName');
        String recordTypeName = (String) args.get('recordTypeName');
        String fieldName      = (String) args.get('fieldName');
        String valuesJson     = (String) args.get('values');
        String defaultValue   = (String) args.get('defaultValue');

        objectApiName = MetadataHelper.addObjectSuffix(objectApiName);
        fieldName     = MetadataHelper.addFieldSuffix(fieldName);

        System.debug('RecordTypeHelper.setPicklistValues(): RT=' + recordTypeName 
            + ', field=' + fieldName + ', values=' + valuesJson);

        List<String> values = (List<String>) JSON.deserialize(valuesJson, List<String>.class);

        // Build picklist mapping XML
        String picklistXml = '<picklistValues>\n';
        picklistXml += '    <picklist>' + fieldName + '</picklist>\n';
        
        for (String value : values) {
            picklistXml += '    <values>\n';
            picklistXml += '        <fullName>' + escapeXml(value) + '</fullName>\n';
            picklistXml += '        <default>' 
                + (value.equals(defaultValue) ? 'true' : 'false') 
                + '</default>\n';
            picklistXml += '    </values>\n';
        }
        
        picklistXml += '</picklistValues>';

        // Stage as fragment to be merged into record type XML
        String fragmentKey = 'recordTypePicklist.' + objectApiName + '.' 
            + recordTypeName + '.' + fieldName;
        
        ZipBuilder.addFile(
            '__record_type_picklist_fragment__',
            fragmentKey,
            fragmentKey,
            picklistXml
        );

        System.debug('RecordTypeHelper: picklist values fragment staged: ' + fragmentKey);
    }

    // ─────────────────────────────────────────────────────────────
    // BUILD RECORD TYPE XML
    // Generates the <recordTypes> XML block
    // ─────────────────────────────────────────────────────────────
    private static String buildRecordTypeXml(
        String developerName,
        String label,
        String description,
        String active,
        String businessProcess
    ) {
        String xml = '<recordTypes>\n';
        xml += '    <fullName>' + escapeXml(developerName) + '</fullName>\n';
        xml += '    <label>' + escapeXml(label) + '</label>\n';
        xml += '    <active>' + active + '</active>\n';
        
        if (String.isNotBlank(description) && description != 'null') {
            xml += '    <description>' + escapeXml(description) + '</description>\n';
        }
        
        if (String.isNotBlank(businessProcess) && businessProcess != 'null') {
            xml += '    <businessProcess>' + escapeXml(businessProcess) + '</businessProcess>\n';
        }
        
        xml += '</recordTypes>';
        
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // XML ESCAPE
    // ─────────────────────────────────────────────────────────────
    private static String escapeXml(String input) {
        if (String.isBlank(input)) return '';
        return input
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&apos;');
    }

    public class RecordTypeHelperException extends Exception {}
}