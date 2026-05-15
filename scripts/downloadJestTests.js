#!/usr/bin/env node

/**
 * downloadJestTests.js
 *
 * Downloads LWC Jest test files saved by the LLM pipeline from Salesforce
 * ContentDocument to the correct local __tests__ folder.
 *
 * HOW IT WORKS:
 * 1. Gets access token + instance URL from SF CLI
 * 2. Queries ContentVersion for all records with Title LIKE 'LwcJest_%'
 * 3. For each record, derives the component name (strips 'LwcJest_' prefix)
 * 4. Downloads file content
 * 5. Saves to force-app/main/default/lwc/{componentName}/__tests__/{componentName}.test.js
 * 6. Deletes the ContentDocument from Salesforce so it won't re-download next run
 *
 * USAGE:
 *   node scripts/downloadJestTests.js
 *   node scripts/downloadJestTests.js --dry-run     (preview only, no save/delete)
 *   node scripts/downloadJestTests.js --no-delete   (save but keep in Salesforce)
 *
 * REQUIREMENTS:
 *   - SF CLI installed and authenticated to JIRA-Salesforce-Org
 *   - Node.js 18+ (uses built-in fetch)
 */

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// ─── CONFIG ───────────────────────────────────────────────────────────────────
const ORG_ALIAS = "JIRA-Salesforce-Org";
const LWC_BASE_DIR = path.resolve(__dirname, "../force-app/main/default/lwc");
const API_VERSION = "v61.0";
const TITLE_PREFIX = "LwcJest_";

// ─── ARGS ─────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const DRY_RUN = args.includes("--dry-run");
const NO_DELETE = args.includes("--no-delete") || DRY_RUN;

// ─── HELPERS ──────────────────────────────────────────────────────────────────

/**
 * Gets access token and instance URL from SF CLI for the target org.
 */
function getOrgCredentials() {
  console.log(`\n🔐 Getting credentials for org: ${ORG_ALIAS}`);
  try {
    const raw = execSync(`sf org display --target-org ${ORG_ALIAS} --json`, {
      encoding: "utf8"
    });
    const parsed = JSON.parse(raw);

    if (parsed.status !== 0) {
      throw new Error(parsed.message || "sf org display failed");
    }

    const { accessToken, instanceUrl } = parsed.result;

    if (!accessToken || !instanceUrl) {
      throw new Error(
        "accessToken or instanceUrl missing from sf org display output"
      );
    }

    console.log(`✅ Instance URL: ${instanceUrl}`);
    return { accessToken, instanceUrl };
  } catch (err) {
    console.error("❌ Failed to get org credentials:", err.message);
    console.error(
      "   Make sure you are authenticated: sf org login web --alias JIRA-Salesforce-Org"
    );
    process.exit(1);
  }
}

/**
 * Runs a SOQL query via Salesforce REST API.
 */
async function runQuery(instanceUrl, accessToken, soql) {
  const url = `${instanceUrl}/services/data/${API_VERSION}/query?q=${encodeURIComponent(soql)}`;
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json"
    }
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Query failed (${response.status}): ${body}`);
  }

  return response.json();
}

/**
 * Downloads the binary content of a ContentVersion record.
 */
async function downloadContentVersion(
  instanceUrl,
  accessToken,
  contentVersionId
) {
  const url = `${instanceUrl}/services/data/${API_VERSION}/sobjects/ContentVersion/${contentVersionId}/VersionData`;
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` }
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Download failed (${response.status}): ${body}`);
  }

  return response.text();
}

/**
 * Deletes a ContentDocument (parent) by Id via REST API.
 * Deleting the ContentDocument also deletes all its ContentVersions.
 */
async function deleteContentDocument(
  instanceUrl,
  accessToken,
  contentDocumentId
) {
  const url = `${instanceUrl}/services/data/${API_VERSION}/sobjects/ContentDocument/${contentDocumentId}`;
  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${accessToken}` }
  });

  // 204 = success (no content), anything else = error
  if (response.status !== 204) {
    const body = await response.text();
    throw new Error(`Delete failed (${response.status}): ${body}`);
  }
}

/**
 * Saves a Jest test file to the correct local __tests__ folder.
 * Creates the folder if it does not exist.
 */
