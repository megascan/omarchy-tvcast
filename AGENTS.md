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

## Backends (DLNA and Chromecast)

- **Every queue device has a `type`** (`dlna` or `chromecast`), and the runner writes it
  into state.json. The type always comes from `url_type` (port 8009 means Chromecast),
  the same rule go2tv uses to route `-t`. Discovery drops entries where go2tv's tag and
  `url_type` disagree (Chromecast groups on other ports), so the two never diverge.
- **Transport calls go through the dispatchers:** `dev_status`, `transport_state`,
  `position_info` and `dev_control pause|play|stop|seek <secs>`. Don't call `soap`
  directly from commands. DLNA behaviour must stay byte-for-byte the same: compare the
  SOAP log of `pause, resume, seek-to, seek ±N, seek h:mm:ss, toggle, stop` against the
  previous release with a fake TV.
- **Chromecast control is `bin/tvcast-chromecast` (python-pychromecast, optional).** Call it
  only through `cast_helper`, which enforces a LAN IP, `timeout`, `ulimit -v` (Cast frames
  declare their own length) and a 4 KiB output cap. The helper must never launch an app on
  the device: it only joins a session that is already running. Missing pychromecast
  (exit 3) is a notification, never a failure: the runner falls back to go2tv's exit as
  the end-of-file signal.
- **The runner caches Chromecast status** in `~/.cache/tvcast/chromecast-status`, so the
  bar's 2 s polls don't each open a Cast connection.
- **Test Chromecast with a fake Cast v2 server on 127.0.0.1:8009** (TLS, protobuf
  `CastMessage` from pychromecast in a throwaway venv) plus the real go2tv, which talks to
  it. Run `_run` with `TERM=xterm-256color` (the unit sets it; go2tv's Chromecast screen
  needs it). go2tv 2.x launches its own receiver app (`C2568A1A`), not Google's default one.

- **`install.sh` never deletes an existing install.** It stages the copy first, moves the old
  plugin dir (edits, `.git`) to `$XDG_STATE_HOME/tvcast/plugin-backups/`, then swaps.
  `uninstall.sh` keeps those backups. (Reported by a marketplace reviewer on 0.3.0.)
- **A fake HOME/XDG does not sandbox systemd.** `systemctl --user` talks to the real user
  manager through `XDG_RUNTIME_DIR`. `uninstall.sh` and `tvcast stop/clear` will stop the
  user's live cast. Put stub `systemctl`/`systemd-run` first on PATH before running them in tests.
- **go2tv must be >= 2.5.0** (`require_go2tv`, `GO2TV_MIN`). go2tv re-fetches the device
  description itself, so our origin checks only hold if go2tv pins endpoints too
  (`validateServiceEndpoints`, added in 2.5.0). Raise `GO2TV_MIN` if a later go2tv fixes
  another device-trust bug. Test stubs for go2tv must answer `-version`.

## Review round 0.3.3 (proactive audit against the marketplace's review patterns)

