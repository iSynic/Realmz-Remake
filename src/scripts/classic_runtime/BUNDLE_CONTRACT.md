# Realmz Remake scenario contract, version 3

This is the coordinated Providence-to-Remake runtime artifact. It is distinct
from a Providence project and from a native Realmz export. Providence produces
the package; Realmz Remake installs, validates, previews, and executes it.

Bundle v3 is still pre-release. The current contract is completed in place:
Remake accepts only the current document shapes, Providence exports only those
shapes, and the 13 built-in campaigns are regenerated with the app.
Experimental document and save schemas are not compatibility targets. The
contract present at the first public release will be published as schema 1
rather than exposing the prototype version history.

`campaignKind` is one of `classic-interpreted`, `classic-enhanced`, or
`remake-authored`. Classic Enhanced packages retain source-preserving Classic
instructions and add typed behavior anchors and encounter overlays. Remake
Authored packages contain semantic triggers and behaviors without active
Classic CODE/ID records.

## Manifest and package identity

Every package contains `campaign.json`:

```json
{
  "format": "realmz-remake-scenario",
  "formatVersion": 3,
  "campaignKind": "classic-interpreted",
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

All document paths are required, unique, package-relative JSON paths. Absolute
paths, URI schemes, drive prefixes, empty segments, parent traversal, and
symbolic links are invalid.

The manifest lists every payload by byte size and SHA-256. The package hash is
the SHA-256 of the canonical manifest with `integrity.packageHash` omitted.
Canonical JSON sorts object keys and renders integral values as integers so
Rust, JavaScript, and Godot calculate the same identity. Undeclared files are
invalid.

## Runtime data and evidence

Source-preserving Classic gameplay documents use `schemaVersion: 4`, as does
`runtime.json`. Semantic `remake/logic.json` uses the current pre-release
schema 6 and `remake/scripts.json` uses schema 3. Remake accepts only those
current shapes. Classic records keep stable IDs and gameplay fields. Source
paths, record indices, byte ranges, confidence, source hashes, decoding
evidence, and diagnostics live in `classic/evidence.json`, keyed by record kind
and stable record ID.

The installer verifies the evidence sidecar's integrity and shape. Ordinary
gameplay does not load it. Preview and debug tooling can resolve trace IDs
through it on demand.

Evidence is not an execution dependency. Fields needed to execute a record,
including authoritative dispatcher no-op classification, remain in runtime
data under stable trigger and slot identities.

`runtime.json` uses schema 4 and declares:

- the recommended gameplay profile;
- required built-in extensions and their API versions;
- required separately installed engine plug-ins and their API versions;
- script or extension provider bindings;
- computed native Realmz and Realmz Remake target support.

Requirements are explicit. An unavailable extension, plug-in, provider, or API
version blocks readiness; it never selects a fallback implementation.

## Semantic activation

Repeat frequency and record availability are independent contracts. Map
Triggers support every activation, once per campaign, and once per map visit.
Modern Encounters support every time and once. Each may reference a Safe
`Available when` behavior whose result is boolean and whose contract is pure,
synchronous, and non-yielding.

An activation attempt is evaluated in this order:

1. enabled and repeat-state gate;
2. record-level `Available when` condition;
3. Map Trigger chance, when applicable;
4. named-variant selection;
5. entry or Trigger Steps.

A false availability result skips execution without consuming a once-only
activation. Event and Scheduled Trigger conditions follow the same pure
condition contract; a skipped scheduled occurrence does not mark that
occurrence as dispatched.

## Instructions and central execution

Imported Classic instructions preserve their signed source opcode and slot:

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
    "behaviorId": "scenario.bywater.offer_help",
    "arguments": {}
  }
}
```

Opening a Classic project does not rewrite its actions. Classic Enhanced
behavior calls are exported beside the preserved actions with typed anchors;
they do not consume or replace one of the eight Classic slots.

`ScenarioInterpreter` is the only AP/XAP and behavior execution authority. It
owns the instruction cursor, GOSUB frames, behavior frames, locals, iterators,
return values, event contexts, pending commands, limits, trace, and serializable
continuation state. Script execution never creates a second map-script engine.

## Behavior document

`remake/scripts.json` uses schema 3 and contains:

- the Scenario API catalog version and hash;
- shared deterministic execution limits;
- typed behavior definitions;
- contextual behavior and provider bindings;
- scoped state definitions;
- explicit state-migration chains;
- a source manifest for every sandboxed script;
- source maps and documentation metadata.

A `BehaviorDefinition` declares a stable ID, display metadata, entry or helper
kind, role and hook, API and behavior versions, state-schema version, typed
parameters and result, generated or declared capabilities, and either a Safe
program or exact sandboxed source.

A `BehaviorBinding` declares a target record reference, role and contract hook,
typed anchor, script ID, typed arguments, deterministic order, and optional
modifier priority. Encounter overlays add named Enhanced Results and explicit
response routing without copying the preserved Classic result actions. The
owning port validates role, hook, target, anchor, order, and arguments before
dispatch.

