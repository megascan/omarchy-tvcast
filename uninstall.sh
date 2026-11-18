#!/bin/bash
# Undo install.sh: stop casting, remove the CLI link, the menu entries and
# tvcast's state. Remove the plugin itself with: omarchy plugin remove <id>
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r .id "$here/manifest.json")

systemctl --user stop tvcast.service 2>/dev/null
[[ $(readlink -f "$HOME/.local/bin/tvcast") == */"$id"/bin/tvcast ]] && rm -f "$HOME/.local/bin/tvcast"
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
# Only the exact lines install.sh recorded, in the file it recorded them for (even if
# the menu symlink now points elsewhere); nothing if --menu was never used.
if [[ -f $state/menu-owned.json ]] &&
  ! python3 -I "$here/menu/menu-edit.py" uninstall "$state/menu-owned.json"; then
  echo "menu cleanup incomplete; kept $state/menu-owned.json so running this again can finish it" >&2
  failed=1
fi
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/tvcast"
# Keep plugin-backups/ (previous installs moved aside by install.sh).
find "$state" -mindepth 1 -maxdepth 1 ! -name plugin-backups ! -name menu-owned.json -exec rm -rf {} + 2>/dev/null
[[ ${failed:-0} == 1 ]] || rm -f "$state/menu-owned.json"
rmdir "$state" 2>/dev/null
[[ -d $state/plugin-backups ]] && echo "kept earlier plugin backups in $state/plugin-backups"
echo "done; if installed with omarchy plugin add, finish with: omarchy plugin remove $id"
exit "${failed:-0}"
