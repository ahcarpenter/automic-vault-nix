#!/usr/bin/env bash
# Install Automic Vault where its own code expects it.
#
# Usage: automic-vault-install check|install app <source app> <app>
#        automic-vault-install check|install cli <source app> <cli>
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
# (any version), or nothing is replaced. `install cli` installs the av from
# <source app> at <cli> the way the app's own "Install av CLI" does.
#
# Neither downgrades, as Automic Vault updates itself: a validly signed <app> or
# <cli> newer than <source app> stays, each judged on its own, and `check` warns
# that the package is behind for each newer copy it leaves.
set -euo pipefail

team="ZU76A67LGU"
app_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"com.automicvault\""
cli_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"com.automicvault.av\""

mode=""
kind=""
source_app=""
app=""
cli=""
packaged=""  # <source app>'s version
installed="" # <app>'s version, when it is a validly signed Automic Vault
source=""    # <source app>'s av
kept=""      # the version left in place, when `install` has nothing to do

fail() {
  echo "automic-vault: error: $*" >&2
  exit 1
}

say() {
  echo "automic-vault: $*" >&2
}

# Only `check` warns: every activation runs it right before `install`, so a
# switch warns once.
behind() {
  if [[ $mode == check ]]; then
    echo "automic-vault: warning: the package is behind: leaving $1 at $2, newer than the packaged $packaged" >&2
  fi
}

# A scratch directory next to $1, so the final move is a rename.
stage=""
cleanup() {
  if [[ -n $stage ]]; then
    # Copies out of the Nix store are read-only, which only stops non-root.
    /bin/rm -rf "$stage" 2>/dev/null || { /bin/chmod -R u+w "$stage" && /bin/rm -rf "$stage"; }
  fi
}

make_stage() {
  stage=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$1")/.automic-vault.XXXXXXXX")
}

