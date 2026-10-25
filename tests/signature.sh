#!/usr/bin/env bash
# Tests that the packaged app and av are Automic Vault's signed release,
# unchanged.
#
# Usage: signature.sh <package>
#
# It runs only bin/av, never code inside the app: macOS protects a notarized
# bundle once code in it has run, and the Nix daemon can then no longer
# delete the store path.
set -euo pipefail

package="$1"
app="$package/Applications/Automic Vault.app"
team="ZU76A67LGU"
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

requirement() {
  echo "anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"$1\""
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || fail "the app does not pass codesign --verify --deep --strict"

info=$(/usr/bin/codesign --display --verbose=2 "$app" 2>&1)
grep -qx "TeamIdentifier=$team" <<<"$info" || fail "the app's team is not $team: $info"
grep -qx "Identifier=com.automicvault" <<<"$info" || fail "the app's identifier is not com.automicvault: $info"

# The requirements the app and the CLI check each other against at runtime.
/usr/bin/codesign --verify --strict -R "=$(requirement com.automicvault)" "$app" ||
  fail "the app does not satisfy Automic Vault's own requirement"
for av in "$app/Contents/MacOS/av" "$package/bin/av"; do
  /usr/bin/codesign --verify --strict -R "=$(requirement com.automicvault.av)" "$av" ||
    fail "$av does not satisfy the requirement the app checks it against"
done
cmp -s "$app/Contents/MacOS/av" "$package/bin/av" || fail "bin/av differs from the app's av"

# Every executable in the bundle is signed by the same team.
while IFS= read -r -d '' file; do
  if [[ $(/usr/bin/file -b "$file") == Mach-O* ]]; then
    /usr/bin/codesign --verify --strict -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$file" ||
      fail "$file is not signed by $team"
  fi
done < <(find "$app" -type f -perm -u+x -print0)

# /usr/local/bin/av must report the CLI revision the app expects, or the app
# and `av harden` call it outdated.
expected=$(/usr/libexec/PlistBuddy -c "Print :AVCLIRevision" "$app/Contents/Info.plist")
actual=$("$package/bin/av" __version)
[[ $actual == "$expected" ]] || fail "av reports CLI revision $actual, the app expects $expected"

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all signature tests passed"
