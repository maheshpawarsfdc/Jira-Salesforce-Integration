# Jira → AI → Salesforce Pipeline — Architecture

A ticket goes in as English. Working Salesforce metadata comes out. This traces every stage the request actually passes through — including the validation layer that catches the AI's mistakes before they ever reach a deploy.

## End-to-end flow

```mermaid
flowchart TB
    classDef jira fill:#2C5FE0,stroke:#1E44AA,color:#fff,font-weight:600
    classDef forge fill:#557FEF,stroke:#2C5FE0,color:#fff,font-weight:600
    classDef entry fill:#5B606B,stroke:#3A3E47,color:#fff,font-weight:600
    classDef context fill:#8A8F9C,stroke:#5B606B,color:#15171C,font-weight:600
    classDef gen fill:#E8A33D,stroke:#B5721E,color:#15171C,font-weight:700
    classDef verify fill:#4FB3A9,stroke:#1F7A6E,color:#15171C,font-weight:700
    classDef deploy fill:#8B5CF6,stroke:#6D3FC4,color:#fff,font-weight:600
    classDef config fill:#3A3E47,stroke:#15171C,color:#fff,font-weight:500,stroke-dasharray: 3 3

    J["Jira issue<br/>Send to Agentforce"] --> F1
    subgraph FORGE["FORGE APP — jira side"]
        F1["executeTask resolver"] --> F2["sf-dispatch-queue"]
        F2 --> F3["dispatch-consumer-fn<br/>OAuth + callout"]
    end
    F3 -->|"POST /services/apexrest/Agentforce"| E1

    subgraph SF_ENTRY["SALESFORCE ENTRY"]
        E1["JiraInboundController"]
    end
    E1 --> C0

    subgraph CONTEXT["CONTEXT GATHERING"]
        C0["LLMService.processJiraTicket"] --> C1["LLMOrgStateService<br/>org state"]
        C1 --> C2["StoryAnalyzer<br/>ticket intent"]
        C2 --> C3["MetadataContextService<br/>live field/type schema"]
        C3 --> C4["ExistingCodeService<br/>existing Apex detection"]
    end

    C4 --> G1
    subgraph GENERATION["AI GENERATION"]
        G1["Existence gate<br/>Bedrock call"]:::gen
        G1 -->|"not fully satisfied"| G2["Router stage<br/>Bedrock call"]:::gen
        G2 --> G3["PromptBuilder + LLM_Prompt__mdt<br/>final prompt assembly"]:::gen
        G3 --> G4["LLMBedrockClient<br/>Bedrock — generation call"]:::gen
    end

    G4 --> V0
    subgraph VALIDATE["VALIDATION SAFETY-NET"]
        V0["LLMResponseProcessor"] --> V1["ApexCodeValidator<br/>11 syntax checks"]:::verify
        V0 --> V2["LwcCodeValidator<br/>template + JS checks"]:::verify
        V0 --> V3["SchemaFieldValidator<br/>live-schema field/type check"]:::verify
        V0 --> V4["LLMXmlSanitizer<br/>targeted XML fixes"]:::verify
        V1 & V2 & V3 & V4 -->|"ValidationException"| RETRY{{"Auto-repair<br/>retry, ×1-2"}}:::verify
        RETRY -->|"corrected"| G4
    end

    V0 -->|"clean"| D1
    subgraph DEPLOY["DEPLOY PIPELINE"]
        D1["ZipBuilder"] --> D2["ZipDeployQueueable"]
        D2 --> D3["DeployService +<br/>MetadataService.cls"]
        D3 -->|"SOAP"| D4["Salesforce<br/>Metadata API"]:::deploy
        D4 --> D5["Deploypoller<br/>async status poll"]:::deploy
    end

    D5 --> B1["JiraCallbackService"]
    B1 -->|"issue property"| F4["getDeploymentStatus<br/>polling"]
    F4 --> J2["Jira issue<br/>result posted"]

    CFG["App_Config__c<br/>model ID · Jira creds"]:::config -.-> G4
    CFG -.-> B1

    class J,J2 jira
    class F1,F2,F3,F4 forge
    class E1 entry
    class C0,C1,C2,C3,C4 context
```