# Root-owned, not writable by group or others, and without an ACL, as the
# app's installer requires of each directory above /usr/local/bin/av.
protected() {
  local uid perms
  read -r uid perms < <(/usr/bin/stat -f '%u %Lp' "$1")
  [[ $uid == 0 ]] && (((8#$perms & 8#022) == 0)) && [[ $(/bin/ls -lde "$1" | /usr/bin/wc -l) -eq 1 ]]
}

# A root-owned regular file with mode 0755 and no ACL, as the app's installer
# leaves /usr/local/bin/av.
installed_as_root() {
  [[ -f $1 && ! -L $1 ]] || return 1
  local uid perms
  read -r uid perms < <(/usr/bin/stat -f '%u %Lp' "$1")
  [[ $uid == 0 && $perms == 755 ]] && [[ $(/bin/ls -le "$1" | /usr/bin/wc -l) -eq 1 ]]
}

# Copies $1 to $2 the way installed_as_root expects.
install_as_root() {
  /usr/bin/install -S -m 0755 -o root -g wheel "$1" "$2"
  /bin/chmod -N "$2"
}

# The directories that hold <cli>, from / down.
cli_dirs() {
  local dir dirs=()
  dir=$(/usr/bin/dirname "$cli")
  while [[ $dir != / ]]; do
    dirs=("$dir" "${dirs[@]}")
    dir=$(/usr/bin/dirname "$dir")
  done
  printf '%s\n' / "${dirs[@]}"
}

cdhash() {
  /usr/bin/codesign --display --verbose=3 "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'
}

# A version such as 4.21.2, which compares number by number.
dotted() {
  [[ $1 =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# Whether version $1 is newer than version $2.
newer() {
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    if ((10#${a[i]:-0} != 10#${b[i]:-0})); then
      ((10#${a[i]:-0} > 10#${b[i]:-0}))
      return
    fi
  done
  return 1
}

# The version of the app at $1, from the Info.plist its signature seals.
app_version() {
  local version
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist") &&
    dotted "$version" &&
    echo "$version"
}

# The version <cli> prints. It runs <cli>, so only call it once <cli> is
# installed as root and signed as av.
cli_version() {
  local output
  output=$("$cli" --version </dev/null) || return
  [[ $output == "av "* ]] && dotted "${output#av }" && echo "${output#av }"
}

# Whether <app> is a validly signed Automic Vault with every file intact.
# Sets $installed to its version, failing rather than guessing when it has
# none, since a newer one must never be downgraded.
app_genuine() {
  installed=""
  if [[ ! -d $app || -L $app ]] ||
    ! /usr/bin/codesign --verify --deep --strict -R "=$app_requirement" "$app" 2>/dev/null; then
    return 1
  fi
  installed=$(app_version "$app") || fail "could not read a version number from $app"
}

check_app() {
  if [[ -e $app || -L $app ]] && ! /usr/bin/codesign --verify -R "=$app_requirement" "$app" 2>/dev/null; then
    fail "$app is in the way and is not a validly signed Automic Vault; move it aside"
  fi
  if app_genuine; then
    if newer "$installed" "$packaged"; then
      kept=$installed
      behind "$app" "$installed"
    # The same signed code: equal code directory hashes cover the executable,
    # Info.plist and the sealed resource list, and app_genuine's strict deep
    # verify proves the installed files still match that list.
    elif [[ $(cdhash "$app") == "$(cdhash "$source_app")" ]]; then
      kept=$installed
    fi
  fi
}

check_cli() {
  local dir version
  while read -r dir; do
    if [[ -e $dir || -L $dir ]] && ! { [[ -d $dir && ! -L $dir ]] && protected "$dir"; }; then
      fail "$dir must be a root-owned directory that only root can write and that has no ACL, to hold $cli"
    fi
  done < <(cli_dirs)
  if [[ -d $cli || -L $cli ]]; then
    fail "$cli is a directory or a symlink; remove it so the av CLI can be installed there"
  fi

  /usr/bin/codesign --verify --strict -R "=$cli_requirement" "$source" ||
    fail "$source is not a validly signed av CLI"

  # <cli> stays when it is the packaged av already, or a validly signed av newer still.
  if installed_as_root "$cli" && /usr/bin/cmp -s "$source" "$cli"; then
    kept=$packaged
  elif installed_as_root "$cli" && /usr/bin/codesign --verify --strict -R "=$cli_requirement" "$cli" 2>/dev/null; then
    version=$(cli_version) || fail "could not read a version number from $cli --version"
    if newer "$version" "$packaged"; then
      kept=$version
      behind "$cli" "$version"
    fi
  fi
}

install_app() {
  local name
  make_stage "$app"
  name=$(/usr/bin/basename "$app")
  /usr/bin/ditto "$source_app" "$stage/$name"
  # Modes are not part of the signature. Give the copy an app's usual modes
  # instead of the store's read-only ones, which would stop the rename below
  # and a later removal for anyone but root.
  /bin/chmod -R u+w "$stage/$name"
  /usr/bin/codesign --verify --deep --strict -R "=$app_requirement" "$stage/$name" ||
    fail "the copy of $source_app in $stage failed its signature check"
  if [[ -e $app || -L $app ]]; then
    /bin/mv "$app" "$stage/previous" ||
      fail "could not move the old $app aside; allow your terminal under System Settings > Privacy & Security > App Management, then switch again"
  fi
  if ! /bin/mv "$stage/$name" "$app"; then
    [[ ! -e $stage/previous && ! -L $stage/previous ]] || /bin/mv "$stage/previous" "$app"
    fail "could not move the new copy of Automic Vault to $app"
  fi
  say "installed $app $packaged"
}

install_cli() {
  local dir
  while read -r dir; do
    [[ -e $dir ]] || /bin/mkdir -m 0755 "$dir"
  done < <(cli_dirs)
  make_stage "$cli"
  install_as_root "$source" "$stage/av"
  /usr/bin/codesign --verify --strict --all-architectures -R "=$cli_requirement" "$stage/av" ||
    fail "the copy of $source in $stage failed its signature check"
  /bin/mv -f "$stage/av" "$cli"
  say "installed $cli $packaged"
}

main() {
  if [[ $# -ne 4 ]] || [[ $1 != check && $1 != install ]] || [[ $2 != app && $2 != cli ]]; then
    echo "usage: automic-vault-install check|install app <source app> <app>" >&2
    echo "       automic-vault-install check|install cli <source app> <cli>" >&2
    exit 2
  fi
  mode="$1"
  kind="$2"
  source_app="$3"
  source="$source_app/Contents/MacOS/av"
  if [[ $kind == app ]]; then
    app="$4"
  else
    cli="$4"
  fi
  trap cleanup EXIT

  /usr/bin/codesign --verify --deep --strict -R "=$app_requirement" "$source_app" ||
    fail "$source_app is not a validly signed Automic Vault app"
  packaged=$(app_version "$source_app") || fail "could not read a version number from $source_app"

  "check_$kind"
  if [[ $mode == install && -z $kept ]]; then
    "install_$kind"
  fi
}

# The tests source this file to stand in for root.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
