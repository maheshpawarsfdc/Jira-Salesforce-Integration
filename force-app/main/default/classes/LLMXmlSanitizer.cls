public class LLMXmlSanitizer {
  // ── Safety constants ───────────────────────────────────────────
  private static final Set<String> STANDARD_OBJECTS = new Set<String>{
    'Account',
    'Case',
    'Contact',
    'Lead',
    'Opportunity',
    'Task',
    'Event',
    'Campaign',
    'Order',
    'Contract',
    'Asset',
    'Solution',
    'Product2',
    'Pricebook2',
    'User',
    'UserRole',
    'Group',
    'Territory',
    'Forecast',
    'ForecastingItem'
  };

  private static final Map<String, String> PROCESS_DRIVEN_OBJECTS = new Map<String, String>{
    'Case' => 'Case',
    'Lead' => 'Lead',
    'Opportunity' => 'Opportunity',
    'Solution' => 'Solution'
  };

  // ── Metadata element defaults (UI-consistent) ──────────────────
  // To add a new default: add an entry here — no other code changes needed.
  private static final Map<String, Map<String, String>> METADATA_DEFAULTS = new Map<String, Map<String, String>>{
    'CustomObject' => new Map<String, String>{
      'deploymentStatus' => 'Deployed',
      'sharingModel' => 'ReadWrite',
      'enableBulkApi' => 'true',
      'enableStreamingApi' => 'true',
      'enableReports' => 'true',
      'enableActivities' => 'true'
    }
  };

  // ─────────────────────────────────────────────────────────────
  // XML VALIDATION
  // ─────────────────────────────────────────────────────────────
  public static String validateXml(
    String metadataType,
    String memberName,
    String xmlContent
  ) {
    if (String.isBlank(xmlContent)) {
      return 'xmlContent is empty';
    }

    try {
      Dom.Document doc = new Dom.Document();
      doc.load(xmlContent);
    } catch (Exception e) {
      ErrorLogger.log(e);
      return 'Malformed XML: ' + e.getMessage();
    }

    if (metadataType == 'CustomObject') {
      if (!memberName.endsWith('__c') && !memberName.endsWith('__mdt')) {
        if (xmlContent.contains('<nameField>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <nameField>';
        }
        if (xmlContent.contains('<sharingModel>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <sharingModel>';
        }
        if (xmlContent.contains('<pluralLabel>')) {
          return 'Standard object [' +
            memberName +
            '] must not contain <pluralLabel>';
        }
        return null;
      }

      if (memberName != null && memberName.endsWith('__mdt')) {
        if (xmlContent.contains('<customMetadataType>')) {
          return 'Invalid element <customMetadataType> — this tag does not exist in Salesforce Metadata API';
        }
        if (xmlContent.contains('<customSettingsType>')) {
          return 'Custom Metadata Type cannot contain <customSettingsType>';
        }
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<label>', '<pluralLabel>' }
        );
      }
      if (xmlContent.contains('<customSettingsType>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<label>', '<customSettingsType>' }
        );
      }
      return validateRequiredElements(
        xmlContent,
        new List<String>{ '<label>', '<pluralLabel>', '<nameField>' }
      );
    }

    if (metadataType == 'CustomField' || xmlContent.contains('<fields>')) {
      return validateRequiredElements(
        xmlContent,
        new List<String>{ '<fullName>', '<label>', '<type>' }
      );
    }

    if (metadataType == 'PermissionSet') {
      return validateRequiredElements(
        xmlContent,
        new List<String>{ '<label>' }
      );
    }

    if (metadataType == 'Profile') {
      return null;
    }

    if (metadataType == 'ValidationRule') {
      return validateRequiredElements(
        xmlContent,
        new List<String>{
          '<fullName>',
          '<active>',
          '<errorConditionFormula>',
          '<errorMessage>'
        }
      );
    }

    if (metadataType == 'CustomLabel' || metadataType == 'CustomLabels') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{ '<fullName>', '<value>' }
      );
      if (String.isNotBlank(baseError)) {
        return baseError;
      }

      Set<String> seenNames = new Set<String>();
      Integer searchFrom = 0;
      while (true) {
        Integer fnStart = xmlContent.indexOf('<fullName>', searchFrom);
        if (fnStart == -1) {
          break;
        }

        Integer fnEnd = xmlContent.indexOf('</fullName>', fnStart);
        if (fnEnd == -1) {
          break;
        }
        String labelName = xmlContent.substring(
            fnStart + '<fullName>'.length(),
            fnEnd
          )
          .trim();
        if (seenNames.contains(labelName)) {
          return 'Duplicate <fullName> "' +
            labelName +
            '" found in CustomLabels XML — each label must appear only once. ' +
            'For translations use translations/{language}.translation instead.';
        }
        seenNames.add(labelName);
        searchFrom = fnEnd + '</fullName>'.length();
      }
      return null;
    }

    if (metadataType == 'NamedCredential') {
      // Modern (External-Credential-based) model uses namedCredentialType +
      // namedCredentialParameters instead of endpoint/protocol/principalType —
      // detect which shape this file is before picking which fields are required.
      Boolean isModernModel = xmlContent.contains('<namedCredentialType>');

      if (isModernModel) {
        String modernError = validateRequiredElements(
          xmlContent,
          new List<String>{
            '<label>',
            '<namedCredentialType>',
            '<namedCredentialParameters>'
          }
        );
        if (String.isNotBlank(modernError)) {
          return modernError;
        }
        if (
          xmlContent.contains('<protocol>') ||
          xmlContent.contains('<principalType>') ||
          xmlContent.contains('<endpoint>')
        ) {
          return 'Invalid: PATH B (modern, namedCredentialType present) must not also ' +
            'contain <protocol>, <principalType>, or <endpoint> — those are legacy-only elements.';
        }
        if (!xmlContent.contains('<parameterType>Url</parameterType>')) {
          return 'Modern Named Credential is missing a namedCredentialParameters block with parameterType=Url';
        }
        if (
          !xmlContent.contains('<parameterType>Authentication</parameterType>')
        ) {
          return 'Modern Named Credential is missing a namedCredentialParameters block with parameterType=Authentication';
        }
        return null;
      }

      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{
          '<label>',
          '<endpoint>',
          '<protocol>',
          '<principalType>'
        }
      );
      if (String.isNotBlank(baseError)) {
        return baseError;
      }

      if (xmlContent.contains('<principalType>Anonymous</principalType>')) {
        return 'Invalid principalType — Named Principal credentials must use NamedUser, not Anonymous';
      }
      if (xmlContent.contains('<developerName>')) {
        return 'Invalid element <developerName> inside AuthProvider XML — remove it, ' +
          'the file name IS the developerName identity';
      }

      if (xmlContent.contains('<protocol>Oauth</protocol>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<authProvider>', '<oauthScope>' }
        );
      }
      if (xmlContent.contains('<protocol>Password</protocol>')) {
        return validateRequiredElements(
          xmlContent,
          new List<String>{ '<username>', '<password>' }
        );
      }

      return null;
    }

    if (metadataType == 'ExternalCredential') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{ '<label>', '<authenticationProtocol>' }
      );
      if (String.isNotBlank(baseError)) {
        return baseError;
      }
      if (xmlContent.contains('<fullName>')) {
        return 'Invalid element <fullName> inside ExternalCredential XML — remove it, ' +
          'the file name is the identity';
      }
      if (xmlContent.contains('<parameters>')) {
        return 'Invalid element <parameters> — ExternalCredential uses ' +
          '<externalCredentialParameters> blocks, not a generic <parameters> wrapper';
      }
      // Custom protocol never carries a literal credential value in metadata —
      // Salesforce populates it post-deploy via Setup/Connect REST API, and
      // rejects AuthParameter here with "The authentication protocol 'Custom'
      // doesn't support the following external credential parameter type(s):
      // AuthParameter." Catch it before deploy instead of after.
      if (
        xmlContent.contains(
          '<authenticationProtocol>Custom</authenticationProtocol>'
        ) && xmlContent.contains('<parameterType>AuthParameter</parameterType>')
      ) {
        return 'Invalid: Custom protocol does not support parameterType=AuthParameter. ' +
          'Only declare the principal (NamedPrincipal/PerUserPrincipal) — literal values ' +
          'are entered manually post-deploy, not embedded in metadata.';
      }
      // Oauth protocol only accepts parameterType=AuthProvider referencing a real
      // AuthProvider component — it does not accept invented parameter names for
      // raw client credentials. Salesforce rejects those with: "The authentication
      // protocol 'Oauth' doesn't support the external credential parameter name:
      // ClientId,ClientSecret,TokenEndpoint." Catch the common invented names here.
      if (
        xmlContent.contains(
          '<authenticationProtocol>Oauth</authenticationProtocol>'
        )
      ) {
        for (
          String badName : new List<String>{
            'ClientId',
            'ClientSecret',
            'TokenEndpoint',
            'AuthorizeEndpoint',
            'IdentityProviderUrl'
          }
        ) {
          if (
            xmlContent.contains(
              '<parameterName>' + badName + '</parameterName>'
            )
          ) {
            return 'Invalid: Oauth protocol does not support parameterName="' +
              badName +
              '". OAuth must reference a separate AuthProvider component via ' +
              'parameterType=AuthProvider — see the AUTH_PROVIDER prompt.';
          }
        }
      }
      // <parameterGroup> is only valid on NamedPrincipal/PerUserPrincipal blocks,
      // or on an AuthParameter block whose parameterName is literally "Scope".
      // Salesforce rejects it anywhere else: "A parameter group can only be
      // specified for the parameter types NamedPrincipal and PerUserPrincipal.
      // It can also be specified for an AuthParameter if the AuthParameter is
      // named Scope."
      Matcher ecpMatcher = Pattern.compile(
          '(?s)<externalCredentialParameters>.*?</externalCredentialParameters>'
        )
        .matcher(xmlContent);
      while (ecpMatcher.find()) {
        String block = ecpMatcher.group(0);
        if (!block.contains('<parameterGroup>')) {
          continue;
        }
        Boolean isPrincipalType =
          block.contains('<parameterType>NamedPrincipal</parameterType>') ||
          block.contains('<parameterType>PerUserPrincipal</parameterType>');
        Boolean isScopeAuthParameter =
          block.contains('<parameterType>AuthParameter</parameterType>') &&
          block.contains('<parameterName>Scope</parameterName>');
        if (!isPrincipalType && !isScopeAuthParameter) {
          return 'Invalid: <parameterGroup> is only allowed on a NamedPrincipal/' +
            'PerUserPrincipal block, or an AuthParameter block named "Scope". ' +
            'Remove it from this block.';
        }
      }
      return null;
    }

    if (metadataType == 'Queue') {
      // Each queueMembers wrapper (users/publicGroups/roles/roleAndSubordinates/
      // roleAndSubordinatesInternal) must appear at most once — Salesforce
      // rejects a repeated wrapper with "Element X is duplicated at this
      // location in type QueueMembers". Multiple members of the same type
      // belong INSIDE one wrapper as multiple inner elements, not as
      // multiple copies of the wrapper itself.
      for (
        String wrapper : new List<String>{
          'users',
          'publicGroups',
          'roles',
          'roleAndSubordinates',
          'roleAndSubordinatesInternal'
        }
      ) {
        Integer occurrences = 0;
        Integer searchFrom = 0;
        while (true) {
          Integer idx = xmlContent.indexOf('<' + wrapper + '>', searchFrom);
          if (idx < 0) {
            break;
          }
          occurrences++;
          searchFrom = idx + 1;
        }
        if (occurrences > 1) {
          return 'Invalid: <' +
            wrapper +
            '> appears ' +
            occurrences +
            ' times inside queueMembers — merge into ONE <' +
            wrapper +
            '> block containing all the individual entries.';
        }
      }

      // Not every object supports Queue ownership (QueueSobject.SobjectType
      // is a restricted picklist — e.g. Opportunity is not on it). Checked
      // here deterministically against live schema, independent of whether
      // the LLM correctly consulted orgState.existingQueueSupportedObjects,
      // so this never surfaces as Salesforce's raw "bad value for
      // restricted picklist field: X" — the LLM gets a clear, actionable
      // message and a chance to correct/fail cleanly on retry instead.
      Matcher sobjMatcher = Pattern.compile(
          '(?is)<sobjectType>\\s*([^<]+?)\\s*</sobjectType>'
        )
        .matcher(xmlContent);
      Set<String> validQueueObjects;
      while (sobjMatcher.find()) {
        String requestedObj = sobjMatcher.group(1).trim();
        if (validQueueObjects == null) {
          validQueueObjects = new Set<String>();
          for (
            Schema.PicklistEntry pe : QueueSobject.SobjectType.getDescribe()
              .getPicklistValues()
          ) {
            if (pe.isActive()) {
              validQueueObjects.add(pe.getValue());
            }
          }
        }
        if (!validQueueObjects.contains(requestedObj)) {
          return 'Invalid: "' +
            requestedObj +
            '" does not support Queue ownership in Salesforce. Queues can ' +
            'only be created for objects that have "Allow queues" enabled ' +
            '(commonly Case, Lead, Task, and most custom __c objects) — ' +
            requestedObj +
            ' is not one of them. Do not deploy this Queue; return a clear ' +
            'error instead of letting this reach the Metadata API.';
        }
      }
      return null;
    }

    if (metadataType == 'AuthProvider') {
      String baseError = validateRequiredElements(
        xmlContent,
        new List<String>{ '<friendlyName>', '<providerType>' }
      );
      if (String.isNotBlank(baseError)) {
        return baseError;
      }

      // friendlyName has a hard 32-character max — Salesforce rejects longer
      // values with "Value too long for field: FriendlyName maximum length is:32"
      Matcher fnMatcher = Pattern.compile(
          '(?is)<friendlyName>\\s*([^<]*?)\\s*</friendlyName>'
        )
        .matcher(xmlContent);
      if (fnMatcher.find() && fnMatcher.group(1).length() > 32) {
        return 'Invalid: <friendlyName> is ' +
          fnMatcher.group(1).length() +
          ' characters ("' +
          fnMatcher.group(1) +
          '") — maximum allowed is 32. Shorten it; do not concatenate the full ticket label with a suffix.';
      }

      if (xmlContent.contains('<fullName>')) {
        return 'Invalid element <fullName> inside AuthProvider XML — remove it, the file name is the identity';
      }
      if (xmlContent.contains('<developerName>')) {
        return 'Invalid element <developerName> inside AuthProvider XML — remove it, the file name IS the developerName';
      }

      if (xmlContent.contains('<tokenEndpointUrl>')) {
        return 'Invalid element <tokenEndpointUrl> — correct element name is <tokenUrl>';
      }
      if (xmlContent.contains('<authorizeEndpointUrl>')) {
        return 'Invalid element <authorizeEndpointUrl> — correct element name is <authorizeUrl>';
      }
      if (xmlContent.contains('<scope>')) {
        return 'Invalid element <scope> — correct element name is <defaultScopes>';
      }
      if (xmlContent.contains('<urlSuffix>')) {
        return 'Invalid element <urlSuffix> — this element does not exist in AuthProvider metadata XML';
      }
      if (xmlContent.contains('<customErrorUrl>')) {
        return 'Invalid element <customErrorUrl> — correct element name is <errorUrl>';
      }
      if (xmlContent.contains('<customLogoutUrl>')) {
        return 'Invalid element <customLogoutUrl> — correct element name is <logoutUrl>';
      }
      if (xmlContent.contains('<tokenIssuer>')) {
        return 'Invalid element <tokenIssuer> — Token Issuer is not supported in AuthProvider metadata XML; set it manually via Setup after deployment';
      }

      Set<String> validTypes = new Set<String>{
        'Apple',
        'Bitbucket',
        'Confluence3LO',
        'Facebook',
        'GitHub',
        'Google',
        'Janrain',
        'LinkedIn',
        'Microsoft',
        'MicrosoftACS',
        'MuleSoft',
        'OpenIdConnect',
        'Salesforce',
        'Slack',
        'Twitter'
      };
      Pattern ptPat = Pattern.compile('<providerType>([^<]+)</providerType>');
      Matcher ptMat = ptPat.matcher(xmlContent);
      if (ptMat.find()) {
        String pt = ptMat.group(1).trim();
        if (!validTypes.contains(pt)) {
          return 'Invalid providerType [' +
            pt +
            ']. Valid values: ' +
            String.join(new List<String>(validTypes), ', ');
        }
        // Types that have no URL fields (OAuth 1.0a or key-based)
        Set<String> NO_URL_TYPES = new Set<String>{ 'Twitter', 'Apple' };
        if (
          !NO_URL_TYPES.contains(pt) && !xmlContent.contains('<authorizeUrl>')
        ) {
          return 'providerType ' +
            pt +
            ' requires <authorizeUrl> and <tokenUrl>';
        }
      }
      return null;
    }

    return null;
  }

  public static String validateRequiredElements(
    String xml,
    List<String> requiredElements
  ) {
    for (String element : requiredElements) {
      if (!xml.contains(element)) {
        return 'Missing required element: ' + element;
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // PERMISSION SET XML SANITIZER
  // Corrects element names the LLM commonly gets wrong
  // ─────────────────────────────────────────────────────────────
  public static String sanitizePermissionSetXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    xml = xml.replace('<apexClassAccesses>', '<classAccesses>')
      .replace('</apexClassAccesses>', '</classAccesses>')
      .replace('<apexPageAccesses>', '<pageAccesses>')
      .replace('</apexPageAccesses>', '</pageAccesses>')
      .replace('<vfPageAccesses>', '<pageAccesses>')
      .replace('</vfPageAccesses>', '</pageAccesses>')
      .replace('<visualforcePageAccesses>', '<pageAccesses>')
      .replace('</visualforcePageAccesses>', '</pageAccesses>')
      .replace('<flowDefinitionAccesses>', '<flowAccesses>')
      .replace('</flowDefinitionAccesses>', '</flowAccesses>')
      .replace('<connectedAppVisibilities>', '<connectedAppAccesses>')
      .replace('</connectedAppVisibilities>', '</connectedAppAccesses>');

    // Strip elements confirmed invalid in PermissionSet metadata schema
    List<String> unsupportedBlocks = new List<String>{
      'agentAccesses',
      'connectedAppAccesses',
      'namedCredentialAccesses'
    };
    for (String tag : unsupportedBlocks) {
      xml = xml.replaceAll('(?s)\\s*<' + tag + '>.*?</' + tag + '>', '');
    }

    // Guardrail for the common false-positive where the model mistakes the
    // org's Bedrock Named Credential for an External Data Source. Salesforce
    // rejects PermissionSet.externalDataSourceAccesses when the referenced
    // ExternalDataSource does not actually exist, so strip that block rather
    // than letting deployment fail.
    xml = xml.replaceAll(
      '(?is)\s*<externalDataSourceAccesses>.*?<externalDataSource>\s*Bedrock\s*</externalDataSource>.*?</externalDataSourceAccesses>',
      ''
    );

    // Inject missing <viewAllFields>false</viewAllFields> into every
    // objectPermissions block that lacks it (required 7th boolean child)
    if (xml.contains('<objectPermissions>')) {
      xml = xml.replaceAll('(?s)\\s*<viewAllFields>[^<]*</viewAllFields>', '');
      xml = xml.replace(
        '<viewAllRecords>',
        '<viewAllFields>false</viewAllFields>\n        <viewAllRecords>'
      );
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTH PROVIDER XML SANITIZER
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeAuthProviderXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    List<String> forbiddenTags = new List<String>{
      'developerName',
      'fullName',
      'keyId',
      'servicesId',
      'teamId',
      'tokenIssuer',
      'urlSuffix'
    };
    for (String tag : forbiddenTags) {
      xml = xml.replaceAll('(?i)\\s*<' + tag + '>[^<]*</' + tag + '>', '');
    }

    xml = xml.replace('<tokenEndpointUrl>', '<tokenUrl>')
      .replace('</tokenEndpointUrl>', '</tokenUrl>')
      .replace('<authorizeEndpointUrl>', '<authorizeUrl>')
      .replace('</authorizeEndpointUrl>', '</authorizeUrl>')
      .replace('<scope>', '<defaultScopes>')
      .replace('</scope>', '</defaultScopes>')
      .replace('<customErrorUrl>', '<errorUrl>')
      .replace('</customErrorUrl>', '</errorUrl>')
      .replace('<customLogoutUrl>', '<logoutUrl>')
      .replace('</customLogoutUrl>', '</logoutUrl>');

    if (!xml.contains('<friendlyName>') && xml.contains('<name>')) {
      xml = xml.replace('<name>', '<friendlyName>')
        .replace('</name>', '</friendlyName>');
    }

    // Force isPkceEnabled=false for types that Salesforce rejects PKCE on
    Set<String> NO_PKCE_TYPES = new Set<String>{
      'Apple',
      'GitHub',
      'Janrain',
      'MicrosoftACS',
      'Twitter'
    };
    Pattern ptPkce = Pattern.compile('<providerType>([^<]+)</providerType>');
    Matcher mtPkce = ptPkce.matcher(xml);
    if (mtPkce.find() && NO_PKCE_TYPES.contains(mtPkce.group(1).trim())) {
      xml = xml.replaceAll(
        '<isPkceEnabled>true</isPkceEnabled>',
        '<isPkceEnabled>false</isPkceEnabled>'
      );
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD OBJECT XML SANITIZER
  // Strips: <nameField>, <pluralLabel>, <deploymentStatus>, <sharingModel>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeStandardObjectXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    Integer removedCount = 0;
    List<String> forbiddenBlocks = new List<String>{
      'nameField',
      'pluralLabel',
      'deploymentStatus',
      'sharingModel'
    };

    for (String tag : forbiddenBlocks) {
      Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
      Matcher m = p.matcher(xml);
      String cleaned = m.replaceAll('');
      if (cleaned != xml) {
        removedCount++;
        xml = cleaned;
      }
    }

    if (removedCount > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeStandardObjectXml: removed ' +
          removedCount +
          ' forbidden element(s) from standard object XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // CUSTOM METADATA TYPE SANITIZER
  // Strips: <customSettingsType>, <customMetadataType>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeMdtObjectXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    Integer removedCount = 0;
    List<String> forbiddenTags = new List<String>{
      'customSettingsType',
      'customMetadataType'
    };

    for (String tag : forbiddenTags) {
      Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
      Matcher m = p.matcher(xml);
      String cleaned = m.replaceAll('');
      if (cleaned != xml) {
        removedCount++;
        xml = cleaned;
      }
    }

    if (removedCount > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeMdtObjectXml: removed ' +
          removedCount +
          ' forbidden element(s) from __mdt object XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // CUSTOM SETTING OBJECT XML SANITIZER
  // Strips elements invalid/unsafe for Custom Settings in this pipeline.
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeCustomSettingObjectXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }

    Integer removedCount = 0;
    List<String> forbiddenTags = new List<String>{
      'deploymentStatus',
      'sharingModel',
      'nameField',
      'pluralLabel',
      'customSettingsVisibility'
    };

    for (String tag : forbiddenTags) {
      Pattern p = Pattern.compile('(?s)\\s*<' + tag + '>.*?</' + tag + '>');
      Matcher m = p.matcher(xml);
      String cleaned = m.replaceAll('');
      if (cleaned != xml) {
        removedCount++;
        xml = cleaned;
      }
    }

    if (removedCount > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeCustomSettingObjectXml: removed ' +
          removedCount +
          ' forbidden element(s) from custom setting object XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // PROFILE CUSTOM-SETTING REFERENCE SANITIZER
  // Removes Profile sections that reference Custom Settings in the same
  // response, because layout/object/field profile refs are invalid for
  // Custom Settings and can fail deploy if parent object creation fails.
  // ─────────────────────────────────────────────────────────────
  public static String stripProfileReferencesToCustomSettings(
    String xml,
    Set<String> customSettingObjectNames
  ) {
    if (
      String.isBlank(xml) ||
      customSettingObjectNames == null ||
      customSettingObjectNames.isEmpty()
    ) {
      return xml;
    }

    String original = xml;
    for (String objApi : customSettingObjectNames) {
      if (String.isBlank(objApi)) {
        continue;
      }
      xml = removeBlocksContaining(
        xml,
        'fieldPermissions',
        '<field>' + objApi + '.'
      );
      xml = removeBlocksContaining(
        xml,
        'objectPermissions',
        '<object>' + objApi + '</object>'
      );
      xml = removeBlocksContaining(
        xml,
        'layoutAssignments',
        '<layout>' + objApi + '-'
      );
    }

    if (xml != original) {
      System.debug(
        '[DEPLOY-TRACE] stripProfileReferencesToCustomSettings: removed custom-setting references from Profile XML'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // EXISTING CUSTOM OBJECT XML SANITIZER
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeExistingCustomObjectXml(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fields>')) {
      return xml;
    }

    List<String> toRemove = new List<String>();
    Boolean hasMasterDetail = false;
    Integer cursor = 0;

    while (true) {
      Integer bs = xml.indexOf('<fields>', cursor);
      if (bs < 0) {
        break;
      }
      Integer be = xml.indexOf('</fields>', bs);
      if (be < 0) {
        break;
      }
      be += '</fields>'.length();

      String block = xml.substring(bs, be);
      String fieldType = extractInlineTagValue(block, 'type');

      if (
        !isIncompleteFieldBlock(block, fieldType) && fieldType == 'MasterDetail'
      ) {
        hasMasterDetail = true;
      }

      if (isIncompleteFieldBlock(block, fieldType)) {
        toRemove.add(block);
        System.debug(
          '[DEPLOY-TRACE] sanitizeExistingCustomObjectXml: removing incomplete [' +
            fieldType +
            '] field block'
        );
      }

      cursor = be;
    }

    for (String block : toRemove) {
      xml = xml.replace(block, '');
    }

    if (
      !hasMasterDetail &&
      xml.contains('<sharingModel>ControlledByParent</sharingModel>')
    ) {
      Pattern p = Pattern.compile(
        '(?s)\\s*<sharingModel>ControlledByParent</sharingModel>'
      );
      Matcher m = p.matcher(xml);
      xml = m.replaceAll('');
      System.debug(
        '[DEPLOY-TRACE] sanitizeExistingCustomObjectXml: ' +
        'removed <sharingModel>ControlledByParent (no MasterDetail field in deploy)'
      );
    }

    if (!toRemove.isEmpty()) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeExistingCustomObjectXml: removed ' +
          toRemove.size() +
          ' incomplete field block(s)'
      );
    }
    return xml;
  }

  // Repairs common malformed CustomObject XML where a <fields> block is left
  // unclosed and the model starts emitting top-level blocks like
  // <validationRules>, <recordTypes>, <listViews>, etc.
  public static String repairMalformedCustomObjectXml(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fields>')) {
      return xml;
    }

    Integer openCount = 0;
    Integer closeCount = 0;
    Integer idx = 0;
    while (true) {
      Integer p = xml.indexOf('<fields>', idx);
      if (p < 0) {
        break;
      }
      openCount++;
      idx = p + '<fields>'.length();
    }

    idx = 0;
    while (true) {
      Integer p = xml.indexOf('</fields>', idx);
      if (p < 0) {
        break;
      }
      closeCount++;
      idx = p + '</fields>'.length();
    }

    if (openCount <= closeCount) {
      return xml;
    }

    List<String> boundaryTags = new List<String>{
      '<validationRules>',
      '<recordTypes>',
      '<listViews>',
      '<webLinks>',
      '<compactLayouts>',
      '<searchLayouts>',
      '<fieldSets>',
      '<nameField>',
      '<sharingModel>',
      '<enableHistory>',
      '<deploymentStatus>',
      '<pluralLabel>',
      '</CustomObject>'
    };

    Integer inserted = 0;
    while (openCount > closeCount) {
      Integer lastFieldStart = xml.lastIndexOf('<fields>');
      if (lastFieldStart < 0) {
        break;
      }

      Integer alreadyClosed = xml.indexOf('</fields>', lastFieldStart);
      if (alreadyClosed > -1) {
        break;
      }

      Integer insertPos = -1;
      for (String tag : boundaryTags) {
        Integer p = xml.indexOf(tag, lastFieldStart + '<fields>'.length());
        if (p > -1 && (insertPos == -1 || p < insertPos)) {
          insertPos = p;
        }
      }

      if (insertPos < 0) {
        break;
      }

      xml =
        xml.substring(0, insertPos) +
        '</fields>' +
        xml.substring(insertPos);
      closeCount++;
      inserted++;
    }

    if (inserted > 0) {
      System.debug(
        '[DEPLOY-TRACE] repairMalformedCustomObjectXml: inserted ' +
          inserted +
          ' missing </fields> tag(s)'
      );
    }
    return xml;
  }

  // Normalizes formula field blocks in CustomObject XML so deploy never
  // carries invalid <type>Formula</type> values.
  public static String normalizeFormulaFieldTypesInCustomObjectXml(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fields>')) {
      return xml;
    }

    Pattern blockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Matcher mat = blockPat.matcher(xml);
    List<String> originals = new List<String>();
    List<String> replacements = new List<String>();

    while (mat.find()) {
      String fieldBody = mat.group(1);
      String block = '<fields>' + fieldBody + '</fields>';
      if (!block.contains('<formula>')) {
        continue;
      }

      String fieldType = extractInlineTagValue(block, 'type');
      if (!'Formula'.equalsIgnoreCase(fieldType)) {
        continue;
      }

      String normalizedType = normalizeFormulaReturnType(
        extractInlineTagValue(block, 'returnType'),
        block
      );

      String updated = block.replaceAll(
        '<type>\\s*Formula\\s*</type>',
        '<type>' + normalizedType + '</type>'
      );
      // returnType is not a valid CustomField element when type already
      // expresses the formula return datatype.
      updated = updated.replaceAll(
        '(?s)\\s*<returnType>[^<]*</returnType>',
        ''
      );

      if (
        normalizedType == 'Number' ||
        normalizedType == 'Currency' ||
        normalizedType == 'Percent'
      ) {
        if (!updated.contains('<precision>')) {
          updated = updated.replace(
            '</fields>',
            '    <precision>18</precision>\n</fields>'
          );
        }
        if (!updated.contains('<scale>')) {
          updated = updated.replace(
            '</fields>',
            '    <scale>2</scale>\n</fields>'
          );
        }
      } else {
        // Non-numeric formulas should not carry numeric sizing tags.
        updated = updated.replaceAll(
          '(?s)\\s*<precision>[^<]*</precision>',
          ''
        );
        updated = updated.replaceAll('(?s)\\s*<scale>[^<]*</scale>', '');
      }
      // Salesforce rejects <length> on ALL formula fields regardless of return type.
      updated = updated.replaceAll('(?s)\\s*<length>[^<]*</length>', '');

      originals.add(block);
      replacements.add(updated);
    }

    for (Integer i = 0; i < originals.size(); i++) {
      xml = xml.replace(originals[i], replacements[i]);
    }

    if (!originals.isEmpty()) {
      System.debug(
        '[DEPLOY-TRACE] normalizeFormulaFieldTypesInCustomObjectXml: normalized ' +
          originals.size() +
          ' formula field block(s)'
      );
    }
    return xml;
  }

  // Normalizes standalone CustomField XML formula type in the same way as
  // object-embedded <fields> blocks.
  public static String normalizeFormulaFieldTypeInCustomFieldXml(String xml) {
    if (String.isBlank(xml) || !xml.contains('<formula>')) {
      return xml;
    }

    String fieldType = extractInlineTagValue(xml, 'type');
    if (!'Formula'.equalsIgnoreCase(fieldType)) {
      return xml;
    }

    String normalizedType = normalizeFormulaReturnType(
      extractInlineTagValue(xml, 'returnType'),
      xml
    );
    String out = xml.replaceAll(
      '<type>\\s*Formula\\s*</type>',
      '<type>' + normalizedType + '</type>'
    );
    out = out.replaceAll('(?s)\\s*<returnType>[^<]*</returnType>', '');

    if (
      normalizedType == 'Number' ||
      normalizedType == 'Currency' ||
      normalizedType == 'Percent'
    ) {
      if (!out.contains('<precision>')) {
        out = out.replace(
          '</CustomField>',
          '    <precision>18</precision>\n</CustomField>'
        );
      }
      if (!out.contains('<scale>')) {
        out = out.replace(
          '</CustomField>',
          '    <scale>2</scale>\n</CustomField>'
        );
      }
    } else {
      out = out.replaceAll('(?s)\\s*<precision>[^<]*</precision>', '');
      out = out.replaceAll('(?s)\\s*<scale>[^<]*</scale>', '');
    }
    // Salesforce rejects <length> on ALL formula fields regardless of return type.
    out = out.replaceAll('(?s)\\s*<length>[^<]*</length>', '');

    System.debug(
      '[DEPLOY-TRACE] normalizeFormulaFieldTypeInCustomFieldXml: normalized formula type to [' +
        normalizedType +
        ']'
    );
    return out;
  }

  private static String normalizeFormulaReturnType(
    String rawReturnType,
    String formulaBlock
  ) {
    Set<String> valid = new Set<String>{
      'Text',
      'Number',
      'Currency',
      'Percent',
      'Date',
      'DateTime',
      'Checkbox'
    };

    if (String.isNotBlank(rawReturnType)) {
      for (String t : valid) {
        if (t.equalsIgnoreCase(rawReturnType.trim())) {
          return t;
        }
      }
    }

    // Best-effort fallback when returnType is omitted by the model.
    if (
      formulaBlock.contains('<precision>') || formulaBlock.contains('<scale>')
    ) {
      return 'Number';
    }
    return 'Text';
  }

  private static String extractInlineTagValue(String block, String tag) {
    String open = '<' + tag + '>';
    String close = '</' + tag + '>';
    Integer ts = block.indexOf(open);
    Integer te = block.indexOf(close);
    if (ts >= 0 && te > ts) {
      return block.substring(ts + open.length(), te).trim();
    }
    return '';
  }

  // ─────────────────────────────────────────────────────────────
  // MERGE DUPLICATE RECORD-IDENTIFIER FIELDS
  //
  // Deterministic backstop for the RECORD IDENTIFIER FIELDS prompt rule
  // (LLM_Prompt__mdt CUSTOM_OBJECT) — the LLM doesn't reliably follow it,
  // so this detects the duplicate mechanically instead of trusting the
  // prompt alone. For every CustomObject in the batch, if a sibling field
  // named <ObjectName>_Name__c or <ObjectName>_Number__c exists (a
  // standalone CustomField file OR an embedded <fields> block), it is
  // folded into <nameField> and removed as its own field. Every
  // Profile/PermissionSet fieldPermissions entry and Layout layoutItems
  // entry referencing that now-removed field is corrected too, so the
  // merge doesn't just trade one deploy failure for another.
  //
  // Must run BEFORE the main files[] loop — it mutates the files list
  // itself (removing entries, rewriting xmlContent in place).
  // ─────────────────────────────────────────────────────────────
  public static void mergeDuplicateIdentifierFields(List<Object> files) {
    if (files == null || files.isEmpty()) {
      return;
    }

    List<String> objectApiNames = new List<String>();
    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      Object mnRaw = file.get('memberName');
      if (
        'CustomObject'.equals(file.get('metadataType')) &&
        mnRaw != null &&
        String.valueOf(mnRaw).endsWith('__c')
      ) {
        objectApiNames.add(String.valueOf(mnRaw));
      }
    }
    if (objectApiNames.isEmpty()) {
      return;
    }

    for (String objectApiName : objectApiNames) {
      // Re-find the object's file each iteration — indices shift as
      // duplicate CustomField entries are removed from `files` below.
      Map<String, Object> objFile = null;
      for (Object rawFile : files) {
        Map<String, Object> file = (Map<String, Object>) rawFile;
        if (
          'CustomObject'.equals(file.get('metadataType')) &&
          objectApiName.equals(file.get('memberName'))
        ) {
          objFile = file;
          break;
        }
      }
      if (objFile == null) {
        continue;
      }
      String objXml = (String) objFile.get('xmlContent');
      if (String.isBlank(objXml)) {
        continue;
      }

      String baseName = objectApiName.removeEnd('__c');
      Set<String> candidates = new Set<String>{
        (baseName + '_Name__c').toLowerCase(),
        (baseName + '_Number__c').toLowerCase()
      };
      // Also match against the object name with a trailing numeric suffix
      // stripped (e.g. object Account1__c naming its identifier field
      // Account_Name__c instead of Account1_Name__c) — tickets aren't
      // always internally consistent about repeating a disambiguating
      // digit in the field name too.
      String baseNameNoDigits = baseName.replaceAll('[0-9]+$', '');
      if (String.isNotBlank(baseNameNoDigits) && baseNameNoDigits != baseName) {
        candidates.add((baseNameNoDigits + '_Name__c').toLowerCase());
        candidates.add((baseNameNoDigits + '_Number__c').toLowerCase());
      }

      // 1. Look for a standalone CustomField match
      Integer matchIndex = -1;
      String matchedFieldName = null;
      String matchedFieldXml = null;
      for (Integer i = 0; i < files.size(); i++) {
        Map<String, Object> f = (Map<String, Object>) files[i];
        if (!'CustomField'.equals(f.get('metadataType'))) {
          continue;
        }
        String mn = (String) f.get('memberName');
        if (String.isBlank(mn) || !mn.startsWith(objectApiName + '.')) {
          continue;
        }
        String fn = mn.substringAfter('.');
        if (candidates.contains(fn.toLowerCase())) {
          matchIndex = i;
          matchedFieldName = fn;
          matchedFieldXml = (String) f.get('xmlContent');
          break;
        }
      }

      // 2. Otherwise look for an embedded <fields> block inside the object
      String embeddedBlockToRemove = null;
      if (matchedFieldName == null) {
        Pattern fieldBlockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
        Matcher m = fieldBlockPat.matcher(objXml);
        while (m.find()) {
          String block = m.group(1);
          String fn = extractInlineTagValue(block, 'fullName');
          if (String.isNotBlank(fn) && candidates.contains(fn.toLowerCase())) {
            matchedFieldName = fn;
            matchedFieldXml = block;
            embeddedBlockToRemove = m.group(0);
            break;
          }
        }
      }

      if (matchedFieldName == null) {
        continue; // nothing to merge for this object
      }

      String fType = extractInlineTagValue(matchedFieldXml, 'type');
      if (String.isBlank(fType)) {
        continue; // can't safely merge without a known type
      }
      String fLabel = extractInlineTagValue(matchedFieldXml, 'label');
      String fDisplayFormat = extractInlineTagValue(
        matchedFieldXml,
        'displayFormat'
      );

      String newNameField =
        '<nameField>' +
        '<label>' +
        (String.isNotBlank(fLabel) ? fLabel : baseName + ' Name') +
        '</label>' +
        '<type>' +
        fType +
        '</type>';
      if ('AutoNumber'.equalsIgnoreCase(fType)) {
        newNameField +=
          '<displayFormat>' +
          (String.isNotBlank(fDisplayFormat)
            ? fDisplayFormat
            : baseName.toUpperCase() + '-{0000}') +
          '</displayFormat>';
      }
      newNameField += '</nameField>';

      Integer nfStart = objXml.indexOf('<nameField>');
      Integer nfEnd = objXml.indexOf('</nameField>');
      if (nfStart >= 0 && nfEnd > nfStart) {
        nfEnd += '</nameField>'.length();
        objXml =
          objXml.substring(0, nfStart) +
          newNameField +
          objXml.substring(nfEnd);
      } else {
        objXml = objXml.replace(
          '</CustomObject>',
          newNameField + '</CustomObject>'
        );
      }

      if (embeddedBlockToRemove != null) {
        objXml = objXml.replace(embeddedBlockToRemove, '');
      }
      objFile.put('xmlContent', objXml);

      if (matchIndex >= 0) {
        files.remove(matchIndex);
      }

      // Clean up every other file that referenced the now-removed field
      String qualifiedField = objectApiName + '.' + matchedFieldName;
      for (Object rawFile : files) {
        Map<String, Object> f = (Map<String, Object>) rawFile;
        String mt = (String) f.get('metadataType');
        String xml = (String) f.get('xmlContent');
        if (String.isBlank(xml)) {
          continue;
        }
        if ('Profile'.equals(mt) || 'PermissionSet'.equals(mt)) {
          String updated = removeBlocksContaining(
            xml,
            'fieldPermissions',
            '<field>' + qualifiedField + '</field>'
          );
          if (updated != xml) {
            f.put('xmlContent', updated);
          }
        } else if ('Layout'.equals(mt)) {
          String updated = xml;
          if (xml.contains('<field>Name</field>')) {
            // Name is already on the layout — drop the redundant item
            // instead of creating a duplicate <field>Name</field>.
            updated = removeBlocksContaining(
              xml,
              'layoutItems',
              '<field>' + matchedFieldName + '</field>'
            );
          } else if (xml.contains('<field>' + matchedFieldName + '</field>')) {
            updated = xml.replace(
              '<field>' + matchedFieldName + '</field>',
              '<field>Name</field>'
            );
          }
          if (updated != xml) {
            f.put('xmlContent', updated);
          }
        }
      }

      System.debug(
        '[DEPLOY-TRACE] mergeDuplicateIdentifierFields: merged [' +
          qualifiedField +
          '] into nameField for [' +
          objectApiName +
          ']'
      );
    }
  }

  // Removes every <blockTag>...</blockTag> block that contains
  // mustContainSubstring — used to drop stale fieldPermissions/layoutItems
  // blocks that reference a field mergeDuplicateIdentifierFields() removed.
  private static String removeBlocksContaining(
    String xml,
    String blockTag,
    String mustContainSubstring
  ) {
    String openTag = '<' + blockTag + '>';
    String closeTag = '</' + blockTag + '>';
    if (String.isBlank(xml) || !xml.contains(openTag)) {
      return xml;
    }
    Integer cursor = 0;
    while (true) {
      Integer bs = xml.indexOf(openTag, cursor);
      if (bs < 0) {
        break;
      }
      Integer be = xml.indexOf(closeTag, bs);
      if (be < 0) {
        break;
      }
      be += closeTag.length();
      String block = xml.substring(bs, be);
      if (block.contains(mustContainSubstring)) {
        xml = xml.substring(0, bs) + xml.substring(be);
        cursor = bs;
      } else {
        cursor = be;
      }
    }
    return xml;
  }

  private static Boolean isIncompleteFieldBlock(
    String block,
    String fieldType
  ) {
    if (block.contains('<formula>')) {
      if (String.isBlank(fieldType) || 'Formula'.equalsIgnoreCase(fieldType)) {
        return true;
      }
      if (
        fieldType == 'Number' ||
        fieldType == 'Currency' ||
        fieldType == 'Percent'
      ) {
        return !block.contains('<precision>') || !block.contains('<scale>');
      }
      // Text/Date/DateTime/Checkbox formula fields do not require
      // length/precision/scale tags.
      return false;
    }

    if (
      fieldType == 'Text' ||
      fieldType == 'TextArea' ||
      fieldType == 'Phone' ||
      fieldType == 'Email' ||
      fieldType == 'Url' ||
      fieldType == 'EncryptedText'
    ) {
      return !block.contains('<length>');
    }
    if (fieldType == 'LongTextArea' || fieldType == 'Html') {
      return !block.contains('<length>') || !block.contains('<visibleLines>');
    }
    if (fieldType == 'Checkbox') {
      return !block.contains('<defaultValue>');
    }
    if (
      fieldType == 'Currency' ||
      fieldType == 'Number' ||
      fieldType == 'Percent'
    ) {
      return !block.contains('<precision>') || !block.contains('<scale>');
    }
    if (fieldType == 'Lookup' || fieldType == 'MasterDetail') {
      return !block.contains('<referenceTo>') ||
        !block.contains('<relationshipName>');
    }
    if (fieldType == 'ExternalLookup') {
      return !block.contains('<externalDeveloperName>') ||
        !block.contains('<relationshipName>');
    }
    if (fieldType == 'AutoNumber') {
      return !block.contains('<displayFormat>');
    }
    if (fieldType == 'Summary') {
      return !block.contains('<summaryOperation>') ||
        !block.contains('<summaryForeignKey>');
    }
    if (fieldType == 'Location') {
      return !block.contains('<scale>');
    }
    // Date, DateTime, Time, Picklist, MultiselectPicklist, etc. — keep by default
    return false;
  }

  // ─────────────────────────────────────────────────────────────
  // PROFILE STANDARD-OBJECT TAB SANITIZER
  // Strips any <tabVisibilities> block whose <tab> does NOT end with __c
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileStandardObjectTabs(String xml) {
    if (String.isBlank(xml) || !xml.contains('<tabVisibilities>')) {
      return xml;
    }

    Pattern tvPat = Pattern.compile(
      '(?s)\\s*<tabVisibilities>\\s*<tab>([^<]+)</tab>.*?</tabVisibilities>'
    );
    Matcher m = tvPat.matcher(xml);

    List<String> toRemove = new List<String>();
    while (m.find()) {
      String tabName = m.group(1).trim();
      if (!tabName.endsWith('__c')) {
        toRemove.add(m.group(0));
        System.debug(
          '[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: ' +
            'removing tabVisibilities for standard object tab [' +
            tabName +
            ']'
        );
      }
    }

    for (String block : toRemove) {
      xml = xml.replace(block, '');
    }

    if (!toRemove.isEmpty()) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileStandardObjectTabs: removed ' +
          toRemove.size() +
          ' standard-object tabVisibilities block(s)'
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // PROFILE CUSTOM TAB — DEFAULT VISIBILITY TO ON
  // A tabVisibilities block with no <visibility> (or a blank one) deploys
  // as hidden by default — a newly created tab then exists (Setup > Tabs)
  // but can't be added to any Lightning app's navigation until someone
  // manually flips its visibility. The ticket almost never asks for a new
  // tab to be hidden, so default to DefaultOn unless the LLM explicitly
  // declared a different value (DefaultOff / Hidden) — that's left as-is.
  // Standard-object tabVisibilities are already stripped upstream by
  // sanitizeProfileStandardObjectTabs(), so only __c tabs reach here.
  // ─────────────────────────────────────────────────────────────
  public static String defaultCustomTabVisibilityToOn(String xml) {
    if (String.isBlank(xml) || !xml.contains('<tabVisibilities>')) {
      return xml;
    }

    Pattern tvPat = Pattern.compile(
      '(?s)<tabVisibilities>\\s*<tab>([^<]+)</tab>(.*?)</tabVisibilities>'
    );
    Pattern visPat = Pattern.compile('<visibility>([^<]*)</visibility>');
    Matcher m = tvPat.matcher(xml);

    Map<String, String> replacements = new Map<String, String>();
    while (m.find()) {
      String tabName = m.group(1).trim();
      if (!tabName.endsWith('__c')) {
        continue;
      }
      Matcher visMatcher = visPat.matcher(m.group(2));
      if (visMatcher.find() && String.isNotBlank(visMatcher.group(1))) {
        continue; // explicit value present — leave it alone
      }
      replacements.put(
        m.group(0),
        '<tabVisibilities>' +
          '\n        <tab>' +
          tabName +
          '</tab>' +
          '\n        <visibility>DefaultOn</visibility>' +
          '\n    </tabVisibilities>'
      );
      System.debug(
        '[DEPLOY-TRACE] defaultCustomTabVisibilityToOn: defaulted [' +
          tabName +
          '] to DefaultOn (no explicit visibility declared)'
      );
    }

    for (String oldBlock : replacements.keySet()) {
      xml = xml.replace(oldBlock, replacements.get(oldBlock));
    }
    return xml;
  }

  // Remove unsupported Profile elements that LLM may emit.
  // Profile metadata has no <label>/<pluralLabel>/<fullName> elements —
  // a profile's display name comes solely from its file name, unlike
  // PermissionSet/CustomObject which require <label>. The LLM sometimes
  // bleeds that convention into a Profile file when asked to "create" a
  // named profile in one shot, which the Metadata API rejects with
  // "Element ... label invalid at this location in type Profile".
  public static String sanitizeProfileXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }
    String cleaned = xml;
    if (cleaned.contains('<cloneFrom>')) {
      cleaned = cleaned.replaceAll('(?s)\\s*<cloneFrom>.*?</cloneFrom>', '');
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileXml: removed unsupported <cloneFrom> element'
      );
    }
    for (String tag : new List<String>{ 'label', 'pluralLabel', 'fullName' }) {
      String tagRegex = '(?s)\\s*<' + tag + '>.*?</' + tag + '>';
      if (Pattern.compile(tagRegex).matcher(cleaned).find()) {
        cleaned = cleaned.replaceAll(tagRegex, '');
        System.debug(
          '[DEPLOY-TRACE] sanitizeProfileXml: removed unsupported <' +
            tag +
            '> element (not a valid Profile field)'
        );
      }
    }
    // <tabSettings> is the PermissionSet element for tab visibility;
    // Profile's equivalent is <tabVisibilities>. The LLM sometimes emits
    // the PermissionSet tag name inside a Profile file. The inner <tab>
    // and <visibility> children are structurally identical and the
    // visibility values the LLM is taught to use (DefaultOn/DefaultOff/
    // Hidden) are already valid on Profile, so a tag rename is sufficient
    // — no need to drop the requested access.
    if (cleaned.contains('<tabSettings>')) {
      cleaned = cleaned
        .replace('<tabSettings>', '<tabVisibilities>')
        .replace('</tabSettings>', '</tabVisibilities>');
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileXml: renamed <tabSettings> to <tabVisibilities> (PermissionSet element used in Profile file)'
      );
    }
    return cleaned;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-INJECT <businessProcess> FOR PROCESS-DRIVEN OBJECTS
  // ─────────────────────────────────────────────────────────────
  public static String injectBusinessProcessIfMissing(
    String xml,
    String memberName,
    Map<String, Object> orgState
  ) {
    if (String.isBlank(xml) || !xml.contains('<recordTypes>')) {
      return xml;
    }
    if (!PROCESS_DRIVEN_OBJECTS.containsKey(memberName)) {
      return xml;
    }
    String tableEnumOrId = PROCESS_DRIVEN_OBJECTS.get(memberName);

    String bpName = null;
    Object rawBps = orgState != null
      ? orgState.get('existingBusinessProcesses')
      : null;
    if (rawBps != null) {
      try {
        Map<String, Object> bpMap = (Map<String, Object>) JSON.deserializeUntyped(
          JSON.serialize(rawBps)
        );
        Object bpListRaw = bpMap.get(tableEnumOrId);
        if (bpListRaw instanceof List<Object>) {
          List<Object> bpList = (List<Object>) bpListRaw;
          if (!bpList.isEmpty()) {
            bpName = String.valueOf(bpList[0]);
          }
        }
      } catch (Exception e) {
        System.debug(
          '[DEPLOY-TRACE] injectBusinessProcess: failed to parse bps — ' +
          e.getMessage()
        );
      }
    }

    if (String.isBlank(bpName)) {
      System.debug(
        '[DEPLOY-TRACE] injectBusinessProcess: no Business Process found for [' +
          memberName +
          '] in orgState — deploy may fail'
      );
      return xml;
    }

    Pattern rtPat = Pattern.compile('(?s)<recordTypes>(.*?)</recordTypes>');
    Matcher rm = rtPat.matcher(xml);
    List<String> origBlocks = new List<String>();
    List<String> fixedBlocks = new List<String>();

    while (rm.find()) {
      String fullBlock = rm.group(0);
      if (fullBlock.contains('<businessProcess>')) {
        continue;
      }
      String fixedBlock = fullBlock.replace(
        '</active>',
        '</active> <businessProcess>' + bpName + '</businessProcess>'
      );
      origBlocks.add(fullBlock);
      fixedBlocks.add(fixedBlock);
      System.debug(
        '[DEPLOY-TRACE] injectBusinessProcess: injected [' +
          bpName +
          '] into ' +
          memberName +
          ' record type'
      );
    }

    for (Integer i = 0; i < origBlocks.size(); i++) {
      xml = xml.replace(origBlocks[i], fixedBlocks[i]);
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-PREFIX BARE LAYOUT NAMES IN PROFILE <layoutAssignments>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileLayoutAssignments(String xml) {
    if (String.isBlank(xml) || !xml.contains('<layoutAssignments>')) {
      return xml;
    }

    Map<String, String> objToLayout = new Map<String, String>();
    Pattern blockPat = Pattern.compile(
      '(?s)<layoutAssignments>(.*?)</layoutAssignments>'
    );
    Matcher bm = blockPat.matcher(xml);
    while (bm.find()) {
      String inner1 = bm.group(1);
      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner1);
      if (!rm.find()) {
        continue;
      }
      String objName = rm.group(1).trim();
      Pattern lPat = Pattern.compile('<layout>([^<]+)</layout>');
      Matcher lm = lPat.matcher(inner1);
      if (!lm.find()) {
        continue;
      }
      String layoutVal = lm.group(1).trim();
      if (layoutVal.contains('-')) {
        objToLayout.put(objName, layoutVal.substringBefore('-'));
      } else {
        objToLayout.put(objName, objName);
      }
    }

    bm = blockPat.matcher(xml);
    List<String> origBlocks = new List<String>();
    List<String> fixedBlocks = new List<String>();

    while (bm.find()) {
      String fullBlock = bm.group(0);
      String inner1 = bm.group(1);

      Pattern layoutPat = Pattern.compile('<layout>([^<]+)</layout>');
      Matcher lm = layoutPat.matcher(inner1);
      if (!lm.find()) {
        continue;
      }
      String layoutVal = lm.group(1).trim();
      if (layoutVal.contains('-')) {
        continue;
      }

      String objName = null;

      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner1);
      if (rm.find()) {
        objName = rm.group(1).trim();
      }
      if (String.isBlank(objName) && layoutVal.contains(' ')) {
        objName = layoutVal.substringBefore(' ').trim();
      }
      if (String.isBlank(objName) && !objToLayout.isEmpty()) {
        objName = objToLayout.values()[0];
      }

      if (String.isBlank(objName)) {
        continue;
      }

      String fixedLayout = objName + '-' + layoutVal;
      String fixedBlock = fullBlock.replace(
        '<layout>' + layoutVal + '</layout>',
        '<layout>' + fixedLayout + '</layout>'
      );
      origBlocks.add(fullBlock);
      fixedBlocks.add(fixedBlock);
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileLayoutAssignments: ' +
          layoutVal +
          ' -> ' +
          fixedLayout
      );
    }

    for (Integer i = 0; i < origBlocks.size(); i++) {
      xml = xml.replace(origBlocks[i], fixedBlocks[i]);
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTO-INJECT/CORRECT <--master--> recordTypeVisibilities
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeProfileMasterRecordType(String xml) {
    if (String.isBlank(xml) || !xml.contains('<recordTypeVisibilities>')) {
      return xml;
    }

    Pattern masterEntryPat = Pattern.compile(
      '(?s)\\s*<recordTypeVisibilities>\\s*<recordType>[^<]+\\.Master</recordType>.*?</recordTypeVisibilities>'
    );
    Matcher mm = masterEntryPat.matcher(xml);
    while (mm.find()) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeProfileMasterRecordType: removing bogus Master entry: ' +
        mm.group(0)
      );
      xml = xml.replace(mm.group(0), '');
      mm = masterEntryPat.matcher(xml);
    }

    Map<String, Boolean> objHasDefault = new Map<String, Boolean>();
    Map<String, String> objFirstBlock = new Map<String, String>();

    Pattern blockPat = Pattern.compile(
      '(?s)<recordTypeVisibilities>(.*?)</recordTypeVisibilities>'
    );
    Matcher bm = blockPat.matcher(xml);
    while (bm.find()) {
      String inner2 = bm.group(1);
      Pattern rtPat = Pattern.compile(
        '<recordType>([^.<]+)[.]([^<]+)</recordType>'
      );
      Matcher rm = rtPat.matcher(inner2);
      if (!rm.find()) {
        continue;
      }
      String objName = rm.group(1).trim();
      Boolean isDef = inner2.contains('<default>true</default>');
      if (!objHasDefault.containsKey(objName)) {
        objHasDefault.put(objName, false);
        objFirstBlock.put(objName, bm.group(0));
      }
      if (isDef) {
        objHasDefault.put(objName, true);
      }
    }

    for (String objName : objHasDefault.keySet()) {
      if (!objHasDefault.get(objName)) {
        String firstBlock = objFirstBlock.get(objName);
        String fixedBlock = firstBlock.replace(
          '<default>false</default>',
          '<default>true</default>'
        );
        xml = xml.replace(firstBlock, fixedBlock);
        System.debug(
          '[DEPLOY-TRACE] sanitizeProfileMasterRecordType: promoted [' +
            objName +
            '] first RT to default=true (no default existed)'
        );
      }
    }

    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // LAYOUT XML SANITIZER
  // Strips <layoutItems> blocks with empty <field>/<behavior>
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeLayoutXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }
    if (!xml.contains('<layoutItems>')) {
      return xml;
    }

    String cleaned = xml;
    Integer removed = 0;
    Integer safety = 500;

    while (safety-- > 0) {
      Integer emptyBehaviorIdx = cleaned.indexOf('<behavior></behavior>');
      Integer emptyFieldIdx = cleaned.indexOf('<field></field>');
      Integer target = -1;
      if (
        emptyBehaviorIdx >= 0 &&
        (emptyFieldIdx < 0 ||
        emptyBehaviorIdx < emptyFieldIdx)
      ) {
        target = emptyBehaviorIdx;
      } else if (emptyFieldIdx >= 0) {
        target = emptyFieldIdx;
      }
      if (target < 0) {
        break;
      }

      Integer itemStart = cleaned.lastIndexOf('<layoutItems>', target);
      Integer itemEnd = cleaned.indexOf('</layoutItems>', target);
      if (itemStart < 0 || itemEnd < 0) {
        break;
      }
      itemEnd += '</layoutItems>'.length();

      cleaned = cleaned.substring(0, itemStart) + cleaned.substring(itemEnd);
      removed++;
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeLayoutXml: stripped ' +
          removed +
          ' broken <layoutItems> block(s) from Layout XML'
      );
    }

    // Strip layoutItems with no valid content element at all
    // (e.g. behavior-only, or completely empty — Salesforce rejects these)
    List<Pattern> noContentPatterns = new List<Pattern>{
      Pattern.compile(
        '(?s)\\s*<layoutItems>\\s*<behavior>[^<]*</behavior>\\s*</layoutItems>'
      ),
      Pattern.compile('(?s)\\s*<layoutItems>\\s*</layoutItems>')
    };
    for (Pattern p : noContentPatterns) {
      Matcher m = p.matcher(cleaned);
      String after = m.replaceAll('');
      if (after != cleaned) {
        System.debug(
          '[DEPLOY-TRACE] sanitizeLayoutXml: removed layoutItems with no valid content element'
        );
        cleaned = after;
      }
    }

    if (cleaned.contains('<field>Name</field>')) {
      // Name field behavior is handled by fixNameFieldBehaviorInLayout()
      // which runs after sanitizeLayoutXml with the correct nameFieldType.
      // Do NOT modify Name behavior here — leave it as-is.
      System.debug(
        '[DEPLOY-TRACE] sanitizeLayoutXml: Name field present — behavior will be set by fixNameFieldBehaviorInLayout'
      );
    } else if (cleaned.contains('<layoutColumns>')) {
      // Name is absent entirely — inject it at the top of the first column.
      // Salesforce requires Name on every layout; LLMs often omit it.
      Integer insertPos =
        cleaned.indexOf('<layoutColumns>') + '<layoutColumns>'.length();
      String nameItem =
        '\n            <layoutItems>\n' +
        '                <behavior>Edit</behavior>\n' +
        '                <field>Name</field>\n' +
        '            </layoutItems>';
      cleaned =
        cleaned.substring(0, insertPos) +
        nameItem +
        cleaned.substring(insertPos);
      System.debug(
        '[DEPLOY-TRACE] sanitizeLayoutXml: injected missing Name field into layout'
      );
    }
    return cleaned;
  }

  // Removes layoutItems that reference fields not known in schema/pending
  // state for the layout's parent object.
  public static String sanitizeLayoutUnknownFields(
    String xml,
    String layoutMemberName
  ) {
    if (
      String.isBlank(xml) ||
      String.isBlank(layoutMemberName) ||
      !layoutMemberName.contains('-')
    ) {
      return xml;
    }
    String objectApi = layoutMemberName.substringBefore('-');
    Pattern itemPat = Pattern.compile('(?s)<layoutItems>.*?</layoutItems>');
    Matcher itemMat = itemPat.matcher(xml);
    List<String> oldItems = new List<String>();
    Integer removed = 0;

    while (itemMat.find()) {
      String item = itemMat.group(0);
      Matcher fm = Pattern.compile('(?is)<field>\\s*([^<]+?)\\s*</field>')
        .matcher(item);
      if (!fm.find()) {
        continue;
      }
      String ref = fm.group(1).trim();
      String fieldName = ref.contains('.') ? ref.substringAfter('.') : ref;

      if (fieldName == 'Name') {
        continue;
      }
      if (!SchemaFieldValidator.fieldExists(objectApi, fieldName)) {
        oldItems.add(item);
        removed++;
      } else {
        String canonical = SchemaFieldValidator.resolveFieldApiName(
          objectApi,
          fieldName
        );
        if (String.isNotBlank(canonical) && canonical != fieldName) {
          String updatedItem = item.replaceFirst(
            '(?is)<field>\\s*[^<]+?\\s*</field>',
            '<field>' + canonical + '</field>'
          );
          // Safe in-place normalization of field API casing.
          xml = xml.replace(item, updatedItem);
        }
      }
    }

    for (String oldItem : oldItems) {
      xml = xml.replace(oldItem, '');
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeLayoutUnknownFields: removed ' +
          removed +
          ' unknown field layoutItems from [' +
          layoutMemberName +
          ']'
      );
    }
    return xml;
  }

  // Removes ListView columns that reference unknown custom fields.
  public static String sanitizeListViewUnknownColumns(
    String xml,
    String listViewMemberName
  ) {
    if (
      String.isBlank(xml) ||
      String.isBlank(listViewMemberName) ||
      !listViewMemberName.contains('.') ||
      !xml.contains('<columns>')
    ) {
      return xml;
    }
    String objectApi = listViewMemberName.substringBefore('.');
    Pattern colPat = Pattern.compile(
      '(?is)\\s*<columns>\\s*([^<]+?)\\s*</columns>'
    );
    Matcher cm = colPat.matcher(xml);
    List<String> oldCols = new List<String>();
    Integer removed = 0;

    while (cm.find()) {
      String fullTag = cm.group(0);
      String colVal = cm.group(1).trim();

      // Keep standard columns and relationship traversals as-is.
      String lowerCol = colVal.toLowerCase();
      if (!lowerCol.endsWith('__c') && !colVal.contains('.')) {
        continue;
      }

      String fieldName = colVal;
      String targetObj = objectApi;
      if (colVal.contains('.')) {
        targetObj = colVal.substringBefore('.');
        fieldName = colVal.substringAfter('.');
      }

      if (targetObj != objectApi) {
        continue;
      }
      if (!SchemaFieldValidator.fieldExists(objectApi, fieldName)) {
        oldCols.add(fullTag);
        removed++;
      } else {
        String canonical = SchemaFieldValidator.resolveFieldApiName(
          objectApi,
          fieldName
        );
        if (String.isNotBlank(canonical) && canonical != fieldName) {
          xml = xml.replace(fullTag, '<columns>' + canonical + '</columns>');
        }
      }
    }

    for (String oldCol : oldCols) {
      xml = xml.replace(oldCol, '');
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeListViewUnknownColumns: removed ' +
          removed +
          ' unknown column(s) from [' +
          listViewMemberName +
          ']'
      );
    }
    return xml;
  }

  // Removes Profile/PermissionSet fieldPermissions that target fields not
  // present in schema/pending field set.
  public static String sanitizeUnknownFieldPermissions(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fieldPermissions>')) {
      return xml;
    }
    Pattern fpPat = Pattern.compile(
      '(?s)<fieldPermissions>.*?</fieldPermissions>'
    );
    Matcher fpm = fpPat.matcher(xml);
    List<String> oldBlocks = new List<String>();
    Integer removed = 0;

    while (fpm.find()) {
      String block = fpm.group(0);
      Matcher fm = Pattern.compile('(?is)<field>\\s*([^<]+?)\\s*</field>')
        .matcher(block);
      if (!fm.find()) {
        continue;
      }
      String qf = fm.group(1).trim();
      if (!qf.contains('.')) {
        continue;
      }
      String obj = qf.substringBefore('.');
      String fld = qf.substringAfter('.');
      if (!obj.endsWith('__c')) {
        continue;
      }
      Boolean exists = SchemaFieldValidator.objectExists(obj)
        ? SchemaFieldValidator.fieldExistsInSchema(obj, fld)
        : SchemaFieldValidator.fieldExists(obj, fld);
      if (!exists) {
        oldBlocks.add(block);
        removed++;
      }
    }

    for (String oldBlock : oldBlocks) {
      xml = xml.replace(oldBlock, '');
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeUnknownFieldPermissions: removed ' +
          removed +
          ' fieldPermissions block(s) for unknown fields'
      );
    }
    return xml;
  }

  // Standard compound-address fields (BillingAddress, ShippingAddress,
  // MailingAddress, OtherAddress) expose sub-components like BillingCity,
  // BillingPostalCode, BillingLatitude etc. Salesforce's retrieveMetadata
  // happily returns fieldPermissions entries for these sub-fields when
  // cloning a profile/permission set with broad FLS (e.g. System
  // Administrator), but deployMetadata REJECTS them:
  //   "Invalid field permission field name Account field Account.BillingPostalCode"
  // This is a documented retrieve/deploy asymmetry — these sub-fields are
  // never independently securable and must never be re-serialized.
  private static final Set<String> COMPOUND_ADDRESS_PREFIXES = new Set<String>{
    'Billing',
    'Shipping',
    'Mailing',
    'Other'
  };
  private static final Set<String> COMPOUND_ADDRESS_SUFFIXES = new Set<String>{
    'Street',
    'City',
    'State',
    'StateCode',
    'PostalCode',
    'Country',
    'CountryCode',
    'Latitude',
    'Longitude',
    'GeocodeAccuracy'
  };

  public static Boolean isNonDeployableCompoundAddressField(
    String fieldApiName
  ) {
    if (String.isBlank(fieldApiName)) {
      return false;
    }
    for (String prefix : COMPOUND_ADDRESS_PREFIXES) {
      if (
        fieldApiName.startsWith(prefix) &&
        COMPOUND_ADDRESS_SUFFIXES.contains(
          fieldApiName.substring(prefix.length())
        )
      ) {
        return true;
      }
    }
    return false;
  }

  // Standard compound Name field (Contact, Lead, Person Account) exposes
  // FirstName/LastName/Salutation/MiddleName/Suffix as sub-components.
  // Same retrieve/deploy asymmetry as compound-address fields:
  //   "Invalid field permission field name Contact field Contact.FirstName"
  private static final Set<String> COMPOUND_NAME_SUBFIELDS = new Set<String>{
    'FirstName',
    'LastName',
    'Salutation',
    'MiddleName',
    'Suffix'
  };

  // Combined check — covers both compound-address and compound-Name
  // sub-fields, the two known-non-deployable-via-FLS categories so far.
  // Use this (not the address-only check) at every fieldPermissions
  // filtering call site so future additions only need to happen here.
  public static Boolean isNonDeployableCompoundField(String fieldApiName) {
    return isNonDeployableCompoundAddressField(fieldApiName) ||
      (String.isNotBlank(fieldApiName) &&
      COMPOUND_NAME_SUBFIELDS.contains(fieldApiName));
  }

  // Removes <fieldPermissions> blocks (Profile or PermissionSet XML) that
  // target non-deployable compound sub-fields. See
  // isNonDeployableCompoundField() for why.
  public static String stripNonDeployableCompoundFieldPermissions(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fieldPermissions>')) {
      return xml;
    }
    Matcher fpm = Pattern.compile(
        '(?s)<fieldPermissions>.*?</fieldPermissions>'
      )
      .matcher(xml);
    List<String> oldBlocks = new List<String>();
    Integer removed = 0;

    while (fpm.find()) {
      String block = fpm.group(0);
      Matcher fm = Pattern.compile('(?is)<field>\\s*([^<]+?)\\s*</field>')
        .matcher(block);
      if (!fm.find()) {
        continue;
      }
      String qf = fm.group(1).trim();
      String fld = qf.contains('.') ? qf.substringAfter('.') : qf;
      if (isNonDeployableCompoundField(fld)) {
        oldBlocks.add(block);
        removed++;
      }
    }

    for (String oldBlock : oldBlocks) {
      xml = xml.replace(oldBlock, '');
    }

    if (removed > 0) {
      System.debug(
        '[DEPLOY-TRACE] stripNonDeployableCompoundFieldPermissions: removed ' +
          removed +
          ' non-deployable compound-address fieldPermissions block(s)'
      );
    }
    return xml;
  }

  // Standard fields that are system-managed / implicitly-controlled and
  // never independently securable via fieldPermissions, regardless of
  // object. Deploying explicit FLS on these fails even when Apex's schema
  // describe doesn't flag them as "required" — e.g. OwnerId reports
  // isDefaultedOnCreate()=true (so PermissionSetHelper.isRequiredField's
  // describe-based heuristic misses it), yet the Metadata API still
  // rejects it with "You cannot deploy to a required field: Object.OwnerId".
  // Single source of truth — checked by both wildcard expansion below and
  // PermissionSetHelper.isRequiredField() for directly-requested fields.
  private static final Set<String> SYSTEM_MANAGED_FIELDS = new Set<String>{
    'Id',
    'IsDeleted',
    'CreatedDate',
    'CreatedById',
    'LastModifiedDate',
    'LastModifiedById',
    'SystemModstamp',
    'LastActivityDate',
    'LastViewedDate',
    'LastReferencedDate',
    'RecordTypeId',
    'OwnerId'
  };

  public static Boolean isSystemManagedField(String fieldApiName) {
    return String.isNotBlank(fieldApiName) &&
      SYSTEM_MANAGED_FIELDS.contains(fieldApiName);
  }

  // Expands "grant on all fields" requests. The LLM sometimes writes
  // <field>Object.*</field> as shorthand instead of enumerating every
  // field, which the Metadata API rejects outright:
  //   "In field: field - no CustomField named Account.* found"
  // There is no wildcard syntax for fieldPermissions — every field must be
  // listed individually. This expands the wildcard block into one
  // <fieldPermissions> block per real field on the object (using the same
  // readable/editable values as the wildcard block), skipping fields that
  // are never independently FLS-securable (system-managed fields and
  // compound-address sub-fields — those are filtered again downstream by
  // stripRequiredFieldPermissions / stripNonDeployableCompoundFieldPermissions
  // in case they weren't already caught here).
  public static String expandWildcardFieldPermissions(String xml) {
    if (String.isBlank(xml) || !xml.contains('<fieldPermissions>')) {
      return xml;
    }
    Matcher fpm = Pattern.compile(
        '(?s)<fieldPermissions>.*?</fieldPermissions>'
      )
      .matcher(xml);
    Map<String, String> wildcardBlockToExpansion = new Map<String, String>();

    while (fpm.find()) {
      String block = fpm.group(0);
      Matcher fm = Pattern.compile('(?is)<field>\\s*([^<]+?)\\s*</field>')
        .matcher(block);
      if (!fm.find()) {
        continue;
      }
      String qf = fm.group(1).trim();
      if (!qf.endsWith('.*')) {
        continue;
      }
      String objectApi = qf.substringBefore('.*');

      Matcher rm = Pattern.compile('(?is)<readable>\\s*([^<]+?)\\s*</readable>')
        .matcher(block);
      String readable = rm.find() ? rm.group(1).trim() : 'false';
      Matcher em = Pattern.compile('(?is)<editable>\\s*([^<]+?)\\s*</editable>')
        .matcher(block);
      String editable = em.find() ? em.group(1).trim() : 'false';

      String knownFields = SchemaFieldValidator.getKnownFieldNames(objectApi);
      if (String.isBlank(knownFields)) {
        System.debug(
          '[DEPLOY-TRACE] expandWildcardFieldPermissions: could not resolve fields for [' +
            objectApi +
            '] — leaving wildcard block as-is (will fail deploy)'
        );
        continue;
      }

      String expanded = '';
      for (String fld : knownFields.split(',\\s*')) {
        if (
          SYSTEM_MANAGED_FIELDS.contains(fld) ||
          isNonDeployableCompoundField(fld)
        ) {
          continue;
        }
        expanded +=
          '    <fieldPermissions>\n' +
          '        <editable>' +
          editable +
          '</editable>\n' +
          '        <field>' +
          objectApi +
          '.' +
          fld +
          '</field>\n' +
          '        <readable>' +
          readable +
          '</readable>\n' +
          '    </fieldPermissions>\n';
      }
      wildcardBlockToExpansion.put(block, expanded);
      System.debug(
        '[DEPLOY-TRACE] expandWildcardFieldPermissions: expanded [' +
          qf +
          '] into individual field entries for [' +
          objectApi +
          ']'
      );
    }

    for (String oldBlock : wildcardBlockToExpansion.keySet()) {
      xml = xml.replace(oldBlock, wildcardBlockToExpansion.get(oldBlock));
    }
    return xml;
  }

  // Sanitizes embedded <listViews> sections inside CustomObject XML.
  public static String sanitizeCustomObjectListViewUnknownColumns(
    String xml,
    String objectApiName
  ) {
    if (
      String.isBlank(xml) ||
      String.isBlank(objectApiName) ||
      !xml.contains('<listViews>') ||
      !xml.contains('<columns>')
    ) {
      return xml;
    }

    Pattern colPat = Pattern.compile(
      '(?is)\\s*<columns>\\s*([^<]+?)\\s*</columns>'
    );
    Matcher cm = colPat.matcher(xml);
    List<String> oldCols = new List<String>();
    List<String> newCols = new List<String>();
    Integer removed = 0;
    Integer normalized = 0;

    while (cm.find()) {
      String fullTag = cm.group(0);
      String colVal = cm.group(1).trim();
      String lowerCol = colVal.toLowerCase();
      if (!lowerCol.endsWith('__c') && !colVal.contains('.')) {
        continue;
      }

      String fieldName = colVal.contains('.')
        ? colVal.substringAfter('.')
        : colVal;
      if (!SchemaFieldValidator.fieldExists(objectApiName, fieldName)) {
        oldCols.add(fullTag);
        newCols.add('');
        removed++;
      } else {
        String canonical = SchemaFieldValidator.resolveFieldApiName(
          objectApiName,
          fieldName
        );
        if (String.isNotBlank(canonical) && canonical != fieldName) {
          oldCols.add(fullTag);
          newCols.add('<columns>' + canonical + '</columns>');
          normalized++;
        }
      }
    }

    for (Integer i = 0; i < oldCols.size(); i++) {
      xml = xml.replace(oldCols[i], newCols[i]);
    }

    if (removed > 0 || normalized > 0) {
      System.debug(
        '[DEPLOY-TRACE] sanitizeCustomObjectListViewUnknownColumns: removed=' +
          removed +
          ' normalized=' +
          normalized +
          ' for [' +
          objectApiName +
          ']'
      );
    }
    return xml;
  }

  // Normalizes <referenceTo> values by resolving case/format drift against
  // live schema object API names.
  public static String normalizeReferenceToTargets(String xml) {
    if (String.isBlank(xml) || !xml.contains('<referenceTo>')) {
      return xml;
    }
    Pattern p = Pattern.compile(
      '(?is)<referenceTo>\\s*([^<]+?)\\s*</referenceTo>'
    );
    Matcher m = p.matcher(xml);
    List<String> oldTags = new List<String>();
    List<String> newTags = new List<String>();

    while (m.find()) {
      String fullTag = m.group(0);
      String val = m.group(1).trim();
      String resolved = SchemaFieldValidator.resolveObjectApiName(val);
      if (String.isNotBlank(resolved) && resolved != val) {
        oldTags.add(fullTag);
        newTags.add('<referenceTo>' + resolved + '</referenceTo>');
      }
    }

    for (Integer i = 0; i < oldTags.size(); i++) {
      xml = xml.replace(oldTags[i], newTags[i]);
    }
    return xml;
  }

  // Required Lookup fields cannot use deleteConstraint=SetNull.
  // Salesforce expects Restrict or CascadeDelete semantics for required
  // lookup foreign keys. This normalizer enforces Restrict for safety.
  public static String normalizeRequiredLookupDeleteConstraint(String xml) {
    if (String.isBlank(xml) || !xml.contains('<required>true</required>')) {
      return xml;
    }

    if (xml.contains('<fields>')) {
      Pattern blockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
      Matcher mat = blockPat.matcher(xml);
      List<String> oldBlocks = new List<String>();
      List<String> newBlocks = new List<String>();

      while (mat.find()) {
        String body = mat.group(1);
        String block = '<fields>' + body + '</fields>';
        String typeVal = extractInlineTagValue(block, 'type');
        String reqVal = extractInlineTagValue(block, 'required');
        if (typeVal != 'Lookup' || reqVal != 'true') {
          continue;
        }

        String updated = block;
        if (updated.contains('<deleteConstraint>')) {
          updated = updated.replaceAll(
            '(?is)<deleteConstraint>\\s*SetNull\\s*</deleteConstraint>',
            '<deleteConstraint>Restrict</deleteConstraint>'
          );
        } else {
          if (updated.contains('</referenceTo>')) {
            updated = updated.replace(
              '</referenceTo>',
              '</referenceTo><deleteConstraint>Restrict</deleteConstraint>'
            );
          } else {
            updated = updated.replace(
              '</fields>',
              '    <deleteConstraint>Restrict</deleteConstraint>\n</fields>'
            );
          }
        }

        oldBlocks.add(block);
        newBlocks.add(updated);
      }

      for (Integer i = 0; i < oldBlocks.size(); i++) {
        xml = xml.replace(oldBlocks[i], newBlocks[i]);
      }
      return xml;
    }

    // Standalone CustomField XML case
    String typeVal = extractInlineTagValue(xml, 'type');
    String reqVal = extractInlineTagValue(xml, 'required');
    if (typeVal != 'Lookup' || reqVal != 'true') {
      return xml;
    }

    if (xml.contains('<deleteConstraint>')) {
      return xml.replaceAll(
        '(?is)<deleteConstraint>\\s*SetNull\\s*</deleteConstraint>',
        '<deleteConstraint>Restrict</deleteConstraint>'
      );
    }
    if (xml.contains('</referenceTo>')) {
      return xml.replace(
        '</referenceTo>',
        '</referenceTo><deleteConstraint>Restrict</deleteConstraint>'
      );
    }
    return xml.replace(
      '</CustomField>',
      '    <deleteConstraint>Restrict</deleteConstraint>\n</CustomField>'
    );
  }

  // Returns a user-friendly error when lookup/master-detail referenceTo
  // values point to objects that do not exist in org schema.
  public static String validateReferenceToTargets(
    String metadataType,
    String memberName,
    String xml
  ) {
    if (String.isBlank(xml) || !xml.contains('<referenceTo>')) {
      return null;
    }

    Set<String> missingRefs = new Set<String>();
    if (metadataType == 'CustomObject') {
      Pattern fieldPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
      Matcher fm = fieldPat.matcher(xml);
      while (fm.find()) {
        String block = fm.group(1);
        String typeVal = extractInlineTagValue(
          '<fields>' + block + '</fields>',
          'type'
        );
        if (
          typeVal != 'Lookup' &&
          typeVal != 'MasterDetail' &&
          typeVal != 'ExternalLookup'
        ) {
          continue;
        }
        String ref = extractInlineTagValue(
          '<fields>' + block + '</fields>',
          'referenceTo'
        );
        if (String.isBlank(ref)) {
          continue;
        }
        if (!SchemaFieldValidator.objectExists(ref)) {
          missingRefs.add(ref);
        }
      }
    } else if (metadataType == 'CustomField') {
      String typeVal = extractInlineTagValue(xml, 'type');
      if (
        typeVal == 'Lookup' ||
        typeVal == 'MasterDetail' ||
        typeVal == 'ExternalLookup'
      ) {
        String ref = extractInlineTagValue(xml, 'referenceTo');
        if (String.isNotBlank(ref) && !SchemaFieldValidator.objectExists(ref)) {
          missingRefs.add(ref);
        }
      }
    }

    if (missingRefs.isEmpty()) {
      return null;
    }

    List<String> lines = new List<String>();
    for (String missingRef : missingRefs) {
      List<String> suggestions = SchemaFieldValidator.suggestObjectApiNames(
        missingRef
      );
      if (!suggestions.isEmpty()) {
        lines.add(
          missingRef +
            ' (did you mean: ' +
            String.join(suggestions, ', ') +
            '?)'
        );
      } else {
        lines.add(missingRef);
      }
    }
    lines.sort();
    return 'Prerequisite missing for [' +
      memberName +
      ']: referenceTo object(s) not found in org: ' +
      String.join(lines, '; ');
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD FIELD SANITIZER
  // Strips erroneous __c suffix from standard object field names
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeStandardFieldReferences(
    String apexCode,
    Map<String, Object> orgState
  ) {
    if (String.isBlank(apexCode) || orgState == null) {
      return apexCode;
    }

    Map<String, Object> existingFields = (Map<String, Object>) orgState.get(
      'existingFields'
    );
    if (existingFields == null || existingFields.isEmpty()) {
      return apexCode;
    }

    String result = apexCode;

    for (String objectName : existingFields.keySet()) {
      if (objectName.endsWith('__c') || objectName.endsWith('__mdt')) {
        continue;
      }

      List<Object> rawFields = (List<Object>) existingFields.get(objectName);
      if (rawFields == null) {
        continue;
      }

      for (Object rawField : rawFields) {
        String fieldName = String.valueOf(rawField);
        if (fieldName.endsWith('__c')) {
          continue;
        }

        String wrongName = fieldName + '__c';
        if (result.containsIgnoreCase(wrongName)) {
          result = result.replaceAll(
            '(?i)\\b' + Pattern.quote(wrongName) + '\\b',
            fieldName
          );
          System.debug(
            'sanitizeStandardFieldReferences: replaced [' +
              wrongName +
              '] → [' +
              fieldName +
              '] on object [' +
              objectName +
              ']'
          );
        }
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // NORMALIZE TRANSLATION LANGUAGE CODE
  // ─────────────────────────────────────────────────────────────
  public static String normalizeTranslationLanguageCode(String lang) {
    if (String.isBlank(lang)) {
      return lang;
    }
    if (!lang.contains('_')) {
      return lang;
    }
    Set<String> validCompound = new Set<String>{
      'pt_BR',
      'zh_CN',
      'zh_TW',
      'en_US',
      'en_GB',
      'nl_BE',
      'fr_CA',
      'nb_NO',
      'en_AU',
      'en_IN'
    };
    if (validCompound.contains(lang)) {
      return lang;
    }
    return lang.substringBefore('_');
  }

  // ─────────────────────────────────────────────────────────────
  // SANITIZE CUSTOM LABELS XML
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeCustomLabelsXml(String xml) {
    if (String.isBlank(xml)) {
      return xml;
    }
    if (!xml.contains('<labels>')) {
      return xml;
    }

    Set<String> seenFullNames = new Set<String>();
    String sanitized = xml;
    Integer redirected = 0;
    Integer dropped = 0;
    Integer searchFrom = 0;
    Integer safety = 200;

    while (safety-- > 0) {
      Integer blockStart = sanitized.indexOf('<labels>', searchFrom);
      if (blockStart == -1) {
        break;
      }
      Integer blockEnd = sanitized.indexOf('</labels>', blockStart);
      if (blockEnd == -1) {
        break;
      }
      blockEnd += '</labels>'.length();

      String block = sanitized.substring(blockStart, blockEnd);

      Integer fnStart = block.indexOf('<fullName>') + '<fullName>'.length();
      Integer fnEnd = block.indexOf('</fullName>');
      String fullName = (fnStart >= '<fullName>'.length() &&
        fnEnd >= 0)
        ? block.substring(fnStart, fnEnd).trim()
        : '';

      Integer lStart = block.indexOf('<language>') + '<language>'.length();
      Integer lEnd = block.indexOf('</language>');
      String language = (lStart >= '<language>'.length() &&
        lEnd >= 0)
        ? block.substring(lStart, lEnd).trim()
        : 'en_US';

      Integer vStart = block.indexOf('<value>') + '<value>'.length();
      Integer vEnd = block.indexOf('</value>');
      String value = (vStart >= '<value>'.length() &&
        vEnd >= 0)
        ? block.substring(vStart, vEnd).trim()
        : '';

      Boolean isEnglish = (language == 'en_US' || language == 'en');
      Boolean isDuplicate = seenFullNames.contains(fullName);

      if (
        !isEnglish &&
        String.isNotBlank(fullName) &&
        String.isNotBlank(value)
      ) {
        String normalizedLang = normalizeTranslationLanguageCode(language);
        String tFilePath = 'translations/' + normalizedLang + '.translation';
        String existing = ZipBuilder.files.get(tFilePath);
        String tXml;
        if (String.isNotBlank(existing)) {
          tXml = existing.replace(
            '</Translations>',
            '    <customLabels>\n        <label>' +
              value +
              '</label>\n        <name>' +
              fullName +
              '</name>\n    </customLabels>\n</Translations>'
          );
        } else {
          tXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n' +
            '<Translations xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
            '    <customLabels>\n' +
            '        <label>' +
            value +
            '</label>\n' +
            '        <name>' +
            fullName +
            '</name>\n' +
            '    </customLabels>\n' +
            '</Translations>';
        }
        ZipBuilder.addFile('Translations', normalizedLang, tFilePath, tXml);
        System.debug(
          '[SANITIZE] sanitizeCustomLabelsXml: redirected label [' +
            fullName +
            '] lang=[' +
            language +
            '] -> ' +
            tFilePath
        );
        redirected++;
        sanitized =
          sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
      } else if (isDuplicate) {
        System.debug(
          '[SANITIZE] sanitizeCustomLabelsXml: dropped duplicate label [' +
            fullName +
            '] lang=[' +
            language +
            ']'
        );
        dropped++;
        sanitized =
          sanitized.substring(0, blockStart) + sanitized.substring(blockEnd);
      } else {
        if (String.isNotBlank(fullName)) {
          seenFullNames.add(fullName);
        }
        searchFrom = blockEnd;
      }
    }

    if (redirected > 0 || dropped > 0) {
      System.debug(
        '[SANITIZE] sanitizeCustomLabelsXml: redirected=' +
          redirected +
          ' dropped=' +
          dropped +
          ' seenNames=' +
          seenFullNames
      );
    }
    return sanitized;
  }

  // All Custom Labels share ONE physical file (labels/CustomLabels.labels),
  // but each is a separately-named package.xml member. The LLM's files[]
  // schema only carries a single memberName per file, so when multiple
  // labels are merged into one file (per the CUSTOM_LABEL prompt's
  // instruction), only the first/declared memberName was ever registered
  // for package.xml — the rest deployed in the file's actual content but
  // were absent from package.xml, causing "Not in package.xml" errors.
  // This extracts every <fullName> still present in the final (post-
  // sanitize) CustomLabels XML so all of them can be registered.
  public static List<String> extractCustomLabelFullNames(String xml) {
    List<String> names = new List<String>();
    if (String.isBlank(xml) || !xml.contains('<labels>')) {
      return names;
    }
    Matcher blockM = Pattern.compile('(?s)<labels>.*?</labels>').matcher(xml);
    while (blockM.find()) {
      Matcher fnM = Pattern.compile(
          '(?is)<fullName>\\s*([^<]+?)\\s*</fullName>'
        )
        .matcher(blockM.group(0));
      if (fnM.find()) {
        names.add(fnM.group(1).trim());
      }
    }
    return names;
  }

  // ─────────────────────────────────────────────────────────────
  // APEX REGEX SANITIZER
  // ─────────────────────────────────────────────────────────────
  public static String sanitizeApexRegex(String apexCode) {
    if (String.isBlank(apexCode)) {
      return apexCode;
    }

    apexCode = apexCode.replace('\\+', '[+]');
    apexCode = apexCode.replace('\\d', '[0-9]');
    apexCode = apexCode.replace('\\s', '[ \\t\\n\\r]');
    apexCode = apexCode.replace('\\w', '[a-zA-Z0-9_]');
    apexCode = apexCode.replace('\\.', '[.]');
    // '\[' and '\]' are not valid Apex string-literal escapes — the model
    // sometimes writes them when hand-building a character class (e.g.
    // '\[ \t\n\r]+' instead of '[ \t\n\r]+'), which fails to compile with
    // "Illegal character sequence \[' in string literal". [ and ] never
    // need escaping in an Apex string literal, so just drop the backslash.
    apexCode = apexCode.replace('\\[', '[');
    apexCode = apexCode.replace('\\]', ']');

    Pattern pmPat = Pattern.compile(
      'Pattern[.]matches[(]([^,]+),\\s*([^)]+)[)]'
    );
    Matcher pmMatcher = pmPat.matcher(apexCode);
    apexCode = pmMatcher.replaceAll(
      'Pattern.compile($1).matcher($2).matches()'
    );

    return apexCode;
  }

  // ─────────────────────────────────────────────────────────────
  // STANDARD OBJECT LAYOUT GUARD
  // ─────────────────────────────────────────────────────────────
  public static Boolean isStandardObjectLayout(String memberName) {
    if (String.isBlank(memberName) || !memberName.contains('-')) {
      return false;
    }
    String objPart = memberName.substringBefore('-');
    return STANDARD_OBJECTS.contains(objPart);
  }

  // ─────────────────────────────────────────────────────────────
  // NAME FIELD BEHAVIOR FIX FOR LAYOUTS
  // Salesforce enforces different Name behavior per nameField type:
  //   AutoNumber  → Readonly  (system-generated, cannot be edited)
  //   Text        → Edit      (user-entered, never Required)
  // Called after sanitizeLayoutXml so context from sibling CustomObject
  // XML can be passed in — no other code changes needed to add new types.
  // ─────────────────────────────────────────────────────────────
  public static String fixNameFieldBehaviorInLayout(
    String xml,
    String nameFieldType
  ) {
    if (String.isBlank(xml)) {
      return xml;
    }
    String correctBehavior = 'AutoNumber'.equalsIgnoreCase(nameFieldType)
      ? 'Readonly'
      : 'Required';
    xml = xml.replaceAll(
      '<behavior>(Required|Edit|Readonly)</behavior>(\\s*)<field>Name</field>',
      '<behavior>' + correctBehavior + '</behavior>$2<field>Name</field>'
    );
    xml = xml.replaceAll(
      '<field>Name</field>(\\s*)<behavior>(Required|Edit|Readonly)</behavior>',
      '<field>Name</field>$1<behavior>' + correctBehavior + '</behavior>'
    );
    System.debug(
      '[SANITIZE] fixNameFieldBehaviorInLayout: nameFieldType=[' +
        nameFieldType +
        '] → behavior=[' +
        correctBehavior +
        ']'
    );
    return xml;
  }

  // Returns field API names whose <fields> block contains a <formula> element.
  public static Set<String> extractFormulaFieldNames(String objectXml) {
    Set<String> result = new Set<String>();
    if (String.isBlank(objectXml)) {
      return result;
    }
    Pattern blockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');
    Matcher blockMat = blockPat.matcher(objectXml);
    while (blockMat.find()) {
      String block = blockMat.group(1);
      if (!block.contains('<formula>')) {
        continue;
      }
      Matcher nameMat = Pattern.compile('<fullName>([^<]+)</fullName>')
        .matcher(block);
      if (nameMat.find()) {
        result.add(nameMat.group(1).trim());
      }
    }
    return result;
  }

  // Forces behavior=Readonly for every formula/rollup/autonumber field in a layout.
  public static String fixFormulaFieldBehaviorsInLayout(
    String xml,
    Set<String> formulaFieldNames
  ) {
    if (
      String.isBlank(xml) ||
      formulaFieldNames == null ||
      formulaFieldNames.isEmpty()
    ) {
      return xml;
    }
    Set<String> normalizedTargets = new Set<String>();
    for (String fieldName : formulaFieldNames) {
      if (String.isBlank(fieldName)) {
        continue;
      }
      String f = fieldName.trim();
      normalizedTargets.add(f.toLowerCase());
      if (f.contains('.')) {
        normalizedTargets.add(f.substringAfter('.').toLowerCase());
      }
    }

    Pattern itemPat = Pattern.compile('(?s)<layoutItems>.*?</layoutItems>');
    Matcher itemMat = itemPat.matcher(xml);
    List<String> oldItems = new List<String>();
    List<String> newItems = new List<String>();
    Pattern fieldValPat = Pattern.compile(
      '(?is)<field>\\s*([^<]+?)\\s*</field>'
    );

    while (itemMat.find()) {
      String item = itemMat.group(0);
      Matcher fieldValMat = fieldValPat.matcher(item);
      if (!fieldValMat.find()) {
        continue;
      }

      String rawField = fieldValMat.group(1).trim();
      String norm = rawField.toLowerCase();
      if (norm.contains('.')) {
        norm = norm.substringAfter('.');
      }
      if (
        !normalizedTargets.contains(norm) &&
        !normalizedTargets.contains(rawField.toLowerCase())
      ) {
        continue;
      }

      String updatedItem = item;
      if (updatedItem.contains('<behavior>')) {
        updatedItem = updatedItem.replaceAll(
          '(?s)<behavior>\\s*[^<]*\\s*</behavior>',
          '<behavior>Readonly</behavior>'
        );
      } else {
        updatedItem = updatedItem.replace(
          '<layoutItems>',
          '<layoutItems>\n                <behavior>Readonly</behavior>'
        );
      }

      oldItems.add(item);
      newItems.add(updatedItem);
    }

    for (Integer i = 0; i < oldItems.size(); i++) {
      xml = xml.replace(oldItems[i], newItems[i]);
    }
    System.debug(
      '[SANITIZE] fixFormulaFieldBehaviorsInLayout: forced Readonly on ' +
      formulaFieldNames
    );
    return xml;
  }

  private static String escapeRegexLiteral(String raw) {
    if (raw == null) {
      return '';
    }
    String s = raw;
    s = s.replace('\\', '\\\\');
    s = s.replace('.', '\\.');
    s = s.replace('+', '\\+');
    s = s.replace('*', '\\*');
    s = s.replace('?', '\\?');
    s = s.replace('^', '\\^');
    s = s.replace('$', '\\$');
    s = s.replace('(', '\\(');
    s = s.replace(')', '\\)');
    s = s.replace('[', '\\[');
    s = s.replace(']', '\\]');
    s = s.replace('{', '\\{');
    s = s.replace('}', '\\}');
    s = s.replace('|', '\\|');
    return s;
  }

  // ─────────────────────────────────────────────────────────────
  // AUTONUMBER FIELD BEHAVIOR ENFORCEMENT FOR LAYOUTS
  //
  // The same Readonly-only rule that applies to an AutoNumber Name field
  // (see fixNameFieldBehaviorInLayout above) applies to ANY AutoNumber
  // field — including regular custom fields like Invoice_Number__c.
  // Salesforce rejects Required or Edit on any AutoNumber field with
  // "Field:X must be Readonly". Unlike the Name-field fix, there is no
  // "else" behavior to force here — every field NOT in autoNumberFieldNames
  // is left completely untouched, since Required/Edit is a legitimate,
  // ticket-driven choice for every other field type.
  // ─────────────────────────────────────────────────────────────
  public static String forceReadonlyForAutoNumberFields(
    String xml,
    Set<String> autoNumberFieldNames
  ) {
    if (
      String.isBlank(xml) ||
      autoNumberFieldNames == null ||
      autoNumberFieldNames.isEmpty()
    ) {
      return xml;
    }
    for (String fieldName : autoNumberFieldNames) {
      if (String.isBlank(fieldName)) {
        continue;
      }
      xml = xml.replaceAll(
        '<behavior>(Required|Edit|Readonly)</behavior>(\\s*)<field>' +
          fieldName +
          '</field>',
        '<behavior>Readonly</behavior>$2<field>' + fieldName + '</field>'
      );
      xml = xml.replaceAll(
        '<field>' +
          fieldName +
          '</field>(\\s*)<behavior>(Required|Edit|Readonly)</behavior>',
        '<field>' + fieldName + '</field>$1<behavior>Readonly</behavior>'
      );
    }
    System.debug(
      '[SANITIZE] forceReadonlyForAutoNumberFields: enforced Readonly for ' +
      autoNumberFieldNames
    );
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // INJECT MISSING XML DEFAULTS
  // Injects UI-consistent default values for any elements absent
  // from the LLM-generated XML.  To add a new default for any
  // metadata type, update METADATA_DEFAULTS only — no other
  // code changes required.
  // ─────────────────────────────────────────────────────────────
  public static String injectMissingXmlDefaults(
    String metadataType,
    String xml
  ) {
    if (String.isBlank(xml)) {
      return xml;
    }
    Map<String, String> defaults = METADATA_DEFAULTS.get(metadataType);
    if (defaults == null || defaults.isEmpty()) {
      return xml;
    }
    String closeRoot = '</' + metadataType + '>';
    if (!xml.contains(closeRoot)) {
      return xml;
    }
    List<String> injected = new List<String>();
    for (String element : defaults.keySet()) {
      if (!xml.contains('<' + element + '>')) {
        String line =
          '    <' +
          element +
          '>' +
          defaults.get(element) +
          '</' +
          element +
          '>';
        xml = xml.replace(closeRoot, line + '\n' + closeRoot);
        injected.add(element);
      }
    }
    if (!injected.isEmpty()) {
      System.debug(
        '[SANITIZE] injectMissingXmlDefaults [' +
          metadataType +
          ']: injected ' +
          injected
      );
    }
    return xml;
  }

  // ─────────────────────────────────────────────────────────────
  // OBJECT-LEVEL HISTORY TRACKING CONSISTENCY
  //
  // A field's <trackHistory>true</trackHistory> only takes effect if its
  // parent CustomObject also has <enableHistory>true</enableHistory> — the
  // Setup UI enforces this by graying out the field-level checkbox until
  // the object-level one is checked, but the Metadata API doesn't reject a
  // mismatch, it just silently no-ops the field-level tracking. Unlike
  // enableReports/enableActivities this is NOT blanket-defaulted — object
  // history tracking has real storage cost, so it should only turn on when
  // the ticket (via the LLM's own trackHistory=true on some field, or on
  // the object itself) actually asked for it.
  //
  // Usage: call collectObjectsNeedingHistoryTracking(files) once before
  // the main file loop, then forceEnableHistory() on each CustomObject
  // file whose memberName is in the returned set.
  // ─────────────────────────────────────────────────────────────
  public static Set<String> collectObjectsNeedingHistoryTracking(
    List<Object> files
  ) {
    Set<String> result = new Set<String>();
    if (files == null) {
      return result;
    }

    Pattern fieldBlockPat = Pattern.compile('(?s)<fields>(.*?)</fields>');

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String mt = (String) file.get('metadataType');
      String mn = (String) file.get('memberName');
      String xml = (String) file.get('xmlContent');
      if (String.isBlank(mn) || String.isBlank(xml)) {
        continue;
      }

      if (mt == 'CustomField' && mn.contains('.')) {
        if (xml.contains('<trackHistory>true</trackHistory>')) {
          result.add(mn.substringBefore('.'));
        }
      } else if (mt == 'CustomObject') {
        Matcher blockMatcher = fieldBlockPat.matcher(xml);
        while (blockMatcher.find()) {
          if (
            blockMatcher.group(1).contains('<trackHistory>true</trackHistory>')
          ) {
            result.add(mn);
            break;
          }
        }
      }
    }
    return result;
  }

  public static String forceEnableHistory(String xml) {
    if (String.isBlank(xml) || !xml.contains('</CustomObject>')) {
      return xml;
    }
    if (xml.contains('<enableHistory>true</enableHistory>')) {
      return xml;
    }
    if (xml.contains('<enableHistory>false</enableHistory>')) {
      return xml.replace(
        '<enableHistory>false</enableHistory>',
        '<enableHistory>true</enableHistory>'
      );
    }
    return xml.replace(
      '</CustomObject>',
      '    <enableHistory>true</enableHistory>\n</CustomObject>'
    );
  }

  // ─────────────────────────────────────────────────────────────
  // APPEND DESTRUCTIVE MEMBER
  // ─────────────────────────────────────────────────────────────
  public static void appendDestructiveMember(
    String metadataType,
    String memberName
  ) {
    String typeEsc = escapeXmlValue(metadataType);
    String memberEsc = escapeXmlValue(memberName);
    String existing = ZipBuilder.files.get('destructiveChangesPost.xml');

    String typeBlock =
      '\n    <types>' +
      '\n        <members>' +
      memberEsc +
      '</members>' +
      '\n        <name>' +
      typeEsc +
      '</name>' +
      '\n    </types>';

    String xml;
    if (String.isBlank(existing)) {
      xml =
        '<?xml version="1.0" encoding="UTF-8"?>' +
        '\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">' +
        typeBlock +
        '\n    <version>61.0</version>' +
        '\n</Package>';
    } else if (existing.contains('<version>')) {
      xml = existing.replace('<version>', typeBlock + '\n    <version>');
    } else if (existing.contains('</Package>')) {
      xml = existing.replace('</Package>', typeBlock + '\n</Package>');
    } else {
      xml = existing + typeBlock;
    }

    ZipBuilder.addFile(
      '__destructive__',
      memberName,
      'destructiveChangesPost.xml',
      xml
    );
  }

  // ─────────────────────────────────────────────────────────────
  // FIELD-LEVEL SECURITY BACKSTOP
  //
  // After all files are processed, scans CustomObject XML in the
  // deploy batch for new custom fields and ensures <fieldPermissions>
  // are set correctly for all relevant profiles.
  //
  // Default rules:
  //   - Formula / Summary / AutoNumber → readable=true, editable=false
  //   - Required fields                → skipped (implicit access)
  //   - All other custom fields        → readable=true, editable=true
  //
  // Profile coverage:
  //   1. Every Profile file already in ZipBuilder gets patched (LLM-generated
  //      or ticket-specified profiles)
  //   2. Admin profile is always guaranteed as minimum fallback
  //   3. The running user's profile is also guaranteed (if different from Admin)
  //      so the person who triggered the deploy can always see the new fields
  //
  // To add new read-only field types → update READ_ONLY_FIELD_TYPES only.
  // ─────────────────────────────────────────────────────────────
  private static final Set<String> READ_ONLY_FIELD_TYPES = new Set<String>{
    'Formula',
    'Summary',
    'AutoNumber'
  };

  public static void injectDefaultFieldPermissions(List<Object> files) {
    if (files == null || files.isEmpty()) {
      return;
    }

    // Step 1: Collect new custom fields from CustomObject files
    Map<String, List<String>> editableByObj = new Map<String, List<String>>();
    Map<String, List<String>> readOnlyByObj = new Map<String, List<String>>();

    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String mt = (String) file.get('metadataType');
      String mn = (String) file.get('memberName');
      if (mt != 'CustomObject' || !mn.endsWith('__c')) {
        continue;
      }
      String xml = (String) file.get('xmlContent');
      if (String.isBlank(xml) || !xml.contains('<fields>')) {
        continue;
      }

      List<String> editable = new List<String>();
      List<String> readOnly = new List<String>();
      Pattern p = Pattern.compile('(?s)<fields>(.*?)</fields>');
      Matcher m = p.matcher(xml);
      while (m.find()) {
        String block = m.group(1);
        String fieldName = extractInlineTagValue(block, 'fullName');
        if (String.isBlank(fieldName)) {
          continue;
        }
        // Required fields have implicit access — Salesforce rejects explicit FLS entries
        String reqVal = extractInlineTagValue(block, 'required');
        if ('true'.equalsIgnoreCase(reqVal)) {
          continue;
        }
        String fieldType = extractInlineTagValue(block, 'type');
        if (READ_ONLY_FIELD_TYPES.contains(fieldType)) {
          readOnly.add(fieldName);
        } else {
          editable.add(fieldName);
        }
      }

      if (!editable.isEmpty()) {
        editableByObj.put(mn, editable);
      }
      if (!readOnly.isEmpty()) {
        readOnlyByObj.put(mn, readOnly);
      }
    }

    if (editableByObj.isEmpty() && readOnlyByObj.isEmpty()) {
      return;
    }

    // Step 2: Resolve running user's profile metadata member name
    // Standard profile display names → metadata API member names
    // (DeveloperName is not accessible via SOQL in all org contexts)
    String runningUserProfile = 'Admin';
    try {
      Profile p = [
        SELECT Name
        FROM Profile
        WHERE Id = :UserInfo.getProfileId()
        LIMIT 1
      ];
      if (String.isNotBlank(p.Name)) {
        runningUserProfile = profileNameToMemberName(p.Name);
      }
    } catch (Exception e) {
      System.debug(
        '[FLS] Could not resolve running user profile, defaulting to Admin: ' +
        e.getMessage()
      );
    }

    // Minimum guaranteed profiles — Admin always, plus the triggering user's profile
    Set<String> defaultProfiles = new Set<String>{
      'Admin',
      runningUserProfile
    };

    // Step 3: Update existing Profile files already in ZipBuilder
    Set<String> handledProfiles = new Set<String>();
    List<String> existingPaths = new List<String>();
    for (String path : ZipBuilder.files.keySet()) {
      if (path.startsWith('profiles/') && path.endsWith('.profile')) {
        existingPaths.add(path);
      }
    }

    for (String filePath : existingPaths) {
      String profileName = filePath.removeStart('profiles/')
        .removeEnd('.profile');
      String profileXml = ZipBuilder.files.get(filePath);
      if (String.isBlank(profileXml) || !profileXml.contains('</Profile>')) {
        continue;
      }
      List<String> newBlocks = buildFLSBlocks(
        editableByObj,
        readOnlyByObj,
        profileXml
      );
      if (!newBlocks.isEmpty()) {
        String updatedXml = profileXml.replace(
          '</Profile>',
          String.join(newBlocks, '\n') + '\n</Profile>'
        );
        ZipBuilder.addFile('Profile', profileName, filePath, updatedXml);
        System.debug(
          '[FLS] injectDefaultFieldPermissions: updated [' +
            filePath +
            '] \u2190 ' +
            newBlocks.size() +
            ' fieldPermissions'
        );
      }
      handledProfiles.add(profileName);
    }

    // Step 4: Create minimal Profile files for any default profile not yet handled
    for (String profileName : defaultProfiles) {
      if (handledProfiles.contains(profileName)) {
        continue;
      }
      List<String> newBlocks = buildFLSBlocks(editableByObj, readOnlyByObj, '');
      if (newBlocks.isEmpty()) {
        continue;
      }
      String profileXml =
        '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
        String.join(newBlocks, '\n') +
        '\n</Profile>';
      String filePath = 'profiles/' + profileName + '.profile';
      ZipBuilder.addFile('Profile', profileName, filePath, profileXml);
      System.debug(
        '[FLS] injectDefaultFieldPermissions: created [' +
          filePath +
          '] \u2190 ' +
          newBlocks.size() +
          ' fieldPermissions'
      );
    }
  }

  // \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  // TAB VISIBILITY BACKSTOP
  //
  // Guarantees the Admin profile always gets a DefaultOn tabVisibilities
  // entry for every custom tab newly created in this deploy \u2014 regardless
  // of whether the LLM's own Profile file mentioned the tab at all. This
  // is what makes a brand-new tab immediately addable to a Lightning app's
  // navigation without a manual Setup fix.
  //
  // Other profiles are left untouched here \u2014 they only get a tab entry
  // when the ticket explicitly targets them, which flows through the
  // LLM's own Profile file and defaultCustomTabVisibilityToOn() above.
  // \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  public static void injectDefaultTabVisibility(List<Object> files) {
    if (files == null || files.isEmpty()) {
      return;
    }

    Set<String> newTabs = new Set<String>();
    for (Object rawFile : files) {
      Map<String, Object> file = (Map<String, Object>) rawFile;
      String mt = (String) file.get('metadataType');
      String mn = (String) file.get('memberName');
      if (mt == 'CustomTab' && String.isNotBlank(mn) && mn.endsWith('__c')) {
        newTabs.add(mn);
      }
    }
    if (newTabs.isEmpty()) {
      return;
    }

    String adminPath = 'profiles/Admin.profile';
    String adminXml = ZipBuilder.files.get(adminPath);

    Set<String> alreadyCovered = new Set<String>();
    if (String.isNotBlank(adminXml)) {
      Pattern tabPat = Pattern.compile(
        '<tabVisibilities>\\s*<tab>([^<]+)</tab>'
      );
      Matcher m = tabPat.matcher(adminXml);
      while (m.find()) {
        alreadyCovered.add(m.group(1).trim());
      }
    }

    List<String> newBlocks = new List<String>();
    for (String tabName : newTabs) {
      if (alreadyCovered.contains(tabName)) {
        continue;
      }
      newBlocks.add(
        '    <tabVisibilities>\n' +
          '        <tab>' +
          tabName +
          '</tab>\n' +
          '        <visibility>DefaultOn</visibility>\n' +
          '    </tabVisibilities>'
      );
    }
    if (newBlocks.isEmpty()) {
      return;
    }

    if (String.isNotBlank(adminXml) && adminXml.contains('</Profile>')) {
      String updatedXml = adminXml.replace(
        '</Profile>',
        String.join(newBlocks, '\n') + '\n</Profile>'
      );
      ZipBuilder.addFile('Profile', 'Admin', adminPath, updatedXml);
    } else {
      String profileXml =
        '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
        String.join(newBlocks, '\n') +
        '\n</Profile>';
      ZipBuilder.addFile('Profile', 'Admin', adminPath, profileXml);
    }
    System.debug(
      '[DEPLOY-TRACE] injectDefaultTabVisibility: granted DefaultOn on Admin for ' +
        newBlocks.size() +
        ' new tab(s)'
    );
  }

  // Maps a Profile display Name to its Salesforce metadata member name.
  // Standard profiles have well-known member names that differ from their
  // display names. Custom profiles use display name with spaces → underscores.
  private static String profileNameToMemberName(String displayName) {
    Map<String, String> KNOWN = new Map<String, String>{
      'System Administrator' => 'Admin',
      'Standard User' => 'Standard',
      'Salesforce Platform User' => 'StandardAul',
      'Standard Platform User' => 'StandardAul',
      'Contract Manager' => 'ContractManager',
      'Marketing User' => 'MarketingProfile',
      'Read Only' => 'ReadOnly',
      'Solution Manager' => 'SolutionManager'
    };
    String mapped = KNOWN.get(displayName);
    if (String.isNotBlank(mapped)) {
      return mapped;
    }
    // Custom profiles: replace non-alphanumeric chars with underscore
    String safe = displayName.replaceAll('[^a-zA-Z0-9]+', '_')
      .removeStart('_')
      .removeEnd('_');
    return String.isNotBlank(safe) ? safe : 'Admin';
  }

  // Builds <fieldPermissions> XML blocks for one profile.
  // Pass existing profile XML to skip already-present fields,
  // or empty string when creating a brand-new profile file.
  private static List<String> buildFLSBlocks(
    Map<String, List<String>> editableByObj,
    Map<String, List<String>> readOnlyByObj,
    String existingXml
  ) {
    List<String> blocks = new List<String>();
    for (String objName : editableByObj.keySet()) {
      for (String fn : editableByObj.get(objName)) {
        String qf = objName + '.' + fn;
        if (
          String.isNotBlank(existingXml) &&
          existingXml.contains('<field>' + qf + '</field>')
        ) {
          continue;
        }
        blocks.add(
          '    <fieldPermissions>\n' +
            '        <editable>true</editable>\n' +
            '        <field>' +
            qf +
            '</field>\n' +
            '        <readable>true</readable>\n' +
            '    </fieldPermissions>'
        );
      }
    }
    for (String objName : readOnlyByObj.keySet()) {
      for (String fn : readOnlyByObj.get(objName)) {
        String qf = objName + '.' + fn;
        if (
          String.isNotBlank(existingXml) &&
          existingXml.contains('<field>' + qf + '</field>')
        ) {
          continue;
        }
        blocks.add(
          '    <fieldPermissions>\n' +
            '        <editable>false</editable>\n' +
            '        <field>' +
            qf +
            '</field>\n' +
            '        <readable>true</readable>\n' +
            '    </fieldPermissions>'
        );
      }
    }
    return blocks;
  }

  public static String escapeXmlValue(String val) {
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
  // VALIDATION RULE FIELD/TYPE CHECK
  // Mechanically verifies (via SchemaFieldValidator, not the LLM's word)
  // that every field referenced in a TODAY()/NOW() date comparison inside
  // a validation rule's errorConditionFormula actually exists on the
  // object, and that the comparison matches the field's REAL type —
  // catches "Incorrect parameter type for operator... Expected Date/Time,
  // received Date" (or the reverse) before it ever reaches a real deploy.
  // ─────────────────────────────────────────────────────────────
  public static void validateValidationRuleFieldTypes(
    String objectApiName,
    String xmlContent
  ) {
    if (
      String.isBlank(xmlContent) || !xmlContent.contains('<validationRules>')
    ) {
      return;
    }

    Pattern rulePat = Pattern.compile(
      '(?s)<errorConditionFormula>(.*?)</errorConditionFormula>'
    );
    Matcher ruleMatcher = rulePat.matcher(xmlContent);

    Pattern cmpPat = Pattern.compile(
      '([A-Za-z_][A-Za-z0-9_]*__c)\\s*[<>]=?\\s*(TODAY|NOW)\\s*\\(\\s*\\)' +
      '|(TODAY|NOW)\\s*\\(\\s*\\)\\s*[<>]=?\\s*([A-Za-z_][A-Za-z0-9_]*__c)'
    );

    while (ruleMatcher.find()) {
      String formula = ruleMatcher.group(1)
        .replace('&lt;', '<')
        .replace('&gt;', '>')
        .replace('&amp;', '&');

      Matcher cmpMatcher = cmpPat.matcher(formula);

      while (cmpMatcher.find()) {
        String fieldName = cmpMatcher.group(1) != null
          ? cmpMatcher.group(1)
          : cmpMatcher.group(4);
        String func = cmpMatcher.group(2) != null
          ? cmpMatcher.group(2)
          : cmpMatcher.group(3);

        String realType = SchemaFieldValidator.getFieldType(
          objectApiName,
          fieldName
        );

        if (realType == null) {
          throw new ApexCodeValidator.ValidationException(
            '[' +
              objectApiName +
              '] Validation rule formula references field "' +
              fieldName +
              '" which does not exist on this object. Known fields: ' +
              SchemaFieldValidator.getKnownFieldNames(objectApiName)
          );
        }

        Boolean isDateTime = realType == 'DATETIME';
        if (isDateTime && func == 'TODAY') {
          throw new ApexCodeValidator.ValidationException(
            '[' +
              objectApiName +
              '] Formula compares "' +
              fieldName +
              '" (actual type: Date/Time) with TODAY() (Date). ' +
              'Use NOW() instead, or wrap the field with DATEVALUE(' +
              fieldName +
              ') to compare with TODAY().'
          );
        }
        if (!isDateTime && func == 'NOW' && realType == 'DATE') {
          throw new ApexCodeValidator.ValidationException(
            '[' +
              objectApiName +
              '] Formula compares "' +
              fieldName +
              '" (actual type: Date) with NOW() (Date/Time). ' +
              'Use TODAY() instead.'
          );
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // SOQL FIELD EXISTENCE CHECK (Apex/trigger source)
  // Only checks simple, single-object, non-relationship SOQL field lists —
  // deliberately skips anything with a subquery, relationship traversal
  // (Account.Name), or aggregate function, since those can't be parsed
  // reliably with regex and a false positive here would block a valid
  // deploy. Under-catching is the safe failure mode; over-catching is not.
  // ─────────────────────────────────────────────────────────────
  public static void validateSoqlFieldsExist(String fileName, String apexCode) {
    if (String.isBlank(apexCode)) {
      return;
    }

    Pattern soqlPat = Pattern.compile(
      '(?is)\\[\\s*SELECT\\s+(.*?)\\s+FROM\\s+([A-Za-z_][A-Za-z0-9_]*)\\b'
    );
    Matcher m = soqlPat.matcher(apexCode);

    while (m.find()) {
      String fieldList = m.group(1);
      String objectApiName = m.group(2);

      if (fieldList.contains('(')) {
        continue; // subquery or aggregate function present — skip, too risky to parse
      }

      for (String rawField : fieldList.split(',')) {
        String field = rawField.trim();
        if (
          String.isBlank(field) ||
          field.contains('.') || // relationship traversal, e.g. Account.Name — different object context
          field == '*'
        ) {
          continue;
        }
        if (!SchemaFieldValidator.fieldExists(objectApiName, field)) {
          throw new ApexCodeValidator.ValidationException(
            '[' +
              fileName +
              '] SOQL query references field "' +
              field +
              '" which does not exist on ' +
              objectApiName +
              '. Known fields: ' +
              SchemaFieldValidator.getKnownFieldNames(objectApiName)
          );
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // LWC @salesforce/schema IMPORT CHECK
  // Only checks the explicit, unambiguous @salesforce/schema/Object.Field
  // import path — deliberately does not attempt to verify datatable column
  // fieldName values or other JS identifiers, since those are frequently
  // aliased wrapper/DTO properties rather than real SObject fields, and
  // checking those would produce false positives.
  // ─────────────────────────────────────────────────────────────
  public static void validateLwcSchemaImports(
    String fileName,
    String jsContent
  ) {
    if (String.isBlank(jsContent)) {
      return;
    }

    Pattern importPat = Pattern.compile(
      'from\\s+[\'"]@salesforce/schema/([A-Za-z_][A-Za-z0-9_]*)\\.([A-Za-z_][A-Za-z0-9_]*)[\'"]'
    );
    Matcher m = importPat.matcher(jsContent);

    while (m.find()) {
      String objectApiName = m.group(1);
      String fieldApiName = m.group(2);

      if (!SchemaFieldValidator.fieldExists(objectApiName, fieldApiName)) {
        throw new ApexCodeValidator.ValidationException(
          '[' +
            fileName +
            '] Imports @salesforce/schema/' +
            objectApiName +
            '.' +
            fieldApiName +
            ' but that field does not exist. Known fields: ' +
            SchemaFieldValidator.getKnownFieldNames(objectApiName)
        );
      }
    }
  }
}
