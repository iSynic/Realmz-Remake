import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const presetPath = path.join(repositoryRoot, "src", "export_presets.cfg");
const presetText = fs.readFileSync(presetPath, "utf8");
const sections = presetText
  .split(/(?=^\[preset\.\d+\]$)/m)
  .filter((section) => /^\[preset\.\d+\]$/m.test(section));

if (sections.length === 0) {
  throw new Error(`No export presets found in ${presetPath}`);
}

const failures = [];
for (const section of sections) {
  const name = section.match(/^name="([^"]+)"$/m)?.[1] ?? "unnamed preset";
  const exportFilter = section.match(/^export_filter="([^"]+)"$/m)?.[1];
  const excluded = section.match(/^exclude_filter="([^"]*)"$/m)?.[1]
    ?.split(",")
    .map((entry) => entry.trim())
    .filter(Boolean) ?? [];

  if (exportFilter === "all_resources" && !excluded.includes("build/**")) {
    failures.push(`${name}: all_resources must exclude build/**`);
  }
}

if (failures.length > 0) {
  throw new Error(`Unsafe Godot export presets:\n- ${failures.join("\n- ")}`);
}

console.log(`Verified ${sections.length} Godot export presets exclude res://build.`);

const python = process.platform === "win32" ? "python" : "python3";
const sharedAssets = spawnSync(
  python,
  [
    path.join(repositoryRoot, "asset_scripts", "share_classic_assets.py"),
    "--root",
    path.join(repositoryRoot, "src"),
    "--expected-campaigns",
    "13",
    "--check",
  ],
  { encoding: "utf8" },
);
if (sharedAssets.error) {
  throw new Error(`Could not validate built-in Classic shared assets: ${sharedAssets.error.message}`);
}
if (sharedAssets.status !== 0) {
  throw new Error(
    `Built-in Classic shared assets are not export-ready.\n${sharedAssets.stdout}${sharedAssets.stderr}`,
  );
}
console.log("Verified built-in Classic shared-asset ownership and integrity.");
