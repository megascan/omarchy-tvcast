#!/bin/bash
# Optional setup after `omarchy plugin add`, run from the plugin folder:
#   ./install.sh          link the tvcast CLI into ~/.local/bin
#   ./install.sh --menu   also add the "Cast to TV" entries to the Omarchy menu
#                         (~/.config/omarchy/extensions/omarchy-menu.jsonc, backed up first)
# Run from a clone outside the plugins folder, it (re)copies the clone in as
# the plugin (for development).
set -euo pipefail
here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
id=$(jq -r .id "$here/manifest.json")
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id != *..* ]] || { echo "invalid plugin id in $here/manifest.json" >&2; exit 1; }
plugins=$HOME/.config/omarchy/plugins
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc
state=${XDG_STATE_HOME:-$HOME/.local/state}/tvcast
backups=$state/plugin-backups
copied=$state/plugin-copy.sum
plugin_files=(manifest.json BarWidget.qml LICENSE README.md AGENTS.md preview.png install.sh uninstall.sh bin i18n menu)

tree_sum() {
  tar -C "$1" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --exclude=.tvcast-stage -cf - . | sha256sum | cut -d' ' -f1
}

make_slot() {
  local base n=0
  { (umask 077 && mkdir -p "$backups") && chmod 700 "$state" "$backups"; } || return 1
  base=$backups/$id.$(date +%Y%m%d-%H%M%S)
  slot=$base
  while [[ -e $slot || -L $slot ]]; do n=$((n + 1)); slot=$base.$n; done
  mkdir "$slot"
}

move_to_slot() {
  mv -T "$1" "$slot" 2>/dev/null || { rmdir "$slot" && mv -T "$1" "$slot"; }
}

mkdir -p "$HOME/.local/bin" "$plugins"
target=$plugins/$id
if [[ $(readlink -f "$target") != "$here" ]]; then
  # A development clone: copy the plugin's files in (the plugin validator refuses
  # symlinks). Never delete an existing install the user may have changed: swap
  # the new copy in atomically, then move the old one to a backup.
  exec 9<"$plugins"
  flock 9
  [[ -d $target && ! -L $target ]] && rm -f "$target/.tvcast-stage"
  for old in "$plugins/.$id.new."*; do
    [[ -d $old && ! -L $old ]] || continue
    if [[ -e $old/.tvcast-stage ]]; then
      rm -rf "$old"
    else
      make_slot && move_to_slot "$old" && echo "moved an interrupted install's previous plugin to $slot"
    fi
  done
  stage=$(mktemp -d "$plugins/.$id.new.XXXXXX")
  trap '[[ -e $stage/.tvcast-stage ]] && rm -rf "$stage"' EXIT
  : >"$stage/.tvcast-stage"
  files=()
  for f in "${plugin_files[@]}"; do [[ -e $here/$f ]] && files+=("$f"); done
  tar -C "$here" --exclude=__pycache__ --exclude='*.pyc' -cf - -- "${files[@]}" | tar -C "$stage" -xf -
  [[ -s $stage/manifest.json ]] || { echo "copy failed; $target left untouched" >&2; exit 1; }
  new_sum=$(tree_sum "$stage")
  old_sum=""
  [[ -d $target && ! -L $target ]] && old_sum=$(tree_sum "$target")
  if [[ $old_sum == "$new_sum" ]]; then
    rm -rf "$stage"
    echo "plugin $id in $target is already up to date"
  elif [[ ! -e $target && ! -L $target ]]; then
    mv -T "$stage" "$target"
    rm -f "$target/.tvcast-stage"
    echo "copied plugin $id into $target"
  else
    slot=""
    if [[ -z $old_sum || ! -s $copied || $old_sum != "$(cat "$copied")" ]]; then
      make_slot || { echo "could not create a backup in $backups; $target left untouched" >&2; exit 1; }
    fi
    if mv --exchange -T "$stage" "$target" 2>/dev/null; then
      rm -f "$target/.tvcast-stage"
      if [[ -n $slot ]]; then
        move_to_slot "$stage" && echo "moved the previous install to $slot"
      else
        rm -rf "$stage"
      fi
    else
      [[ -n $slot ]] || make_slot || { echo "could not create a backup in $backups; $target left untouched" >&2; exit 1; }
      move_to_slot "$target"
      echo "moved the previous install to $slot"
      mv -T "$stage" "$target"
      rm -f "$target/.tvcast-stage"
    fi
    echo "copied plugin $id into $target"
  fi
  trap - EXIT
  (umask 077 && mkdir -p "$state" && printf '%s\n' "$new_sum" >"$copied")
fi

# Never replace someone else's `tvcast`: link only when the name is free or
# already points into this plugin (the same test uninstall.sh uses).
link=$HOME/.local/bin/tvcast
own_link() {
  local to
  to=$(readlink "$link") || return 1
  [[ $to == "$target/bin/tvcast" || $to == */"$id"/bin/tvcast || $(readlink -f "$link") == "$here/bin/tvcast" ]]
}
if [[ -e $link || -L $link ]] && ! own_link; then
  echo "left $link alone: it is not tvcast's link (remove or rename it, then run this again)" >&2
  link_failed=1
elif ln -sfn "$target/bin/tvcast" "$link"; then
  echo "linked $link"
else
  link_failed=1
fi

if [[ ${1:-} == --menu ]]; then
  mkdir -p "$(dirname "$menu")"
  (umask 077 && mkdir -p "$state")
  python3 -I "$here/menu/menu-edit.py" install "$menu" "$here/menu/omarchy-menu.snippet.jsonc" "$state/menu-owned.json" || menu_failed=1
fi

command -v go2tv >/dev/null || [[ -x $HOME/.local/bin/go2tv ]] ||
  echo "warning: go2tv not found; put the go2tv binary in ~/.local/bin (see README)" >&2
echo "add the widget to the bar with: omarchy bar put $id --section right"
[[ ${menu_failed:-0} == 0 && ${link_failed:-0} == 0 ]]
