public class MetadataHelper {

    public static Map<String, Object> runToolingApiQuery(String query) {
        System.debug('MetadataHelper.runToolingApiQuery() called: ' + query);

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
        System.debug('MetadataHelper.runToolingApiQuery() status: ' + res.getStatusCode());

        if (res.getStatusCode() != 200) {
            throw new MetadataHelperException(
                'Tooling API query failed. Status: ' + res.getStatusCode() + ' Body: ' + res.getBody()
            );
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    public class MetadataHelperException extends Exception {}
}