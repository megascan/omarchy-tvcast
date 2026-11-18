#!/bin/bash
# Undo install.sh: stop casting, remove the CLI link, the menu entries and
# tvcast's state. Remove the plugin itself with: omarchy plugin remove <id>
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r .id "$here/manifest.json")
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

systemctl --user stop tvcast.service 2>/dev/null
[[ $(readlink -f "$HOME/.local/bin/tvcast") == */"$id"/bin/tvcast ]] && rm -f "$HOME/.local/bin/tvcast"
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
# Only the exact lines install.sh recorded as its own; nothing if --menu was never used.
if [[ -f $menu && -f $state/menu-owned.json ]]; then
  cp "$menu" "$(mktemp "$menu.bak.XXXXXX")"
  python3 -I "$here/menu/menu-edit.py" uninstall "$menu" "$state/menu-owned.json"
fi
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/tvcast"
# Keep plugin-backups/ (previous installs moved aside by install.sh).
find "$state" -mindepth 1 -maxdepth 1 ! -name plugin-backups -exec rm -rf {} + 2>/dev/null
rmdir "$state" 2>/dev/null
[[ -d $state/plugin-backups ]] && echo "kept earlier plugin backups in $state/plugin-backups"
echo "done; if installed with omarchy plugin add, finish with: omarchy plugin remove $id"
