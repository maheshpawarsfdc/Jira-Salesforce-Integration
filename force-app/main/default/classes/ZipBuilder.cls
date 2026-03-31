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
 * FILE STRUCTURE INSIDE ZIP:
 *   package.xml
 *   objects/Reservation__c.object-meta.xml
 *   objects/Reservation__c/fields/TotalAmount__c.field-meta.xml
 *   permissionsets/Sales_Team_Access.permissionset-meta.xml
 *   profiles/Standard User.profile-meta.xml
 *   classes/MyClass.cls
 *   classes/MyClass.cls-meta.xml
 *
 * USES: Zippex library (Zippex.cls + HexUtil.cls + Puff.cls)
 * These must be deployed in the org before this class.
 */
public class ZipBuilder {

    // ─────────────────────────────────────────────────────────────
    // FILE STORE
    // Key   = file path inside ZIP  e.g. "objects/Reservation__c.object-meta.xml"
    // Value = file XML content
    // ─────────────────────────────────────────────────────────────
    public static Map<String, String> files = new Map<String, String>();
    public static Map<String, String> binaryFiles = new Map<String, String>();

    // Track which metadata types are included — needed for package.xml
    // Key   = metadata type  e.g. "CustomObject"
    // Value = set of member names  e.g. {"Reservation__c"}
    public static Map<String, Set<String>> metadataTypes = new Map<String, Set<String>>();

    // ─────────────────────────────────────────────────────────────
    // ADD FILE
    // Called by MetadataHelper, PermissionSetHelper, ProfileHelper
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