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
- **Treat everything a device announces as untrusted** (SSDP LOCATION, URLBase, controlURL,
  friendlyName). Every curl goes through `CURL` (http/https only, no redirects), every URL
  through `lan_url` (private LAN IPs only), and control requests must keep the description's
  origin (`url_origin`). Otherwise a rogue LAN device can aim our requests at localhost
  services or the internet (reported by a marketplace reviewer on 0.2.2).
  Test with a fake description that points controlURL/URLBase elsewhere: it must be refused.
- **Never auto-trust a newly discovered device.** Discovery may auto-select only a device
  at the exact description URL we already used. Any other device, even when it is the only
  one found, goes through the picker, which shows its IP next to the name. Otherwise a rogue
  LAN device that answers while the TV is off receives the file and becomes the default.
- **Values from the queue, state file or a device never reach bash arithmetic unvalidated.**
  `$(( ))`, `(( ))`, `[[ -gt ]]` and array subscripts evaluate `a[$(cmd)]` and run `cmd`.
  Pass numbers through `uint` (and `q_read`, which normalises the queue) first, and give
  jq indices with `--argjson`, never by splicing them into the filter.
  Test with `"index":"PATH[$(touch /tmp/x)]"` in queue.json and run next/prev/status/list/move.
- **Cap everything read from a device.** All requests go through `fetch` (CURL with
  `--max-filesize`, piped through `head -c $MAX_BODY`, since chunked replies declare no size).
- **Notification text is markup.** `notify` escapes `&`, `<` and `>` in the headline and
  body, so titles and TV names can't inject links. Don't call `omarchy-notification-send` directly.
- **`script -c` runs its command with `$SHELL`.** Always run it with `SHELL=/bin/bash`.
- **Test only against fakes in a sandbox.** Export temporary `XDG_CACHE_HOME`, `XDG_STATE_HOME`
  (and `HOME`) in the same shell before running any `tvcast` command, including `_run`.
  A real cast may be running, and its queue lives in the default dirs (a test run once
  cleared the user's live queue because the exports were missing from that shell).
