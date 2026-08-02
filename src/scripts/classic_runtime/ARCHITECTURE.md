# Realmz Remake scenario runtime architecture

This document describes the current modular runtime shared by compiled Classic
campaigns and Remake-authored behavior. It is written for contributors working
on the interpreter, Godot integration, Providence contract, saves, preview, or
scenario extensions.

## The central rule

`ScenarioInterpreter` is the only scenario execution authority.

Classic AP/XAP instructions, semantic instructions, Safe behaviors, encounter
hooks, spell and item hooks, monster decisions, lifecycle events, and scenario
rule modifiers all enter the same interpreter and continuation model. There is
no parallel “Remake map-script mode.”

The interpreter never touches `SceneTree`, scenes, UI nodes, `GameGlobal`,
resources, character objects, or item objects. It owns only deterministic,
serializable execution state:

- trigger and action identity;
- instruction cursor;
- GOSUB and behavior call frames;
- typed locals, iterators, and return values;
- immutable event contexts;
- encounter origin and result state;
- pending command and resume data;
- mutation ordering;
- execution limits and trace;
- snapshot and restoration.

Godot-facing state belongs behind ports.

## Runtime flow

```text
Classic trigger, semantic instruction, or gameplay hook
                         |
                         v
                ScenarioInterpreter
                         |
          handler or Safe behavior step
                         |
       continue / branch / call / return / yield
                         |
                         v
             ScenarioCommandRouter
                         |
      Map / Combat / Inventory / Character /
             Presentation / Persistence
                         |
                         v
            validated response to the VM
```

The runtime host is the pump around that loop. It asks the interpreter to
advance, routes a yielded command, and resumes the serialized pending record
with the response. It does not contain a command-name continuation switch.

## Instructions and handlers

Classic instructions preserve the source slot, signed opcode, normalized
opcode, ID, and GOSUB bit. Semantic instructions use namespaced operation IDs.

`ScenarioInstructionRegistry` owns handler registration. Every supported
Classic opcode registers exactly once. Duplicate opcode ownership, duplicate
semantic operation ownership, missing handlers, and attempts to replace
reserved core IDs are startup errors.

Handlers implement cohesive families:

- control flow;
- encounters;
- map and time;
- combat;
- inventory;
- character;
- state and rules;
- presentation;
- behavior calls.

A handler returns a `ScenarioStepResult`: continue, yield, branch, call,
return, replace, halt, or error. Cursor normalization, negative/GOSUB handling,
stack mutation, pending records, and application of the result remain in the
interpreter.

## Behavior runtime

`ScenarioScriptRuntime` executes the behavior document in
`remake/scripts.json` schema 3. A behavior is either:

- an entry behavior attached to a typed gameplay role and hook; or
- a helper with typed parameters and return value.

The supported roles are Action, Encounter, Spell, Item, Monster AI, Lifecycle,
Rule Modifier, and Helper. Each role receives an immutable context and returns
a role-specific typed outcome. A result with the wrong shape is an execution
error, not an implicit continuation.

Behavior bindings identify the target record, behavior contract, typed
arguments, deterministic order, and one typed anchor. Record anchors cover
start/completion, Classic-action anchors cover before/after a reached slot,
Encounter anchors cover response availability/selection and result sequence
positions, and domain anchors cover spell, item, monster, lifecycle, and rule
hooks. Placement is not encoded in the behavior definition itself.

Argument values can come from constants, declared state, current context, or
selected record references. The runtime validates the complete mapping before
opening a behavior frame.

### Safe behavior

Safe behavior is a canonical AST executed in the central interpreter. It
supports typed values, optionals, enums, opaque references, immutable context
records, bounded arrays, locals, helper calls, conditionals, match, bounded
for-each, collection queries, and yield only through catalog operations that
allow it.

It cannot access Godot APIs, nodes, resources, engine singletons, files,
network, processes, native code, reflection, dynamic calls, classes, signals,
lambdas, wall-clock time, recursion, or unbounded loops.

The same limits are enforced by Providence, the exporter, and Remake:

- 4,096 AST nodes;
- 256 entries per array;
- 32 behavior call frames;
- a shared deterministic instruction budget.

Safe frames, locals, iterators, contexts, return values, and pending commands
are part of the interpreter snapshot.

### Sandboxed GDScript

Sandboxed GDScript is the only executable source shipped in a scenario. It
runs as an explicit-state reducer in a separate persistent headless Godot
process. The main game sends a bounded JSON event, prior state, and restricted
context. The runner returns bounded JSON state and a continue, yield, halt, or
error result.

