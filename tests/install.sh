#!/usr/bin/env bash
# Tests automic-vault-install against a scratch directory.
#
# Usage: install.sh <automic-vault-install> <app> <previous app>
#
# <previous app> is an older release, to test an upgrade and, as the package,
# an installed copy newer than it. The CLI half needs root, so past its
# refusals it runs the installer's own functions with the test user standing
# in for root.
set -euo pipefail

installer="$1"
source="$2"
previous="$3"
team="ZU76A67LGU"
# Without symlinks, such as macOS's /var, which no CLI directory may be.
work="$(cd "$(mktemp -d)" && pwd -P)"
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

# Runs the installer as root would, with the test user's files and
# directories counting as root's.
as_root() {
  (
    # shellcheck source=/dev/null
    source "$installer"
    # shellcheck disable=SC2329 # the installer calls these
    {
      protected() { true; }
      installed_as_root() { [[ -f $1 && ! -L $1 && $(/usr/bin/stat -f %Lp "$1") == 755 ]]; }
      install_as_root() { /usr/bin/install -m 0755 "$1" "$2"; }
    }
    main "$@"
  )
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

# A newer Automic Vault at the target stays, and check warns that the package is behind.
inode=$(/usr/bin/stat -f %i "$app")
"$installer" check app "$previous" "$app" 2>"$work/err" || fail "check refused a newer app: $(cat "$work/err")"
grep -qF "the package is behind: leaving $app at $(version "$source"), newer than the packaged $(version "$previous")" "$work/err" ||
  fail "check did not warn about a newer app: $(cat "$work/err")"
"$installer" install app "$previous" "$app" 2>"$work/err" || fail "install refused a newer app: $(cat "$work/err")"
[[ $(/usr/bin/stat -f %i "$app") == "$inode" ]] || fail "a newer app was replaced"
[[ ! -s $work/err ]] || fail "keeping a newer app printed: $(cat "$work/err")"

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
if "$installer" check cli "$source" "$app" "$work/bin/av" 2>"$work/err"; then
  fail "accepted a CLI directory that is not root-owned"
fi
grep -q "must be a root-owned directory" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"
[[ ! -e $work/bin ]] || fail "check created the CLI directory"

# The CLI of an app that is not Automic Vault is refused.
if "$installer" check cli "$other" "$app" "$work/bin/av" 2>"$work/err"; then
  fail "accepted the CLI of an app that is not Automic Vault"
fi
grep -q "is not a validly signed Automic Vault app" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"

# Versions compare number by number.
if ! (
  # shellcheck source=/dev/null
  source "$installer"
  newer 4.10.0 4.9.9 && newer 4.20.0.1 4.20 && ! newer 4.20 4.20.0 && ! newer 4.9.9 4.10.0 && ! dotted 4.22.0-beta
); then
  fail "versions do not compare number by number"
fi

# From here on, no app is installed unless a case says so.
apps="$work/cli/Applications"
app="$apps/Automic Vault.app"
cli="$work/cli/bin/av"
mkdir -p "$apps"

put_cli() {
  mkdir -p "$(dirname "$cli")"
  rm -f "$cli"
  /usr/bin/install -m 0755 "$1" "$cli"
}

# A check changes nothing, and a first install puts the packaged av in place.
as_root check cli "$source" "$app" "$cli" 2>"$work/err" || fail "check refused a missing CLI: $(cat "$work/err")"
[[ ! -e $work/cli/bin ]] || fail "check created the CLI directory"
as_root install cli "$source" "$app" "$cli" 2>"$work/err" || fail "a first CLI install failed: $(cat "$work/err")"
cmp -s "$source/Contents/MacOS/av" "$cli" || fail "a first CLI install did not install the packaged av"
[[ $(/usr/bin/stat -f %Lp "$cli") == 755 ]] || fail "the CLI has mode $(/usr/bin/stat -f %Lp "$cli"), not 755"
[[ $(ls -A "$work/cli/bin") == av ]] || fail "a CLI install left behind: $(ls -A "$work/cli/bin")"

# Installing the same CLI again leaves it alone, without a warning.
inode=$(/usr/bin/stat -f %i "$cli")
as_root check cli "$source" "$app" "$cli" 2>"$work/err" || fail "check refused an up-to-date CLI: $(cat "$work/err")"
as_root install cli "$source" "$app" "$cli" 2>>"$work/err" || fail "a repeated CLI install failed: $(cat "$work/err")"
[[ $(/usr/bin/stat -f %i "$cli") == "$inode" ]] || fail "an up-to-date CLI was replaced"
[[ ! -s $work/err ]] || fail "an up-to-date CLI printed: $(cat "$work/err")"

# An older av is replaced.
put_cli "$previous/Contents/MacOS/av"
as_root install cli "$source" "$app" "$cli" 2>"$work/err" || fail "a CLI upgrade failed: $(cat "$work/err")"
cmp -s "$source/Contents/MacOS/av" "$cli" || fail "a CLI upgrade did not install the packaged av"

# A newer av stays, and check warns that the package is behind.
inode=$(/usr/bin/stat -f %i "$cli")
as_root check cli "$previous" "$app" "$cli" 2>"$work/err" || fail "check refused a newer CLI: $(cat "$work/err")"
grep -qF "the package is behind: leaving $cli at $(version "$source"), newer than the packaged $(version "$previous")" "$work/err" ||
  fail "check did not warn about a newer CLI: $(cat "$work/err")"
as_root install cli "$previous" "$app" "$cli" 2>"$work/err" || fail "install refused a newer CLI: $(cat "$work/err")"
[[ $(/usr/bin/stat -f %i "$cli") == "$inode" ]] || fail "a newer CLI was replaced"
[[ ! -s $work/err ]] || fail "keeping a newer CLI printed: $(cat "$work/err")"

# A CLI that is not validly signed is replaced, and never run to read its version.
cat >"$work/fake-av" <<EOF
#!/bin/sh
touch "$work/ran"
echo "av 99.0"
EOF
put_cli "$work/fake-av"
as_root install cli "$source" "$app" "$cli" 2>"$work/err" || fail "replacing an unsigned CLI failed: $(cat "$work/err")"
cmp -s "$source/Contents/MacOS/av" "$cli" || fail "an unsigned CLI was not replaced"
[[ ! -e $work/ran ]] || fail "ran a CLI that is not validly signed"

# Next to a newer app, which stays, av comes from that app, never the older package.
/usr/bin/ditto "$source" "$app"
/bin/chmod -R u+w "$app"
for start in "$previous/Contents/MacOS/av" ""; do
  if [[ -n $start ]]; then put_cli "$start"; else rm -f "$cli"; fi
  as_root check cli "$previous" "$app" "$cli" 2>"$work/err" || fail "check refused a CLI next to a newer app: $(cat "$work/err")"
  [[ ! -s $work/err ]] || fail "check printed for a CLI it will replace: $(cat "$work/err")"
  as_root install cli "$previous" "$app" "$cli" 2>"$work/err" || fail "a CLI install next to a newer app failed: $(cat "$work/err")"
  cmp -s "$app/Contents/MacOS/av" "$cli" || fail "the CLI next to a newer app is not that app's av"
  as_root check cli "$previous" "$app" "$cli" 2>"$work/err" || fail "check refused the newer app's CLI: $(cat "$work/err")"
  grep -qF "the package is behind: leaving $cli at $(version "$app")" "$work/err" ||
    fail "check did not warn about the newer app's CLI: $(cat "$work/err")"
done

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all install tests passed"
