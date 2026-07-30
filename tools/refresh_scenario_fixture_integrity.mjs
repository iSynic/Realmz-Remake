import { createHash } from "node:crypto";
import { access, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const repositoryRoot = path.resolve(import.meta.dirname, "..");
const catalogPath = path.join(
  repositoryRoot,
  "src",
  "Data",
  "remake-scenario-capabilities.v2.json"
);
const defaultRoots = [
  path.join(repositoryRoot, "src", "scripts", "classic_runtime", "tests", "fixtures"),
  path.join(repositoryRoot, "src", "scripts", "scenario_runtime", "tests", "fixtures")
];

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

async function filesNamed(root, targetName) {
  const result = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const entryPath = path.join(root, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`Fixture roots may not contain symlinks: ${entryPath}`);
    }
    if (entry.isDirectory()) result.push(...await filesNamed(entryPath, targetName));
    else if (entry.isFile() && entry.name === targetName) result.push(entryPath);
  }
  return result;
}

async function refreshBundle(bundleRoot, catalogHash) {
  const scriptsPath = path.join(bundleRoot, "remake", "scripts.json");
  const manifestPath = path.join(bundleRoot, "campaign.json");
  const scripts = JSON.parse(await readFile(scriptsPath, "utf8"));
  const scriptsChanged = scripts.capabilityCatalogHash !== catalogHash;
  if (scriptsChanged) {
    scripts.capabilityCatalogHash = catalogHash;
    await writeFile(scriptsPath, jsonBytes(scripts));
  }

  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const integrityFiles = manifest?.integrity?.files;
  if (!integrityFiles || typeof integrityFiles !== "object") {
    throw new Error(`Fixture has no manifest integrity table: ${manifestPath}`);
  }
  for (const relativePath of Object.keys(integrityFiles)) {
    const absolutePath = path.resolve(bundleRoot, relativePath);
    if (!absolutePath.startsWith(`${path.resolve(bundleRoot)}${path.sep}`)) {
      throw new Error(`Fixture integrity path escapes its bundle: ${relativePath}`);
    }
    const bytes = await readFile(absolutePath);
    const metadata = await stat(absolutePath);
    if (!metadata.isFile()) throw new Error(`Fixture payload is not a file: ${absolutePath}`);
    integrityFiles[relativePath] = {
      bytes: bytes.length,
      sha256: sha256(bytes)
    };
  }
  delete manifest.integrity.packageHash;
  manifest.integrity.packageHash = sha256(jsonBytes(manifest));
  await writeFile(manifestPath, jsonBytes(manifest));
  const provenancePath = `${bundleRoot}.provenance.json`;
  try {
    await access(provenancePath);
    const provenance = JSON.parse(await readFile(provenancePath, "utf8"));
    for (const entry of provenance.files ?? []) {
      const filePath = path.resolve(bundleRoot, entry.path);
      if (!filePath.startsWith(`${path.resolve(bundleRoot)}${path.sep}`)) {
        throw new Error(`Fixture provenance path escapes its bundle: ${entry.path}`);
      }
      const bytes = await readFile(filePath);
      entry.bytes = bytes.length;
      entry.sha256 = sha256(bytes);
    }
    await writeFile(provenancePath, jsonBytes(provenance));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return scriptsChanged;
}

const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const catalogHash = sha256(jsonBytes(catalog));
const roots = process.argv.slice(2).map((value) => path.resolve(value));
const fixtureRoots = roots.length ? roots : defaultRoots;
let refreshed = 0;

for (const root of fixtureRoots) {
  for (const scriptsPath of await filesNamed(root, "scripts.json")) {
    if (path.basename(path.dirname(scriptsPath)) !== "remake") continue;
    const bundleRoot = path.dirname(path.dirname(scriptsPath));
    if (await refreshBundle(bundleRoot, catalogHash)) refreshed += 1;
  }
}

console.log(`Refreshed ${refreshed} scenario fixture bundle(s) for ${catalogHash}.`);