On Windows, AppContainer/LPAC and Job Objects form the enforcement boundary.
The runner has no network capability, cannot create child processes, cannot
load native libraries or PCKs, cannot access the main process, and sees only
its declared source plus a private scratch directory. Memory, CPU, process
count, wall time, state depth, message size, and request rate are limited.

Packaged Windows builds place `scenario-sandbox-host.exe` beside the game
executable. Debug runs from a Remake checkout also discover a host built under
`tools/scenario-sandbox-host/target/debug` or `target/release`, which keeps
managed Providence preview on the same isolation path as ordinary play.

Every yielded operation is checked against the source manifest and capability
catalog before it reaches a port. If isolation is unavailable, readiness
fails. Sandboxed source never falls back to in-process execution.

Scenario packages do not have a trusted/in-process script tier.

## Scenario API catalog

`src/Data/remake-scenario-capabilities.v2.json` is the public script surface.
Providence consumes the byte-identical catalog. Its hash is pinned by packages
and saves.

Every operation declares:

- stable ID and API version;
- friendly name, category, reference text, examples, and editor metadata;
- owning port;
- typed parameters and result;
- compatible roles;
- whether it yields or mutates state;
- minimum security tier and deprecation state.

Role descriptors distinguish their hook vocabulary from `runtimeHooks`, the
hooks that have an authoritative gameplay boundary. Providence export and
Remake readiness both reject a behavior that targets a
reserved-but-unconnected hook. The current catalog connects every declared
action, encounter, spell, item, AI, lifecycle, and rule-modifier hook; future
vocabulary still has to enter through this gate.

Queries produce immutable values, snapshots, or opaque stable references.
Mutations become validated commands. Public operations never return live
Godot objects.

The generated reference is a contract check, not separate prose. CI rejects a
public entry without role compatibility, parameter/result documentation, or a
compiling example.

## Six Godot ports

Only ports and their Godot services may touch the native game.

### MapPort

Owns map lookup, movement, edge transitions, teleportation, exploration,
world time, timed encounters, random rectangles, camping/rest integration,
map mutation, and map-scoped state.

### CombatPort

Owns battle creation, combatants, battlefield snapshots, damage, healing,
effects, spawning, morale, rewards, spell integration, and Monster AI
dispatch. Scenario AI receives an immutable combat snapshot and returns a
decision that native combat validates before use.

### InventoryPort

Owns item definitions and instances, equipment, charges, treasure, shops,
wealth, storage, and item hooks. Field and combat item-use paths consult the
scenario binding before the native item provider. The behavior receives
stable item/user/target snapshots, not the mutable inventory object.

### CharacterPort

Owns party selection, character snapshots, statistics, progression,
conditions, health, spell points, allies, abilities, and character-scoped
state.

### PresentationPort

Owns text, choices, pictures, sound, music, waits, encounter UI, animation,
camera/interface markers, and presentation pacing. Presentation is always
performed by the real Remake UI in play and managed preview.

### PersistencePort

Owns port-state aggregation, save policy, validation, snapshots, and
restoration. A port that cannot serialize an in-flight native action must
report that boundary instead of producing an unsafe save.

Each port declares a stable ID, owned command IDs, request/response schemas,
save policy, and optional state serializer. Duplicate command ownership is a
startup error.

## Dispatch outside AP slots

The host exposes typed entry dispatch so native systems do not need to know
how a behavior executes.

- Encounter entry, response availability/selection, result, and completion hooks run around the
  native encounter flow. A plain Continue does not suppress the native
  encounter.
- Spell validation runs before resolution. Cast and effect hooks may own
  resolution; without an attachment, the built-in or extension spell provider
  remains authoritative.
- Field and combat item-use paths ask InventoryPort for a matching behavior
  before using the native provider.
- Monster turns ask CombatPort for an attached AI behavior before native AI.
  The returned action is validated against the current combat snapshot.
- Campaign start/resume, map enter/leave, party movement, rest
  start/completion, time advancement, battle start/completion, character
  defeat, and party defeat enter the Lifecycle role through one serialized
  event queue.

For APs and XAPs, `ScenarioInterpreter` projects one mixed sequence from
record-start behaviors, the eight preserved Classic slots, ordered
before/after-slot behaviors, and record-complete behaviors. A yielding Classic
action resumes before its after-slot behaviors are eligible. Save restoration
pins the exact mixed cursor and never replays a completed action or behavior.

