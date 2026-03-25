public class MetadataHelper {

    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('            ── MetadataHelper: initializing MetadataPort connection...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = UserInfo.getSessionId();
                System.debug('            ── MetadataHelper: MetadataPort ready. Endpoint = ' + port.endpoint_x);
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT — LIST
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> getSObjects(Boolean customOnly) {
        System.debug('            ── MetadataHelper.getSObjects() called. customOnly=' + customOnly);
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        for (Schema.SObjectType objType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = objType.getDescribe();
            if (customOnly == true && !describe.isCustom()) continue;
            result.add(new Map<String, Object>{
                'apiName'  => describe.getName(),
                'label'    => describe.getLabel(),
                'isCustom' => describe.isCustom()
            });
        }

        System.debug('            ✔ MetadataHelper.getSObjects(): returning ' + result.size() + ' objects');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT — DESCRIBE
    // ─────────────────────────────────────────────────────────────
    public static Map<String, Object> describeSObject(String objectName) {
        objectName = addObjectSuffix(objectName);
        System.debug('            ── MetadataHelper.describeSObject() called for [' + objectName + ']');

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) throw new MetadataHelperException('Object not found: ' + objectName);

        Schema.DescribeSObjectResult describe = objType.getDescribe();
        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        for (Schema.SObjectField field : describe.fields.getMap().values()) {
            Schema.DescribeFieldResult f = field.getDescribe();
            fields.add(new Map<String, Object>{
                'apiName'  => f.getName(),
                'label'    => f.getLabel(),
                'type'     => String.valueOf(f.getType()),
                'required' => !f.isNillable(),
                'isCustom' => f.isCustom()
            });
        }

        System.debug('            ✔ MetadataHelper.describeSObject(): found object with ' + fields.size() + ' fields');
        return new Map<String, Object>{
            'apiName'    => describe.getName(),
            'label'      => describe.getLabel(),
            'isCustom'   => describe.isCustom(),
            'fieldCount' => fields.size(),
            'fields'     => fields
        };
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT — CREATE
    // ─────────────────────────────────────────────────────────────
    public static void createSObject(String objectName, Map<String, Object> args) {
        objectName = addSuffix(objectName);
        System.debug('            ── MetadataHelper.createSObject() called for [' + objectName + ']');

        String nameFieldType  = getRequired(args, 'nameFieldType');
        String nameFieldLabel = getRequired(args, 'nameFieldLabel');
        String label          = getRequired(args, 'label');
        String pluralLabel    = getRequired(args, 'pluralLabel');
        String sharingModel   = getOptional(args, 'sharingModel', 'ReadWrite');
        String description    = getOptional(args, 'description', null);
        String autoNumFormat  = getOptional(args, 'autoNumberFormat', 'RES-{0000}');

        // Build XML
        String xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml += '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">';
        xml += '    <label>' + escapeXml(label) + '</label>';
        xml += '    <pluralLabel>' + escapeXml(pluralLabel) + '</pluralLabel>';
        if (String.isNotBlank(description)) {
            xml += '    <description>' + escapeXml(description) + '</description>';
        }
        xml += '    <nameField>';
        xml += '        <label>' + escapeXml(nameFieldLabel) + '</label>';
        xml += '        <type>' + nameFieldType + '</type>';
        if (nameFieldType == 'AutoNumber') {
            xml += '        <displayFormat>' + autoNumFormat + '</displayFormat>';
        }
        xml += '    </nameField>';
        xml += '    <deploymentStatus>Deployed</deploymentStatus>';
        xml += '    <sharingModel>' + sharingModel + '</sharingModel>';
        xml += '</CustomObject>';

        String filePath = 'objects/' + objectName + '.object';
        ZipBuilder.addFile('CustomObject', objectName, filePath, xml);
        System.debug('            ✔ MetadataHelper.createSObject(): [' + objectName + '] queued for deploy');

        // Auto-create a Tab for the object so it appears in the App navigation
        createTabForObject(objectName, label);
    }

    // ─────────────────────────────────────────────────────────────
    // TAB — CREATE FOR OBJECT (called automatically on object create)
    // ─────────────────────────────────────────────────────────────
    public static void createTabForObject(String objectName, String label) {
        objectName = addSuffix(objectName);
        System.debug('            ── MetadataHelper.createTabForObject() called for [' + objectName + ']');

        String tabXml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<customObject>true</customObject>'
            + '<motif>Custom18: Form</motif>'
            + '</CustomTab>';

        String filePath = 'tabs/' + objectName + '.tab';
        ZipBuilder.addFile('CustomTab', objectName, filePath, tabXml);
        System.debug('            ✔ MetadataHelper.createTabForObject(): tab for [' + objectName + '] queued for deploy');

        // Set tab visibility to DefaultOn for System Administrator profile
        setTabVisibilityOnAdminProfile(objectName);
    }

    // ─────────────────────────────────────────────────────────────
    // TAB — STANDALONE CREATE (called from tool directly)
    // ─────────────────────────────────────────────────────────────
    public static void createTab(String objectName, Map<String, Object> args) {
        objectName = addSuffix(objectName);
        String motif = getOptional(args, 'motif', 'Custom18: Form');

        System.debug('            ── MetadataHelper.createTab() called for [' + objectName + ']');

        String tabXml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<customObject>true</customObject>'
            + '<motif>' + escapeXml(motif) + '</motif>'
            + '</CustomTab>';

        String filePath = 'tabs/' + objectName + '.tab';
        ZipBuilder.addFile('CustomTab', objectName, filePath, tabXml);
        System.debug('            ✔ MetadataHelper.createTab(): tab for [' + objectName + '] queued for deploy');

        // Set tab visibility to DefaultOn for System Administrator profile
        setTabVisibilityOnAdminProfile(objectName);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Set tab DefaultOn on System Administrator profile
    // Uses minimal profile XML — Salesforce merges tabVisibilities additively
    // ─────────────────────────────────────────────────────────────
    private static void setTabVisibilityOnAdminProfile(String objectName) {
        System.debug('            ── MetadataHelper.setTabVisibilityOnAdminProfile() called for [' + objectName + ']');

        // Check if Admin profile already staged this session — merge into it
        String profilePath = 'profiles/Admin.profile';
        String existingXml = ZipBuilder.files.get(profilePath);
        String profileXml;

        if (existingXml != null) {
            // Merge into already-staged profile XML
            String tabVisBlock = '    <tabVisibilities>'
                + '<tab>' + objectName + '</tab>'
                + '<visibility>DefaultOn</visibility>'
                + '</tabVisibilities>\n';
            profileXml = existingXml.replace('</Profile>', tabVisBlock + '</Profile>');
        } else {
            // Minimal profile XML — Salesforce merges tabVisibilities additively
            profileXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n'
                + '    <tabVisibilities>\n'
                + '        <tab>' + objectName + '</tab>\n'
                + '        <visibility>DefaultOn</visibility>\n'
                + '    </tabVisibilities>\n'
                + '</Profile>';
        }

        ZipBuilder.addFile('Profile', 'Admin', profilePath, profileXml);
        System.debug('            ✔ MetadataHelper.setTabVisibilityOnAdminProfile(): tab visibility set for [' + objectName + ']');
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT — UPDATE
    // ─────────────────────────────────────────────────────────────
    public static void updateSObject(String objectName, Map<String, Object> args) {
        objectName = addSuffix(objectName);
        System.debug('            ── MetadataHelper.updateSObject() called for [' + objectName + ']');

        // For updates we must read current state first to preserve existing settings
        System.debug('            ── MetadataHelper: reading current object from Salesforce...');
        MetadataService.IReadResult readResult = port.readMetadata(
            'CustomObject', new List<String>{ objectName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new MetadataHelperException('Object not found: ' + objectName);
        }

        MetadataService.CustomObject obj = (MetadataService.CustomObject) records[0];

        // Apply updates
        String newLabel       = getOptional(args, 'label', null);
        String newPluralLabel = getOptional(args, 'pluralLabel', null);
        String newDesc        = getOptional(args, 'description', null);
        if (String.isNotBlank(newLabel))       obj.label       = newLabel;
        if (String.isNotBlank(newPluralLabel)) obj.pluralLabel = newPluralLabel;
        if (String.isNotBlank(newDesc))        obj.description = newDesc;

        // Build XML from updated object
        String xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml += '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">';
        xml += '    <label>' + escapeXml(obj.label) + '</label>';
        xml += '    <pluralLabel>' + escapeXml(obj.pluralLabel) + '</pluralLabel>';
        if (String.isNotBlank(obj.description)) {
            xml += '    <description>' + escapeXml(obj.description) + '</description>';
        }
        if (obj.nameField != null) {
            xml += '    <nameField>';
            xml += '        <label>' + escapeXml(obj.nameField.label) + '</label>';
            xml += '        <type>' + obj.nameField.type_x + '</type>';
            xml += '    </nameField>';
        }
        xml += '    <deploymentStatus>Deployed</deploymentStatus>';
        xml += '    <sharingModel>' + (obj.sharingModel != null ? obj.sharingModel : 'ReadWrite') + '</sharingModel>';
        xml += '</CustomObject>';

        String filePath = 'objects/' + objectName + '.object';
        ZipBuilder.addFile('CustomObject', objectName, filePath, xml);
        System.debug('            ✔ MetadataHelper.updateSObject(): [' + objectName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // SOBJECT — DELETE
    // ─────────────────────────────────────────────────────────────
    public static void deleteSObject(String objectName) {
        objectName = addSuffix(objectName);
        System.debug('            ── MetadataHelper.deleteSObject() called for [' + objectName + ']');

        // Merge into existing destructiveChangesPost.xml if present
        String existingDestructive = ZipBuilder.files.get('destructiveChangesPost.xml');
        String destructiveXml;
        if (existingDestructive != null && existingDestructive.contains('<name>CustomObject</name>')) {
            destructiveXml = existingDestructive.replace(
                '<name>CustomObject</name>',
                '<members>' + objectName + '</members>' + '<name>CustomObject</name>'
            );
        } else if (existingDestructive != null) {
            destructiveXml = existingDestructive.replace(
                '</Package>',
                '<types><members>' + objectName + '</members>' + '<name>CustomObject</name></types></Package>'
            );
        } else {
            destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                + '<types>'
                + '<members>' + objectName + '</members>'
                + '<name>CustomObject</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', objectName, 'destructiveChangesPost.xml', destructiveXml);
        System.debug('            ✔ MetadataHelper.deleteSObject(): [' + objectName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD — LIST
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> getSObjectFieldsList(String objectName) {
        objectName = addObjectSuffix(objectName);
        System.debug('            ── MetadataHelper.getSObjectFieldsList() called for [' + objectName + ']');

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) throw new MetadataHelperException('Object not found: ' + objectName);

        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult f = field.getDescribe();
            fields.add(new Map<String, Object>{
                'apiName'  => f.getName(),
                'label'    => f.getLabel(),
                'type'     => String.valueOf(f.getType()),
                'required' => !f.isNillable(),
                'isCustom' => f.isCustom()
            });
        }

        System.debug('            ✔ MetadataHelper.getSObjectFieldsList(): returning ' + fields.size() + ' fields');
        return fields;
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD — DESCRIBE
    // ─────────────────────────────────────────────────────────────
    public static Map<String, Object> describeSObjectField(String objectName, String fieldName) {
        objectName = addObjectSuffix(objectName);
        fieldName  = addFieldSuffix(fieldName);
        System.debug('            ── MetadataHelper.describeSObjectField() called for [' + objectName + '.' + fieldName + ']');

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) throw new MetadataHelperException('Object not found: ' + objectName);

        Schema.SObjectField field = objType.getDescribe().fields.getMap().get(fieldName.toLowerCase());
        if (field == null) throw new MetadataHelperException('Field not found: ' + fieldName + ' on ' + objectName);

        Schema.DescribeFieldResult f = field.getDescribe();
        System.debug('            ✔ MetadataHelper.describeSObjectField(): found field type=' + f.getType());
        return new Map<String, Object>{
            'apiName'  => f.getName(),
            'label'    => f.getLabel(),
            'type'     => String.valueOf(f.getType()),
            'required' => !f.isNillable(),
            'isCustom' => f.isCustom(),
            'length'   => f.getLength()
        };
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD — CREATE
    // Uses MDAPI format: field embedded inside object XML wrapper.
    // Salesforce merges the field into the existing object on deploy.
    // Multiple fields on same object are merged into a single object file.
    // ─────────────────────────────────────────────────────────────
    public static void createField(String objectName, String fieldName, Map<String, Object> args) {
        objectName = addObjectSuffix(objectName);
        fieldName  = addFieldSuffix(fieldName);
        String fieldType = getRequired(args, 'type');
        String label     = getRequired(args, 'label');

        System.debug('            ── MetadataHelper.createField() called for [' + objectName + '.' + fieldName + ']');

        // Guard: check if field already exists — avoids deploy failure on retry
        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType != null) {
            Schema.SObjectField existingField = objType.getDescribe().fields.getMap().get(fieldName.toLowerCase());
            if (existingField != null) {
                System.debug('            ⚠ MetadataHelper.createField(): field [' + objectName + '.' + fieldName + '] already exists — skipping deploy');
                throw new MetadataHelperException('Field ' + objectName + '.' + fieldName + ' already exists. Use sobject_field_update to modify it.');
            }
        }

        String fieldXml = buildFieldXmlBlock(fieldName, fieldType, label, args);
        String filePath = 'objects/' + objectName + '.object';

        // If another field on the same object is already queued, merge into that file
        String existingXml = ZipBuilder.files.get(filePath);
        String objXml;
        if (existingXml != null) {
            objXml = existingXml.replace('</CustomObject>', fieldXml + '</CustomObject>');
        } else {
            // Read object label from org — Salesforce requires a non-empty label even for partial deploys
            objXml = buildObjectWrapperWithField(objectName, fieldXml);
        }

        ZipBuilder.addFile('CustomObject', objectName, filePath, objXml);
        System.debug('            ✔ MetadataHelper.createField(): [' + objectName + '.' + fieldName + '] queued for deploy');

        
    }
    

    // Builds a minimal CustomObject XML wrapper with the object's real metadata.
    // Reads label, pluralLabel, sharingModel, and nameField from the org via SOAP.
    // Salesforce requires all of these even for partial (field-only) deploys.
    private static String buildObjectWrapperWithField(String objectName, String fieldXml) {
        System.debug('            ── MetadataHelper: reading object metadata for wrapper [' + objectName + ']');
        MetadataService.IReadResult readResult = port.readMetadata(
            'CustomObject', new List<String>{ objectName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();

        // Fallback values in case read fails
        String objLabel        = objectName.replace('__c', '');
        String objPluralLabel  = objLabel + 's';
        String sharingModel    = 'ReadWrite';
        String nameFieldLabel  = 'Name';
        String nameFieldType   = 'Text';

        if (records != null && !records.isEmpty() && records[0] != null) {
            MetadataService.CustomObject obj = (MetadataService.CustomObject) records[0];
            if (String.isNotBlank(obj.label))        objLabel       = obj.label;
            if (String.isNotBlank(obj.pluralLabel))  objPluralLabel = obj.pluralLabel;
            if (String.isNotBlank(obj.sharingModel)) sharingModel   = obj.sharingModel;
            if (obj.nameField != null) {
                if (String.isNotBlank(obj.nameField.label))  nameFieldLabel = obj.nameField.label;
                if (String.isNotBlank(obj.nameField.type_x)) nameFieldType  = obj.nameField.type_x;
            }
        }

        // MasterDetail fields require sharingModel=ControlledByParent — Salesforce enforces this
        if (fieldXml.contains('<type>MasterDetail</type>')) {
            sharingModel = 'ControlledByParent';
        }

        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<label>' + escapeXml(objLabel) + '</label>'
            + '<pluralLabel>' + escapeXml(objPluralLabel) + '</pluralLabel>'
            + '<nameField>'
            +     '<label>' + escapeXml(nameFieldLabel) + '</label>'
            +     '<type>' + nameFieldType + '</type>'
            + '</nameField>'
            + '<deploymentStatus>Deployed</deploymentStatus>'
            + '<sharingModel>' + sharingModel + '</sharingModel>'
            + fieldXml
            + '</CustomObject>';
    }

    // Builds the inner <fields>...</fields> XML block for a field (no root element)
    private static String buildFieldXmlBlock(String fieldName, String fieldType, String label, Map<String, Object> args) {
        String xml = '<fields>';
        xml += '<fullName>' + fieldName + '</fullName>';
        xml += '<label>' + escapeXml(label) + '</label>';
        xml += '<type>' + fieldType + '</type>';

        String req = getOptional(args, 'required', 'false');
        if (req == 'true') xml += '<required>true</required>';

        String fieldDesc = getOptional(args, 'description', null);
        if (String.isNotBlank(fieldDesc)) xml += '<description>' + escapeXml(fieldDesc) + '</description>';

        String help = getOptional(args, 'helpText', null);
        if (String.isNotBlank(help)) xml += '<inlineHelpText>' + escapeXml(help) + '</inlineHelpText>';

        if (fieldType == 'Text') {
            xml += '<length>' + getOptional(args, 'length', '255') + '</length>';
        } else if (fieldType == 'TextArea') {
            xml += '<length>255</length>';
        } else if (fieldType == 'LongTextArea') {
            xml += '<length>32768</length>';
            xml += '<visibleLines>5</visibleLines>';
        } else if (fieldType == 'Number' || fieldType == 'Currency' || fieldType == 'Percent') {
            xml += '<precision>' + getOptional(args, 'precision', '18') + '</precision>';
            xml += '<scale>' + getOptional(args, 'scale', '2') + '</scale>';
        } else if (fieldType == 'Checkbox') {
            xml += '<defaultValue>' + getOptional(args, 'defaultValue', 'false') + '</defaultValue>';
        } else if (fieldType == 'Picklist' || fieldType == 'MultiselectPicklist') {
            String vals = getRequired(args, 'picklistValues');
            xml += '<valueSet><restricted>false</restricted><valueSetDefinition><sorted>false</sorted>';
            Boolean isFirst = true;
            for (String v : vals.split(',')) {
                String val = v.trim();
                if (String.isBlank(val)) continue;
                xml += '<value>'
                    + '<fullName>' + escapeXml(val) + '</fullName>'
                    + '<default>' + (isFirst ? 'false' : 'false') + '</default>'
                    + '<label>' + escapeXml(val) + '</label>'
                    + '</value>';
                isFirst = false;
            }
            xml += '</valueSetDefinition></valueSet>';
            if (fieldType == 'MultiselectPicklist') {
                xml += '<visibleLines>4</visibleLines>';
            }
        } else if (fieldType == 'Lookup' || fieldType == 'MasterDetail') {
            String refTo   = getRequired(args, 'referenceTo');
            String defaultRelName = fieldName.replace('__c', '');
            String relName = getOptional(args, 'relationshipName', defaultRelName);
            xml += '<referenceTo>' + refTo + '</referenceTo>';
            xml += '<relationshipName>' + relName + '</relationshipName>';
            if (fieldType == 'MasterDetail') {
                xml += '<reparentableMasterDetail>false</reparentableMasterDetail>';
                xml += '<writeRequiresMasterRead>false</writeRequiresMasterRead>';
            }
        }

        xml += '</fields>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD — UPDATE
    // Reads current field via SOAP to preserve all existing settings,
    // then deploys updated field embedded in MDAPI object XML wrapper.
    // ─────────────────────────────────────────────────────────────
    public static void updateField(String objectName, String fieldName, Map<String, Object> args) {
        objectName = addObjectSuffix(objectName);
        fieldName  = addFieldSuffix(fieldName);
        String fullName = objectName + '.' + fieldName;

        System.debug('            ── MetadataHelper.updateField() called for [' + fullName + ']');
        System.debug('            ── MetadataHelper: reading current field from Salesforce first...');

        // Read current state to preserve all existing settings
        MetadataService.IReadResult readResult = port.readMetadata(
            'CustomField', new List<String>{ fullName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new MetadataHelperException('Field not found: ' + fullName);
        }
        MetadataService.CustomField field = (MetadataService.CustomField) records[0];

        // Apply requested updates
        String newLabel    = getOptional(args, 'label', null);
        String newDesc     = getOptional(args, 'description', null);
        String newHelp     = getOptional(args, 'helpText', null);
        String newRequired = getOptional(args, 'required', null);
        if (String.isNotBlank(newLabel))    field.label          = newLabel;
        if (String.isNotBlank(newDesc))     field.description    = newDesc;
        if (String.isNotBlank(newHelp))     field.inlineHelpText = newHelp;
        if (String.isNotBlank(newRequired)) field.required       = Boolean.valueOf(newRequired);

        // Build field XML block with all preserved + updated settings
        String fieldXml = '<fields>';
        fieldXml += '<fullName>' + fieldName + '</fullName>';
        fieldXml += '<label>' + escapeXml(field.label) + '</label>';
        fieldXml += '<type>' + field.type_x + '</type>';
        if (field.required == true) fieldXml += '<required>true</required>';
        if (String.isNotBlank(field.description))    fieldXml += '<description>' + escapeXml(field.description) + '</description>';
        if (String.isNotBlank(field.inlineHelpText)) fieldXml += '<inlineHelpText>' + escapeXml(field.inlineHelpText) + '</inlineHelpText>';
        if (field.length != null)    fieldXml += '<length>' + field.length + '</length>';
        if (field.precision != null) fieldXml += '<precision>' + field.precision + '</precision>';
        if (field.scale != null)     fieldXml += '<scale>' + field.scale + '</scale>';
        // Preserve Lookup/MasterDetail relationship info
        if (String.isNotBlank(field.referenceTo)) {
            fieldXml += '<referenceTo>' + field.referenceTo + '</referenceTo>';
            fieldXml += '<relationshipName>' + field.relationshipName + '</relationshipName>';
        }
        // Preserve Picklist values
        if (field.valueSet != null && field.valueSet.valueSetDefinition != null) {
            fieldXml += '<valueSet><restricted>false</restricted><valueSetDefinition><sorted>false</sorted>';
            for (MetadataService.CustomValue cv : field.valueSet.valueSetDefinition.value) {
                fieldXml += '<value>'
                    + '<fullName>' + escapeXml(cv.fullName) + '</fullName>'
                    + '<default>false</default>'
                    + '<label>' + escapeXml(cv.label) + '</label>'
                    + '</value>';
            }
            fieldXml += '</valueSetDefinition></valueSet>';
        }
        // Preserve Checkbox default
        if (field.type_x == 'Checkbox' && field.defaultValue != null) {
            fieldXml += '<defaultValue>' + field.defaultValue + '</defaultValue>';
        }
        fieldXml += '</fields>';

        // Wrap in MDAPI object XML — merge with existing queued object file if present
        String filePath = 'objects/' + objectName + '.object';
        String existingXml = ZipBuilder.files.get(filePath);
        String objXml;
        if (existingXml != null) {
            objXml = existingXml.replace('</CustomObject>', fieldXml + '</CustomObject>');
        } else {
            // Read object label from org — Salesforce requires a non-empty label even for partial deploys
            objXml = buildObjectWrapperWithField(objectName, fieldXml);
        }

        ZipBuilder.addFile('CustomObject', objectName, filePath, objXml);
        System.debug('            ✔ MetadataHelper.updateField(): [' + fullName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // FIELD — DELETE
    // Uses destructiveChangesPost.xml in MDAPI format.
    // CustomField type with full member name ObjectName__c.FieldName__c.
    // ─────────────────────────────────────────────────────────────
    public static void deleteField(String objectName, String fieldName) {
        objectName = addObjectSuffix(objectName);
        fieldName  = addFieldSuffix(fieldName);
        String fullName = objectName + '.' + fieldName;
        System.debug('            ── MetadataHelper.deleteField() called for [' + fullName + ']');

        // Merge into existing destructiveChangesPost.xml if present
        String existingDestructive = ZipBuilder.files.get('destructiveChangesPost.xml');
        String destructiveXml;
        if (existingDestructive != null && existingDestructive.contains('<name>CustomField</name>')) {
            destructiveXml = existingDestructive.replace(
                '<name>CustomField</name>',
                '<members>' + fullName + '</members>' + '<name>CustomField</name>'
            );
        } else if (existingDestructive != null) {
            destructiveXml = existingDestructive.replace(
                '</Package>',
                '<types><members>' + fullName + '</members>' + '<name>CustomField</name></types></Package>'
            );
        } else {
            destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                + '<types>'
                + '<members>' + fullName + '</members>'
                + '<name>CustomField</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', fullName, 'destructiveChangesPost.xml', destructiveXml);
        System.debug('            ✔ MetadataHelper.deleteField(): [' + fullName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // TOOLING API QUERY
    // ─────────────────────────────────────────────────────────────
    public static Map<String, Object> runToolingApiQuery(String query) {
        System.debug('            ── MetadataHelper.runToolingApiQuery() called');
        System.debug('            ── Query: ' + query);

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
        System.debug('            ── MetadataHelper: Tooling API status = ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            throw new MetadataHelperException(
                'Tooling API query failed. Status: ' + res.getStatusCode() + ' Body: ' + res.getBody()
            );
        }

        System.debug('            ✔ MetadataHelper.runToolingApiQuery(): query succeeded');
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Result checkers
    // ─────────────────────────────────────────────────────────────

    private static void checkUpsertResults(MetadataService.UpsertResult[] results) {
        if (results == null || results.isEmpty()) {
            throw new MetadataHelperException('No results returned from Metadata API');
        }
        for (MetadataService.UpsertResult result : results) {
            if (!result.success) {
                String errors = '';
                if (result.errors != null) {
                    for (MetadataService.Error err : result.errors) {
                        errors += err.message + ' (' + err.statusCode + '). ';
                    }
                }
                System.debug('            ✖ MetadataHelper: upsert FAILED for [' + result.fullName + ']: ' + errors);
                throw new MetadataHelperException('Metadata API error on ' + result.fullName + ': ' + errors);
            }
            System.debug('            ✔ MetadataHelper: Salesforce confirmed success for [' + result.fullName + ']');
        }
    }

    // private static void checkDeleteResults(MetadataService.DeleteResult[] results) {
    //     if (results == null || results.isEmpty()) {
    //         throw new MetadataHelperException('No results returned from Metadata API');
    //     }
    //     for (MetadataService.DeleteResult result : results) {
    //         if (!result.success) {
    //             String errors = '';
    //             if (result.errors != null) {
    //                 for (MetadataService.Error err : result.errors) {
    //                     errors += err.message + ' (' + err.statusCode + '). ';
    //                 }
    //             }
    //             System.debug('            ✖ MetadataHelper: delete FAILED for [' + result.fullName + ']: ' + errors);
    //             throw new MetadataHelperException('Delete error on ' + result.fullName + ': ' + errors);
    //         }
    //         System.debug('            ✔ MetadataHelper: Salesforce confirmed delete for [' + result.fullName + ']');
    //     }
    // }

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
    // PRIVATE — Parameter helpers
    // ─────────────────────────────────────────────────────────────

    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

    private static String addSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }
    // For OBJECT names — only add __c if the object isn't already in the schema as-is
    private static String addObjectSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        
        // Already has __c — return as-is
        if (name.endsWith('__c')) return name;
        
        // Check if it exists as a standard object (no suffix)
        if (Schema.getGlobalDescribe().containsKey(name) || 
            Schema.getGlobalDescribe().containsKey(name.toLowerCase())) {
            return name; // Standard object — don't add __c
        }
        
        // Not found without suffix — assume custom, add __c
        return name + '__c';
    }

    // For FIELD names — new fields are always custom, always need __c
    // UNLESS it's a standard field (for read/describe only, not for create)
    private static String addFieldSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new MetadataHelperException('Required parameter missing: ' + key);
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

    private static MetadataService.ValueSet buildPicklistValueSet(String csvValues) {
        MetadataService.ValueSet valueSet = new MetadataService.ValueSet();
        MetadataService.ValueSetValuesDefinition definition =
            new MetadataService.ValueSetValuesDefinition();
        List<MetadataService.CustomValue> picklistValues = new List<MetadataService.CustomValue>();
        Boolean isFirst = true;
        for (String val : csvValues.split(',')) {
            val = val.trim();
            if (String.isNotBlank(val)) {
                MetadataService.CustomValue cv = new MetadataService.CustomValue();
                cv.fullName  = val;
                cv.label     = val;
                cv.isActive  = true;
                cv.default_x = isFirst;
                picklistValues.add(cv);
                isFirst = false;
            }
        }
        definition.value            = picklistValues;
        valueSet.valueSetDefinition = definition;
        return valueSet;
    }

    public class MetadataHelperException extends Exception {}
}