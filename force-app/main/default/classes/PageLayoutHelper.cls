/**
 * PageLayoutHelper.cls
 *
 * Handles Page Layout operations via ZIP deploy.
 *
 * MDAPI facts:
 * - File path:    layouts/{ObjectName}-{LayoutName}.layout
 * - Package type: Layout
 * - Member name:  {ObjectName}-{LayoutName}  (e.g. Car__c-Car Layout)
 *
 * Read strategy:  Metadata.Operations.retrieve() — typed Metadata.Layout objects
 * Deploy strategy: ZIP deploy (consistent with entire system)
 *
 * Field behavior:
 *   - Required fields (IsNillable=false, not system) → "Required"
 *   - All other fields                               → "Edit"
 *
 * Section layout:
 *   - Fields alternate left/right: index 0→left, 1→right, 2→left, etc.
 *   - Style: TwoColumnsTopToBottom
 */
public class PageLayoutHelper {

    private static final String NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    // System fields to always exclude from layout field lists
    private static final Set<String> SYSTEM_FIELDS = new Set<String>{
        'Id', 'IsDeleted', 'CreatedById', 'CreatedDate',
        'LastModifiedById', 'LastModifiedDate', 'SystemModstamp',
        'LastActivityDate', 'LastViewedDate', 'LastReferencedDate',
        'OwnerId', 'CurrencyIsoCode', 'RecordTypeId'
    };

