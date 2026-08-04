# Classic fidelity-fallback audit

This summary is generated from the readiness-only corpus audit. It records
diagnostic ownership and priority; it does not include proprietary assets
or the multi-megabyte raw readiness report.

- Campaigns ready: 13/13
- Progression blockers: 0
- Fidelity fallbacks: 2098 (1915 active, 183 inactive)
- Catalog complete: true
- Baseline matches: true

## Taxonomy reconciliation

Schema 2 removes the obsolete classicInertMoraleThresholds marker and splits mixed item and monster rows into independently owned leaf diagnostics.

The previous 2470-row baseline minus 1693 resolved false positives, plus 1321 additional leaf rows created by splitting mixed diagnostics, produces the current 2098-row baseline.

## Ownership and priority totals

| Group | Diagnostics |
|---|---:|
| Disposition: Remake runtime gap | 1820 |
| Disposition: inactive content | 180 |
| Disposition: intentional compatibility choice | 4 |
| Disposition: missing Classic resource | 77 |
| Disposition: producer/import gap | 12 |
| Disposition: source-research need | 5 |
| Priority: P1 | 1798 |
| Priority: P2 | 116 |
| Priority: P3 | 184 |

## Fallbacks by code

| Code | Total | Active | Inactive | Priority | Disposition | Owner | Representative |
|---|---:|---:|---:|---|---|---|---|
| `classic-monster-item-materialization-fallback` | 511 | 511 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 60; slot 30; reference 130; fallbackFields ["items[2].nativeFields"] |
| `classic-monster-weapon-requirement-feedback` | 426 | 426 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 24; slot 84; reference 61; fallbackFields ["weaponRequirementsUseNativeMissFeedback"] |
| `classic-monster-random-weapon-fallback` | 242 | 242 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 4; slot 31; reference 85; fallbackFields ["weapon.randomSelector"] |
| `classic-monster-elemental-mitigation-fallback` | 151 | 151 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 180; slot 28; reference 157; fallbackFields ["elementalSpecialAttackMitigation"] |
| `classic-item-restriction-fallback` | 139 | 139 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Castle in the Clouds (Classic); source Data ED2; record 14; reference 898; unsupportedFields ["raceRestrictions", "raceClassOnly", "casteRestrictions", "casteClassOnly"] |
| `inactive-custom-spell-definition` | 129 | 0 | 129 | P3 | inactive content | F:/Realmz - Providence | Mithril Vault (Classic); source Data Spell; record scenario-mithril-vault:spell:0; reference 5101 |
| `classic-item-special-effect-fallback` | 117 | 117 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data ED2; record 23; reference 881; unsupportedFields ["special1", "special2"] |
| `unresolved-classic-sound-resource` | 75 | 75 | 0 | P2 | missing Classic resource | F:/Realmz Classic asset inventory | Assault on Giant Mountain (Classic); source Data DD; record Data DD:0:60; slot 3; reference 23400 |
| `classic-monster-missile-item-fallback` | 60 | 60 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Destroy the Necronomicon (Classic); source Data BD; record 125; slot 37; reference 108; fallbackFields ["missilePercent"] |
| `classic-item-combat-field-fallback` | 54 | 54 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data ED2; record 23; reference 881; unsupportedFields ["heat"] |
| `inactive-macro-target` | 51 | 0 | 51 | P3 | inactive content | F:/Realmz - Providence | Assault on Giant Mountain (Classic); source Data MD; record 73; target 165 |
| `classic-monster-active-weapon-projection-fallback` | 35 | 35 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 261; slot 79; reference 93; fallbackFields ["separateActiveWeaponInventoryEntry"] |
| `classic-monster-item-detection-fallback` | 34 | 34 | 0 | P2 | Remake runtime gap | F:/Realmz Remake | Half Truth (Classic); source Data ED3; record Data ED3:macro:374; slot 4; reference 59; fallbackFields ["itemDetectionMarkers"] |
| `classic-item-category-fallback` | 22 | 22 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Grilochs Revenge (Classic); source Data ED2; record 1; reference 935; unsupportedFields ["itemCategory[47]"] |
| `classic-monster-special-attack-fallback` | 21 | 21 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Assault on Giant Mountain (Classic); source Data BD; record 217; slot 17; reference 113; fallbackFields ["attacks[2].special"] |
| `invalid-scenario-spell-item-fallback` | 12 | 12 | 0 | P1 | producer/import gap | F:/Realmz - Providence | White Dragon (Classic); source Data NI; record 858; reference 3357 |
| `classic-monster-non-equippable-weapon-fallback` | 5 | 5 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Mithril Vault (Classic); source Data ED3; record Data ED3:macro:145; slot 6; reference 63; fallbackFields ["weapon.nonEquippable"] |
| `missing-message` | 4 | 4 | 0 | P2 | source-research need | F:/Realmz source and compatibility research | City of Bywater (Classic); source Data DD; record Data DD:8:63; slot 0; reference -30000 |
| `inactive-scenario-rule-table` | 3 | 0 | 3 | P3 | intentional compatibility choice | F:/Realmz - Providence | City of Bywater (Classic); source Data Race; record -1 |
| `unresolved-classic-picture-resource` | 2 | 2 | 0 | P2 | missing Classic resource | F:/Realmz Classic asset inventory | Mithril Vault (Classic); source Data ED2; record encounter:complex:26; slot 2; reference 758 |
| `classic-monster-attack-sound-fallback` | 1 | 1 | 0 | P2 | Remake runtime gap | F:/Realmz Remake | Prelude to Pestilence (Classic); source Data BD; record 32; slot 108; reference 77; fallbackFields ["attackSounds"] |
| `classic-monster-weapon-materialization-fallback` | 1 | 1 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Mithril Vault (Classic); source Data ED3; record Data ED3:macro:182; slot 1; reference 182; fallbackFields ["weapon.nativeFields"] |
| `classic-monster-zero-melee-action-fallback` | 1 | 1 | 0 | P1 | Remake runtime gap | F:/Realmz Remake | Twin Sands of Time (Classic); source Data BD; record 4; slot 56; reference 174; fallbackFields ["zeroMeleeAttacksUseNativeActionFloor"] |
| `invalid-complex-spell-failure-sentinel` | 1 | 1 | 0 | P3 | intentional compatibility choice | F:/Realmz - Providence | Mithril Vault (Classic); source Data ED2; record 16; slot 0; reference 6100 |
| `missing-macro-target` | 1 | 1 | 0 | P1 | source-research need | F:/Realmz source and compatibility research | White Dragon (Classic); source Data BD; record 143; target 9363 |

## Fallbacks by campaign

| Campaign | Total | Active | Inactive |
|---|---:|---:|---:|
| Assault on Giant Mountain (Classic) | 39 | 37 | 2 |
| Castle in the Clouds (Classic) | 41 | 41 | 0 |
| City of Bywater (Classic) | 14 | 11 | 3 |
| Destroy the Necronomicon (Classic) | 97 | 97 | 0 |
| Grilochs Revenge (Classic) | 81 | 78 | 3 |
| Half Truth (Classic) | 156 | 148 | 8 |
| Mithril Vault (Classic) | 259 | 186 | 73 |
| Prelude to Pestilence (Classic) | 27 | 27 | 0 |
| Trouble in the Sword Lands (Classic) | 213 | 212 | 1 |
| Twin Sands of Time (Classic) | 32 | 31 | 1 |
| War in the Sword Lands (Classic) | 599 | 556 | 43 |
| White Dragon (Classic) | 98 | 98 | 0 |
| Wrath of the Mind Lords (Classic) | 442 | 393 | 49 |