The interpreter also owns the complete Classic Enhanced encounter sequence:
entry behaviors, pure response availability, native presentation, selected
response behaviors, result routing, the mixed Classic or named Enhanced result
sequence, result completion, terminal transition, and encounter completion.
Presentation returns a stable response reference as well as the Classic numeric
outcome. The selected response/result, local Classic result slot, pending
behavior, transition count, and attachment order are serialized. Redirected
paths displace the original result rather than double-running it.

## Rules and modifiers

Gameplay profiles still select independently versioned Map/Time, Combat,
Inventory, Character, Presentation, and Persistence providers. The resolved
selection is pinned in the save.

Scenario behaviors may observe stable calculation events and return bounded
modifiers. They do not replace the core rules engine.

Resolution order is:

1. active gameplay-profile provider;
2. built-in extension modifiers;
3. scenario modifiers by explicit priority and stable binding ID;
4. domain validation and clamping;
5. post-resolution notification.

The modifier pipeline covers attack chance, damage, healing, spell cost,
movement cost, fatigue, experience, loot, encounter chance, rest recovery,
time advancement, and condition resistance. Modifier hooks are pure and
cannot yield.

## Extensions and engine plug-ins

Built-in scenario extensions are descriptors and GDScript providers shipped
under `res://scripts/scenario_runtime/extensions/`. They can register
namespaced handlers, commands, spells, item providers, encounter resolvers,
AI, lifecycle hooks, and rules providers. Campaigns select and configure them
by stable ID. They cannot replace reserved core IDs.

Raw Godot access for third-party development belongs to separately installed
engine plug-ins. `ScenarioEnginePluginRegistry` validates plug-in ID, API
version, namespaced registrations, and duplicate ownership. A campaign can
declare a required plug-in, but cannot package its executable code. Missing or
incompatible requirements block readiness.

The installed catalog is user-local at
`user://scenario_plugins/installed.json`. Each descriptor names an exact
`contentHash`, safe relative `.gd` `entryPoint`, a manifest of every installed
file, API version, approval state, providers, and public operations. The
content hash covers canonical relative paths, byte sizes, and per-file
SHA-256 values. Approved metadata is pinned by `approvedHash`, the SHA-256 of
the canonical descriptor with `approved` and `approvedHash` removed. Changing
any declared file or approved metadata invalidates activation.

`ScenarioEnginePluginStore` owns non-executing package inspection, atomic
installation/update, exact-package approval, revocation, and removal. Remake's
Settings screen is the user-facing manager. Updating a package replaces its
complete directory and always revokes approval. Plug-in source is loaded only
when an approved plug-in is required by the selected campaign.

Plug-in IDs need a non-core namespace. Provider, operation, and command IDs
must remain below that plug-in ID. Public operations use the
`engine.plugins` bridge port and carry the same typed roles, parameters,
result, yield/mutation flags, reference, and example fields as built-in
catalog operations. The bridge validates JSON-compatible results before they
return to the interpreter.

The word “extension” in runtime JSON therefore means a built-in provider that
ships with Remake. It does not mean a script loaded from a campaign folder.

## Campaign and evidence boundary

Bundle v3 contains:

- `campaign.json`, with complete integrity inventory and package hash;
- Classic runtime documents with gameplay data;
- `classic/evidence.json`, with source/provenance/decoding evidence;
- `runtime.json`, with profiles, requirements, provider bindings, and target
  support;
- semantic `remake/logic.json` schema 6 for Remake Authored campaigns;
- `remake/scripts.json` schema 3, with behaviors, state, typed anchors,
  Encounter overlays, migrations, and sandbox source manifests;
- immutable scenario-owned assets and decoded runtime media.

The evidence file is verified at installation but not loaded in normal play.
Trace and preview tooling can resolve a stable record ID through it when a
source-linked diagnostic is requested.

Undeclared executable content, `.gdc`, PCKs, native libraries, symlinks, and
unmanifested files are rejected. The runtime never scans a campaign folder for
GDScript.

## Saves and content updates

The current pre-release campaign save schema 8 records:

- campaign identity, content version, and package hash;
- API catalog hash;
- behavior versions, hashes, and state-schema versions;
- interpreter and behavior frames;
- pending command and event queue;
- mixed-sequence cursor, active response/result reference, pending behavior,
  result-transition count, and attachment order;
