#!/usr/bin/env bash
# Install what's missing from the Homebrew lists through Automic Vault's brew.
#
# Usage: brew-sync <prefix> <library> <brew> <item>...
#
# Items are `tap:<name>[:<clone url>]`, `trusted-tap:<name>[:<clone url>]`,
# `formula:<name>`, `trusted-formula:<name>`, `cask:<name>` and
# `trusted-cask:<name>`, in install order. A trusted item is trusted with
# `brew trust` before it is tapped or installed. <library> is Homebrew's
# Library directory, which is not under <prefix> on every Mac
# (/usr/local/Homebrew/Library on Intel). Hardened Homebrew refuses
# `brew bundle`, so each missing item gets its own command through <brew>
# (Automic Vault's brew, which asks for approval). Installed items are left
# alone: nothing is upgraded or removed. A denied or failed install prints a
# warning and the rest carry on.
#
# Run it as yourself after a switch: Automic Vault's brew refuses root and
# asks for approval in your session.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: brew-sync <prefix> <library> <brew> <item>..." >&2
  exit 2
fi

prefix="$1"
library="$2"
brew="$3"
shift 3

say() {
  echo "brew-sync: $*" >&2
}

warn() {
  echo "brew-sync: warning: $*" >&2
}

installed() {
  local kind="$1" name="$2"
  local token="${name##*/}"
  case "$kind" in
    tap | trusted-tap)
      local owner="${name%%/*}" repo="${name#*/}"
      [[ -d "$library/Taps/${owner,,}/homebrew-${repo#homebrew-}" ]]
      ;;
    formula | trusted-formula) [[ -d "$prefix/Cellar/$token" || -e "$prefix/opt/$token" ]] ;;
    cask | trusted-cask) [[ -d "$prefix/Caskroom/$token" ]] ;;
  esac
}

for item in "$@"; do
  case "${item%%:*}" in
    tap | trusted-tap | formula | trusted-formula | cask | trusted-cask) ;;
    *)
      echo "brew-sync: unknown item '$item'" >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "brew-sync: run it as yourself, not root: Automic Vault's brew refuses root" >&2
  exit 2
fi

missing=0
failed=()
for item in "$@"; do
  kind="${item%%:*}"
  name="${item#*:}"
  url=""
  if [[ $kind == tap || $kind == trusted-tap ]] && [[ $name == *:* ]]; then
    url="${name#*:}"
    name="${name%%:*}"
  fi
  if installed "$kind" "$name"; then
    continue
  fi
  missing=$((missing + 1))

  commands=()
  case "$kind" in
    trusted-tap) commands=("trust --tap $name") ;;
    trusted-formula) commands=("trust --formula $name") ;;
    trusted-cask) commands=("trust --cask $name") ;;
  esac
  case "$kind" in
    tap | trusted-tap) commands+=("tap $name${url:+ $url}") ;;
    formula | trusted-formula) commands+=("install --formula $name") ;;
    cask | trusted-cask) commands+=("install --cask $name") ;;
  esac

  say "installing ${kind#trusted-} $name through Automic Vault's brew (approve it in Automic Vault)"
  for command in "${commands[@]}"; do
    # shellcheck disable=SC2086 # each command is brew's own words, split on purpose
    if ! "$brew" $command; then
      warn "'brew $command' was denied or failed; run it yourself to install $name"
      failed+=("$name")
      break
    fi
  done
done

if [[ $missing -eq 0 ]]; then
  say "everything listed is installed"
elif [[ ${#failed[@]} -gt 0 ]]; then
  warn "not installed: ${failed[*]}"
fi
