/**
 * Copyright (c), FinancialForce.com, inc
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 *   are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *      this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *      this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 * - Neither the name of the FinancialForce.com, inc nor the names of its contributors
 *      may be used to endorse or promote products derived from this software without
 *      specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 *  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 *  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 *  THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 *  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 *  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 *  OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**/
@SuppressWarnings('PMD')
public class MetadataPort {
    // MODIFICATIONS START
    public String endpoint_x = new URL('https', DomainCreator.getOrgMyDomainHostname(), '/services/Soap/m/42.0').toExternalForm();
    // MODIFICATIONS END
    public Map<String,String> inputHttpHeaders_x;
    public Map<String,String> outputHttpHeaders_x;
    public String clientCertName_x;
    public String clientCert_x;
    public String clientCertPasswd_x;
    public Integer timeout_x;
    public MetadataService.SessionHeader_element SessionHeader;
    public MetadataService.DebuggingInfo_element DebuggingInfo;
    public MetadataService.DebuggingHeader_element DebuggingHeader;
    public MetadataService.CallOptions_element CallOptions;
    public MetadataService.AllOrNoneHeader_element AllOrNoneHeader;
    private String SessionHeader_hns = 'SessionHeader=http://soap.sforce.com/2006/04/metadata';
    private String DebuggingInfo_hns = 'DebuggingInfo=http://soap.sforce.com/2006/04/metadata';
    private String DebuggingHeader_hns = 'DebuggingHeader=http://soap.sforce.com/2006/04/metadata';
    private String CallOptions_hns = 'CallOptions=http://soap.sforce.com/2006/04/metadata';
    private String AllOrNoneHeader_hns = 'AllOrNoneHeader=http://soap.sforce.com/2006/04/metadata';
    private String[] ns_map_type_info = new String[]{MetadataService.SOAP_M_URI, 'MetadataService'};
    public MetadataService.DeleteResult[] deleteMetadata(String type_x,String[] fullNames) {
        MetadataService.deleteMetadata_element request_x = new MetadataService.deleteMetadata_element();
        request_x.type_x = type_x;
        request_x.fullNames = fullNames;
        MetadataService.deleteMetadataResponse_element response_x;
        Map<String, MetadataService.deleteMetadataResponse_element> response_map_x = new Map<String, MetadataService.deleteMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'deleteMetadata',
          MetadataService.SOAP_M_URI,
          'deleteMetadataResponse',
          'MetadataService.deleteMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.SaveResult renameMetadata(String type_x,String oldFullName,String newFullName) {
        MetadataService.renameMetadata_element request_x = new MetadataService.renameMetadata_element();
        request_x.type_x = type_x;
        request_x.oldFullName = oldFullName;
        request_x.newFullName = newFullName;
        MetadataService.renameMetadataResponse_element response_x;
        Map<String, MetadataService.renameMetadataResponse_element> response_map_x = new Map<String, MetadataService.renameMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'renameMetadata',
          MetadataService.SOAP_M_URI,
          'renameMetadataResponse',
          'MetadataService.renameMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.SaveResult[] updateMetadata(MetadataService.Metadata[] metadata) {
        MetadataService.updateMetadata_element request_x = new MetadataService.updateMetadata_element();
        request_x.metadata = metadata;
        MetadataService.updateMetadataResponse_element response_x;
        Map<String, MetadataService.updateMetadataResponse_element> response_map_x = new Map<String, MetadataService.updateMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'updateMetadata',
          MetadataService.SOAP_M_URI,
          'updateMetadataResponse',
          'MetadataService.updateMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.DescribeMetadataResult describeMetadata(Double asOfVersion) {
        MetadataService.describeMetadata_element request_x = new MetadataService.describeMetadata_element();
        request_x.asOfVersion = asOfVersion;
        MetadataService.describeMetadataResponse_element response_x;
        Map<String, MetadataService.describeMetadataResponse_element> response_map_x = new Map<String, MetadataService.describeMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'describeMetadata',
          MetadataService.SOAP_M_URI,
          'describeMetadataResponse',
          'MetadataService.describeMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.DeployResult checkDeployStatus(String asyncProcessId,Boolean includeDetails) {
        MetadataService.checkDeployStatus_element request_x = new MetadataService.checkDeployStatus_element();
        request_x.asyncProcessId = asyncProcessId;
        request_x.includeDetails = includeDetails;
        MetadataService.checkDeployStatusResponse_element response_x;
        Map<String, MetadataService.checkDeployStatusResponse_element> response_map_x = new Map<String, MetadataService.checkDeployStatusResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'checkDeployStatus',
          MetadataService.SOAP_M_URI,
          'checkDeployStatusResponse',
          'MetadataService.checkDeployStatusResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.RetrieveResult checkRetrieveStatus(String asyncProcessId,Boolean includeZip) {
        MetadataService.checkRetrieveStatus_element request_x = new MetadataService.checkRetrieveStatus_element();
        request_x.asyncProcessId = asyncProcessId;
        request_x.includeZip = includeZip;
        MetadataService.checkRetrieveStatusResponse_element response_x;
        Map<String, MetadataService.checkRetrieveStatusResponse_element> response_map_x = new Map<String, MetadataService.checkRetrieveStatusResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'checkRetrieveStatus',
          MetadataService.SOAP_M_URI,
          'checkRetrieveStatusResponse',
          'MetadataService.checkRetrieveStatusResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.AsyncResult retrieve(MetadataService.RetrieveRequest retrieveRequest) {
        MetadataService.retrieve_element request_x = new MetadataService.retrieve_element();
        request_x.retrieveRequest = retrieveRequest;
        MetadataService.retrieveResponse_element response_x;
        Map<String, MetadataService.retrieveResponse_element> response_map_x = new Map<String, MetadataService.retrieveResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'retrieve',
          MetadataService.SOAP_M_URI,
          'retrieveResponse',
          'MetadataService.retrieveResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.CancelDeployResult cancelDeploy(String String_x) {
        MetadataService.cancelDeploy_element request_x = new MetadataService.cancelDeploy_element();
        request_x.String_x = String_x;
        MetadataService.cancelDeployResponse_element response_x;
        Map<String, MetadataService.cancelDeployResponse_element> response_map_x = new Map<String, MetadataService.cancelDeployResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'cancelDeploy',
          MetadataService.SOAP_M_URI,
          'cancelDeployResponse',
          'MetadataService.cancelDeployResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public String deployRecentValidation(String validationId) {
        MetadataService.deployRecentValidation_element request_x = new MetadataService.deployRecentValidation_element();
        request_x.validationId = validationId;
        MetadataService.deployRecentValidationResponse_element response_x;
        Map<String, MetadataService.deployRecentValidationResponse_element> response_map_x = new Map<String, MetadataService.deployRecentValidationResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'deployRecentValidation',
          MetadataService.SOAP_M_URI,
          'deployRecentValidationResponse',
          'MetadataService.deployRecentValidationResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.DescribeValueTypeResult describeValueType(String type_x) {
        MetadataService.describeValueType_element request_x = new MetadataService.describeValueType_element();
        request_x.type_x = type_x;
        MetadataService.describeValueTypeResponse_element response_x;
        Map<String, MetadataService.describeValueTypeResponse_element> response_map_x = new Map<String, MetadataService.describeValueTypeResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'describeValueType',
          MetadataService.SOAP_M_URI,
          'describeValueTypeResponse',
          'MetadataService.describeValueTypeResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.SaveResult[] createMetadata(MetadataService.Metadata[] metadata) {
        MetadataService.createMetadata_element request_x = new MetadataService.createMetadata_element();
        request_x.metadata = metadata;
        MetadataService.createMetadataResponse_element response_x;
        Map<String, MetadataService.createMetadataResponse_element> response_map_x = new Map<String, MetadataService.createMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'createMetadata',
          MetadataService.SOAP_M_URI,
          'createMetadataResponse',
          'MetadataService.createMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.AsyncResult deploy(String ZipFile,MetadataService.DeployOptions DeployOptions) {
        MetadataService.deploy_element request_x = new MetadataService.deploy_element();
        request_x.ZipFile = ZipFile;
        request_x.DeployOptions = DeployOptions;
        MetadataService.deployResponse_element response_x;
        Map<String, MetadataService.deployResponse_element> response_map_x = new Map<String, MetadataService.deployResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'deploy',
          MetadataService.SOAP_M_URI,
          'deployResponse',
          'MetadataService.deployResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.IReadResult readMetadata(String type_x,String[] fullNames) {
        MetadataService.readMetadata_element request_x = new MetadataService.readMetadata_element();
        request_x.type_x = type_x;
        request_x.fullNames = fullNames;
        MetadataService.IReadResponseElement response_x;
        Map<String, MetadataService.IReadResponseElement> response_map_x = new Map<String, MetadataService.IReadResponseElement>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'readMetadata',
          MetadataService.SOAP_M_URI,
          'readMetadataResponse',
          'MetadataService.read' + type_x + 'Response_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.getResult();
    }
    public MetadataService.UpsertResult[] upsertMetadata(MetadataService.Metadata[] metadata) {
        MetadataService.upsertMetadata_element request_x = new MetadataService.upsertMetadata_element();
        request_x.metadata = metadata;
        MetadataService.upsertMetadataResponse_element response_x;
        Map<String, MetadataService.upsertMetadataResponse_element> response_map_x = new Map<String, MetadataService.upsertMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'upsertMetadata',
          MetadataService.SOAP_M_URI,
          'upsertMetadataResponse',
          'MetadataService.upsertMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
    public MetadataService.FileProperties[] listMetadata(MetadataService.ListMetadataQuery[] queries,Double asOfVersion) {
        MetadataService.listMetadata_element request_x = new MetadataService.listMetadata_element();
        request_x.queries = queries;
        request_x.asOfVersion = asOfVersion;
        MetadataService.listMetadataResponse_element response_x;
        Map<String, MetadataService.listMetadataResponse_element> response_map_x = new Map<String, MetadataService.listMetadataResponse_element>();
        response_map_x.put('response_x', response_x);
        WebServiceCallout.invoke(
          this,
          request_x,
          response_map_x,
          new String[]{endpoint_x,
          '',
          MetadataService.SOAP_M_URI,
          'listMetadata',
          MetadataService.SOAP_M_URI,
          'listMetadataResponse',
          'MetadataService.listMetadataResponse_element'}
        );
        response_x = response_map_x.get('response_x');
        return response_x.result;
    }
}