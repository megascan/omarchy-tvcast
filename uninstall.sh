#!/bin/bash
# Undo install.sh: stop casting, remove the CLI link, the menu entries and
# tvcast's state. Remove the plugin itself with: omarchy plugin remove <id>
set -uo pipefail
here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
id=$(jq -r .id "$here/manifest.json")
plugins=$HOME/.config/omarchy/plugins

if ! "$here/bin/tvcast" _stop-owned 2>/dev/null; then
  if systemctl --user show -p Version >/dev/null 2>&1; then
    echo "could not stop casting; left the CLI link, menu entries, queue and state as they are." \
      "Stop it with 'tvcast stop', then run this again" >&2
  else
    echo "could not reach the systemd user manager from this shell (run through sudo or su, or without a login session)," \
      "so a running cast could not be stopped; left the CLI link, menu entries, queue and state as they are." \
      "Run this again as $(id -un) from your own desktop session" >&2
  fi
  exit 1
fi
link=$HOME/.local/bin/tvcast
installed=$plugins/$id/bin/tvcast
if to=$(readlink "$link") &&
  { [[ $to == "$installed" ]] || { [[ -e $installed ]] && [[ $(readlink -f "$link") == "$(readlink -f "$installed")" ]]; }; }; then
  rm -f "$link" || failed=1
fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
rec=$state/menu-owned.json
# The exact lines install.sh recorded, in each file it recorded them for, plus
# lines tvcast ever shipped in the menu Omarchy reads now (also menus from before the record).
if ! python3 -I "$here/menu/menu-edit.py" uninstall "$rec" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"; then
  if [[ -e $rec || -L $rec ]]; then
    echo "menu cleanup incomplete; kept $rec so running this again can finish it" >&2
  else
    echo "menu cleanup incomplete; fix the menu named above, then run this again" >&2
  fi
  failed=1
fi
cache=${XDG_CACHE_HOME:-$HOME/.cache}/tvcast
rm -rf "$cache" 2>/dev/null
# Keep plugin-backups/ (previous installs moved aside by install.sh).
find "$state" -mindepth 1 -maxdepth 1 ! -name plugin-backups ! -name menu-owned.json -exec rm -rf {} + 2>/dev/null
if [[ -e $cache || -L $cache ]] || { [[ -d $state ]] && [[ -n $(find "$state" -mindepth 1 -maxdepth 1 ! -name plugin-backups ! -name menu-owned.json -print -quit 2>/dev/null) ]]; }; then
  echo "could not remove everything in $cache and $state; delete what is left by hand" >&2
  failed=1
fi
[[ ${failed:-0} == 1 ]] || rm -f "$rec"
rmdir "$state" 2>/dev/null
[[ -d $state/plugin-backups ]] && echo "kept earlier plugin backups in $state/plugin-backups"
if [[ ${failed:-0} == 1 ]]; then
  echo "uninstall incomplete; see the messages above" >&2
  exit 1
fi
echo "done; if installed with omarchy plugin add, finish with: omarchy plugin remove $id"