## Stage by stage

### 01 · Jira & the Forge app

_Not in this repo._

Clicking **Send to Agentforce** never blocks on Salesforce — it drops onto a queue and returns immediately, so the UI stays responsive no matter how long generation takes.

- **`index.js` — `executeTask`** — reads the user's stored Salesforce connection, pushes the ticket onto `sf-dispatch-queue`, returns "accepted" immediately.
- **`consumer.js` — `dispatch-consumer-fn`** — fetches the Jira issue body + attachments, resolves an OAuth token, calls Salesforce's REST endpoint.
- **`sfClient.js`** — token cache, refresh-on-401, the actual `fetch` to `/services/apexrest/Agentforce`.
- **`index.js` — `getDeploymentStatus`** — reads the `agentforce-deploy-status` Jira issue property. Polled by `index.jsx` every 3s, with a bounded timeout.

### 02 · Salesforce entry point

The REST resource Forge calls. Parses and validates the payload, then hands off to the orchestrator.

- **`JiraInboundController.cls`** — `@RestResource(urlMapping='/Agentforce')`. Parses the JSON body, decodes attachments, validates required fields, calls `LLMService.processJiraTicket`.

### 03 · Context gathering

Before anything is generated, the pipeline reads what's actually true about the org — this is the data the validation layer later checks generated output against.

- **`LLMOrgStateService.runOrgCheck`** — existing objects, fields, layouts, labels, queues, assignment rules — a snapshot of relevant org state.
- **`StoryAnalyzer.analyze`** — ticket text → structured intent: `needTrigger`, `needLwc`, `needTestClass`, `needHandler`, detected object/fields.
- **`MetadataContextService.buildContext`** — live `Schema.describe()` read — real field API names and real field _types_, not what a ticket or an earlier ticket assumed.
- **`ExistingCodeService.build`** — detects existing trigger/handler/service/selector classes so generation can extend rather than duplicate.

### 04 · Prompt assembly

Two systems combine into one final prompt — one lives in Apex and needs a deploy to change, the other lives in org data and doesn't.

- **`PromptService` + `LLM_Prompt__mdt`** — custom-metadata prompt fragments (`VALIDATION_RULE`, `APEX`, `LWC`, etc.), some always-included, most router-selected. Editable as org data — no code deploy required.
- **`PromptBuilder.build`** — Apex-hardcoded implementation rules, conditionally assembled from the `StoryAnalysis` flags — only pulls in Apex/LWC/trigger-specific guidance when the ticket actually needs it.

### 05 · AI generation

_Bedrock_

Up to three model calls per ticket: does this already exist, which prompt sections are relevant, then the real generation — plus up to two automatic repair calls if validation rejects the output.

- **`runExistenceGateStage`** — one call: "is everything requested already satisfied?" — lets a duplicate ticket skip deploy entirely.
- **`runRouterStage`** — one call: classifies which prompt sections apply, keeping the final prompt smaller and cheaper.
- **`LLMGroqClient` → `LLMBedrockClient.callBedrock`** — the actual model call — `deepseek.v3.2` via `App_Config__c.Bedrock_Model_Id__c`, `temperature: 0.15` for run-to-run consistency.

### 06 · Validation safety-net

_Catches mistakes before deploy_

Every generated file is mechanically checked against real rules and real org schema — not just trusted. A failure here triggers one automatic repair call with the specific, factual problem stated, before anything reaches a live deploy.