State may be scoped to Campaign, Map, Encounter, Character, Item Instance, or
Combat. Script locals are transient. Classic quest flags are exposed through a
named adapter rather than duplicated as Remake variables.

## Behavior roles and outcomes

Entry behaviors use immutable typed contexts and typed results:

| Role | Typical hooks | Result |
| --- | --- | --- |
| Action | AP/XAP action | Continue, halt, call, replace, or return |
| Encounter | entry, availability, response, result, completion | Boolean availability, or continue, resolve, repeat, close, or branch |
| Spell | validation, casting, effect, duration, expiration | Validation or effect outcome |
| Item | use, equip, unequip, attack, defense, passive | Use, equip, or effect outcome |
| Monster AI | decision | Validated combat decision |
| Lifecycle | campaign and gameplay events | Commands or completion |
| Rule modifier | typed calculation event | Additive, multiplicative, or clamped modifier |
| Helper | typed parameters | Typed value |

Validation and rule-modifier hooks are pure and cannot yield. Other hooks may
yield only when both the role and the called Scenario API operation allow it.

Scenario rule modifiers cannot replace the rules engine. Resolution order is:

1. selected gameplay-profile provider;
2. built-in extension modifiers;
3. scenario modifiers ordered by explicit priority and stable binding ID;
4. domain validation and clamping;
5. post-resolution notification events.

## Scenario API catalog

Remake owns `remake-scenario-capabilities.v2.json`. Providence consumes the
byte-identical file and verifies its hash. Each entry declares:

- stable ID and API version;
- friendly name, category, summary, detailed reference, and examples;
- owning port;
- typed parameters, result, enums, and domain references;
- compatible roles;
- yield, mutation, and security properties;
- deprecation and editor metadata.

Queries return immutable snapshots and opaque stable references. Mutations are
validated commands routed through Map, Combat, Inventory, Character,
Presentation, or Persistence ports. A behavior receives no live Godot node,
resource, singleton, UI object, mutable character dictionary, or item
dictionary.

Adding a public operation is incomplete until the catalog, port, Providence
editor, validation, save/restore behavior, preview diagnostics, examples,
generated reference, and cross-repository tests agree.

## Safe behavior

Safe behavior is the normal authoring tier. Providence stores a canonical
typed AST and Remake executes it inside the central interpreter. Safe behavior
does not create or execute a `.gd` file.

The language supports:

- bool, signed 64-bit integer, 64-bit float, and string;
- optionals, enums, opaque domain references, and immutable context records;
- homogeneous arrays bounded to 256 entries;
- typed locals, parameters, results, and helpers;
- assignment, arithmetic, comparisons, and boolean expressions;
- `if`, `elif`, `else`, `match`, and bounded `for`;
- bounded collection queries;
- `await` only for catalog operations marked as yielding.

It prohibits `while`, recursion, inheritance, classes, signals, lambdas,
reflection, dynamic calls, arbitrary callables, nodes, resources, engine
singletons, filesystem, network, processes, native code, and wall-clock access.

Providence, export validation, and Remake enforce the same limits: 4,096 AST
nodes, 256 array entries, 32 call frames, and one shared deterministic
instruction budget. Frames, locals, iterators, return values, contexts, and
pending commands are serializable.

## Sandboxed GDScript

Sandboxed full GDScript is the only executable source tier distributed inside
a scenario. Exact UTF-8 source lives below `remake/source/`; each file is
declared in `remake/scripts.json` and manifest integrity with its exact hash,
API version, role, capabilities, and state-schema hash.

Sandboxed scripts implement an explicit reducer:

```gdscript
func step(event: Dictionary, state: Dictionary, context) -> Dictionary:
    return {
        "state": state,
        "result": context.continued()
    }
```

State and results are bounded JSON. Nodes, resources, callables, and live
coroutines never cross the process, command, or save boundary. Every requested
operation is checked against the declared capabilities and routed through the
same ports used by Classic and Safe execution.

On Windows the persistent headless runner is isolated with AppContainer/LPAC
and Job Object limits. It is denied network, child processes, native
libraries, arbitrary filesystem access, PCK loading, and access to the main
Remake process. Messages, state size and depth, process count, memory, CPU
time, wall time, and request rate are bounded. Static source scanning is
defense in depth, not the security boundary.

If the isolation feasibility gate fails, sandbox-required campaigns fail
readiness. They never run in process.

Undeclared `.gd`, `.gdc`, PCK, native libraries, executables, WebAssembly, and
symlinks are invalid package contents.

## Engine plug-ins and built-in extensions

Raw Godot or Remake access belongs to separately installed engine plug-ins,
not scenario packages. Plug-ins:

- are installed and approved independently;
- declare a versioned plug-in API;
- may register namespaced capabilities or providers;
- cannot replace reserved core opcode, command, rule, or provider IDs;
- are named explicitly by packages that require them.

