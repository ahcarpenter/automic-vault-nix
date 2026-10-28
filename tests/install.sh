#!/usr/bin/env bash
# Tests automic-vault-install against a scratch directory.
#
# Usage: install.sh <automic-vault-install> <app> <previous app>
#
# <previous app> is an older release, to test an upgrade. The CLI half needs
# root-owned directories, so only its refusals are tested here.
set -euo pipefail

installer="$1"
source="$2"
previous="$3"
team="ZU76A67LGU"
work="$(mktemp -d)"
trap '/bin/chmod -R u+w "$work"; rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

genuine() {
  /usr/bin/codesign --verify --deep --strict \
    -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"com.automicvault\"" "$1"
}

version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"
}

apps="$work/Applications"
mkdir "$apps"
app="$apps/Automic Vault.app"

# A check changes nothing.
"$installer" check app "$source" "$app" || fail "check refused an empty target"
[[ ! -e $app ]] || fail "check created the app"

# A first install copies the app, signature intact, and leaves nothing else behind.
"$installer" install app "$source" "$app" 2>"$work/err" || fail "a first install failed: $(cat "$work/err")"
genuine "$app" || fail "the installed app does not verify"
[[ $(version "$app") == "$(version "$source")" ]] || fail "installed $(version "$app"), not $(version "$source")"
[[ $(ls -A "$apps") == "Automic Vault.app" ]] || fail "left behind: $(ls -A "$apps")"

# Installing the same app again leaves it alone.
inode=$(/usr/bin/stat -f %i "$app")
"$installer" install app "$source" "$app" 2>"$work/err" || fail "a repeated install failed: $(cat "$work/err")"
[[ $(/usr/bin/stat -f %i "$app") == "$inode" ]] || fail "an up-to-date app was replaced"
[[ ! -s $work/err ]] || fail "an up-to-date install printed: $(cat "$work/err")"

# The installed copy has an app's usual modes, not the store's read-only ones.
[[ -w $app && -w $app/Contents/Info.plist ]] || fail "the installed app is read-only"

# An older Automic Vault at the target is replaced.
rm -rf "$app"
/usr/bin/ditto "$previous" "$app"
/bin/chmod -R u+w "$app"
[[ $(version "$app") != "$(version "$source")" ]] || fail "the previous app is the same version as the source"
"$installer" install app "$source" "$app" 2>"$work/err" || fail "an upgrade failed: $(cat "$work/err")"
[[ $(version "$app") == "$(version "$source")" ]] || fail "the upgrade left $(version "$app")"
genuine "$app" || fail "the upgraded app does not verify"
[[ $(ls -A "$apps") == "Automic Vault.app" ]] || fail "an upgrade left behind: $(ls -A "$apps")"

# Anything else at the target is left alone.
other="$work/Other/Automic Vault.app"
mkdir -p "$other/Contents"
echo keep >"$other/Contents/file"
if "$installer" install app "$source" "$other" 2>"$work/err"; then
  fail "replaced a bundle that is not Automic Vault"
fi
grep -q "is in the way and is not a validly signed Automic Vault" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"
[[ $(cat "$other/Contents/file") == keep ]] || fail "changed a bundle that is not Automic Vault"

# An unsigned source is refused.
if "$installer" check app "$other" "$work/target.app" 2>"$work/err"; then
  fail "accepted an unsigned source app"
fi
grep -q "is not a validly signed Automic Vault app" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"

# The CLI is refused in a directory that is not root-owned.
if "$installer" check cli "$source/Contents/MacOS/av" "$work/bin/av" 2>"$work/err"; then
  fail "accepted a CLI directory that is not root-owned"
fi
grep -q "must be a root-owned directory" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"
[[ ! -e $work/bin ]] || fail "check created the CLI directory"

# A CLI that is not Automic Vault's is refused.
if "$installer" check cli "$source/Contents/MacOS/AutomicVaultMenubar" /usr/local/bin/av 2>"$work/err"; then
  fail "accepted a CLI that is not av"
fi
grep -q "is not a validly signed av CLI" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all install tests passed"
