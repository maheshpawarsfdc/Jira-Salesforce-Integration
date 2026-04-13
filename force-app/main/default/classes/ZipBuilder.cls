/**
 * ZipBuilder.cls
 *
 * Collects metadata XML files during tool execution.
 * After all tools run, builds a ZIP file ready for Metadata API deploy.
 *
 * HOW IT WORKS:
 * 1. During tool execution — tools call addFile() to queue XML content
 * 2. After loop — LLMService calls buildBase64Zip() to get the ZIP
 * 3. ZIP is passed to DeployService.deploy()
 *
 * USES: Zippex library (Zippex.cls + HexUtil.cls + Puff.cls)
 */
public class ZipBuilder {

    // FILE STORE
    // Key   = file path inside ZIP  e.g. "objects/Reservation__c.object-meta.xml"
    // Value = file XML content
    public static Map<String, String> files = new Map<String, String>();
    public static Map<String, String> binaryFiles = new Map<String, String>();

    // Track which metadata types are included — needed for package.xml
    // Key   = metadata type  e.g. "CustomObject"
    // Value = set of member names  e.g. {"Reservation__c"}
    public static Map<String, Set<String>> metadataTypes = new Map<String, Set<String>>();

    // ─────────────────────────────────────────────────────────────
    // ADD FILE
    // Called by MetadataHelper, PermissionSetHelper, ProfileHelper etc
    // ─────────────────────────────────────────────────────────────
    public static void addFile(String metadataType, String memberName, String filePath, String content) {
        System.debug('ZipBuilder.addFile(): type=' + metadataType + ', member=' + memberName + ', path=' + filePath);
        files.put(filePath, content);

        // Track for package.xml — skip __destructive__ entries (they use destructiveChangesPost.xml)
        if (!metadataType.startsWith('__destructive__')) {
            if (!metadataTypes.containsKey(metadataType)) {
                metadataTypes.put(metadataType, new Set<String>());
            }
            metadataTypes.get(metadataType).add(memberName);
        }
    }

    public static void addBinaryFile(String metadataType, String memberName, String filePath, String base64Content) {
        System.debug('ZipBuilder.addBinaryFile(): type=' + metadataType + ', member=' + memberName + ', path=' + filePath);
        binaryFiles.put(filePath, base64Content);

        if (!metadataTypes.containsKey(metadataType)) {
            metadataTypes.put(metadataType, new Set<String>());
        }
        metadataTypes.get(metadataType).add(memberName);
    }

