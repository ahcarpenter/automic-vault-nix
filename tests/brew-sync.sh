#!/usr/bin/env bash
# Tests brew-sync against a sample prefix and a stand-in for Automic Vault's brew.
#
# Usage: brew-sync.sh <brew-sync>
set -euo pipefail

sync="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# A brew that records each call and refuses the commands listed in $work/deny.
cat >"$work/brew" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$work/calls"
! grep -qxF -- "\$*" "$work/deny" 2>/dev/null
SH
chmod +x "$work/brew"

prefix="$work/prefix"
# Homebrew's library outside <prefix>/Library, as on Intel Macs.
library="$prefix/Homebrew/Library"
# ripgrep is installed under another name, as with a formula alias.
mkdir -p "$prefix/Cellar/jq" "$prefix/Cellar/ripgrep-all/1.0" "$prefix/opt" "$prefix/Caskroom" \
  "$library/Taps/acme/homebrew-tools"
ln -s ../Cellar/ripgrep-all/1.0 "$prefix/opt/ripgrep"

items=(
  trusted-tap:acme/tools trusted-tap:acme/extras tap:acme/private:https://git.example.com/acme/homebrew-private.git
  formula:jq formula:ripgrep formula:mosh trusted-formula:acme/extras/widget
  cask:claude-code@latest trusted-cask:acme/extras/gadget
)

# Only missing items are installed, in order, each trusted first when asked;
# a refused install warns and the rest still run.
rm -f "$work/calls"
echo "install --formula mosh" >"$work/deny"
"$sync" "$prefix" "$library" "$work/brew" "${items[@]}" 2>"$work/err" || fail "a refused install did not exit 0"
expected="trust --tap acme/extras
tap acme/extras
tap acme/private https://git.example.com/acme/homebrew-private.git
install --formula mosh
trust --formula acme/extras/widget
install --formula acme/extras/widget
install --cask claude-code@latest
trust --cask acme/extras/gadget
install --cask acme/extras/gadget"
[[ "$(cat "$work/calls")" == "$expected" ]] || fail "unexpected brew calls: $(cat "$work/calls")"
grep -q "warning: 'brew install --formula mosh' was denied or failed" "$work/err" || fail "refused install gave no warning naming the command"
grep -q "warning: not installed: mosh$" "$work/err" || fail "summary does not name what was not installed"
grep -q "installing formula acme/extras/widget" "$work/err" || fail "a trusted formula was not announced by its kind"

# A refused trust skips that tap's clone.
rm -f "$work/calls"
echo "trust --tap acme/extras" >"$work/deny"
"$sync" "$prefix" "$library" "$work/brew" trusted-tap:acme/extras 2>"$work/err" || fail "a refused trust did not exit 0"
[[ "$(cat "$work/calls")" == "trust --tap acme/extras" ]] || fail "tap ran after its trust was refused"

# With everything installed, brew is never called.
mkdir -p "$library/Taps/acme/homebrew-extras" "$library/Taps/acme/homebrew-private" "$prefix/Cellar/mosh" \
  "$prefix/Cellar/widget" "$prefix/Caskroom/claude-code@latest" "$prefix/Caskroom/gadget"
rm -f "$work/calls" "$work/deny"
"$sync" "$prefix" "$library" "$work/brew" "${items[@]}" 2>"$work/err" || fail "an up-to-date run did not exit 0"
[[ ! -e "$work/calls" ]] || fail "brew was called with everything installed: $(cat "$work/calls")"
grep -q "everything listed is installed" "$work/err" || fail "an up-to-date run did not say so"

# An unknown item is a usage error, and nothing is installed.
rm -f "$work/calls"
if "$sync" "$prefix" "$library" "$work/brew" formula:jq mas:12345 2>/dev/null; then
  fail "an unknown item did not fail"
fi
[[ ! -e "$work/calls" ]] || fail "brew was called despite an unknown item"

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all brew-sync tests passed"
