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
    // PRIVATE — Build base profile XML
    //
    // If newFullName/newLabel are provided, they override the source.
    // Used both for reading existing profiles and for cloning.
    // ─────────────────────────────────────────────────────────────
    private static String buildBaseProfileXml(MetadataService.Profile profile, String newFullName, String newLabel) {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n';

        // Preserve custom flag
        if (profile.custom != null) {
            xml += '    <custom>' + profile.custom + '</custom>\n';
        }

        // Preserve user license — critical for profile to be valid
        if (String.isNotBlank(profile.userLicense)) {
            xml += '    <userLicense>' + escapeXml(profile.userLicense) + '</userLicense>\n';
        }

        // Preserve user permissions early to keep Profile element ordering valid.
        if (profile.userPermissions != null) {
            for (MetadataService.ProfileUserPermission up : profile.userPermissions) {
                Boolean upEnabled = up.enabled != null ? up.enabled : false;
                xml += '    <userPermissions>\n'
                    + '        <enabled>' + upEnabled  + '</enabled>\n'
                    + '        <name>'    + up.name    + '</name>\n'
                    + '    </userPermissions>\n';
            }
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
            ErrorLogger.log(ex);
            return UserInfo.getSessionId();
        }
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new ProfileException('Required parameter missing: ' + key);
        }
        return String.valueOf(val).trim();
    }

    public class ProfileException extends Exception {}
}