    // ─────────────────────────────────────────────────────────────
    // EXTRACT FILE FROM ZIP
    //
    // Given a ZIP blob (e.g. from a Metadata API retrieve response),
    // extracts and returns the content of a single file by path.
    // Returns null if the file is not found in the ZIP.
    //
    // Used by PermissionSetHelper.clonePermissionSet() to read the
    // raw deployed XML of a source permission set.
    // ─────────────────────────────────────────────────────────────
    public static String extractFileFromZip(Blob zipBlob, String filePath) {
        System.debug('ZipBuilder.extractFileFromZip(): looking for [' + filePath + ']');
        try {
            Zippex zip = new Zippex(zipBlob);
            Set<String> fileNames = zip.getFileNames();
            System.debug('ZipBuilder.extractFileFromZip(): ZIP contains ' + fileNames.size() + ' files: ' + fileNames);

            // Try exact path first
            if (fileNames.contains(filePath)) {
                Blob fileBlob = zip.getFile(filePath);
                System.debug('ZipBuilder.extractFileFromZip(): found [' + filePath + '], size=' + fileBlob.size());
                return fileBlob.toString();
            }

            // Try case-insensitive match (Salesforce ZIPs sometimes vary casing)
            String lowerTarget = filePath.toLowerCase();
            for (String name : fileNames) {
                if (name.toLowerCase() == lowerTarget) {
                    Blob fileBlob = zip.getFile(name);
                    System.debug('ZipBuilder.extractFileFromZip(): found (case-insensitive) [' + name + '], size=' + fileBlob.size());
                    return fileBlob.toString();
                }
            }

            // Try matching just the filename without directory prefix
            // (some retrieve ZIPs omit the top-level folder or add unpackaged/ prefix)
            String fileName = filePath.contains('/') ? filePath.substringAfterLast('/') : filePath;
            for (String name : fileNames) {
                if (name.endsWith(fileName)) {
                    Blob fileBlob = zip.getFile(name);
                    System.debug('ZipBuilder.extractFileFromZip(): found by filename [' + name + '], size=' + fileBlob.size());
                    return fileBlob.toString();
                }
            }

            System.debug('ZipBuilder.extractFileFromZip(): file not found in ZIP: ' + filePath);
            return null;
        } catch (Exception e) {
            System.debug('ZipBuilder.extractFileFromZip(): ERROR - ' + e.getMessage());
            throw new ZipBuilderException('Failed to extract [' + filePath + '] from ZIP: ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────
    // BUILD BASE64 ZIP
    // Builds the complete ZIP and returns base64 encoded string
    // ready to pass to MetadataPort.deploy()
    // ─────────────────────────────────────────────────────────────
    public static String buildBase64Zip() {
        System.debug('ZipBuilder.buildBase64Zip(): building ZIP with ' + files.size() + ' files');

        if (files.isEmpty() && binaryFiles.isEmpty()) {
            throw new ZipBuilderException('No files to deploy');
        }

        finalizeObjectXml();  // Merge record type fragments into object XML
        finalizeProfileXml();  // Merge record type visibility into profile XML
        // Use Zippex library for ZIP creation
        Zippex zip = new Zippex();

        // Add package.xml first
        String packageXml = buildPackageXml();
        System.debug('ZipBuilder: package.xml =\n' + packageXml);
        zip.addFile('package.xml', Blob.valueOf(packageXml), null);

        // Add all metadata files
        for (String filePath : files.keySet()) {
            String content   = files.get(filePath);
            Blob   fileBlob  = Blob.valueOf(content);
            // Pre-compute CRC32 from Blob to avoid the expensive hex-string CRC loop in Zippex
            String crc32     = HexUtil.intToHexLE(HexUtil.CRC32Table(fileBlob), 4);
            System.debug('ZipBuilder: adding file [' + filePath + ']');
            zip.addFile(filePath, fileBlob, crc32);
        }

        // Add all binary files (e.g. static resources)
        for (String filePath : binaryFiles.keySet()) {
            try {
                String base64Content = binaryFiles.get(filePath);
                System.debug('ZipBuilder: decoding binary file [' + filePath + '], base64 length=' + base64Content.length());
                String cleanBase64   = base64Content
                                        .replace('\n', '')
                                        .replace('\r', '')
                                        .replace(' ', '')
                                        .replace('\t', '');

                Blob fileBlob = EncodingUtil.base64Decode(cleanBase64);
                System.debug('ZipBuilder: adding binary file [' + filePath + '], size=' + fileBlob.size() + ' bytes');
                // Pre-compute CRC32 from the decoded Blob — this uses the fast Blob-based CRC path
                // and avoids iterating over the 2x-larger hex string representation inside Zippex
                String crc32 = HexUtil.intToHexLE(HexUtil.CRC32Table(fileBlob), 4);
                zip.addFile(filePath, fileBlob, crc32);
            } catch (Exception e) {
                System.debug('ZipBuilder: ERROR with binary file [' + filePath + ']: ' + e.getMessage());
                throw new ZipBuilderException('Failed to add binary file ' + filePath + ': ' + e.getMessage());
            }
        }

        Blob zipBlob = zip.getZipArchive();
        String base64 = EncodingUtil.base64Encode(zipBlob);
        System.debug('ZipBuilder.buildBase64Zip(): ZIP built successfully. Size = ' + zipBlob.size() + ' bytes');
        return base64;
    }

    // ─────────────────────────────────────────────────────────────
    // BUILD PACKAGE.XML
    // Generates package.xml from tracked metadata types
    // ─────────────────────────────────────────────────────────────
    public static String buildPackageXml() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xml += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n';

        for (String metadataType : metadataTypes.keySet()) {
            Set<String> members = metadataTypes.get(metadataType);
            xml += '    <types>\n';
            for (String member : members) {
                xml += '        <members>' + member + '</members>\n';
            }
            xml += '        <name>' + metadataType + '</name>\n';
            xml += '    </types>\n';
        }

        xml += '    <version>61.0</version>\n';
        xml += '</Package>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // FINALIZE OBJECT XML WITH RECORD TYPE FRAGMENTS
    // Called before building ZIP to merge all staged record type fragments
    // ─────────────────────────────────────────────────────────────
    public static void finalizeObjectXml() {
        System.debug('ZipBuilder.finalizeObjectXml(): merging record type fragments...');
        
        // Collect all record type fragments by object
        Map<String, List<String>> rtFragmentsByObject = new Map<String, List<String>>();
        Map<String, List<String>> picklistFragmentsByRT = new Map<String, List<String>>();
        
        List<String> keysToRemove = new List<String>();
        
        for (String key : files.keySet()) {
            if (key.startsWith('recordTypes.')) {
                // Parse: recordTypes.Car__c.Premium
                List<String> parts = key.split('\\.');
                String objectName = parts[1];
                
                if (!rtFragmentsByObject.containsKey(objectName)) {
                    rtFragmentsByObject.put(objectName, new List<String>());
                }
                rtFragmentsByObject.get(objectName).add(files.get(key));
                keysToRemove.add(key);
                
            } else if (key.startsWith('recordTypePicklist.')) {
                // Parse: recordTypePicklist.Opportunity__c.Premium.StageName
                List<String> parts = key.split('\\.');
                String objectName = parts[1];
                String rtName = parts[2];
                String rtKey = objectName + '.' + rtName;
                
                if (!picklistFragmentsByRT.containsKey(rtKey)) {
                    picklistFragmentsByRT.put(rtKey, new List<String>());
                }
                picklistFragmentsByRT.get(rtKey).add(files.get(key));
                keysToRemove.add(key);
            }
        }
        
        // Remove fragments from files map
        for (String key : keysToRemove) {
            files.remove(key);
        }
        
        if (rtFragmentsByObject.isEmpty()) {
            System.debug('ZipBuilder: no record type fragments to merge');
            return;
        }
        
        // For each object with record types, build/update its object XML
        for (String objectName : rtFragmentsByObject.keySet()) {
            String objectXmlPath = 'objects/' + objectName + '.object-meta.xml';
            String objectXml;
            
            if (files.containsKey(objectXmlPath)) {
                // Object XML already exists (from sobject_create or sobject_update)
                objectXml = files.get(objectXmlPath);
            } else {
                // Need to retrieve existing object XML or create skeleton
                objectXml = retrieveOrCreateObjectXml(objectName);
            }
            
            // Merge record type fragments
            List<String> rtFragments = rtFragmentsByObject.get(objectName);
            for (String rtXml : rtFragments) {
                // Insert before </CustomObject>
                Integer insertIdx = objectXml.lastIndexOf('</CustomObject>');
                objectXml = objectXml.substring(0, insertIdx)
                    + '    ' + rtXml + '\n'
                    + objectXml.substring(insertIdx);
            }
            
            // Save merged XML
            files.put(objectXmlPath, objectXml);
            
            // Track for package.xml
            if (!metadataTypes.containsKey('CustomObject')) {
                metadataTypes.put('CustomObject', new Set<String>());
            }
            metadataTypes.get('CustomObject').add(objectName);
        }
        
        System.debug('ZipBuilder: record type fragments merged into object XML');
    }

    private static String retrieveOrCreateObjectXml(String objectName) {
        // Try to get via Schema first (for existing objects)
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (gd.containsKey(objectName)) {
            // Object exists - return minimal skeleton (Metadata API will merge with existing)
            return '<?xml version="1.0" encoding="UTF-8"?>\n'
                + '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n'
                + '</CustomObject>';
        }
        
        // Object doesn't exist yet - return full skeleton
        // (This shouldn't happen if LLM follows "create object first" pattern)
        throw new ZipBuilderException(
            'Cannot add record type to non-existent object: ' + objectName
        );
    }

    // ─────────────────────────────────────────────────────────────
    // FINALIZE PROFILE XML WITH RECORD TYPE FRAGMENTS
    // Called before building ZIP to merge all staged profile fragments
    // ─────────────────────────────────────────────────────────────
    public static void finalizeProfileXml() {
        System.debug('ZipBuilder.finalizeProfileXml(): merging profile fragments...');
        
        // Collect all profile RT visibility fragments by profile name
        Map<String, List<String>> fragmentsByProfile = new Map<String, List<String>>();
        List<String> keysToRemove = new List<String>();
        
        for (String key : files.keySet()) {
            if (key.startsWith('profileRTVisibility.')) {
                // Parse: profileRTVisibility.System Administrator.Account.Premium_Customer
                List<String> parts = key.split('\\.');
                String profileName = parts[1];
                
                // Handle profile names with spaces (they get split)
                // e.g., "System Administrator" becomes parts[1]="System", parts[2]="Administrator"
                Integer objectIdx = parts.size() - 2;  // Second to last is object name
                Integer rtIdx = parts.size() - 1;      // Last is record type name
                
                // Reconstruct profile name (everything between index 1 and objectIdx)
                profileName = '';
                for (Integer i = 1; i < objectIdx; i++) {
                    if (i > 1) profileName += '.';
                    profileName += parts[i];
                }
                
                if (!fragmentsByProfile.containsKey(profileName)) {
                    fragmentsByProfile.put(profileName, new List<String>());
                }
                fragmentsByProfile.get(profileName).add(files.get(key));
                keysToRemove.add(key);
            }
        }
        
        // Remove fragments from files map
        for (String key : keysToRemove) {
            files.remove(key);
        }
        
        if (fragmentsByProfile.isEmpty()) {
            System.debug('ZipBuilder: no profile fragments to merge');
            return;
        }
        
        // For each profile with fragments, build/update its XML
        for (String profileName : fragmentsByProfile.keySet()) {
            String profileXmlPath = 'profiles/' + profileName + '.profile-meta.xml';
            String profileXml;
            
            if (files.containsKey(profileXmlPath)) {
                // Profile XML already exists in this deploy
                profileXml = files.get(profileXmlPath);
            } else {
                // Create minimal profile skeleton
                profileXml = '<?xml version="1.0" encoding="UTF-8"?>\n';
                profileXml += '<Profile xmlns="http://soap.sforce.com/2006/04/metadata">\n';
                profileXml += '</Profile>';
            }
            
            // Merge fragments
            List<String> fragments = fragmentsByProfile.get(profileName);
            for (String fragmentXml : fragments) {
                // Insert before </Profile>
                Integer insertIdx = profileXml.lastIndexOf('</Profile>');
                profileXml = profileXml.substring(0, insertIdx)
                    + '    ' + fragmentXml + '\n'
                    + profileXml.substring(insertIdx);
            }
            
            // Save merged XML
            files.put(profileXmlPath, profileXml);
            
            // Track for package.xml
            if (!metadataTypes.containsKey('Profile')) {
                metadataTypes.put('Profile', new Set<String>());
            }
            metadataTypes.get('Profile').add(profileName);
        }
        
        System.debug('ZipBuilder: profile fragments merged');
    }

    // ─────────────────────────────────────────────────────────────
    // HAS FILES
    // ─────────────────────────────────────────────────────────────
    public static Boolean hasFiles() {
        return !files.isEmpty() || !binaryFiles.isEmpty();
    }

    // ─────────────────────────────────────────────────────────────
    // CLEAR
    // Called after deploy to reset state
    // ─────────────────────────────────────────────────────────────
    public static void clear() {
        files.clear();
        metadataTypes.clear();
        binaryFiles.clear();
        System.debug('ZipBuilder.clear(): state reset');
    }

    // ─────────────────────────────────────────────────────────────
    // EXCEPTION
    // ─────────────────────────────────────────────────────────────
    public class ZipBuilderException extends Exception {}
}