- **IP literals must be canonical before any check.** curl (and WHATWG parsers) read
  `010.0.0.1` as octal 8.0.0.1, so a check that reads decimal and a client that reads octal
  disagree. `url_origin` accepts only dotted decimal without leading zeros, and ports
  1-65535 without leading zeros (`:08009` would split `url_type` from go2tv's routing).
  Test: `010.0.0.1`, `0172.020.1.1`, `10.0.0.01`, `:08009`, `:70000` must all be refused.
- **"LAN" excludes this machine.** `lan_url` refuses every address on `ip -o addr`
  (including docker/libvirt bridges). A device advertising our own LAN IP would reach
  local services bound to 0.0.0.0. IPv6 is compared after `ipv6_full` expansion.
- **Private data on disk is owner-only.** `bin/tvcast` runs with `umask 077` and
  `chmod 700`s its cache and state dirs on every start (older installs made them 755).
  The queue, state and `session.log` name what the user watches. `install.sh` makes
  `plugin-backups/` 0700 too. Check with `stat` after a run under `umask 022`.
- **Untrusted text must never look like an option.** `omarchy-notification-send` parses a
  headline or body such as `--image=URL` as an option. `notify` puts U+2060 before
  any value starting with `-`. Test with a file named `--image=http:x.mp4` and
  `tvcast notify-status`.
- **Device names are cleaned at discovery** (`clean_text`: C0/DEL/C1 control characters
  removed, 120 chars), and tabs become spaces before splitting go2tv's output. That
  keeps terminal escape sequences (OSC 52 and the like) out of `tvcast devices`.
- **The runner re-validates the queue's device URL** with `lan_url` before every go2tv
  call. The queue file is re-read per item.
- **Installers never take over a name they don't own.** `install.sh` links
  `~/.local/bin/tvcast` only if it is free or already resolves into this plugin.
  Menu edits (install and uninstall) touch only lines that *start* with one of the
  snippet's exact keys, or the `// tvcast: ` comment. A user's `"trigger.castle"`, a
  mention inside a string, or a one-line file are left alone. The menu is rewritten
  atomically (temp file + rename, following a dotfiles symlink), and the install
  aborts without a closing brace. Keep the key list in `install.sh`/`uninstall.sh` in step
  with `menu/omarchy-menu.snippet.jsonc`.
- **By design, documented in the README:** go2tv's media server is unauthenticated
  HTTP on the TV-facing address while a file plays. The README's first firewall rule
  is scoped to the TV's IP. File paths appear in go2tv's argv (a same-basename symlink
  was rejected: go2tv's artwork lookup reads the file's real directory). go2tv pins
  the renderer IP but not the port, so it may use another port on the same device.
- **Gate at the point of use, not at entry points.** The go2tv version check runs in
  `start_runner` and right before every go2tv launch in the runner loop, because resume paths
  (Play on a saved queue) skip the CLI commands that discover devices. When adding any check
  on an external binary or device, put it where the binary is executed or the request is
  sent, and test the resume path (saved queue + `tvcast play`) as well as a fresh cast.

## Review round 0.4.0 (discovery)

- **Never hand an external tool unvalidated network input, and audit what third-party
  tools fetch on their own.** `go2tv -l` fetched every SSDP LOCATION (any IP, hostname,
  loopback or internet host) before tvcast could filter its output. A reviewer reported
  this on 0.3.4; it is tracked upstream as https://github.com/alexballas/go2tv/issues/188.
  go2tv is now only ever given a device URL that already passed `lan_url`. Before
  adding any tool call, read what that tool contacts by itself (descriptions, icons,
  DTDs, playlists, proxies, rc files). That is why curl runs with `-q --noproxy '*'`,
  xmllint with `--nonet`, and ffprobe with `-protocol_whitelist file`.
- **Discovery is `bin/tvcast-discover` (python3 -I, listen-only) plus filtering in bash.**
  SSDP: M-SEARCH from a UDP source port in 3339-3438 (the README's ufw rule). At most 64
  replies of 2 KiB each. Each reply is printed as `source-ip<TAB>LOCATION`. `discover`
  drops anything failing `lan_url`, `url_type == dlna`, or LOCATION host == reply source,
  BEFORE any fetch. It then fetches at most 32 descriptions, 4 at a time, with `fetch`,
  and keeps only those with an AVTransport service. mDNS: `avahi-browse -rtpk
  _googlecast._tcp` (zeroconf fallback), IPv4 only, no fetch. A group on a port other
  than 8009 is dropped by `url_type`.
- **Test discovery with fakes:** `TVCAST_SSDP_TARGET=127.0.0.1:<port>` points the M-SEARCH
  at a fake responder. Stub `avahi-browse` on PATH (the real one queries the LAN), and
  wrap `curl` on PATH to log every call. Hostile LOCATIONs (8.8.8.8, 127.0.0.1 without
  TVCAST_ALLOW_LOOPBACK, a hostname, octal, our own IP, another LAN host) must produce
  zero curl calls and zero hits on fake servers.
- **Policy for go2tv-internal behaviour:** report it upstream and raise `GO2TV_MIN` once
  go2tv fixes it. Don't reimplement go2tv inside tvcast, unless (as with discovery) a
  small listen-only replacement takes the tool out of the untrusted path entirely.
- **Clean untrusted text before it enters any delimited record** (tab-separated lists, the
  device cache, menu options), not after parsing it back: a tab or newline in a device name
  can forge extra fields or rows. When parsing such a list, re-check every security-relevant
  field against the trusted source (DLNA URLs must be in the vetted SSDP `locations` set).
