public class ProfileHelper {

    private static final Map<String, String> PROFILE_NAME_MAP = new Map<String, String>{
        'System Administrator'              => 'Admin',
        'Standard User'                     => 'Standard',
        'Standard Platform User'            => 'StandardAul',
        'Marketing User'                    => 'MarketingProfile',
        'Contract Manager'                  => 'ContractManager',
        'Solution Manager'                  => 'SolutionManager',
        'Authenticated Website'             => 'PlatformPortal',
        'High Volume Customer Portal'       => 'HighVolumePortal',
        'Force.com - App Subscription User' => 'Force%2Ecom - App Subscription User',
        'Force.com - Free User'             => 'Force%2Ecom - Free User'
    };

    private static MetadataPort port {
        get {
            if (port == null) {
                System.debug('ProfileHelper: initializing MetadataPort...');
                port = new MetadataPort();
                port.endpoint_x = 'https://' + DomainCreator.getOrgMyDomainHostname()
                    + '/services/Soap/m/61.0';
                port.SessionHeader = new MetadataService.SessionHeader_element();
                port.SessionHeader.sessionId = getSessionId();
                System.debug('ProfileHelper: MetadataPort ready.');
            }
            return port;
        }
        set;
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — LIST
    // Returns all profiles via SOQL (read-only, no deploy needed)
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listProfiles() {
        System.debug('ProfileHelper.listProfiles() called');

        List<Profile> profiles = [
            SELECT Id, Name, Description, UserLicense.Name
            FROM Profile
            ORDER BY Name
        ];

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Profile p : profiles) {
            result.add(new Map<String, Object>{
                'id'          => p.Id,
                'name'        => p.Name,
                'description' => p.Description,
                'userLicense' => p.UserLicense?.Name
            });
        }

        System.debug('ProfileHelper.listProfiles(): found ' + result.size() + ' profiles');
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — CLONE
    //
    // Copies an existing profile and saves it as a new profile.
    // This is the only supported way to create a profile via metadata.
    //
    // Required args: sourceProfileName, newProfileName, newLabel
    // ─────────────────────────────────────────────────────────────
    public static void cloneProfile(Map<String, Object> args) {
        String sourceProfileName = getRequired(args, 'sourceProfileName');
        String newProfileName    = getRequired(args, 'newProfileName');

        String sourceMetadataName = resolveProfileName(sourceProfileName);

        System.debug('ProfileHelper.cloneProfile() called');
        System.debug('source=' + sourceMetadataName + ', new=' + newProfileName);

        // Read source profile
        MetadataService.IReadResult readResult = port.readMetadata(
            'Profile', new List<String>{ sourceMetadataName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new ProfileException('Source profile not found: ' + sourceProfileName);
        }

        MetadataService.Profile sourceProfile = (MetadataService.Profile) records[0];
        System.debug('ProfileHelper: source profile [' + sourceProfile.fullName + '] read successfully');

        // Build XML from source profile, replacing fullName
        String xml = buildBaseProfileXml(sourceProfile, newProfileName, null);

        String filePath = 'profiles/' + newProfileName + '.profile';
        ZipBuilder.addFile('Profile', newProfileName, filePath, xml);
        System.debug('ProfileHelper.cloneProfile(): [' + newProfileName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — DELETE
    //
    // Adds profile to destructiveChangesPost.xml in ZipBuilder.
    // ZIP deploy will remove the profile from the org.
    //
    // Required args: profileName
    // ─────────────────────────────────────────────────────────────
    public static void deleteProfile(Map<String, Object> args) {
        String profileName  = getRequired(args, 'profileName');
        String metadataName = resolveProfileName(profileName);

        System.debug('ProfileHelper.deleteProfile() called for [' + metadataName + ']');

        // Cannot delete standard/system profiles
        List<String> protectedProfiles = new List<String>{
            'Admin', 'Standard', 'StandardAul', 'MarketingProfile',
            'ContractManager', 'SolutionManager'
        };
        if (protectedProfiles.contains(metadataName)) {
            throw new ProfileException('Cannot delete standard Salesforce profile: ' + profileName);
        }

        addDestructiveXml(metadataName);
        System.debug('ProfileHelper.deleteProfile(): [' + metadataName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — GRANT OBJECT ACCESS
    // ─────────────────────────────────────────────────────────────
    public static void grantObjectAccess(Map<String, Object> args) {
        String profileName  = getRequired(args, 'profileName');
        String objectName   = addSuffix(getRequired(args, 'objectName'));
        String metadataName = resolveProfileName(profileName);

        System.debug('ProfileHelper.grantObjectAccess() called');
        System.debug('profile=' + profileName + ' (' + metadataName + '), object=' + objectName);

        Boolean allowRead        = Boolean.valueOf(getOptional(args, 'allowRead',        'false'));
        Boolean allowCreate      = Boolean.valueOf(getOptional(args, 'allowCreate',      'false'));
        Boolean allowEdit        = Boolean.valueOf(getOptional(args, 'allowEdit',        'false'));
        Boolean allowDelete      = Boolean.valueOf(getOptional(args, 'allowDelete',      'false'));
        Boolean viewAllRecords   = Boolean.valueOf(getOptional(args, 'viewAllRecords',   'false'));
        Boolean modifyAllRecords = Boolean.valueOf(getOptional(args, 'modifyAllRecords', 'false'));

        // Check if already staged this session — merge into existing ZIP XML
        String existingXml = ZipBuilder.files.get('profiles/' + metadataName + '.profile');
        String xml;
        if (existingXml != null) {
            xml = existingXml;
            // Remove existing block for this object if present
            String objectTag = '<object>' + objectName + '</object>';
            while (xml.contains(objectTag)) {
                Integer tagPos   = xml.indexOf(objectTag);
                Integer startIdx = xml.lastIndexOf('<objectPermissions>', tagPos);
                Integer endIdx   = xml.indexOf('</objectPermissions>', tagPos) + '</objectPermissions>'.length();
                if (startIdx == -1 || endIdx < startIdx) break;
                xml = xml.substring(0, startIdx) + xml.substring(endIdx);
            }
        } else {
            // Minimal profile XML — Salesforce merges objectPermissions additively
            xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n'
                + '</Profile>';
        }

        String objBlock = '    <objectPermissions>\n'
            + '        <allowCreate>'      + allowCreate      + '</allowCreate>\n'
            + '        <allowDelete>'      + allowDelete      + '</allowDelete>\n'
            + '        <allowEdit>'        + allowEdit        + '</allowEdit>\n'
            + '        <allowRead>'        + allowRead        + '</allowRead>\n'
            + '        <modifyAllRecords>' + modifyAllRecords + '</modifyAllRecords>\n'
            + '        <object>'           + objectName       + '</object>\n'
            + '        <viewAllRecords>'   + viewAllRecords   + '</viewAllRecords>\n'
            + '    </objectPermissions>\n';

        xml = xml.replace('</Profile>', objBlock + '</Profile>');

        String filePath = 'profiles/' + metadataName + '.profile';
        ZipBuilder.addFile('Profile', metadataName, filePath, xml);
        System.debug('ProfileHelper.grantObjectAccess(): SUCCESS - queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — REVOKE OBJECT ACCESS
    // ─────────────────────────────────────────────────────────────
    public static void revokeObjectAccess(Map<String, Object> args) {
        String profileName  = getRequired(args, 'profileName');
        String objectName   = addSuffix(getRequired(args, 'objectName'));
        String metadataName = resolveProfileName(profileName);

        System.debug('ProfileHelper.revokeObjectAccess() called');
        System.debug('profile=' + profileName + ', object=' + objectName);

        String existingXml = ZipBuilder.files.get('profiles/' + metadataName + '.profile');
        String xml;
        if (existingXml != null) {
            xml = existingXml;
            String objectTag = '<object>' + objectName + '</object>';
            Integer removedCount = 0;
            while (xml.contains(objectTag)) {
                Integer tagPos   = xml.indexOf(objectTag);
                Integer startIdx = xml.lastIndexOf('<objectPermissions>', tagPos);
                Integer endIdx   = xml.indexOf('</objectPermissions>', tagPos) + '</objectPermissions>'.length();
                if (startIdx == -1 || endIdx < startIdx) break;
                xml = xml.substring(0, startIdx) + xml.substring(endIdx);
                removedCount++;
            }
            System.debug('ProfileHelper.revokeObjectAccess(): removed ' + removedCount + ' block(s) from staged XML');
        } else {
            // Send minimal XML with allowRead=false — Salesforce sets all to false
            xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n'
                + '    <objectPermissions>\n'
                + '        <allowCreate>false</allowCreate>\n'
                + '        <allowDelete>false</allowDelete>\n'
                + '        <allowEdit>false</allowEdit>\n'
                + '        <allowRead>false</allowRead>\n'
                + '        <modifyAllRecords>false</modifyAllRecords>\n'
                + '        <object>' + objectName + '</object>\n'
                + '        <viewAllRecords>false</viewAllRecords>\n'
                + '    </objectPermissions>\n'
                + '</Profile>';
        }

        String filePath = 'profiles/' + metadataName + '.profile';
        ZipBuilder.addFile('Profile', metadataName, filePath, xml);
        System.debug('ProfileHelper.revokeObjectAccess(): SUCCESS - queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — GRANT FIELD ACCESS
    // ─────────────────────────────────────────────────────────────
    public static void grantFieldAccess(Map<String, Object> args) {
        String profileName   = getRequired(args, 'profileName');
        String objectName    = addSuffix(getRequired(args, 'objectName'));
        String fieldName     = addSuffix(getRequired(args, 'fieldName'));
        String fullFieldName = objectName + '.' + fieldName;
        String metadataName  = resolveProfileName(profileName);

        System.debug('ProfileHelper.grantFieldAccess() called');
        System.debug('profile=' + profileName + ', field=' + fullFieldName);

        Boolean readable = Boolean.valueOf(getOptional(args, 'readable', 'true'));
        Boolean editable = Boolean.valueOf(getOptional(args, 'editable', 'false'));

        String xml = getOrBuildMinimalXml(metadataName);
        xml = removeFieldBlock(xml, fullFieldName);

        String fieldBlock = '    <fieldPermissions>\n'
            + '        <editable>'  + editable      + '</editable>\n'
            + '        <field>'     + fullFieldName  + '</field>\n'
            + '        <readable>'  + readable       + '</readable>\n'
            + '    </fieldPermissions>\n';

        xml = xml.replace('</Profile>', fieldBlock + '</Profile>');

        String filePath = 'profiles/' + metadataName + '.profile';
        ZipBuilder.addFile('Profile', metadataName, filePath, xml);
        System.debug('ProfileHelper.grantFieldAccess(): SUCCESS for [' + fullFieldName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — REVOKE FIELD ACCESS
    // ─────────────────────────────────────────────────────────────
    public static void revokeFieldAccess(Map<String, Object> args) {
        String profileName   = getRequired(args, 'profileName');
        String objectName    = addSuffix(getRequired(args, 'objectName'));
        String fieldName     = addSuffix(getRequired(args, 'fieldName'));
        String fullFieldName = objectName + '.' + fieldName;
        String metadataName  = resolveProfileName(profileName);

        System.debug('ProfileHelper.revokeFieldAccess() called');
        System.debug('profile=' + profileName + ', field=' + fullFieldName);

        String xml = getOrBuildMinimalXml(metadataName);
        xml = removeFieldBlock(xml, fullFieldName);

        String fieldBlock = '    <fieldPermissions>\n'
            + '        <editable>false</editable>\n'
            + '        <field>'    + fullFieldName + '</field>\n'
            + '        <readable>false</readable>\n'
            + '    </fieldPermissions>\n';

        xml = xml.replace('</Profile>', fieldBlock + '</Profile>');

        String filePath = 'profiles/' + metadataName + '.profile';
        ZipBuilder.addFile('Profile', metadataName, filePath, xml);
        System.debug('ProfileHelper.revokeFieldAccess(): SUCCESS for [' + fullFieldName + '] queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PROFILE — GRANT ALL FIELDS ACCESS
    // ─────────────────────────────────────────────────────────────
    public static void grantAllFieldsAccess(Map<String, Object> args) {
        String profileName  = getRequired(args, 'profileName');
        String objectName   = addSuffix(getRequired(args, 'objectName'));
        Boolean readable    = Boolean.valueOf(getOptional(args, 'readable', 'true'));
        Boolean editable    = Boolean.valueOf(getOptional(args, 'editable', 'false'));
        String metadataName = resolveProfileName(profileName);

        System.debug('ProfileHelper.grantAllFieldsAccess() called');
        System.debug('profile=' + profileName + ', object=' + objectName);

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw new ProfileException('Object not found: ' + objectName);
        }

        String xml = getOrBuildMinimalXml(metadataName);

        Integer fieldsAdded = 0;
        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult f = field.getDescribe();
            if (!f.isCustom()) continue;
            String fullFieldName = objectName + '.' + f.getName();
            xml = removeFieldBlock(xml, fullFieldName);

            String fieldBlock = '    <fieldPermissions>\n'
                + '        <editable>'  + editable      + '</editable>\n'
                + '        <field>'     + fullFieldName  + '</field>\n'
                + '        <readable>'  + readable       + '</readable>\n'
                + '    </fieldPermissions>\n';
            xml = xml.replace('</Profile>', fieldBlock + '</Profile>');
            fieldsAdded++;
        }

        String filePath = 'profiles/' + metadataName + '.profile';
        ZipBuilder.addFile('Profile', metadataName, filePath, xml);
        System.debug('ProfileHelper.grantAllFieldsAccess(): SUCCESS - ' + fieldsAdded + ' fields queued for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get staged XML or build a fresh minimal profile XML
    // Used for grant/revoke operations — Salesforce merges additively
    // ─────────────────────────────────────────────────────────────
    private static String getOrBuildMinimalXml(String metadataName) {
        String existingXml = ZipBuilder.files.get('profiles/' + metadataName + '.profile');
        if (existingXml != null) {
            System.debug('ProfileHelper: using staged XML for [' + metadataName + ']');
            return existingXml;
        }
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n'
            + '</Profile>';
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Remove a fieldPermissions block from XML safely
    // ─────────────────────────────────────────────────────────────
    private static String removeFieldBlock(String xml, String fullFieldName) {
        String fieldTag = '<field>' + fullFieldName + '</field>';
        while (xml.contains(fieldTag)) {
            Integer tagPos   = xml.indexOf(fieldTag);
            Integer startIdx = xml.lastIndexOf('<fieldPermissions>', tagPos);
            Integer endIdx   = xml.indexOf('</fieldPermissions>', tagPos) + '</fieldPermissions>'.length();
            if (startIdx == -1 || endIdx < startIdx) break;
            xml = xml.substring(0, startIdx) + xml.substring(endIdx);
        }
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get existing staged XML or read fresh from org
    // Used ONLY for cloneProfile
    // ─────────────────────────────────────────────────────────────
    private static String getOrReadProfileXml(String metadataName, String profileName) {
        // If already staged in ZipBuilder this session, use that
        String existingXml = ZipBuilder.files.get('profiles/' + metadataName + '.profile');
        if (existingXml != null) {
            System.debug('ProfileHelper: using staged XML for [' + metadataName + ']');
            return existingXml;
        }

        // Otherwise read fresh from org
        MetadataService.IReadResult readResult = port.readMetadata(
            'Profile', new List<String>{ metadataName }
        );
        MetadataService.Metadata[] records = readResult.getRecords();
        if (records == null || records.isEmpty() || records[0] == null) {
            throw new ProfileException('Profile not found: ' + profileName);
        }

        MetadataService.Profile profile = (MetadataService.Profile) records[0];
        System.debug('ProfileHelper: read fresh profile [' + profile.fullName + '] from org');
        return buildBaseProfileXml(profile, metadataName, null);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Add destructive XML for profile delete
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String metadataName) {
        String existingDestructive = ZipBuilder.files.get('destructiveChangesPost.xml');
        String destructiveXml;

        if (existingDestructive != null && existingDestructive.contains('<name>Profile</name>')) {
            // Already has a Profile types block — insert new member
            destructiveXml = existingDestructive.replace(
                '<name>Profile</name>',
                '<members>' + metadataName + '</members><name>Profile</name>'
            );
        } else if (existingDestructive != null) {
            // Has other types — add Profile types block
            destructiveXml = existingDestructive.replace(
                '</Package>',
                '<types><members>' + metadataName + '</members><name>Profile</name></types></Package>'
            );
        } else {
            // Fresh destructive XML
            destructiveXml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                + '<types>'
                + '<members>' + metadataName + '</members>'
                + '<name>Profile</name>'
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', metadataName, 'destructiveChangesPost.xml', destructiveXml);
        System.debug('ProfileHelper.addDestructiveXml(): [' + metadataName + '] added to destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build base profile XML
    //
    // If newFullName/newLabel are provided, they override the source.
    // Used both for reading existing profiles and for cloning.
    // ─────────────────────────────────────────────────────────────
    private static String buildBaseProfileXml(MetadataService.Profile profile, String newFullName, String newLabel) {
        String fullName = String.isNotBlank(newFullName) ? newFullName : profile.fullName;

        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n'
            + '    <fullName>' + escapeXml(fullName) + '</fullName>\n';

        // Preserve custom flag
        if (profile.custom != null) {
            xml += '    <custom>' + profile.custom + '</custom>\n';
        }

        // Preserve user license — critical for profile to be valid
        if (String.isNotBlank(profile.userLicense)) {
            xml += '    <userLicense>' + escapeXml(profile.userLicense) + '</userLicense>\n';
        }

        // Preserve object permissions
        if (profile.objectPermissions != null) {
            for (MetadataService.ProfileObjectPermissions op : profile.objectPermissions) {
                Boolean allowCreate      = op.allowCreate      != null ? op.allowCreate      : false;
                Boolean allowDelete      = op.allowDelete      != null ? op.allowDelete      : false;
                Boolean allowEdit        = op.allowEdit        != null ? op.allowEdit        : false;
                Boolean allowRead        = op.allowRead        != null ? op.allowRead        : false;
                Boolean modifyAllRecords = op.modifyAllRecords != null ? op.modifyAllRecords : false;
                Boolean viewAllRecords   = op.viewAllRecords   != null ? op.viewAllRecords   : false;

                xml += '    <objectPermissions>\n'
                    + '        <allowCreate>'      + allowCreate      + '</allowCreate>\n'
                    + '        <allowDelete>'      + allowDelete      + '</allowDelete>\n'
                    + '        <allowEdit>'        + allowEdit        + '</allowEdit>\n'
                    + '        <allowRead>'        + allowRead        + '</allowRead>\n'
                    + '        <modifyAllRecords>' + modifyAllRecords + '</modifyAllRecords>\n'
                    + '        <object>'           + op.object_x      + '</object>\n'
                    + '        <viewAllRecords>'   + viewAllRecords   + '</viewAllRecords>\n'
                    + '    </objectPermissions>\n';
            }
        }

        // Preserve field permissions
        if (profile.fieldPermissions != null) {
            for (MetadataService.ProfileFieldLevelSecurity fp : profile.fieldPermissions) {
                Boolean fpReadable = fp.readable != null ? fp.readable : false;
                Boolean fpEditable = fp.editable != null ? fp.editable : false;

                xml += '    <fieldPermissions>\n'
                    + '        <editable>'  + fpEditable  + '</editable>\n'
                    + '        <field>'     + fp.field    + '</field>\n'
                    + '        <readable>'  + fpReadable  + '</readable>\n'
                    + '    </fieldPermissions>\n';
            }
        }

        // Preserve user permissions (system-level: ApiEnabled, RunReports, etc.)
        if (profile.userPermissions != null) {
            for (MetadataService.ProfileUserPermission up : profile.userPermissions) {
                Boolean upEnabled = up.enabled != null ? up.enabled : false;
                xml += '    <userPermissions>\n'
                    + '        <enabled>' + upEnabled  + '</enabled>\n'
                    + '        <name>'    + up.name    + '</name>\n'
                    + '    </userPermissions>\n';
            }
        }

        xml += '</Profile>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Helpers
    // ─────────────────────────────────────────────────────────────
    private static String resolveProfileName(String profileName) {
        if (PROFILE_NAME_MAP.containsKey(profileName)) {
            String resolved = PROFILE_NAME_MAP.get(profileName);
            System.debug('ProfileHelper: resolved [' + profileName + '] → [' + resolved + ']');
            return resolved;
        }
        return profileName;
    }

    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

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

    private static String addSuffix(String name) {
        if (String.isBlank(name)) return name;
        name = name.trim();
        return name.endsWith('__c') ? name : name + '__c';
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new ProfileException('Required parameter missing: ' + key);
        }
        return String.valueOf(val).trim();
    }

    private static String getOptional(Map<String, Object> args, String key, String defaultValue) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) return defaultValue;
        String strVal = String.valueOf(val).trim();
        if (strVal == 'null') return defaultValue;
        return strVal;
    }

    public class ProfileException extends Exception {}
}