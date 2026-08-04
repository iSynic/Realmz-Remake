# Classic fidelity-fallback audit

This summary is generated from the readiness-only corpus audit. It records
diagnostic ownership and priority; it does not include proprietary assets
or the multi-megabyte raw readiness report.

- Campaigns ready: 13/13
- Progression blockers: 0
- Fidelity fallbacks: 288 (105 active, 183 inactive)
- Catalog complete: true
- Baseline matches: true

## Taxonomy reconciliation

Schema 2 removed the obsolete classicInertMoraleThresholds marker and split mixed rows into independently owned leaf diagnostics. Schema 3 established source-backed item and monster leaf families. This remediation pass resolved 1220 additional active rows by implementing item effects, monster weapons, missile items, special attacks, and exact zero-melee behavior; the remaining catalog contains only currently observed codes.

The previous 2470-row baseline minus 3503 resolved or implemented rows, plus 1321 additional leaf rows created by splitting mixed diagnostics, produces the current 288-row baseline.

## Ownership and priority totals

| Group | Diagnostics |
|---|---:|
| Disposition: inactive content | 180 |
| Disposition: intentional compatibility choice | 4 |
| Disposition: missing Classic resource | 78 |
| Disposition: producer/import gap | 21 |
| Disposition: source-research need | 5 |
| Priority: P1 | 22 |
| Priority: P2 | 82 |
| Priority: P3 | 184 |

## Fallbacks by code

| Code | Total | Active | Inactive | Priority | Disposition | Owner | Representative |
|---|---:|---:|---:|---|---|---|---|
| `inactive-custom-spell-definition` | 129 | 0 | 129 | P3 | inactive content | F:/Realmz - Providence | Mithril Vault (Classic); source Data Spell; record scenario-mithril-vault:spell:0; reference 5101 |
| `unresolved-classic-sound-resource` | 75 | 75 | 0 | P2 | missing Classic resource | F:/Realmz Classic asset inventory | Assault on Giant Mountain (Classic); source Data DD; record Data DD:0:60; slot 3; reference 23400 |
| `inactive-macro-target` | 51 | 0 | 51 | P3 | inactive content | F:/Realmz - Providence | Assault on Giant Mountain (Classic); source Data MD; record 73; target 165 |
| `invalid-scenario-spell-item-fallback` | 12 | 12 | 0 | P1 | producer/import gap | F:/Realmz - Providence | White Dragon (Classic); source Data NI; record 858; reference 3357 |
| `classic-monster-missile-item-fallback` | 7 | 7 | 0 | P1 | producer/import gap | F:/Realmz - Providence and source research | Destroy the Necronomicon (Classic); source Data BD; record 125; slot 37; reference 108; fallbackFields ["missilePercent"] |
| `missing-message` | 4 | 4 | 0 | P2 | source-research need | F:/Realmz source and compatibility research | City of Bywater (Classic); source Data DD; record Data DD:8:63; slot 0; reference -30000 |
| `inactive-scenario-rule-table` | 3 | 0 | 3 | P3 | intentional compatibility choice | F:/Realmz - Providence | City of Bywater (Classic); source Data Race; record -1 |
| `unresolved-classic-picture-resource` | 2 | 2 | 0 | P2 | missing Classic resource | F:/Realmz Classic asset inventory | Mithril Vault (Classic); source Data ED2; record encounter:complex:26; slot 2; reference 758 |
| `classic-monster-attack-sound-fallback` | 1 | 1 | 0 | P2 | missing Classic resource | F:/Realmz Classic asset inventory | Prelude to Pestilence (Classic); source Data BD; record 32; slot 108; reference 77; fallbackFields ["attackSounds"] |
| `classic-monster-item-materialization-fallback` | 1 | 1 | 0 | P1 | producer/import gap | F:/Realmz - Providence | Half Truth (Classic); source Data BD; record 158; slot 134; reference 179; fallbackFields ["items[0].nativeFields"] |
| `classic-monster-weapon-materialization-fallback` | 1 | 1 | 0 | P1 | producer/import gap | F:/Realmz - Providence | Half Truth (Classic); source Data BD; record 158; slot 134; reference 179; fallbackFields ["weapon.nativeFields"] |
| `invalid-complex-spell-failure-sentinel` | 1 | 1 | 0 | P3 | intentional compatibility choice | F:/Realmz - Providence | Mithril Vault (Classic); source Data ED2; record 16; slot 0; reference 6100 |
| `missing-macro-target` | 1 | 1 | 0 | P1 | source-research need | F:/Realmz source and compatibility research | White Dragon (Classic); source Data BD; record 143; target 9363 |

## Fallbacks by campaign

| Campaign | Total | Active | Inactive |
|---|---:|---:|---:|
| Assault on Giant Mountain (Classic) | 6 | 4 | 2 |
| Castle in the Clouds (Classic) | 5 | 5 | 0 |
| City of Bywater (Classic) | 10 | 7 | 3 |
| Destroy the Necronomicon (Classic) | 22 | 22 | 0 |
| Grilochs Revenge (Classic) | 10 | 7 | 3 |
| Half Truth (Classic) | 14 | 6 | 8 |
| Mithril Vault (Classic) | 98 | 25 | 73 |
| Prelude to Pestilence (Classic) | 3 | 3 | 0 |
| Trouble in the Sword Lands (Classic) | 5 | 4 | 1 |
| Twin Sands of Time (Classic) | 1 | 0 | 1 |
| War in the Sword Lands (Classic) | 47 | 4 | 43 |
| White Dragon (Classic) | 15 | 15 | 0 |
| Wrath of the Mind Lords (Classic) | 52 | 3 | 49 |

## User help needed

- `classic-monster-attack-sound-fallback` (Prelude to Pestilence (Classic)): Provide or identify sound resource 623 from a licensed Classic Realmz installation and, if available, a save or reproduction sequence for Prelude to Pestilence Data BD battle 32 monster 77 so its exact attack presentation can be compared.
- `unresolved-classic-picture-resource` (Mithril Vault (Classic)): Provide or identify picture resource 758 from a licensed Classic installation and, if available, a save or reproduction sequence for Mithril Vault complex encounter 26; the second unresolved picture is ID 20126 used by War in the Sword Lands macro 2381.
- `unresolved-classic-sound-resource` (Assault on Giant Mountain (Classic)): Provide or identify sound resource 23400 from a licensed Classic installation and, if available, a save or reproduction sequence for Assault on Giant Mountain Data DD land 0 record 60; that archive can then be checked against the other 74 unresolved sound IDs.
