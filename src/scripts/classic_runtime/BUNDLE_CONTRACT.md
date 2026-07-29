# Realmz Remake scenario contract, version 3

This is the coordinated Providence-to-Remake runtime artifact. It is distinct
from Providence's editable project and from a native Realmz export. Providence
is the producer; Remake is the runtime and preview companion.

## Manifest and package identity

Every package contains `campaign.json` with:

```json
{
  "format": "realmz-remake-scenario",
  "formatVersion": 3,
  "campaignKind": "classic-compiled",
  "compatibilityProfile": "realmz-7.1",
  "id": "scenario-city-of-bywater-classic",
  "name": "City of Bywater (Classic)",
  "start": {
    "levelType": "land",
    "levelIndex": 0,
    "x": 2,
    "y": 1
  },
  "files": {
    "scenario": "classic/scenario.json",
    "maps": "classic/maps.json",
    "scripts": "classic/scripts.json",
    "encounters": "classic/encounters.json",
    "content": "classic/content.json",
    "rules": "classic/rules.json",
    "assets": "classic/assets.json",
    "evidence": "classic/evidence.json",
    "runtime": "runtime.json",
    "remakeScripts": "remake/scripts.json"
  },
  "integrity": {
    "algorithm": "sha256",
    "files": {
      "classic/scenario.json": {
        "bytes": 1234,
        "sha256": "..."
      }
    },
    "packageHash": "..."
  }
}
```

All ten document paths are required, unique, package-relative JSON paths.
Absolute paths, URI schemes, drive prefixes, empty segments, parent traversal,
and symbolic links are invalid.

The manifest lists every payload by byte size and SHA-256. The package hash is
the SHA-256 of the canonical manifest with `integrity.packageHash` omitted.
Canonical JSON sorts object keys and renders integral values as integers so
Rust, JavaScript, and Godot calculate the same identity. A package may not
contain an undeclared file.

Remake accepts only format 3. This is a pre-release cutover; older bundles and
saves are rejected without a converter or a version-specific migration warning.

## Runtime and evidence documents

All runtime documents use `schemaVersion: 2`. `runtime.json` declares the
recommended gameplay profile, trusted built-in extension requirements,
bindings, and computed target support:

```json
{
  "schemaVersion": 2,
  "recommendedGameplayProfile": "core.classic",
  "requiredExtensions": [],
  "bindings": {
    "spells": {},
    "items": {},
    "encounters": {},
    "monsterAi": {},
    "lifecycle": {}
  },
  "targetSupport": {
    "realmzRemake": true,
    "nativeRealmz": true,
    "remakeOnlyReasons": []
  }
}
```

Runtime records retain stable IDs and gameplay fields. Source paths,
`recordIndex`, byte offsets and lengths, confidence, source hashes, decoding
evidence, and diagnostics live only in `classic/evidence.json`. Evidence rows
are keyed by both record kind and stable record ID. The installer verifies the
sidecar's hash and shape, but normal gameplay does not load it. Preview and
debug tooling may resolve a runtime record ID through the sidecar when a
source-linked diagnostic is requested.

Evidence is not an execution dependency. Information needed to execute a
record, such as whether an opcode is an authoritative dispatcher no-op, remains
in the appropriate runtime document under stable trigger/slot identity.

## Instructions and script calls

Imported Classic actions retain their original signed opcode and slot:

```json
{
  "kind": "classic",
  "slot": 0,
  "rawCode": -42,
  "code": 42,
  "id": 17,
  "gosub": true
}
```

An authored Remake operation is explicit and namespaced:

```json
{
  "kind": "semantic",
  "slot": 1,
  "operation": "core.script.call",
  "parameters": {
    "scriptId": "scenario.bywater.offer_help",
    "arguments": {}
  }
}
```

Existing Classic action records are not rewritten merely because a project is
opened in Providence. Adding a script attachment deliberately replaces the
selected slot with `core.script.call`. `ScenarioInterpreter` remains the only
AP/XAP executor; script frames live inside its serializable continuation state.

## Scenario scripts

`remake/scripts.json` contains the capability-catalog hash, persistent variable
declarations, attachment records, and a manifest entry for every named script.
Each script declares a stable ID, name, documentation, tier, API version, typed
signature, requested capabilities, state schema and hash, content hash, and
source map.

The three execution tiers are:

| Tier | Canonical content | Execution boundary |
| --- | --- | --- |
| Safe | Structured, typed AST | Compiled instructions in the central scenario VM |
| Sandboxed | Exact UTF-8 GDScript | Persistent headless Godot child in a Windows LPAC AppContainer and Job Object |
| Trusted | Exact UTF-8 GDScript | In-process after developer mode and exact-package approval |

Safe scripts do not create or execute `.gd` files. They support typed locals and
parameters, bounded homogeneous arrays, assignment, expressions, conditions,
returns, acyclic named-script calls, persistent state, and `await` only on
registered yielding capabilities. Loops, recursion, classes, inheritance,
signals, lambdas, reflection, dynamic calls, file access, and arbitrary Godot
APIs are not part of the safe grammar.

Sandboxed and trusted source is stored under `remake/source/`. Every `.gd` must
be declared in `remake/scripts.json` and in manifest integrity with its exact
SHA-256. `.gdc`, PCK, native libraries, executables, WebAssembly, undeclared
GDScript, and symlinks are always rejected.

The initial capability slice is:

- read and write Classic quest flags and typed persistent variables;
- present text and a choice;
- teleport the party;
- start a battle; and
- use deterministic scenario RNG.

Every capability has a typed request/result schema, minimum tier, yield flag,
and owning port in `remake-scenario-capabilities.v1.json`. Missing or
incompatible capabilities fail readiness. Scripts cannot replace core Classic
opcode registrations.

## Full-tier reducer contract

Sandboxed and trusted scripts implement:

```gdscript
func step(event: Dictionary, state: Dictionary, context) -> Dictionary:
    return {
        "state": state,
        "result": context.continued()
    }
```

State and results must be bounded JSON. Nodes, resources, callables, and live
coroutines never cross a process or save boundary. A yield names one declared
capability plus JSON arguments; Remake validates it before routing the command
through the same six ports used by Classic and safe execution.

Sandbox enforcement is operating-system based. The child has no network
capabilities, cannot create child processes, runs under memory/CPU/process and
wall-time limits, and sees only a private staging directory containing the
declared source plus scratch space. Static token scanning is defense in depth,
not the security boundary. If the isolation helper is unavailable, sandboxed
campaigns fail readiness and never fall back to trusted execution.

Trusted scripts run with the user's account privileges. Installation,
inspection, export, and unlaunched preview never execute them. Execution
requires Developer Scripting plus approval of the exact package hash and
aggregate requested capabilities. Any package or manifest change invalidates
approval. Approvals are user-local and never enter projects or saves.

## Persistence

Campaign saves use schema 4 and pin:

- campaign ID and package hash;
- capability-catalog hash;
- each script's tier, API version, content hash, and state-schema hash;
- Classic mutations and the fully resolved gameplay rules;
- the VM cursor, GOSUB and encounter frames, safe-script frames and locals;
- one pending script or Classic command; and
- explicit sandboxed/trusted reducer state.

Saving is valid at safe and reducer step boundaries, including pending
dialogue, choice, teleport, and battle commands. Restore fails if a package,
provider, script, API, or state schema changed. Trust approval is checked again
at execution and is not restored from the save. Saving is blocked only while a
developer-only unmanaged legacy compatibility script is active.

## Managed preview

Providence desktop exports the current project atomically to a temporary v3
package and launches Remake with an ephemeral profile and deterministic test
party. A nonce-authenticated, versioned loopback WebSocket carries handshake,
load, launch, stop, ping, diagnostics, trace, location, and state-summary
messages.

Preview can start at campaign start, a map, an AP, or a battle. Apply and
Restart always begins from a clean package state. Trace records carry script
node and runtime record IDs; Remake resolves those through source maps and,
when requested, the evidence sidecar. Browser Providence can author, validate,
and export, but it cannot launch a local process.

## Producer and consumer gates

Providence must prove stable safe parsing/printing, script validation,
byte-exact full-tier source, deterministic v3 exports, and native-export
blocking for Remake-only behavior. Remake validates package integrity, script
policy, save restoration, all opcode ownership, all 13 campaign readiness
reports, and representative scenario routes.

The cross-repository verifier exports twice, compares every package byte, and
passes the result through Remake's consumer:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify_remake_classic_export.ps1 `
  -ProvidenceRoot "F:\Realmz - Providence" `
  -RemakeRoot "F:\Realmz Remake"
```