    // ─────────────────────────────────────────────────────────────
    // LIST LAYOUTS
    // ─────────────────────────────────────────────────────────────
    public static List<Map<String, Object>> listPageLayouts(Map<String, Object> args) {
        String objectApiName = getRequired(args, 'objectApiName');
        System.debug('PageLayoutHelper.listPageLayouts(): ' + objectApiName);

        String query = 'SELECT Id, FullName, TableEnumOrId FROM Layout '
            + 'WHERE TableEnumOrId = \'' + objectApiName + '\'';

        Map<String, Object> response = toolingQuery(query);
        List<Object> records = (List<Object>) response.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                String fullName   = (String) r.get('FullName');
                String layoutName = fullName != null && fullName.contains('-')
                    ? fullName.substringAfter('-') : fullName;
                result.add(new Map<String, Object>{
                    'id'         => r.get('Id'),
                    'fullName'   => fullName,
                    'layoutName' => layoutName,
                    'objectName' => objectApiName
                });
            }
        }

        System.debug('PageLayoutHelper.listPageLayouts(): found ' + result.size());
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // CREATE LAYOUT FROM SCRATCH
    // sections: JSON array of {label, fields[]}
    // e.g. [{"label":"Basic Info","fields":["Name","Price__c"]}]
    // If blank → two default sections created
    // Required fields always prepended to first section
    // ─────────────────────────────────────────────────────────────
    public static void createPageLayout(Map<String, Object> args) {
        String objectApiName = getRequired(args, 'objectApiName');
        String layoutName    = getRequired(args, 'layoutName');
        String sectionsJson  = getOptional(args, 'sections', '');

        String fullName = objectApiName + '-' + layoutName;
        System.debug('PageLayoutHelper.createPageLayout(): ' + fullName);

        Set<String> requiredFields = getRequiredFields(objectApiName);

        Metadata.Layout layout = new Metadata.Layout();
        layout.fullName        = fullName;
        layout.layoutSections  = buildLayoutSections(sectionsJson, requiredFields);

        String xml      = serializeLayoutToXml(layout);
        String filePath = 'layouts/' + fullName + '.layout';
        ZipBuilder.addFile('Layout', fullName, filePath, xml);

        System.debug('PageLayoutHelper: layout [' + fullName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // ADD FIELDS TO EXISTING LAYOUT
    // ─────────────────────────────────────────────────────────────
    public static void addFieldsToLayout(Map<String, Object> args) {
        String objectApiName = getRequired(args, 'objectApiName');
        String layoutName    = getRequired(args, 'layoutName');
        String sectionLabel  = getOptional(args, 'sectionLabel', 'Information');
        String fieldsJson    = getRequired(args, 'fields');

        String fullName        = objectApiName + '-' + layoutName;
        List<String> newFields = parseStringArray(fieldsJson);
        Set<String> required   = getRequiredFields(objectApiName);
        String filePath        = 'layouts/' + fullName + '.layout';

        System.debug('PageLayoutHelper.addFieldsToLayout(): ' + fullName);

        String stagedXml = ZipBuilder.files.get(filePath);
        String xml;

        if (String.isNotBlank(stagedXml)) {
            xml = injectFieldsIntoXml(stagedXml, sectionLabel, newFields, required);
        } else {
            Metadata.Layout layout = retrieveLayout(fullName);
            layout = addFieldsToLayoutObject(layout, sectionLabel, newFields, required);
            xml = serializeLayoutToXml(layout);
        }

        ZipBuilder.addFile('Layout', fullName, filePath, xml);
        System.debug('PageLayoutHelper: fields added to [' + fullName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // REMOVE FIELDS FROM EXISTING LAYOUT
    // ─────────────────────────────────────────────────────────────
    public static void removeFieldsFromLayout(Map<String, Object> args) {
        String objectApiName = getRequired(args, 'objectApiName');
        String layoutName    = getRequired(args, 'layoutName');
        String fieldsJson    = getRequired(args, 'fields');

        String fullName      = objectApiName + '-' + layoutName;
        Set<String> toRemove = new Set<String>(parseStringArray(fieldsJson));
        Set<String> required = getRequiredFields(objectApiName);
        String filePath      = 'layouts/' + fullName + '.layout';

        System.debug('PageLayoutHelper.removeFieldsFromLayout(): ' + fullName);

        String stagedXml = ZipBuilder.files.get(filePath);
        String xml;

        if (String.isNotBlank(stagedXml)) {
            xml = removeFieldsFromXml(stagedXml, toRemove);
        } else {
            Metadata.Layout layout = retrieveLayout(fullName);
            layout = removeFieldsFromLayoutObject(layout, toRemove);
            xml = serializeLayoutToXml(layout);
        }

        ZipBuilder.addFile('Layout', fullName, filePath, xml);
        System.debug('PageLayoutHelper: fields removed from [' + fullName + '] staged for deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // DELETE LAYOUT
    // ─────────────────────────────────────────────────────────────
    public static void deletePageLayout(Map<String, Object> args) {
        String objectApiName = getRequired(args, 'objectApiName');
        String layoutName    = getRequired(args, 'layoutName');
        String fullName      = objectApiName + '-' + layoutName;

        System.debug('PageLayoutHelper.deletePageLayout(): ' + fullName);
        addDestructiveXml('Layout', fullName);
        System.debug('PageLayoutHelper: layout [' + fullName + '] queued for destructive deploy');
    }

    // ─────────────────────────────────────────────────────────────
    // ASSIGN LAYOUT TO PROFILES
    // ─────────────────────────────────────────────────────────────
    public static void assignPageLayout(Map<String, Object> args) {
        String objectApiName  = getRequired(args, 'objectApiName');
        String layoutName     = getRequired(args, 'layoutName');
        String profilesParam  = getOptional(args, 'profiles', '');
        String recordType     = getOptional(args, 'recordType', '');

        String fullLayoutName = objectApiName + '-' + layoutName;
        System.debug('PageLayoutHelper.assignPageLayout(): ' + fullLayoutName);

        List<String> profileNames = resolveProfileNames(profilesParam);

        for (String profileName : profileNames) {
            String safeProfile = profileName.trim();
            String filePath    = 'profiles/' + safeProfile + '.profile';
            String staged      = ZipBuilder.files.get(filePath);

            String profileXml = String.isNotBlank(staged)
                ? injectLayoutAssignmentIntoProfile(staged, fullLayoutName, recordType)
                : buildProfileLayoutAssignmentXml(fullLayoutName, recordType);

            ZipBuilder.addFile('Profile', safeProfile, filePath, profileXml);
            System.debug('PageLayoutHelper: layout assigned to profile [' + safeProfile + ']');
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Retrieve layout via Metadata.Operations.retrieve()
    // ─────────────────────────────────────────────────────────────
    private static Metadata.Layout retrieveLayout(String fullName) {
        try {
            List<Metadata.Metadata> layouts = Metadata.Operations.retrieve(
                Metadata.MetadataType.Layout,
                new List<String>{ fullName }
            );

            if (layouts == null || layouts.isEmpty() || layouts[0] == null) {
                throw new PageLayoutException('Layout not found: ' + fullName
                    + '. Call page_layout_list first to confirm the exact name.');
            }

            return (Metadata.Layout) layouts[0];
        } catch (PageLayoutException e) {
            throw e;
        } catch (Exception e) {
            throw new PageLayoutException('Failed to retrieve layout '
                + fullName + ': ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build List<Metadata.LayoutSection> from sectionsJson
    // ─────────────────────────────────────────────────────────────
    private static List<Metadata.LayoutSection> buildLayoutSections(
        String sectionsJson, Set<String> requiredFields) {

        List<Map<String, Object>> defs = parseSectionDefs(sectionsJson, requiredFields);
        List<Metadata.LayoutSection> sections = new List<Metadata.LayoutSection>();

        for (Map<String, Object> def : defs) {
            String sectionLabel    = (String) def.get('label');
            List<Object> rawFields = (List<Object>) def.get('fields');
            List<String> fields    = new List<String>();
            if (rawFields != null) {
                for (Object f : rawFields) fields.add(String.valueOf(f).trim());
            }
            sections.add(buildLayoutSection(sectionLabel, fields, requiredFields));
        }

        return sections;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build a single Metadata.LayoutSection
    // Even index → left column, odd index → right column
    // ─────────────────────────────────────────────────────────────
    private static Metadata.LayoutSection buildLayoutSection(
        String label, List<String> fields, Set<String> requiredFields) {

        Metadata.LayoutSection section = new Metadata.LayoutSection();
        section.label         = label;
        section.style         = Metadata.LayoutSectionStyle.TwoColumnsTopToBottom;
        section.customLabel   = true;
        section.detailHeading = true;
        section.editHeading   = true;

        Metadata.LayoutColumn leftCol  = new Metadata.LayoutColumn();
        Metadata.LayoutColumn rightCol = new Metadata.LayoutColumn();
        leftCol.layoutItems  = new List<Metadata.LayoutItem>();
        rightCol.layoutItems = new List<Metadata.LayoutItem>();

        for (Integer i = 0; i < fields.size(); i++) {
            String fieldName         = fields[i].trim();
            Metadata.LayoutItem item = new Metadata.LayoutItem();
            item.field    = fieldName;
            item.behavior = (fieldName == 'Name' || requiredFields.contains(fieldName))
                ? Metadata.UiBehavior.Required
                : Metadata.UiBehavior.Edit;

            if (Math.mod(i, 2) == 0) {
                leftCol.layoutItems.add(item);
            } else {
                rightCol.layoutItems.add(item);
            }
        }

        section.layoutColumns = new List<Metadata.LayoutColumn>{ leftCol, rightCol };
        return section;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Add fields to typed Metadata.Layout object
    // ─────────────────────────────────────────────────────────────
    private static Metadata.Layout addFieldsToLayoutObject(
        Metadata.Layout layout, String sectionLabel,
        List<String> newFields, Set<String> requiredFields) {

        if (layout.layoutSections == null) {
            layout.layoutSections = new List<Metadata.LayoutSection>();
        }

        Metadata.LayoutSection targetSection = null;
        for (Metadata.LayoutSection sec : layout.layoutSections) {
            if (sec.label == sectionLabel) {
                targetSection = sec;
                break;
            }
        }

        if (targetSection == null) {
            layout.layoutSections.add(
                buildLayoutSection(sectionLabel, newFields, requiredFields));
            return layout;
        }

        if (targetSection.layoutColumns == null || targetSection.layoutColumns.isEmpty()) {
            Metadata.LayoutColumn lc = new Metadata.LayoutColumn();
            Metadata.LayoutColumn rc = new Metadata.LayoutColumn();
            lc.layoutItems = new List<Metadata.LayoutItem>();
            rc.layoutItems = new List<Metadata.LayoutItem>();
            targetSection.layoutColumns = new List<Metadata.LayoutColumn>{ lc, rc };
        }

        Metadata.LayoutColumn leftCol  = targetSection.layoutColumns[0];
        Metadata.LayoutColumn rightCol = targetSection.layoutColumns.size() > 1
            ? targetSection.layoutColumns[1] : targetSection.layoutColumns[0];

        if (leftCol.layoutItems  == null) leftCol.layoutItems  = new List<Metadata.LayoutItem>();
        if (rightCol.layoutItems == null) rightCol.layoutItems = new List<Metadata.LayoutItem>();

        Integer totalExisting = leftCol.layoutItems.size() + rightCol.layoutItems.size();

        for (Integer i = 0; i < newFields.size(); i++) {
            String fieldName         = newFields[i].trim();
            Metadata.LayoutItem item = new Metadata.LayoutItem();
            item.field    = fieldName;
            item.behavior = (fieldName == 'Name' || requiredFields.contains(fieldName))
                ? Metadata.UiBehavior.Required
                : Metadata.UiBehavior.Edit;

            if (Math.mod(totalExisting + i, 2) == 0) {
                leftCol.layoutItems.add(item);
            } else {
                rightCol.layoutItems.add(item);
            }
        }

        return layout;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Remove fields from typed Metadata.Layout object
    // ─────────────────────────────────────────────────────────────
    private static Metadata.Layout removeFieldsFromLayoutObject(
        Metadata.Layout layout, Set<String> fieldsToRemove) {

        if (layout.layoutSections == null) return layout;

        for (Metadata.LayoutSection section : layout.layoutSections) {
            if (section.layoutColumns == null) continue;
            for (Metadata.LayoutColumn col : section.layoutColumns) {
                if (col.layoutItems == null) continue;
                List<Metadata.LayoutItem> kept = new List<Metadata.LayoutItem>();
                for (Metadata.LayoutItem item : col.layoutItems) {
                    if (!fieldsToRemove.contains(item.field)) kept.add(item);
                }
                col.layoutItems = kept;
            }
        }

        return layout;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Serialize Metadata.Layout to XML string for ZIP deploy
    // ─────────────────────────────────────────────────────────────
    private static String serializeLayoutToXml(Metadata.Layout layout) {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<Layout xmlns="' + NAMESPACE + '">'
            + '<fullName>' + escapeXml(layout.fullName) + '</fullName>';

        if (layout.layoutSections != null) {
            for (Metadata.LayoutSection section : layout.layoutSections) {
                xml += serializeSectionToXml(section);
            }
        }

        xml += '</Layout>';
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Serialize a single LayoutSection to XML
    // ─────────────────────────────────────────────────────────────
    private static String serializeSectionToXml(Metadata.LayoutSection section) {
        String style = section.style != null
            ? String.valueOf(section.style) : 'TwoColumnsTopToBottom';

        String xml = '<layoutSections>'
            + '<customLabel>'   + (section.customLabel   == true ? 'true' : 'false') + '</customLabel>'
            + '<detailHeading>' + (section.detailHeading == true ? 'true' : 'false') + '</detailHeading>'
            + '<editHeading>'   + (section.editHeading   == true ? 'true' : 'false') + '</editHeading>'
            + '<label>' + escapeXml(section.label) + '</label>';

        if (section.layoutColumns != null) {
            for (Metadata.LayoutColumn col : section.layoutColumns) {
                xml += '<layoutColumns>';
                if (col.layoutItems != null) {
                    for (Metadata.LayoutItem item : col.layoutItems) {
                        String behavior = item.behavior == Metadata.UiBehavior.Required
                            ? 'Required' : 'Edit';
                        xml += '<layoutItems>'
                            + '<behavior>' + behavior + '</behavior>'
                            + '<field>'    + escapeXml(item.field) + '</field>'
                            + '</layoutItems>';
                    }
                }
                xml += '</layoutColumns>';
            }
        }

        xml += '<style>' + style + '</style>'
            + '</layoutSections>';

        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Inject fields into staged XML string
    // ─────────────────────────────────────────────────────────────
    private static String injectFieldsIntoXml(String xml, String sectionLabel,
        List<String> newFields, Set<String> requiredFields) {

        String labelTag = '<label>' + escapeXml(sectionLabel) + '</label>';

        if (!xml.contains(labelTag)) {
            Metadata.LayoutSection newSection =
                buildLayoutSection(sectionLabel, newFields, requiredFields);
            return xml.replace('</Layout>',
                serializeSectionToXml(newSection) + '</Layout>');
        }

        String newItems = '';
        for (String f : newFields) {
            String behavior = (f == 'Name' || requiredFields.contains(f)) ? 'Required' : 'Edit';
            newItems += '<layoutItems>'
                + '<behavior>' + behavior + '</behavior>'
                + '<field>'    + escapeXml(f) + '</field>'
                + '</layoutItems>';
        }

        Integer labelPos       = xml.indexOf(labelTag);
        Integer firstColClose  = xml.indexOf('</layoutColumns>', labelPos);
        Integer secondColClose = xml.indexOf('</layoutColumns>', firstColClose + 1);
        if (secondColClose == -1) secondColClose = firstColClose;

        return xml.substring(0, secondColClose) + newItems + xml.substring(secondColClose);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Remove fields from staged XML string
    // ─────────────────────────────────────────────────────────────
    private static String removeFieldsFromXml(String xml, Set<String> fieldsToRemove) {
        for (String fieldName : fieldsToRemove) {
            String fieldTag = '<field>' + escapeXml(fieldName) + '</field>';
            while (xml.contains(fieldTag)) {
                Integer itemStart = xml.lastIndexOf('<layoutItems>', xml.indexOf(fieldTag));
                Integer itemEnd   = xml.indexOf('</layoutItems>', itemStart)
                    + '</layoutItems>'.length();
                if (itemStart == -1 || itemEnd <= '<layoutItems>'.length()) break;
                xml = xml.substring(0, itemStart) + xml.substring(itemEnd);
            }
        }
        return xml;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Parse sections JSON into List<Map>
    // ─────────────────────────────────────────────────────────────
    private static List<Map<String, Object>> parseSectionDefs(
        String sectionsJson, Set<String> requiredFields) {

        List<Map<String, Object>> sections = new List<Map<String, Object>>();

        if (String.isBlank(sectionsJson) || sectionsJson == '[]') {
            List<Object> reqList = new List<Object>();
            for (String r : requiredFields) reqList.add(r);
            sections.add(new Map<String, Object>{
                'label'  => 'Information',
                'fields' => reqList
            });
            sections.add(new Map<String, Object>{
                'label'  => 'Additional Information',
                'fields' => new List<Object>()
            });
            return sections;
        }

        try {
            List<Object> parsed = (List<Object>) JSON.deserializeUntyped(sectionsJson);
            Boolean isFirst = true;

            for (Object sec : parsed) {
                Map<String, Object> s   = (Map<String, Object>) sec;
                String label            = (String) s.get('label');
                List<Object> rawFields  = (List<Object>) s.get('fields');
                List<Object> fields     = new List<Object>();

                if (isFirst) {
                    for (String req : requiredFields) {
                        if (!fields.contains((Object) req)) fields.add(req);
                    }
                    isFirst = false;
                }

                if (rawFields != null) {
                    for (Object f : rawFields) {
                        String fn = String.valueOf(f).trim();
                        if (!fields.contains((Object) fn)) fields.add(fn);
                    }
                }

                sections.add(new Map<String, Object>{ 'label' => label, 'fields' => fields });
            }
        } catch (Exception e) {
            System.debug('PageLayoutHelper.parseSectionDefs() failed: ' + e.getMessage());
            List<Object> reqList = new List<Object>();
            for (String r : requiredFields) reqList.add(r);
            sections.add(new Map<String, Object>{
                'label'  => 'Information',
                'fields' => reqList
            });
        }

        return sections;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Resolve profile names
    // ─────────────────────────────────────────────────────────────
    private static List<String> resolveProfileNames(String profilesParam) {
        if (String.isBlank(profilesParam) || profilesParam == '[]') {
            return new List<String>{ 'System Administrator' };
        }
        String lower = profilesParam.toLowerCase().trim()
            .replaceAll('"', '').replaceAll('\'', '');
        if (lower == 'all') return getAllProfileNames();
        return parseStringArray(profilesParam);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Build Profile XML for layout assignment
    // ─────────────────────────────────────────────────────────────
    private static String buildProfileLayoutAssignmentXml(
        String fullLayoutName, String recordType) {

        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<Profile xmlns="' + NAMESPACE + '">'
            + buildLayoutAssignmentBlock(fullLayoutName, recordType)
            + '</Profile>';
    }

    private static String injectLayoutAssignmentIntoProfile(
        String profileXml, String fullLayoutName, String recordType) {

        return profileXml.replace('</Profile>',
            buildLayoutAssignmentBlock(fullLayoutName, recordType) + '</Profile>');
    }

    private static String buildLayoutAssignmentBlock(
        String fullLayoutName, String recordType) {

        return '<layoutAssignments>'
            + '<layout>' + escapeXml(fullLayoutName) + '</layout>'
            + (String.isNotBlank(recordType)
                ? '<recordType>' + escapeXml(recordType) + '</recordType>' : '')
            + '</layoutAssignments>';
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get required fields via Tooling API
    // ─────────────────────────────────────────────────────────────
    private static Set<String> getRequiredFields(String objectApiName) {
        Set<String> required = new Set<String>();
        try {
            String query = 'SELECT QualifiedApiName FROM FieldDefinition '
                + 'WHERE EntityDefinition.QualifiedApiName = \'' + objectApiName + '\' '
                + 'AND IsNillable = false';

            Map<String, Object> response = toolingQuery(query);
            List<Object> records = (List<Object>) response.get('records');

            if (records != null) {
                for (Object rec : records) {
                    Map<String, Object> r = (Map<String, Object>) rec;
                    String fieldName = (String) r.get('QualifiedApiName');
                    if (!SYSTEM_FIELDS.contains(fieldName)) {
                        required.add(fieldName);
                    }
                }
            }
        } catch (Exception e) {
            System.debug('PageLayoutHelper.getRequiredFields() failed: ' + e.getMessage());
            required.add('Name');
        }
        return required;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Get all profile names
    // ─────────────────────────────────────────────────────────────
    private static List<String> getAllProfileNames() {
        List<String> names = new List<String>();
        try {
            String endpoint = 'https://' + DomainCreator.getOrgMyDomainHostname()
                + '/services/data/v61.0/query?q='
                + EncodingUtil.urlEncode('SELECT Name FROM Profile ORDER BY Name', 'UTF-8');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setTimeout(30000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> resp =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> records = (List<Object>) resp.get('records');
                if (records != null) {
                    for (Object rec : records) {
                        names.add((String) ((Map<String, Object>) rec).get('Name'));
                    }
                }
            }
        } catch (Exception e) {
            System.debug('PageLayoutHelper.getAllProfileNames() failed: ' + e.getMessage());
            names.add('System Administrator');
        }
        return names;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Tooling API query helper
    // ─────────────────────────────────────────────────────────────
    private static Map<String, Object> toolingQuery(String query) {
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
            throw new PageLayoutException('Tooling API query failed. Status: '
                + res.getStatusCode() + ' Body: ' + res.getBody());
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Destructive XML helper
    // ─────────────────────────────────────────────────────────────
    private static void addDestructiveXml(String metaType, String member) {
        String nameTag  = '<' + 'name>' + metaType + '</' + 'name>';
        String existing = ZipBuilder.files.get('destructiveChangesPost.xml');
        String xml;

        if (existing != null && existing.contains(nameTag)) {
            xml = existing.replace(nameTag, '<members>' + member + '</members>' + nameTag);
        } else if (existing != null) {
            xml = existing.replace('</Package>',
                '<types><members>' + member + '</members>' + nameTag + '</types></Package>');
        } else {
            xml = '<?xml version="1.0" encoding="UTF-8"?>'
                + '<Package xmlns="' + NAMESPACE + '">'
                + '<types>'
                + '<members>' + member + '</members>'
                + nameTag
                + '</types>'
                + '<version>61.0</version>'
                + '</Package>';
        }

        ZipBuilder.addFile('__destructive__', member, 'destructiveChangesPost.xml', xml);
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Parse JSON string array
    // ─────────────────────────────────────────────────────────────
    private static List<String> parseStringArray(String jsonStr) {
        List<String> result = new List<String>();
        if (String.isBlank(jsonStr)) return result;
        try {
            List<Object> parsed = (List<Object>) JSON.deserializeUntyped(jsonStr);
            for (Object o : parsed) result.add(String.valueOf(o).trim());
        } catch (Exception e) {
            for (String s : jsonStr.split(',')) {
                result.add(s.trim().replaceAll('"', '').replaceAll('\'', ''));
            }
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // PRIVATE — Helpers
    // ─────────────────────────────────────────────────────────────
    private static String escapeXml(String val) {
        if (String.isBlank(val)) return '';
        return val.replace('&', '&amp;')
                  .replace('<', '&lt;')
                  .replace('>', '&gt;')
                  .replace('"', '&quot;')
                  .replace('\'', '&apos;');
    }

    private static String getRequired(Map<String, Object> args, String key) {
        Object val = args?.get(key);
        if (val == null || String.isBlank(String.valueOf(val))) {
            throw new PageLayoutException('Required parameter missing: ' + key);
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

    public class PageLayoutException extends Exception {}
}