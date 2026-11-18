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
  rm -rf "$target"
  mkdir -p "$target"
  tar -C "$here" --exclude=.git -cf - . | tar -C "$target" -xf -
  echo "copied plugin $id into $target"
fi
ln -sfn "$target/bin/tvcast" "$HOME/.local/bin/tvcast"
echo "linked ~/.local/bin/tvcast"

if [[ ${1:-} == --menu ]]; then
  mkdir -p "$(dirname "$menu")"
  [[ -s $menu ]] || printf '{\n}\n' >"$menu"
  cp "$menu" "$menu.bak.$(date +%s)"
  python3 -I - "$menu" "$here/menu/omarchy-menu.snippet.jsonc" <<'PY'
import sys
path, snip = sys.argv[1], sys.argv[2]
lines = [l for l in open(path).read().split("\n")
         if '"trigger.cast' not in l and not l.strip().startswith("// tvcast")]
text = "\n".join(lines)
end = text.rstrip().rfind("}")
head = text[:end].rstrip()
if head and not head.endswith(("{", ",")):
    head += ","
open(path, "w").write(head + "\n" + open(snip).read() + text[end:])
PY
  echo "added menu entries (Trigger > Cast to TV); backup saved next to $menu"
fi

command -v go2tv >/dev/null || [[ -x $HOME/.local/bin/go2tv ]] ||
  echo "warning: go2tv not found; put the go2tv binary in ~/.local/bin (see README)" >&2
echo "add the widget to the bar with: omarchy bar put $id --section right"
