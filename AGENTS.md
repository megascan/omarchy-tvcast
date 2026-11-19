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
- **DLNA seeks go through `dlna_seek` and only ever reach the TV from PLAYING.** LG webOS
  hangs for good on a Seek sent while PAUSED_PLAYBACK (LG_TRANSITIONING, actions = Stop
  only, every later Seek fails with 710, Play with 701; only Stop + Play recovers), and
  refuses seeks while TRANSITIONING (loading). A paused TV is sought with Play, wait for
  PLAYING, Seek, Pause. Seeks are serialised by `seek.lock`. The bar's `canSeek` greys the
  slider, ±30 s and scroll out while the TV is loading or stopped. Fake TVs used for seek
  tests must hang on a paused Seek like the LG does.
- **Volume goes through `dev_volume`, `dev_set_volume` and `dev_set_mute`.** DLNA uses
  RenderingControl (Channel Master). Its controlURL and SCPDURL come from `service_url`
  (the same origin pinning as AVTransport's `control_url`), every request goes through
  `soap_call`, and the result is cached in `~/.cache/tvcast/rendering` per description URL
  ("none" is retried after a minute, so the bar's polls don't refetch the description).
  The cached URL is re-checked on every read. tvcast speaks 0-100 and scales to the SCPD's
  Volume maximum. Test with a fake TV whose RenderingControl controlURL (absolute, octal,
  or via URLBase) points elsewhere, plus a hand-edited cache: no request may leave.
  The bar's volume slider is optimistic (`volumeTarget`/`muteTarget`) and sends one
  `tvcast volume` per 150 ms pause in dragging or scrolling. Epoch seconds are 10 digits:
  never pass them through `uint` (9 digits max), compare them in jq.
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

- **`install.sh` never deletes an existing install.** It stages the copy first, swaps it in
  with `mv --exchange` (no moment without a plugin), then moves the old plugin dir (edits,
  `.git`) to `$XDG_STATE_HOME/tvcast/plugin-backups/<id>.<date>[.n]` (a fresh slot, never
  nested). The old dir is only dropped when it is byte-identical to the new copy or to the
  previous run's copy (`plugin-copy.sum`). The dev-copy section holds `flock` on the plugins
  dir; under it, a stale `.<id>.new.*` dir with the `.tvcast-stage` marker is a killed copy
  (removed), one without is a swapped-out old install (moved to backups). Symlinks there are
  never touched. Paths are physical (`pwd -P`), or a symlinked `~/.config` looks like a dev
  clone and replaces the git checkout. The copy is the `plugin_files` allowlist (no
  untracked files, no `__pycache__`): add new plugin files to it. `uninstall.sh` keeps the
  backups. (Reported by a marketplace reviewer on 0.3.0.)
- **`uninstall.sh` changes nothing if `tvcast _stop-owned` fails** (a cast still running, or
  systemd unreachable): deleting the queue under a live runner is worse than stopping early.
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
- **Only touch systemd units tvcast created.** The runner is `megascan-tvcast.service`
  (`tvcast.service` up to 0.5.4 is still recognised). `owns_unit` requires
  `Transient=yes` and an ExecStart of this plugin's `tvcast _run` before any
  stop/reset/is-active decision; start refuses if a foreign unit holds the name.
  Menu `when` checks and `uninstall.sh` go through `tvcast active` / `tvcast _stop-owned`,
  never raw `systemctl` on a unit name.
- **Installers never take over a name they don't own.** `install.sh` links
  `~/.local/bin/tvcast` only if it is free or already ours (its literal target is this
  plugin's `bin/tvcast`, which still works once the plugin dir is gone, or it resolves
  into this plugin), and exits non-zero when it could not. The menu snippet never calls
  that link: it runs the bundled `"$HOME/.config/omarchy/plugins/megascan.tvcast/bin/tvcast"`
  (always quoted: `when` and actions run in bash, and HOME may contain spaces), because
  `when` checks run as soon as the menu opens. Every row has a `when` that runs the
  bundled CLI, so after `omarchy plugin remove` (which never runs uninstall.sh) all rows
  hide. Temp and backup files are created fresh (`mkstemp`/`mktemp`), never at a fixed
  path that could already be a symlink.
  Menu edits go through `menu/menu-edit.py`. Ownership is the exact lines recorded in
  `$XDG_STATE_HOME/tvcast/menu-owned.json`, keyed by the real (symlink-resolved) file
  they were written to, plus lines byte-identical to any snippet line tvcast ever shipped
  (`menu/legacy-lines.txt`; menus from before 0.5.2 have no record). **Before changing
  any snippet line, append the old line to `legacy-lines.txt`.** Uninstall cleans each
  recorded file and the file the menu path points at now. A recorded file that is gone
  (its directory still there) is forgotten; one whose directory is missing keeps its
  entry. tvcast entries that remain afterwards (edited, or a user's own child) are named.
  A user's own `trigger.cast` parent makes install add nothing; a user's own child key is
  kept and tvcast's skipped. Uninstall does nothing if `--menu` was never run.
  Omarchy's JSONC parser only strips whole-line `//` comments, so never mark ownership
  with trailing comments. `omarchy_items` mirrors `MenuModel.js` `readMenuJsonc`
  exactly, including JS's `\s` set and line terminators (U+2028/2029, BOM; not U+0085)
  and UTF-8 decoding with replacement. Entries go right after the opening brace of the
  object Omarchy reads (`items` when it is an object, else the root), so no user or
  comment line is ever edited; blank or comment-only files get a new `{}`. Every edit
  is re-parsed before writing; any mismatch leaves the menu unchanged and exits
  non-zero. Files are read and written as bytes (CRLF and non-UTF-8 bytes survive).
  A backup is made only when the file changes, is a byte copy, and is removed if the
  edit fails. Non-regular and hard-linked menus are refused. A failed uninstall keeps
  the ownership record so a rerun can finish. Writes are atomic via `mkstemp` beside
  the real (symlink-resolved) file; the record itself is never written through a symlink.
- **By design, documented in the README:** go2tv's media server is unauthenticated
  HTTP on the TV-facing address while a file plays. The README's first firewall rule
  is scoped to the TV's IP. go2tv's argv carries only the private play-dir symlink
  (see 0.5.6), so the file's name, not its directory, shows in `ps`. go2tv pins
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
- **The real TV is someone's living room.** Never start, resume or seek the user's own media
  on it for a test without asking first. Test on the item the user names, put the queue back
  to how it was, and leave the TV paused or stopped as you found it, never playing.

## Review round 0.5.6 (marketplace review #15258 plus a sweep)

- **An address is not an identity.** A saved device carries `id` (DLNA: root device UDN
  via `dlna_udn`; Chromecast: mDNS TXT `id`, re-read with `tvcast-discover mdns`).
  `verify_device` must pass before reuse in `choose_device`/`ensure_device` and before
  every item in the runner. Auto-select after discovery needs URL **and** ID equal.
  Mismatch or no ID: picker (CLI) or die (runner, after `write_state '{"active":false}'`
  so `_cleanup` doesn't send Stop to the other device). Devices saved by 0.5.5 have no ID
  and are re-picked once; never record an ID on first contact (that trusts the address
  again). The ID is self-announced: it catches DHCP reassignment, not spoofing.
  Test: fake TV, switch its UDN mid-queue; the picker must open, the runner must die.
- **Media allowlist at queue time and in the runner** (`media_ok`): content MIME from
  `file -b --mime-type -` reading stdin (file's sandbox can't open `/proc/<pid>/fd`
  links) must be video/audio/image, minus `DENY_MIME` (playlists, SVG, ASX), and the
  extension must not be `.torrent` (go2tv 2.9.0 starts BitTorrent for any `-v *.torrent`,
  whatever the content). Raw args `-`, `*://*`, `magnet:*` are refused. Test every
  extension the picker offers plus `.torrent`, a real MP4 renamed `.TORRENT`, `.m3u8`,
  `.pls`, `.svg`, a URL and `-`, in `cast`/`add` and as hand-edited queue entries.
- **Serve the file that was picked, not whatever the path names later.** go2tv re-opens
  `-v`/`-s` paths on every HTTP request. Queue items record `file_id` (statfs id, inode,
  birth time; not `st_dev`, which btrfs renumbers). `pin_media` opens the file in the
  runner's main shell, checks `file_id` and MIME on the fd, and gives go2tv
  `$CACHE_DIR/play.XXXXXX/<original name>` -> `/proc/<runner>/fd/<n>`. The original name
  keeps go2tv's URL, DIDL title, MIME and extension logic intact (a bare `/proc/.../fd/N`
  would not). Subtitles are copied (size-capped) into that dir, and only from a sidecar
  whose real path is in the video's own directory. Lost by design: sidecar cover art
  (go2tv only scans the media's directory for regular files). Close the fd only after
  `kill_player`; stale `play.*` dirs are removed at runner start. Items without `id`
  are skipped. Test: real go2tv against a loopback fake renderer, fetch the media URL,
  `mv` another file over the path, fetch again: same bytes.
- **Device text never reaches arithmetic or a multi-field `read`.** A same-origin
  controlURL `"/ctl UNIT[$(cmd)]"` once ran `cmd`: `rc_info` printed `"$ctl $max"`,
  `read -r ctl max` put device text into `max`, and `((raw > max))` evaluated it.
  Rules: `url_origin` accepts only `[[:graph:]]` after the origin (no space, tab, CR, LF);
  helpers that print several fields use a tab and are split explicitly (`rc_get`);
  every number goes through `uint` and every state word through `^[A-Z_]{1,40}$`
  (`transport_state`, `dev_status`) before `(( ))`, `$(( ))`, `[[ -lt ]]` or a subscript.
  Test with controlURLs containing a space, a tab and a newline plus `$(touch marker)`,
  a hand-edited `rendering` cache, and a CurrentTransportState of
  `PLAYING x[$(touch marker)]`, then run `volume`, `volume 50`, `mute`, `status --json`
  and `toggle`: no marker, no request.
- **Smaller rules from the same sweep:** CURL runs with `-g` (no URL globbing of device
  paths); counters for background jobs are incremented in the parent, not inside
  `>"$((++i))" &`; an empty friendlyName becomes `TV` before it enters a tab record (IFS
  collapses empty tab fields); `clean_text` also strips U+200B-200F, U+202A-202E,
  U+2066-2069, U+FEFF; `pick_files` drops any picked name containing a newline; sidecars
  are only `stem.ext` or `stem.<lang>.ext`; `ext_of` and titles use the basename.
- **Never `pkill -f`/`pgrep -f` a pattern that appears in your own command line**, and
  never a go2tv pattern at all: the user's live go2tv matches too. Kill test processes
  by the PID you saved.