- **`ApexCodeValidator`** — 11 checks: unbalanced braces, `AND`/`OR` outside SOQL, `&&`/`||` inside SOQL, `WITH SECURITY_ENFORCED` misplacement, DML/SOQL-in-loops, untyped collections, TODO/placeholder text, empty handlers, missing null checks.
- **`LwcCodeValidator`** — template bindings restricted to simple property/getter references (no inline operators or function calls), no HTML entities inside `.js` source, blank/placeholder detection.
- **`SchemaFieldValidator`** — cross-checks field/object references against _live_ `Schema.describe()` data — validation-rule `TODAY()`/`NOW()` correctness against the field's real type, SOQL field existence, LWC `@salesforce/schema` imports. Tracks fields newly created in the same generation pass so it doesn't reject its own output.
- **`LLMXmlSanitizer`** — targeted, mechanical fixes: Profile `layoutAssignments` dedup, invalid regex escapes in Apex strings, Layout Name-field behavior, CustomObject defaults, ApexClass/ApexTrigger package.xml type correction by file extension.
- **`LLMLayoutHelper`, `LLMTriggerMerger`** — layout backstops for new fields, trigger-merge enforcement so multiple tickets don't create duplicate triggers on one object.
- **`AICodeReviewService`, `ResponseValidator`** — a second, LLM-adjacent review stage — present in the codebase but currently dead code (the calling block in `LLMService` is commented out and references a method that no longer exists). Not part of the live path today.

### 07 · Packaging & deploy

Validated files get zipped and sent through the Metadata API, with an async poller that respects Salesforce's own governor limits.

- **`ZipBuilder`** — stages files into a deployable package over a pure-Apex ZIP/DEFLATE implementation (`Zippex`/`Puff`/`HexUtil`); deploy scenario forced to `single` — object, fields, and layout deploy together in one round rather than two chained ones.
- **`ZipDeployQueueable` → `DeployService` → `MetadataService.cls`** — WSDL2Apex SOAP bindings to the Metadata API (including a hand-patched `ProfileFlowAccess` field the generator was originally missing).
- **`Deploypoller`** — polls deploy status asynchronously — fast `System.enqueueJob` hops kept under the platform's queueable chain-depth ceiling, falling back to `Deploypollerscheduler` (`System.schedule`) only when needed.
- **`ApexTestRunQueueable` + `ApexTestPollScheduler`** — a second repair loop, after deploy: for Apex-first tickets, runs the generated tests asynchronously, enforces a 75% coverage floor, and on failure re-invokes the LLM with the held-back second package to fix the code — not just a status poller.

### 08 · Feedback loop

The only thing Jira ever sees: a single property write, independent of however long deployment actually took.

- **`JiraCallbackService.storeDeploymentStatus`** — writes success/error/skipped + message to the `agentforce-deploy-status` Jira issue property via the Jira REST API.
- **Forge — `getDeploymentStatus`** — polled by the frontend until a fresh (non-stale) result appears, or the window elapses.

### 09 · Configuration

_Org data, not code_

Everything environment-specific lives in one custom setting — which is exactly where a mismatch hides if it's copied carelessly between orgs.

- **`App_Config__c`** — Hierarchy custom setting: Bedrock model ID, Jira base URL, Jira user email, Jira API token. The token is tied to the specific Atlassian account it was generated for — pairing one user's token with a different user's email fails Jira auth silently.
- **`Bedrock` named credential** — AWS SigV4 to `bedrock-runtime` — the only live model provider. `Groq_API_Key__c`/`Groq_Base_URL__c`/`Groq_Model__c` still exist on `App_Config__c` and a `Groq_API` named credential still exists too — vestiges of a prior provider; `LLMGroqClient` now just delegates straight to Bedrock regardless.
- **Jira auth** — no named credential — `JiraCallbackService` builds Basic Auth manually from the three `App_Config__c` fields above.

---

**Not part of the pipeline:** the LWCs and Apex classes the pipeline _generates_ for test tickets — `Reservation__c`, `contactDirectory`, `accountWorkspace`, and so on — are output, not infrastructure. They live in the Salesforce org but carry none of the guarantees above once deployed; they're just ordinary Salesforce metadata from that point on.