function saveJestFile(componentName, fileContent) {
  const testsDir = path.join(LWC_BASE_DIR, componentName, "__tests__");
  const filePath = path.join(testsDir, `${componentName}.test.js`);

  if (!fs.existsSync(testsDir)) {
    fs.mkdirSync(testsDir, { recursive: true });
    console.log(`   📁 Created folder: ${testsDir}`);
  }

  fs.writeFileSync(filePath, fileContent, "utf8");
  console.log(`   💾 Saved: ${filePath}`);
}

// ─── MAIN ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("═══════════════════════════════════════════");
  console.log("   LWC Jest Test Downloader");
  console.log("═══════════════════════════════════════════");

  if (DRY_RUN)
    console.log("⚠️  DRY RUN MODE — no files will be saved or deleted");
  if (NO_DELETE && !DRY_RUN)
    console.log(
      "ℹ️  NO DELETE MODE — files will be saved but kept in Salesforce"
    );

  // Step 1: Get org credentials
  const { accessToken, instanceUrl } = getOrgCredentials();

  // Step 2: Query for pending Jest test files
  console.log(
    `\n🔍 Querying for Jest test files (Title LIKE '${TITLE_PREFIX}%')...`
  );

  const soql =
    `SELECT Id, Title, PathOnClient, ContentDocumentId FROM ContentVersion ` +
    `WHERE Title LIKE '${TITLE_PREFIX}%' AND IsLatest = true ORDER BY CreatedDate ASC`;
  const result = await runQuery(instanceUrl, accessToken, soql);

  if (result.totalSize === 0) {
    console.log("\n✅ No pending Jest test files found. Nothing to download.");
    return;
  }

  console.log(`\n📦 Found ${result.totalSize} Jest test file(s):\n`);

  // Step 3: Process each file
  let successCount = 0;
  let errorCount = 0;

  for (const record of result.records) {
    const {
      Id: contentVersionId,
      Title: title,
      ContentDocumentId: contentDocumentId
    } = record;

    // Derive component name from title: 'LwcJest_openOpportunityList' → 'openOpportunityList'
    const componentName = title.replace(TITLE_PREFIX, "");

    console.log(`\n─── Processing: ${componentName}`);
    console.log(`    ContentVersionId : ${contentVersionId}`);
    console.log(`    ContentDocumentId: ${contentDocumentId}`);

    // Check if LWC component folder exists locally
    const componentDir = path.join(LWC_BASE_DIR, componentName);
    if (!fs.existsSync(componentDir)) {
      console.warn(
        `   ⚠️  Component folder not found locally: ${componentDir}`
      );
      console.warn(
        `      Skipping — deploy the component first before downloading its Jest test.`
      );
      errorCount++;
      continue;
    }

    try {
      // Step 4: Download file content
      console.log(`   ⬇️  Downloading file content...`);
      const fileContent = await downloadContentVersion(
        instanceUrl,
        accessToken,
        contentVersionId
      );

      if (DRY_RUN) {
        console.log(
          `   🔍 DRY RUN — would save to: lwc/${componentName}/__tests__/${componentName}.test.js`
        );
        console.log(`   📄 Preview (first 300 chars):\n`);
        console.log(fileContent.substring(0, 300) + "...\n");
      } else {
        // Step 5: Save to local __tests__ folder
        saveJestFile(componentName, fileContent);
      }

      // Step 6: Delete from Salesforce so it won't re-download
      if (!NO_DELETE) {
        console.log(`   🗑️  Deleting ContentDocument from Salesforce...`);
        await deleteContentDocument(
          instanceUrl,
          accessToken,
          contentDocumentId
        );
        console.log(`   ✅ Deleted ContentDocument: ${contentDocumentId}`);
      }

      successCount++;
    } catch (err) {
      console.error(`   ❌ Error processing ${componentName}: ${err.message}`);
      errorCount++;
    }
  }

  // Summary
  console.log("\n═══════════════════════════════════════════");
  console.log(`   Done. ✅ ${successCount} saved  ❌ ${errorCount} failed`);
  console.log("═══════════════════════════════════════════\n");

  if (successCount > 0 && !DRY_RUN) {
    console.log("💡 Run Jest tests with:");
    console.log("   npm run test:unit\n");
  }
}

main().catch((err) => {
  console.error("\n❌ Unexpected error:", err.message);
  process.exit(1);
});
