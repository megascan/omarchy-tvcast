#!/bin/bash
# Optional setup after `omarchy plugin add`, run from the plugin folder:
#   ./install.sh          link the tvcast CLI into ~/.local/bin
#   ./install.sh --menu   also add the "Cast to TV" entries to the Omarchy menu
#                         (~/.config/omarchy/extensions/omarchy-menu.jsonc, backed up first)
# Run from a clone outside the plugins folder, it (re)copies the clone in as
# the plugin (for development).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r .id "$here/manifest.json")
plugins=$HOME/.config/omarchy/plugins
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

mkdir -p "$HOME/.local/bin" "$plugins"
target=$plugins/$id
if [[ $(readlink -f "$target") != "$here" ]]; then
  # A development clone: copy it in (the plugin validator refuses symlinks).
  # Never delete an existing install: copy into a staging dir first, then move
  # the old install (local edits, .git and all) to a backup, then swap.
  stage=$(mktemp -d "$plugins/.$id.new.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  tar -C "$here" --exclude=.git -cf - . | tar -C "$stage" -xf -
  [[ -s $stage/manifest.json ]] || { echo "copy failed; $target left untouched" >&2; exit 1; }
  if [[ -e $target || -L $target ]]; then
    backups=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast/plugin-backups
    # Owner-only: a backup can hold local edits and the queue dir's neighbours.
    (umask 077 && mkdir -p "$backups")
    chmod 700 "${backups%/*}" "$backups"
    backup=$backups/$id.$(date +%Y%m%d-%H%M%S)
    mv "$target" "$backup"
    echo "moved the previous install to $backup"
  fi
  mv "$stage" "$target"
  trap - EXIT
  echo "copied plugin $id into $target"
fi
# Never replace someone else's `tvcast`: link only when the name is free or
# already points into this plugin (the same test uninstall.sh uses).
link=$HOME/.local/bin/tvcast
if [[ -e $link || -L $link ]] && [[ $(readlink -f "$link") != */"$id"/bin/tvcast ]]; then
  echo "left $link alone: it is not tvcast's link (remove or rename it, then run this again)" >&2
else
  ln -sfn "$target/bin/tvcast" "$link"
  echo "linked $link"
fi

if [[ ${1:-} == --menu ]]; then
  mkdir -p "$(dirname "$menu")"
  [[ -s $menu ]] || printf '{\n}\n' >"$menu"
  cp "$menu" "$menu.bak.$(date +%s)"
  python3 -I - "$menu" "$here/menu/omarchy-menu.snippet.jsonc" <<'PY'
import os, re, sys
path, snip = sys.argv[1], sys.argv[2]
# Only our own lines: a line that starts with one of the snippet's keys, or
# the snippet's comment. Anything else (a "trigger.castle" entry, a one-line
# file) is left exactly as it is.
ours = re.compile(r'^\s*("trigger\.cast(\.(file|add|other|play|toggle|next|prev|back|forward|status|stop|clear))?"\s*:|// tvcast: )')
text = "\n".join(l for l in open(path).read().split("\n") if not ours.match(l))
end = text.rstrip().rfind("}")
if end < 0:
    sys.exit(f"{path} has no closing brace; menu left unchanged")
head = text[:end].rstrip()
if head and not head.endswith(("{", ",")):
    head += ","
real = os.path.realpath(path)  # a dotfiles symlink stays a symlink
tmp = real + ".tvcast.tmp"
with open(tmp, "w") as f:
    f.write(head + "\n" + open(snip).read() + text[end:])
os.chmod(tmp, os.stat(real).st_mode & 0o7777)
os.replace(tmp, real)
PY
  echo "added menu entries (Trigger > Cast to TV); backup saved next to $menu"
fi

command -v go2tv >/dev/null || [[ -x $HOME/.local/bin/go2tv ]] ||
  echo "warning: go2tv not found; put the go2tv binary in ~/.local/bin (see README)" >&2
echo "add the widget to the bar with: omarchy bar put $id --section right"
