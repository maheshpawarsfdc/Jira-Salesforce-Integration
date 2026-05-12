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

        // NOTE: For CUSTOM objects, Layout.TableEnumOrId stores the 15-char CustomObject Id,
        // NOT the API name — only standard objects store the API name there.
        // Tooling API also forbids `WHERE FullName ...` on Layout. So for custom objects we
        // first look up the CustomObject's Id, then filter TableEnumOrId by it.
        String tableEnumOrIdFilter;
        if (objectApiName.endsWith('__c')) {
            String developerName = objectApiName.removeEnd('__c');
            String coQuery = 'SELECT Id FROM CustomObject WHERE DeveloperName = \''
                + String.escapeSingleQuotes(developerName) + '\'';
            Map<String, Object> coResp = toolingQuery(coQuery);
            List<Object> coRecs = (List<Object>) coResp.get('records');
            if (coRecs == null || coRecs.isEmpty()) {
                System.debug('PageLayoutHelper.listPageLayouts(): no CustomObject row for ['
                    + objectApiName + '] — returning empty layout list');
                return new List<Map<String, Object>>();
            }
            tableEnumOrIdFilter = (String) ((Map<String, Object>) coRecs[0]).get('Id');
        } else {
            tableEnumOrIdFilter = objectApiName;
        }

        // NOTE: FullName is a synthetic Tooling API field that triggers a
        // "no more than one row for retrieval" restriction when multiple layouts
        // exist. Use Name (the plain layout label) instead and reconstruct
        // fullName as objectApiName + '-' + name, which is always correct.
        String query = 'SELECT Id, Name FROM Layout '
            + 'WHERE TableEnumOrId = \'' + String.escapeSingleQuotes(tableEnumOrIdFilter) + '\'';

        Map<String, Object> response = toolingQuery(query);
        List<Object> records = (List<Object>) response.get('records');
        List<Map<String, Object>> result = new List<Map<String, Object>>();

        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                String layoutName = (String) r.get('Name');
                String fullName   = objectApiName + '-' + layoutName;
                result.add(new Map<String, Object>{
                    'id'         => r.get('Id'),
                    'fullName'   => fullName,
                    'layoutName' => layoutName,
                    'objectName' => objectApiName
                });
            }
        }

        System.debug('PageLayoutHelper.listPageLayouts(): found ' + result.size()
            + ' for object [' + objectApiName + ']');
        return result;
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
            ErrorLogger.log(e);
            throw new PageLayoutException('Failed to retrieve layout '
                + fullName + ': ' + e.getMessage());
        }
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
            item.field = fieldName;
            
            // Determine behavior based on field type
            if (SYSTEM_FIELDS.contains(fieldName)) {
                // System fields must always be Readonly
                item.behavior = Metadata.UiBehavior.Readonly;
            } else if (fieldName == 'Name' || requiredFields.contains(fieldName)) {
                // Required fields
                item.behavior = Metadata.UiBehavior.Required;
            } else {
                // Optional custom fields
                item.behavior = Metadata.UiBehavior.Edit;
            }

            if (Math.mod(totalExisting + i, 2) == 0) {
                leftCol.layoutItems.add(item);
            } else {
                rightCol.layoutItems.add(item);
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
                        String behavior;
                        if (item.behavior == Metadata.UiBehavior.Required) {
                            behavior = 'Required';
                        } else if (item.behavior == Metadata.UiBehavior.Readonly) {
                            behavior = 'Readonly';
                        } else {
                            behavior = 'Edit';
                        }
                        
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
            String behavior;
            if (SYSTEM_FIELDS.contains(f)) {
                behavior = 'Readonly';
            } else if (f == 'Name' || requiredFields.contains(f)) {
                behavior = 'Required';
            } else {
                behavior = 'Edit';
            }
            
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
            ErrorLogger.log(e);
            required.add('Name');
        }
        return required;
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
    // PRIVATE — Parse JSON string array
    // ─────────────────────────────────────────────────────────────
    private static List<String> parseStringArray(String jsonStr) {
        List<String> result = new List<String>();
        if (String.isBlank(jsonStr)) return result;
        try {
            List<Object> parsed = (List<Object>) JSON.deserializeUntyped(jsonStr);
            for (Object o : parsed) result.add(String.valueOf(o).trim());
        } catch (Exception e) {
            ErrorLogger.log(e);
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