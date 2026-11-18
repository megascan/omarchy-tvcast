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
  bak=$(mktemp "$menu.bak.XXXXXX")
  cp "$menu" "$bak"
  state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
  (umask 077 && mkdir -p "$state")
  if python3 -I "$here/menu/menu-edit.py" install "$menu" "$here/menu/omarchy-menu.snippet.jsonc" "$state/menu-owned.json"; then
    echo "added menu entries (Trigger > Cast to TV); backup saved next to $menu"
  else
    menu_failed=1
  fi
fi

command -v go2tv >/dev/null || [[ -x $HOME/.local/bin/go2tv ]] ||
  echo "warning: go2tv not found; put the go2tv binary in ~/.local/bin (see README)" >&2
echo "add the widget to the bar with: omarchy bar put $id --section right"
exit "${menu_failed:-0}"