Built-in extensions ship under reserved `res://` game paths and follow the same
namespace and duplicate-ownership rules. A package may select and configure a
built-in extension by stable ID, but it cannot supply or replace its code.

Remake reads the user-local engine plug-in catalog from
`user://scenario_plugins/installed.json`. A catalog entry has this shape:

```json
{
  "id": "example.weather",
  "displayName": "Example Weather",
  "description": "Adds authored weather behavior.",
  "apiVersion": 1,
  "approved": true,
  "approvedHash": "<canonical descriptor SHA-256>",
  "entryPoint": "plugin.gd",
  "files": [
    {
      "path": "plugin.gd",
      "size": 2048,
      "sha256": "<exact file SHA-256>"
    }
  ],
  "contentHash": "<canonical declared-file-manifest SHA-256>",
  "providers": [
    {"id": "example.weather.forecast-provider", "method": "forecast"}
  ],
  "operations": [
    {
      "id": "example.weather.forecast",
      "commandId": "example.weather.forecast-command",
      "providerId": "example.weather.forecast-provider",
      "owningPort": "engine.plugins",
      "label": "Forecast Weather",
      "category": "Weather",
      "minimumTier": "safe",
      "roles": ["action", "helper"],
      "yields": true,
      "mutates": false,
      "parameters": {"value": "int"},
      "result": "int",
      "summary": "Returns the scenario forecast.",
      "reference": "Reads the installed weather provider.",
      "example": "var forecast = await weather_forecast(1)"
    }
  ]
}
```

An installable package is a directory containing `plugin.json` and every file
declared by its manifest. `plugin.json` adds `"packageSchemaVersion": 1` to the
descriptor above and never carries approval state. Remake Settings can inspect,
install, update, approve, revoke, and remove a package. Inspection and
installation parse and copy bytes only; they never load the entry script.

Installed files live below `user://scenario_plugins/<plug-in-id>/`. Paths must
be relative, unique, and explicitly declared. The package `contentHash` covers
the canonical path, size, and SHA-256 record for every declared file. The
entry point must be one of those files. Updates replace the whole installed
directory and revoke approval, so undeclared or stale files cannot survive an
update.

Every public ID must use the plug-in namespace and cannot begin with `core.`.
Approval pins exact hashes for all declared files plus canonical descriptor
metadata; a change to either requires approval again. The approval dialog
warns that engine plug-ins run with the user's account privileges. Only
plug-ins named in `runtime.requiredPlugins` are activated for a campaign.

## Persistence and scenario updates

Campaign saves use the current pre-release schema 8 and pin:

- campaign ID, content version, and package hash;
- Scenario API catalog hash;
- behavior versions, tiers, content hashes, and state-schema versions;
- interpreter and Safe behavior frames;
- pending commands and event queue;
- explicit sandbox reducer state;
- fully resolved gameplay rules;
- required extension and engine plug-in versions.

Saving is valid at Safe or reducer boundaries, including a pending dialogue,
choice, movement, battle, spell, or item command whose owning port provides a
save policy.

A released package may update an existing save only when it keeps the stable
campaign identity, declares a compatible content-version range, and supplies a
complete exact migration chain. Migration functions are pure, parameterless,
non-yielding Safe helpers. Remake validates the migrated state against every
resulting schema before gameplay resumes. Missing, cyclic, ambiguous, yielding,
or incompatible migrations fail with an actionable message.

## Managed preview and debugging

Providence desktop exports the current project atomically to a temporary v3
package and launches Remake with an ephemeral profile and deterministic test
party. A random nonce authenticates a versioned loopback WebSocket.

Preview entry points include campaign start, map position, AP/XAP, encounter
option, spell cast, item use, battle or monster decision, lifecycle event, and
rule-calculation fixture. Apply and Restart always starts from clean package
state.

The protocol carries diagnostics, VM trace, location, state summaries, active
behavior, stack, locals, persistent state, event and command timeline, pending
yield, breakpoints, and step controls. Safe behaviors support block-level
stepping; sandboxed behaviors pause at reducer boundaries. Source maps and the
evidence sidecar connect runtime diagnostics to Providence records and blocks.

Browser Providence can author, validate, and export, but cannot launch a local
process.

## Producer and consumer gates

Providence proves project migration, guided/Safe AST round trips, type and role
validation, deterministic exports, exact sandbox source, generated
documentation, and native-export blocking for Remake-only behavior.

Remake proves package integrity, unique opcode and port ownership, role
dispatch, command validation, sandbox policy, save restoration and migration,
modifier ordering, engine plug-in readiness, all 13 campaigns, and
representative Classic routes.

The cross-repository verifier exports twice, compares every package byte, and
passes the result through Remake's consumer:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify_remake_classic_export.ps1 `
  -ProvidenceRoot "F:\Realmz - Providence" `
  -RemakeRoot "F:\Realmz Remake"
```
