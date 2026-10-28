#!/usr/bin/env bash
# Install Automic Vault where its own code expects it.
#
# Usage: automic-vault-install check|install app <source app> <app>
#        automic-vault-install check|install cli <source av> <cli>
#
# `av harden brew` copies its brew stub out of /Applications/Automic Vault.app,
# and the app, `av doctor` and every hardened tool run /usr/local/bin/av, which
# must be a root-owned regular file with mode 0755 and no ACL, in directories
# that only root can write. `check` reports what would stop `install` and
# changes nothing.
#
# `install app` replaces <app> only when it differs from <source app>: it copies
# the source next to <app>, verifies the copy's signature, then swaps it in with
# a rename. Whatever is at <app> already must be a validly signed Automic Vault
# (any version), or nothing is replaced. `install cli` installs <source av> at
# <cli> the way the app's own "Install av CLI" does.
set -euo pipefail

team="ZU76A67LGU"
app_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"com.automicvault\""
cli_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"com.automicvault.av\""

if [[ $# -ne 4 ]] || [[ $1 != check && $1 != install ]] || [[ $2 != app && $2 != cli ]]; then
  echo "usage: automic-vault-install check|install app|cli <source> <target>" >&2
  exit 2
fi
mode="$1"
kind="$2"
source="$3"
target="$4"

fail() {
  echo "automic-vault: error: $*" >&2
  exit 1
}

say() {
  echo "automic-vault: $*" >&2
}

# A scratch directory next to <target>, so the final move is a rename.
stage=""
cleanup() {
  if [[ -n $stage ]]; then
    # Copies out of the Nix store are read-only, which only stops non-root.
    /bin/rm -rf "$stage" 2>/dev/null || { /bin/chmod -R u+w "$stage" && /bin/rm -rf "$stage"; }
  fi
}
trap cleanup EXIT

make_stage() {
  stage=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$target")/.automic-vault.XXXXXXXX")
}

# Root-owned, not writable by group or others, and without an ACL, as the
# app's installer requires of each directory above /usr/local/bin/av.
protected() {
  local uid perms
  read -r uid perms < <(/usr/bin/stat -f '%u %Lp' "$1")
  [[ $uid == 0 ]] && (((8#$perms & 8#022) == 0)) && [[ $(/bin/ls -lde "$1" | /usr/bin/wc -l) -eq 1 ]]
}

# The directories that hold <cli>, from / down.
cli_dirs() {
  local dir dirs=()
  dir=$(/usr/bin/dirname "$target")
  while [[ $dir != / ]]; do
    dirs=("$dir" "${dirs[@]}")
    dir=$(/usr/bin/dirname "$dir")
  done
  printf '%s\n' / "${dirs[@]}"
}

cdhash() {
  /usr/bin/codesign --display --verbose=3 "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'
}

check_app() {
  /usr/bin/codesign --verify --deep --strict -R "=$app_requirement" "$source" ||
    fail "$source is not a validly signed Automic Vault app"
  if [[ -e $target || -L $target ]] && ! /usr/bin/codesign --verify -R "=$app_requirement" "$target" 2>/dev/null; then
    fail "$target is in the way and is not a validly signed Automic Vault; move it aside"
  fi
}

check_cli() {
  /usr/bin/codesign --verify --strict -R "=$cli_requirement" "$source" ||
    fail "$source is not a validly signed av CLI"
  local dir
  while read -r dir; do
    if [[ -e $dir || -L $dir ]] && ! { [[ -d $dir && ! -L $dir ]] && protected "$dir"; }; then
      fail "$dir must be a root-owned directory that only root can write and that has no ACL, to hold $target"
    fi
  done < <(cli_dirs)
  if [[ -d $target || -L $target ]]; then
    fail "$target is a directory or a symlink; remove it so the av CLI can be installed there"
  fi
}

# The same signed code: equal code directory hashes cover the executable,
# Info.plist and the sealed resource list, and a strict deep verify proves
# the installed files still match that list.
app_current() {
  [[ -d $target && ! -L $target ]] &&
    [[ $(cdhash "$target") == "$(cdhash "$source")" ]] &&
    /usr/bin/codesign --verify --deep --strict "$target" 2>/dev/null
}

install_app() {
  if app_current; then
    return
  fi
  local name
  make_stage
  name=$(/usr/bin/basename "$target")
  /usr/bin/ditto "$source" "$stage/$name"
  # Modes are not part of the signature. Give the copy an app's usual modes
  # instead of the store's read-only ones, which would stop the rename below
  # and a later removal for anyone but root.
  /bin/chmod -R u+w "$stage/$name"
  /usr/bin/codesign --verify --deep --strict -R "=$app_requirement" "$stage/$name" ||
    fail "the copy of $source in $stage failed its signature check"
  if [[ -e $target || -L $target ]]; then
    /bin/mv "$target" "$stage/previous" ||
      fail "could not move the old $target aside; allow your terminal under System Settings > Privacy & Security > App Management, then switch again"
  fi
  if ! /bin/mv "$stage/$name" "$target"; then
    [[ ! -e $stage/previous && ! -L $stage/previous ]] || /bin/mv "$stage/previous" "$target"
    fail "could not move the new copy of Automic Vault to $target"
  fi
  say "installed $target"
}

cli_current() {
  [[ -f $target && ! -L $target ]] || return 1
  local uid perms
  read -r uid perms < <(/usr/bin/stat -f '%u %Lp' "$target")
  [[ $uid == 0 && $perms == 755 ]] &&
    [[ $(/bin/ls -le "$target" | /usr/bin/wc -l) -eq 1 ]] &&
    /usr/bin/cmp -s "$source" "$target"
}

install_cli() {
  if cli_current; then
    return
  fi
  local dir
  while read -r dir; do
    [[ -e $dir ]] || /bin/mkdir -m 0755 "$dir"
  done < <(cli_dirs)
  make_stage
  /usr/bin/install -S -m 0755 -o root -g wheel "$source" "$stage/av"
  /bin/chmod -N "$stage/av"
  /usr/bin/codesign --verify --strict --all-architectures -R "=$cli_requirement" "$stage/av" ||
    fail "the copy of $source in $stage failed its signature check"
  /bin/mv -f "$stage/av" "$target"
  say "installed $target"
}

"check_$kind"
if [[ $mode == install ]]; then
  "install_$kind"
fi
