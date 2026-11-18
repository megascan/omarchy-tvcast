#!/bin/bash
# Undo install.sh: stop casting, remove the CLI link, the menu entries and
# tvcast's state. Remove the plugin itself with: omarchy plugin remove <id>
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r .id "$here/manifest.json")
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

systemctl --user stop tvcast.service 2>/dev/null
[[ $(readlink -f "$HOME/.local/bin/tvcast") == */"$id"/bin/tvcast ]] && rm -f "$HOME/.local/bin/tvcast"
if [[ -f $menu ]] && grep -q '"trigger.cast' "$menu"; then
  cp "$menu" "$menu.bak.$(date +%s)"
  sed -i '/"trigger\.cast/d; /^ *\/\/ tvcast/d' "$menu"
  echo "removed menu entries (backup saved)"
fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/tvcast"
# Keep plugin-backups/ (previous installs moved aside by install.sh).
find "$state" -mindepth 1 -maxdepth 1 ! -name plugin-backups -exec rm -rf {} + 2>/dev/null
rmdir "$state" 2>/dev/null
[[ -d $state/plugin-backups ]] && echo "kept earlier plugin backups in $state/plugin-backups"
echo "done; if installed with omarchy plugin add, finish with: omarchy plugin remove $id"
