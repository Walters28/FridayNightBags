# Friday Night Gamepad Bags by Walters

Version **0.1.42** for the WoW Forever beta (interface 16001, developed on build 70532).

Friday Night Bags gives the gamepad combined backpack a compact grid with bag-origin colors. The gamepad layout displays “Friday Night Bags” as its title. It retains Blizzard's item buttons, pickup and drop actions, bag options, controller bindings, and O-to-close behavior. Keyboard and mouse mode keeps Blizzard's bag layout.

The seven-column navigation layout is enabled by default. On accounts with four locked extra backpack slots, `/fnb landscape on` places those slots beside the `+` control and spreads usable items across eleven columns. The wider layout was tested in game by the author. It falls back to seven columns when the locked slots are unavailable. The equipped-bag row stays visible in the navigation layout.

## Install

Extract the ZIP into `World of Warcraft/_classic_beta_/Interface/AddOns` so the files reside in `AddOns/FridayNightBags`. In game, use `/reload`. The wider layout is a per-character choice: use `/fnb landscape on`, close and reopen the bags to rebuild the navigation grid, then `/reload` to save the choice. `/fnb landscape off` restores seven columns.

## Bag colors

Open **Settings > AddOns > Friday Night Bags** (or use `/fnb colors`). The menu has a coloring on/off checkbox, a tint-opacity slider with controller-friendly `-` and `+` buttons, and a row for each bag. Each row shows a live opacity preview, a bag-name button to select that bag, and a **Default** button. The inline RGB editor uses `-` and `+` buttons for red, green, and blue. Choose **Apply** to keep the selected bag color or **Cancel** to restore its saved color. **Reset color settings** restores all bag colors and opacity. These choices are saved per character.

The RGB editor stays in the Settings page. It does not open Blizzard's separate color-picker window or change controller bindings.

## Commands

- `/fnb on` or `/fnb off`: enable or disable gamepad-only gray-junk selling. It is enabled by default and requests sales only for quality-zero items with a positive vendor price. Locked items, changed slots, and keep-listed item IDs are skipped.
- `/fnb keep <item link or ID>`, `/fnb unkeep <item link or ID>`, `/fnb list`: manage protected item IDs.
- `/fnb sort`: request Blizzard's native bag sort.
- `/fnb landscape on|off|status`: choose the eleven-column view when its locked-slot headers are available.
- `/fnb navlayout on|off`: use the aligned navigation layout or the earlier collapsible bag-strip layout. The latter can bring back the beta's D-pad navigation problems; return to `on` if it does.
- `/fnb layout on|off`: enable the addon gamepad layout or restore Blizzard's native layout. The native title returns when this is off or gamepad mode ends.

Diagnostic and export commands are available for troubleshooting. No character data or diagnostic capture is included in the download.

## Beta status

Earlier beta tests intermittently showed protected-action popups and a game hang after bag and bank transfers. Version 0.1.41 removes extra layout refreshes that were suspected of contributing. With the custom layout enabled, the author completed controlled tests of ordinary bag navigation and O close, bank open/close, a bag-to-bank transfer followed by O, a bank-to-bag transfer followed by O, and a deposit followed by the bank window's on-screen X. All closed without a popup. These tests do not prove the sole cause, and longer play remains to be observed. If the issue returns, capture the exact popup text and action sequence.

On one beta character, the custom bag organization was intermittently absent after a reload, despite saved options remaining present. Another character later showed the intended layout with saved color and opacity. The cause of the intermittent layout symptom remains unresolved.

## License and support

Copyright © 2026 Walters28. **All Rights Reserved.** See [LICENSE](LICENSE) for the permission to download, install, and use unmodified copies; modification and redistribution require prior written permission.

If you'd like to support future addon work, optional tips are welcome at https://ko-fi.com/walterschaos. Tips are unrelated to addon functionality.