- sandbox reducer state;
- Classic mutations and port state;
- resolved gameplay rules;
- required extension and engine plug-in versions.

Idle state is serialized even when no instruction is suspended so persistent
behavior state is not lost between APs.

An update under the same campaign identity requires an explicit compatible
content-version range and complete migration chain. Each migration is a pure,
parameterless, non-yielding Safe helper. The chain must be exact, acyclic, and
unambiguous. Remake validates the resulting state schemas before restoring
gameplay and never guesses a migration.

## Managed preview

Providence exports an atomic temporary v3 package and launches Remake with an
ephemeral profile and deterministic party. A random nonce authenticates the
versioned loopback WebSocket.

The preview host can launch campaign start, a map position, AP/XAP, encounter
option, spell cast, item use, battle/monster decision, lifecycle event, or
rule-calculation fixture. Apply and Restart always starts clean.

The debugger protocol exposes source-linked diagnostics, active behavior,
stack, locals, persistent state, context snapshots, watches, event/command
timeline, pending yield, trace, breakpoints, and step controls. Safe behavior
can step at block level; sandboxed behavior pauses at reducer boundaries.

Providence never bypasses sandbox feasibility or engine plug-in readiness.

## Important files

| Area | File |
| --- | --- |
| Interpreter | `scenario_runtime/scenario_interpreter.gd` |
| Behavior engine | `scenario_runtime/scenario_script_runtime.gd` |
| Instruction registry | `scenario_runtime/scenario_instruction_registry.gd` |
| Command router | `scenario_runtime/scenario_command_router.gd` |
| Core ports | `scenario_runtime/ports/` |
| Godot services | `scenario_runtime/godot/` |
| Capability catalog | `Data/remake-scenario-capabilities.v2.json` |
| Extension registry | `scenario_runtime/scenario_extension_registry.gd` |
| Engine plug-ins | `scenario_runtime/scenario_engine_plugin_registry.gd`, `scenario_runtime/scenario_engine_plugin_store.gd` |
| Rule modifiers | `scenario_runtime/scenario_rule_modifier_pipeline.gd` |
| Sandbox runner | `scenario_runtime/sandbox/` |
| Preview host | `scenario_runtime/preview/scenario_preview_host.gd` |
| Runtime host | `classic_runtime/classic_runtime_host.gd` |
| Campaign session/save | `classic_runtime/classic_campaign_session.gd` |
| Package contract | `classic_runtime/BUNDLE_CONTRACT.md` |

## Adding a capability

1. Add the typed catalog entry, role compatibility, ownership, docs, example,
   and editor metadata.
2. Implement request validation and execution in exactly one port.
3. Add Providence block/source support and type checking.
4. Define yield and save/restore behavior.
5. Add preview diagnostics and source mapping.
6. Regenerate the public reference.
7. Add cross-repository tests for success, invalid arguments, wrong role,
   undeclared capability, save/restore, and deterministic export.

Do not add a host special case or expose a native object to avoid this path.

The Windows sandbox boundary has a process-level acceptance suite:

```powershell
pwsh -NoProfile -File tools/scenario-sandbox-host/run-security-acceptance.ps1 `
  -GodotExecutable "C:\path\to\Godot_console.exe"
```

It exercises file, network, process, reflection, resource-loading, runaway,
oversized-state, and undeclared-command fixtures through the real
AppContainer/Job Object host. Static scanner unit tests are not a substitute
for this gate.

## Invariants

The architecture is considered intact only while all of these remain true:

- one AP/XAP and behavior interpreter;
- exactly one handler for every supported Classic opcode;
- exactly one port owner for every command;
- no core ID overrides;
- no campaign-folder script scanning;
- no in-process executable scenario source;
- immutable query results and validated mutations;
- serializable Safe and sandbox state;
- save-pinned rules, APIs, behaviors, and plug-ins;
- byte-identical Providence and Remake API catalogs;
- generated public docs from that catalog;
- no loss against the Classic trace and 13-campaign regression baseline.

Run the focused scenario-runtime suite with:

```powershell
Godot_v4.7.1-stable_win64_console.exe --headless --path src `
  res://scripts/scenario_runtime/tests/scenario_runtime_tests.tscn
```

The full Classic suite remains the behavioral regression authority:

```powershell
Godot_v4.7.1-stable_win64_console.exe --headless --resolution 1100x619 `
  --path src res://scripts/classic_runtime/tests/run_classic_runtime_tests.tscn
```
