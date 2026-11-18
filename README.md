# TV Cast for Omarchy

Cast local video, audio and image files to a DLNA smart TV or a Chromecast
(experimental) from Omarchy, as a play queue you manage from the top bar. Files
are served by [go2tv](https://github.com/alexballas/go2tv). Pause, seek, stop and
the queue's auto-advance go straight to the TV over UPnP AVTransport, or over the
Cast protocol for a Chromecast.

![Queue panel](preview.png)

## Features

- **Bar widget** (`megascan.tvcast`) is always on the bar.
  - Idle, it shows a cast icon. Click it for "Cast files…" and "Add to queue…", plus
    the TV to cast to, with a button to search again.
  - While casting, it shows `▶ Title (2/5)`. Click opens the queue panel: progress
    (click or drag the bar to seek; greyed out when the TV reports no duration), previous, −30 s, play/pause, +30 s, next and stop, the queue (hover
    an item to move or remove it, click to play it), and the file actions.
  - Middle-click pauses or resumes, right-click stops, and scrolling seeks 30 s.
- **Queue:** moves to the next file when the TV reports the current one finished.
  Stopping it yourself never skips ahead, and the queue clears itself once the last file ends.
- **DLNA and Chromecast:** the TV picker lists both, with each device's IP address
  and type. A device you haven't picked before is never chosen for you.
- **Format check (DLNA):** ffprobe decides whether a video needs transcoding. H.264, HEVC,
  MPEG-2 and MPEG-4 video in MP4, MKV, MOV, TS or AVI with AAC, AC3, EAC3 or MP3
  audio plays as-is. Everything else gets go2tv's ffmpeg transcode (`-tc`).
  On a Chromecast, go2tv makes that call itself.
- **Subtitles:** a sidecar with the same name (`movie.srt`, `movie.en.srt`, `.vtt`,
  `.ass`, `.ssa`) is sent along automatically.
- **Images** stay on screen for 10 s (`TVCAST_IMAGE_SECONDS`), or until you stop if
  the image is last in the queue.
- **Menu entries** (optional): Trigger › Cast to TV, also `omarchy menu summon cast`.
  Cast files (multi-select), add to queue, cast to another TV, play, pause/resume,
  next, previous, ±30 s, what's playing, stop and clear queue. Entries that don't
  apply right now are hidden.

## Requirements

- Omarchy with the Quickshell bar (Quattro or later).
- [go2tv](https://github.com/alexballas/go2tv/releases) **2.5.0 or newer** (older versions follow
  whatever control URL a device advertises; tvcast refuses them): put the `go2tv` binary on
  your `PATH` or in `~/.local/bin`, or install the AUR package `go2tv`.
- `ffmpeg`/`ffprobe`, `jq`, `curl`, `libxml2` (`xmllint`), `file`, `iproute2` (`ip`),
  `python` (discovery and menu edits), `avahi` (`avahi-browse`, for finding
  Chromecasts) and `util-linux` (`script`, `setsid`, `flock`).
  Omarchy ships all of these.
- A **DLNA/UPnP media renderer**, which most smart TVs are (LG webOS, Samsung,
  Sony, Philips and so on), or a **Chromecast** / Google TV (see below).

### Chromecast (experimental)

go2tv casts to Chromecasts by itself. To pause, seek, show progress and move
through the queue reliably, tvcast also needs one optional package, only if you
use a Chromecast:

```sh
sudo pacman -S python-pychromecast
```

Without it, files still play and the queue still advances when go2tv sees the
end of a file, but pause, seek and the progress bar don't work, and tvcast tells
you so in a notification. Known limits: this has been tested against a simulated
Chromecast only, not real hardware. Seeking in a file go2tv transcodes for the
Chromecast may not work, and Chromecast groups (speaker groups) aren't listed.

### Firewall

Omarchy enables ufw with incoming connections denied. The TV has to reach the
media server go2tv runs on your machine, and discovery needs replies to get
back. tvcast never changes the firewall; you run these rules yourself.

Open the media server to the TV (or Chromecast) alone. Give it a fixed address
first (a DHCP reservation in your router):

```sh
sudo ufw allow from <TV-IP> to any port 3500:4499 proto tcp         # go2tv media server, TV only
```

Discovery replies can come from any device, so these stay LAN-wide. They carry
no file contents:

```sh
sudo ufw allow from <your-LAN>/24 to any port 3339:3438 proto udp   # tvcast's SSDP discovery replies
sudo ufw allow from <your-LAN>/24 to any port 1900 proto udp        # SSDP
sudo ufw allow from <your-LAN>/24 to any port 5353 proto udp        # mDNS (Chromecast)
```

Why the media rule is per device: while a file is casting, go2tv serves it,
and its sidecar subtitles, over plain HTTP with no password or token, on the
address that faces the TV. Any machine that can reach that port can fetch the
file during playback; the URL contains the file's name. That is how DLNA and
Cast receivers fetch media, so it can't be avoided, only fenced in. Without a
fixed TV address you can open `from <your-LAN>/24` instead, at that cost.

## Install

```sh
omarchy plugin add https://github.com/megascan/omarchy-tvcast --enable
~/.config/omarchy/plugins/megascan.tvcast/install.sh --menu
```

`omarchy plugin add` installs the bar widget, and the widget works on its own.
`install.sh` links the `tvcast` CLI into `~/.local/bin`. If something else already
uses that name, it leaves it alone and says so. `--menu` also adds the menu
entries to `~/.config/omarchy/extensions/omarchy-menu.jsonc`, after saving a backup
next to it. It only adds or replaces lines that start with its own
`"trigger.cast…"` keys. Leave out `--menu` to keep your menu untouched.

If the widget isn't on the bar yet: `omarchy bar put megascan.tvcast --section right`.

The first cast looks for TVs on the network (about 5 s). The chosen TV is remembered,
and "Cast files to another TV…" (or `tvcast cast --pick`) searches again.

## Command line

```
tvcast cast [--pick] [file...]   replace the queue and play (file picker if no files)
tvcast add [--pick] [file...]    append to the queue (starts it if it was empty)
tvcast next | prev | play-index N | remove N | move N up|down | clear | list
tvcast play | toggle | pause | resume | stop
tvcast seek +30 | seek -30 | seek 1:02:03 | seek-to <seconds>
tvcast status [--json] | devices [--json] | pick-device
```

Playback runs as the transient user service `tvcast.service` (created with
`systemd-run --user`, removed when it stops), so you can also stop it with
`systemctl --user stop tvcast`. tvcast touches no other service and never uses sudo.
Playback runs go2tv under `script(1)`, because go2tv's CLI needs a terminal.
State lives in `~/.local/state/tvcast/` (queue) and `~/.cache/tvcast/` (now
playing, last TV, go2tv's `session.log`). Both directories and their files are
owner-only (0700/0600). Nothing in them is ever executed.
`TVCAST_TRANSCODE=always|never` overrides the transcode check.

Discovery is tvcast's own (`bin/tvcast-discover`), not `go2tv -l`. go2tv's list
mode fetches every SSDP `LOCATION` it hears before returning, to any host
([go2tv#188](https://github.com/alexballas/go2tv/issues/188)). tvcast only
listens: it sends an SSDP M-SEARCH from a port in 3339–3438, and asks avahi for
`_googlecast._tcp`. It drops every `LOCATION` that is not a private LAN IP, is
this machine, or is not on the host that sent the reply, before fetching
anything. It then fetches the remaining descriptions itself, with the limits
below. Chromecasts are found without any HTTP request.

Network safety: tvcast only talks to TVs on private LAN IP addresses (10/8, 172.16/12,
192.168/16, link-local, IPv6 ULA), written in plain dotted decimal (no hostnames,
no octal or zero-padded forms). It refuses this machine's own addresses, never
follows redirects, caps every reply at 1 MiB, and only sends playback commands to
the same address and port that served the TV's device description. go2tv
(2.5.0+) fetches the description again itself. It pins every request to the IP
address it first resolved, and follows a redirect only to that same host.
Chromecast commands go only to the cast port of the address you picked, and the
helper runs under a timeout and a memory limit. Device names are stripped of
control characters and shortened.
`TVCAST_ALLOW_LOOPBACK=1` also allows 127.0.0.1, for testing against a fake TV.

Privacy: the file's path is on go2tv's command line while it plays, like any
media player, so other local accounts can see it in `ps`. The TV, and anything
that can reach the media port, sees its name.

## Uninstall

```sh
~/.config/omarchy/plugins/megascan.tvcast/uninstall.sh   # stops casting; removes the CLI link (if it is ours), menu entries and state; keeps plugin-backups/
omarchy plugin remove megascan.tvcast
```

## Development

From a clone, `./install.sh` copies the working tree into
`~/.config/omarchy/plugins/megascan.tvcast`, because the plugin validator doesn't
allow symlinks. An existing install is moved to
`~/.local/state/tvcast/plugin-backups/` first, never deleted. Run it again
after each change.

## License

MIT. See [LICENSE](LICENSE).
