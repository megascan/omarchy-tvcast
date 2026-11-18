# Notes for agents working on omarchy-tvcast

## UI rules (bar widget and panel)

- **Stay inside the padding.** Nothing in the panel may reach past the popup's
  content box. Rows that hold several controls use anchors (left label elides,
  right controls fixed), never a free `Row` that can outgrow its parent.
- **Reuse the shell's components, don't hand-roll them:** `PopupCard`, `PopupMenuRow`
  for actions, `Button` for icon controls, `PanelSlider`, `PanelSeparator`, `WidgetButton`.
  Take colours, fonts, spacing and radius from `Commons.Color.popups.*`, `Style.font.*`,
  `Style.spacing.*` and `Style.cornerRadius`. Read the reference QML under
  `/usr/share/omarchy/shell/` (read-only).
- **Keep one column grid.** The TV glyph, the queue numbers and the menu-row glyphs
  share `glyphColumn`, so every label in the panel starts at the same x.
- **Keep untrusted text plain.** File names and TV names only go through `plain()`
  and `Text.PlainText`. They are always single-line and elided.
- **Test long strings:** a very long title, a very long TV name, a markup-shaped
  title, and no TV at all.
- **Before committing a UI change, screenshot every state:** idle with a known TV,
  idle with no TV, stopped queue, and playing. Read each picture and check for
  clipping, overflow and misalignment. Then get a fresh reviewer's read.
  (The panel renders off-screen with the shell's own components. The live bar
  usually needs `omarchy restart shell` to pick up a reinstalled plugin.)
- **The bar icon is always visible:** idle shows just the cast icon, and while
  casting it shows `▶ Title (n/m)`. Right-click stops only while casting.
- **Keep the preview honest.** `preview.png` must show the real widget and panel at
  2x with neutral sample data and no real device names or addresses.

## Shell rules

- `bin/tvcast` must pass `shellcheck`. The jq filters are single-quoted on purpose (SC2016 is off).
- A user stop must never advance the queue: stop the service before telling the TV to stop.
- **Launch the CLI from QML as an argv list, never as a re-quoted or "sanitised" shell string.**
  Version 0.2.0 stripped every character except `[A-Za-z0-9+:._-]` from each argument.
  That removed the `/` from the CLI's absolute path, so every click silently did nothing.
  To check a change, click each action in the live shell and confirm what it does:
  a picker window opens, a notification appears, or the queue state changes.
