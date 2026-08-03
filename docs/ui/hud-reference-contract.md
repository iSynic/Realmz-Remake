# Realmz HUD reference contract

The HUD should feel like Realmz because its information groups and interaction
flow remain familiar, not because an 800x600 arrangement is enlarged. This
contract records the behavior and geography that the responsive shell must
preserve while its presentation is modernized.

## Original functional geography

The maintained original source defines an 800x600 logical canvas, a 556-pixel
visible game height, a 308-pixel lower-left region, and a lower dialog boundary
at y=555 in `src/realmz_orig/LegacyUILayout.h`. Source paths such as
`buttonchoice.c` also keep movement/look interaction, party state, messages,
and command controls as distinct concerns.

The remake maps those concerns as follows:

| Realmz concern | HUD node | Modern rule |
| --- | --- | --- |
| Look and map | `VBoxScreen/HBoxTop/MapArea` | Expands in both directions and receives surplus screen space. |
| Party and character state | `VBoxScreen/HBoxTop/VBoxCharTime/CharactersRect` | Stays in a bounded 320-pixel rail until the character card itself is redesigned. |
| Time, position, light, and fatigue | `VBoxScreen/HBoxTop/VBoxCharTime/TimeRect` | Remains attached to the party rail and visible in exploration and combat. |
| Narrative and event text | `VBoxScreen/HBoxBot/TextRect` | Persists across modes, wraps across the available width, and remains 200-216 pixels high. |
| Exploration commands | `VBoxScreen/HBoxBot/BotRightPanel` | Forms one connected lower console with the narrative region; actions are grouped as Party, Explore, and System. |
| Effects and torch | `BotRightPanel/GlobalEffectsRect` and `ClassicTorchButton` | Uses an `Effects` column plus a separate framed torch control inside the command console. |
| Encounter and combat context | `CreatureRect`, `CombatBRPanel`, `TurnOrderPanel`, and map overlays | Reuses the shell instead of replacing its geography. |

## Presentation facade

`OWHUDControl` remains the gameplay-facing facade. Gameplay code may continue
to call its existing public methods and handlers while the world, party,
narrative, action, context, and status regions are separated internally.
Modernization must not change scenario response IDs, save data, gameplay state
routing, or the central scenario interpreter.

The scene paths above are temporarily part of the compatibility surface. New
components should be reached through explicit facade methods or signals rather
than adding more deep-node access.

## Current exploration action inventory

The pilot must keep every current action reachable:

| Action | Current handler or component |
| --- | --- |
| Camp | `_on_CampButton_pressed` |
| Rest | `_on_RestButton_button_down`, `_on_RestButton_button_up`, and the rest timer |
| Inventory | `_on_InventoryButton_pressed` |
| Party money | `_on_MoneyButton_pressed` |
| Cast spell | `_on_SpellButton_pressed` |
| Abilities | `_on_abi_list_button_pressed` |
| Encounter actions | `_on_EncounterButton_pressed`; Classic campaigns check the party's current action point and dispatch the matching manual encounter macro through the existing runtime |
| Bestiary | `_on_bestiary_button_pressed` |
| Player map | `_on_minimaps_button_pressed` |
| Temple | `_on_temple_button_pressed` |
| Shop | `_on_shop_button_pressed` in its own service slot |
| Change party order | `_on_CharSwapButton_pressed` |
| Quick save | `_on_q_save_button_pressed` |
| Save or load | `_on_save_button_pressed` |
| Settings | `_on_SettingsButton_pressed` |
| Classic search | `ClassicSearchActionButton`; its effect-slot animation is visible only while the party is actively searching |
| Classic torch | `ClassicTorchButton`; its frame is always stable, an unlit torch appears for party-owned inventory, the flame animates only while lit, and the image is empty without a torch |

The status contract includes party portraits and selection, fatigue, time,
light duration and power, map coordinates, global effects, classic searching,
and torch state. Combat additionally exposes turn order, active creature
context, targeting, and the existing combat action panel.

## Responsive pilot rules

- Supported mouse-and-keyboard viewports begin at 1152x648.
- The HUD renders at 1:1 scale. It is never shrunk as one bitmap-like surface.
- The party rail remains 320 pixels wide. The command console is 490 pixels
  wide so its actions and status can be grouped without enlarging their hit
  targets.
- The narrative and action band is `clamp(round(height * 0.28), 200, 216)`.
- HUD regions meet at zero spacing so the stone frame reads as one Realmz
  console rather than detached dashboard panes.
- Action controls retain their stone-and-gold Realmz frames, expose tooltips,
  accept keyboard focus, and remain at least 48x48 in the supported matrix.
  Their three rows are Party (inventory, money, spells, abilities, order),
  Explore (camp, rest, map, bestiary, encounter, search), and System (temple,
  shop, quick save, save/load, settings).
- Character selection uses the familiar side marker. The portrait and hidden
  selection hit area do not add animated or sweeping hover frames.
- While loot or encounter choices are open, each visible party row becomes a
  selection target. The selected party member is then used by loot recipients
  and encounter item, ability, and spell pickers.
- All additional width and nearly all additional height go to the world/map
  region. Ultrawide layouts do not inflate the rails or controls.

The first runtime matrix covered 1152x648, 1280x720, 1920x1080, 2560x1440,
and 3440x1440. The grouped-console probe kept every direct action, group label,
divider, effect display, and torch control inside the dock at each size. The
world region grew while the command console stayed 490 pixels wide.
Remake-owned captures are kept in the separate UI reference
workspace rather than this repository.

## Next bounded slices

1. Populate equivalent original and remake states for exploration, encounter,
   combat, inventory, spells, loot, and character inspection.
2. Replace the party card's fixed 320-pixel internals with container-driven
   rows, then evaluate a compact 288-pixel minimum rail.
3. Split the `OWHUDControl` internals behind the existing facade and add an
   explicit overlay coordinator.
4. Exercise ordinary, typed, spell, item, and rogue-attempt encounter replies
   through their real presentation paths.
5. Modernize character, inventory, spells, abilities, money, and treasure only
   after the pilot interaction and screenshot review is accepted.
