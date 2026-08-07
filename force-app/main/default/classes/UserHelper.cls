public class UserHelper {
  public class UserHelperException extends Exception {}

  private static final Map<String, String> PROFILE_NAME_MAP = new Map<String, String>{
    'System Administrator' => 'Admin',
    'Standard User' => 'Standard',
    'Standard Platform User' => 'StandardAul',
    'Marketing User' => 'MarketingProfile',
    'Contract Manager' => 'ContractManager',
    'Solution Manager' => 'SolutionManager'
  };

  public static SObject buildUser(Map<String, Object> args) {
    String username = getRequired(args, 'username');
    String lastName = getOptional(args, 'lastName', 'TestUser');
    String firstName = getOptional(args, 'firstName', 'Test');
    String alias = getOptional(args, 'alias', buildAlias(username));
    String email = getOptional(args, 'email', username);
    String profileName = getOptional(args, 'profileName', 'Standard User');
    String timeZoneSidKey = getOptional(args, 'timeZoneSidKey', 'America/Los_Angeles');
    String localeSidKey = getOptional(args, 'localeSidKey', 'en_US');
    String emailEncodingKey = getOptional(args, 'emailEncodingKey', 'UTF-8');
    String languageLocaleKey = getOptional(args, 'languageLocaleKey', 'en_US');

    List<User> existing = [
      SELECT Id, Username, IsActive
      FROM User
      WHERE Username = :username
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      throw new UserHelperException('User already exists: ' + username);
    }

    List<Profile> profiles = [
      SELECT Id, Name
      FROM Profile
      WHERE Name = :profileName
      LIMIT 1
    ];
    if (profiles.isEmpty()) {
      String resolvedProfileName = resolveProfileName(profileName);
      if (resolvedProfileName != profileName) {
        profiles = [
          SELECT Id, Name
          FROM Profile
          WHERE Name = :resolvedProfileName
          LIMIT 1
        ];
      }
    }
    if (profiles.isEmpty()) {
      throw new UserHelperException('Profile not found: ' + profileName);
    }

    User userRecord = new User();
    userRecord.Username = username;
    userRecord.FirstName = firstName;
    userRecord.LastName = lastName;
    userRecord.Alias = normalizeAlias(alias);
    userRecord.Email = email;
    userRecord.ProfileId = profiles[0].Id;
    userRecord.TimeZoneSidKey = timeZoneSidKey;
    userRecord.LocaleSidKey = localeSidKey;
    userRecord.EmailEncodingKey = emailEncodingKey;
    userRecord.LanguageLocaleKey = languageLocaleKey;
    userRecord.IsActive = true;

    System.debug(
      'UserHelper.buildUser(): queued active user [' + username + '] with profile [' +
        profiles[0].Name + ']'
    );
    return userRecord;
  }

  private static String buildAlias(String username) {
    if (String.isBlank(username)) {
      return 'testusr';
    }
    String localPart = username.contains('@') ? username.substringBefore('@') : username;
    localPart = localPart.replaceAll('[^A-Za-z0-9]', '').toLowerCase();
    if (String.isBlank(localPart)) {
      localPart = 'testusr';
    }
    return normalizeAlias(localPart.length() > 8 ? localPart.substring(0, 8) : localPart);
  }

  private static String normalizeAlias(String alias) {
    if (String.isBlank(alias)) {
      return 'testusr';
    }
    String clean = alias.replaceAll('[^A-Za-z0-9]', '');
    if (clean.length() > 8) {
      clean = clean.substring(0, 8);
    }
    return clean;
  }

  private static String resolveProfileName(String profileName) {
    if (PROFILE_NAME_MAP.containsKey(profileName)) {
      return PROFILE_NAME_MAP.get(profileName);
    }
    return profileName;
  }

  private static String getRequired(Map<String, Object> args, String key) {
    String value = getOptional(args, key, null);
    if (String.isBlank(value)) {
      throw new UserHelperException('Missing required arg: ' + key);
    }
    return value;
  }

  private static String getOptional(Map<String, Object> args, String key, String defaultValue) {
    if (args == null || !args.containsKey(key) || args.get(key) == null) {
      return defaultValue;
    }
    String value = String.valueOf(args.get(key));
    return String.isBlank(value) ? defaultValue : value;
  }
}