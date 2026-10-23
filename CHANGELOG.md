# Changelog

## 0.1.42 - WoW Forever beta

- Added a per-character coloring switch, a tint-opacity slider with live color previews, and six named bag-color rows with individual Default buttons.
- Added an inline RGB editor with controller-friendly buttons, Apply and Cancel; Reset color settings restores all color defaults. The editor does not open Blizzard's separate color picker.
- Kept the tested seven-column/optional eleven-column bag layout, native item navigation, and guarded bank-close layout refresh behavior from 0.1.41.
- The author reported clean inline-editor Cancel and Apply/Settings Close tests, saved color and opacity after reload, and correct bag organization on the working character. Intermittent missing organization after reload on another character remains unresolved.
- Removed the temporary layout-startup capture from the release package; diagnostic records are not included.

## 0.1.41 - WoW Forever beta

- Preserved the seven-column and optional eleven-column gamepad layout and Blizzard's native controller navigation; `navfix` remains retired.
- Avoided extra frame-size, item-layout, and anchor refreshes on routine bag updates and other automatic events; guarded the item-layout hook against reentry.
- With the custom layout enabled on client build 1.60.1.70450, the author reported clean ordinary bag navigation and O close, bank open/close, bag-to-bank and bank-to-bag transfers followed by O, and a deposit followed by the bank window's on-screen X.
- Earlier protected-action popups and hangs were intermittent. The exact cause remains unproven, and longer play remains to be observed.

## 0.1.40 — WoW Forever beta

- Aligned the gamepad navigation grid so horizontal movement stays on the intended item row.
- Added an optional eleven-column landscape view using four locked backpack slots as native grid headers, with a seven-column fallback.
- Kept equipped-bag controls visible while the aligned navigation layout is active.
- Displayed “Friday Night Bags” on the combined backpack when the addon gamepad layout is active, restoring the native title when it is off.
- Kept Blizzard's native item pickup, drop, bag options, sorting, controller bindings, and O-close handler.
- Kept the gamepad-only gray-junk seller and per-character keep-list.

The known bags-to-bank transfer followed by controller O crash remains under investigation. See the README for the author's exact observations and on-screen X workaround.
