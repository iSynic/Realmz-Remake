import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const repositoryRoot = path.resolve(import.meta.dirname, "..");
const campaignsRoot = path.join(repositoryRoot, "src", "Campaigns");
const storePath = path.join(repositoryRoot, "src", "ClassicAssets", "store.json");

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonical(value[key])])
    );
  }
  return value;
}

function jsonBytes(value) {
  return Buffer.from(JSON.stringify(canonical(value)), "utf8");
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

const store = JSON.parse(await readFile(storePath, "utf8"));
if (
  store.format !== "realmz-remake-classic-shared-assets"
  || store.formatVersion !== 1
  || store.hashAlgorithm !== "sha256"
  || !store.files
) {
  throw new Error(`Unsupported Classic shared asset store: ${storePath}`);
}

const referencesByCampaign = new Map();
for (const [contentHash, record] of Object.entries(store.files)) {
  for (const owner of record.owners ?? []) {
    const references = referencesByCampaign.get(owner.campaignId) ?? [];
    references.push({
      bytes: record.bytes,
      kind: "stock-tileset",
      logicalPath: owner.logicalPath,
      sha256: contentHash
    });
    referencesByCampaign.set(owner.campaignId, references);
  }
}

let refreshed = 0;
for (const [campaignId, references] of referencesByCampaign) {
  const owner = Object.values(store.files)
    .flatMap((record) => record.owners ?? [])
    .find((candidate) => candidate.campaignId === campaignId);
  if (!owner) throw new Error(`Shared asset owner is missing for ${campaignId}`);

  const manifestPath = path.join(
    campaignsRoot,
    owner.campaignDirectory,
    "campaign.json"
  );
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (manifest.id !== campaignId) {
    throw new Error(
      `Campaign identity mismatch at ${manifestPath}: ${manifest.id} != ${campaignId}`
    );
  }

  references.sort((left, right) => left.logicalPath.localeCompare(right.logicalPath));
  manifest.sharedAssets = {
    files: references,
    format: "realmz-remake-classic-shared-assets",
    formatVersion: 1
  };
  delete manifest.integrity.packageHash;
  manifest.integrity.packageHash = sha256(jsonBytes(manifest));
  await writeFile(manifestPath, jsonBytes(manifest));
  refreshed += 1;
}

console.log(`Refreshed shared-asset ownership for ${refreshed} built-in campaigns.`);
