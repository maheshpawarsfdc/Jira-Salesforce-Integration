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

    // ─────────────────────────────────────────────────────────────
    // BUILD BASE64 ZIP
    // Builds the complete ZIP and returns base64 encoded string
    // ready to pass to MetadataPort.deploy()
    // ─────────────────────────────────────────────────────────────
    public static String buildBase64Zip() {
        System.debug('ZipBuilder.buildBase64Zip(): building ZIP with ' + files.size() + ' files');

        if (files.isEmpty()) {
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
            String content = files.get(filePath);
            System.debug('ZipBuilder: adding file [' + filePath + ']');
            zip.addFile(filePath, Blob.valueOf(content), null);
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
        return !files.isEmpty();
    }

    // ─────────────────────────────────────────────────────────────
    // CLEAR
    // Called after deploy to reset state
    // ─────────────────────────────────────────────────────────────
    public static void clear() {
        files.clear();
        metadataTypes.clear();
        System.debug('ZipBuilder.clear(): state reset');
    }

    // ─────────────────────────────────────────────────────────────
    // EXCEPTION
    // ─────────────────────────────────────────────────────────────
    public class ZipBuilderException extends Exception {}
}