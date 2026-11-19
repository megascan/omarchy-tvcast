#!/bin/bash
# Undo install.sh: stop casting, remove the CLI link, the menu entries and
# tvcast's state. Remove the plugin itself with: omarchy plugin remove <id>
set -uo pipefail
here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
id=$(jq -r .id "$here/manifest.json")
plugins=$HOME/.config/omarchy/plugins

if ! "$here/bin/tvcast" _stop-owned 2>/dev/null; then
  echo "could not stop casting (the stop failed or the systemd user manager is unreachable);" \
    "left the CLI link, menu entries, queue and state as they are. Stop it with 'tvcast stop', then run this again" >&2
  exit 1
fi
link=$HOME/.local/bin/tvcast
if to=$(readlink "$link") &&
  [[ $to == "$plugins/$id/bin/tvcast" || $to == */"$id"/bin/tvcast || $(readlink -f "$link") == "$here/bin/tvcast" ]]; then
  rm -f "$link"
fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
# The exact lines install.sh recorded, in each file it recorded them for, plus
# tvcast's own lines in the menu Omarchy reads now; nothing if --menu was never used.
if [[ -e $state/menu-owned.json || -L $state/menu-owned.json ]] &&
  ! python3 -I "$here/menu/menu-edit.py" uninstall "$state/menu-owned.json" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"; then
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
