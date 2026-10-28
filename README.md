# automic-vault-nix

A Nix package and a nix-darwin module for [Automic Vault](https://github.com/automic-vault/automic-vault),
the macOS credential vault that ships as an app plus the `av` command-line tool.

> [!WARNING]
> Experimental, and private for now. The goal is to propose the package to
> [nixpkgs](https://github.com/NixOS/nixpkgs) (and the module to
> [nix-darwin](https://github.com/nix-darwin/nix-darwin)) once it has proven
> itself. Nothing has been proposed upstream yet.

It provides:

- `packages.aarch64-darwin.automic-vault`: Automic Vault's signed release,
  repackaged unchanged. It holds `Applications/Automic Vault.app` and `bin/av`.
  It is written as a nixpkgs `pkgs/by-name` package so it can be proposed
  with little change.
- `overlays.default`, which adds `automic-vault` to nixpkgs.
- `darwinModules.default`: `programs.automic-vault`, which installs the app
  and the CLI where Automic Vault expects them.

## Why the signed release, not a build from source

Automic Vault is open source (Apache-2.0, Rust and Swift), but its security
model is tied to its code signature. The app and the CLI only trust each other
when signed by Automic Vault's team (`ZU76A67LGU`) with identifiers
`com.automicvault` and `com.automicvault.av`. The app also holds keychain
entitlements granted to that team by an embedded provisioning profile. A build
from source cannot carry that signature, so it would install but not work. The
package therefore repackages the notarized DMG, pinned by the hash in the
release's `SHA256SUMS`, without changing a byte of it
(`meta.sourceProvenance = binaryNativeCode`).

Upstream only ships an Apple silicon build, so the package is `aarch64-darwin`
only.

## Where Automic Vault has to live

Automic Vault's code hard-codes two paths:

- `/Applications/Automic Vault.app`. `av harden brew` copies its guarded
  `brew` stub out of this exact path, and fails without it.
- `/usr/local/bin/av`. Hardened tools are scripts starting
  `#!/usr/local/bin/av`, and `av harden` elevates this copy with `sudo`. It must be a
  root-owned regular file (not a symlink), mode `0755`, without an ACL, in
  directories only root can write, and report the CLI revision the app
  expects. Otherwise the app and `av doctor` treat it as outdated.

nix-darwin puts apps in `/Applications/Nix Apps`, and `nix profile` puts them
in `~/.nix-profile/Applications`, so neither is enough on its own. That is what
the module is for.

## nix-darwin

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    automic-vault.url = "github:ahcarpenter/automic-vault-nix";
    automic-vault.inputs.nixpkgs.follows = "nixpkgs";
    # Only the checks use nix-darwin.
    automic-vault.inputs.nix-darwin.follows = "nix-darwin";
  };

  outputs = { nix-darwin, automic-vault, ... }: {
    darwinConfigurations.mac = nix-darwin.lib.darwinSystem {
      modules = [
        automic-vault.darwinModules.default
        { programs.automic-vault.enable = true; }
        # ...
      ];
    };
  };
}
```

`programs.automic-vault.enable`:

- copies the app to `/Applications/Automic Vault.app`. Anything already there
  must be a validly signed Automic Vault (any version, for example a manual
  install), or the switch stops before changing anything. An identical app is
  left alone. A different one is replaced: a verified copy is staged next to
  it and swapped in with a rename.
- installs `/usr/local/bin/av` the way the app's own "Install av CLI" does.

Do not also add the package to `environment.systemPackages`: that would put a
second copy of the app in `/Applications/Nix Apps`. The module warns if you do.

The module leaves `PATH` alone. nix-darwin's default `PATH` already has
`/usr/local/bin`, after the Nix profiles, so `av` finds the installed copy.
Tools you harden with `av harden` also go in `/usr/local/bin`, and Automic
Vault needs that directory ahead of any other copy of the same tool;
`av doctor <tool>` reports one that is shadowed. If you also install such a
tool through Nix or Homebrew, order `PATH` yourself, for example with
`environment.systemPath = lib.mkBefore [ "/usr/local/bin" ];`.

## nix profile

```sh
nix profile add github:ahcarpenter/automic-vault-nix
```

This puts `av` on your `PATH` (`nix profile install` on older Nix). To use
the app, copy it to where Automic Vault expects it, rather than opening it from
the Nix store (see [Known limits](#known-limits)):

```sh
ditto ~/.nix-profile/Applications/Automic\ Vault.app /Applications/Automic\ Vault.app
chmod -R u+w /Applications/Automic\ Vault.app
open /Applications/Automic\ Vault.app
```

Then choose "Install av CLI" in its menu to get `/usr/local/bin/av`. Nix does
not update that copy; the nix-darwin module does.

## What is verified

`nix flake check` builds and runs:

- `automic-vault`: the package, whose build checks that `bin/av --version`
  reports the packaged version.
- `signature`: `codesign --verify --deep --strict` passes on the app; the app
  reports team `ZU76A67LGU` and identifier `com.automicvault`; the app and `av`
  satisfy the code requirements they check each other against; every
  executable in the bundle is signed by that team. It also checks that `bin/av` matches
  the app's `av` and reports the CLI revision the app expects.
- `install`: the module's installer, run against a scratch directory. A first
  install verifies; a second is a no-op; the 4.20.1 release is upgraded in place;
  anything that is not Automic Vault is left alone. An unsigned source, a CLI
  directory that is not root-owned and a CLI that is not `av` are all refused.
- `module`: the nix-darwin module evaluated off and enabled. It checks what
  each sets, that each system evaluates, and that the snippets it adds to
  activation pass `shellcheck`.
- `lint`: `nixfmt` and `shellcheck`.

The checks call Apple's `/usr/bin/codesign`, so they need the Nix sandbox off
or `relaxed` (the default on macOS is off).

Checked by hand on a Mac running Automic Vault 4.20.2:

- The packaged app is byte-identical to the installed `/Applications/Automic Vault.app`, and
  `bin/av` to the installed `/usr/local/bin/av`.
- The module's checks pass against that install, and its installer leaves a
  copy of it untouched.
- `nix-update` finds new releases, and the hash it writes for 4.20.1 matches
  that release's `SHA256SUMS`.

## Known limits

- **Do not open the app from the Nix store.** Once code inside a notarized bundle
  has run, macOS marks the bundle (`com.apple.macl`). The Nix daemon can then
  no longer change its permissions to delete it, so garbage collection of that
  store path fails with "Operation not permitted". Run it from
  `/Applications`, as the module and the `nix profile` steps above do. `bin/av` is
  a copy outside the bundle for the same reason, and running it is safe.
- **Updates come from Nix.** With the module, every switch resets the app to
  the pinned version, so update the flake input rather than using the app's own
  "Update to …".
- **After an upgrade, quit and reopen Automic Vault.** The running menu bar app
  keeps the old version until it restarts.
- **Replacing the app needs App Management.** The terminal you run
  `darwin-rebuild` from needs permission under System Settings > Privacy &
  Security > App Management, as nix-darwin needs for `/Applications/Nix Apps`.

## Updating

```sh
nix run nixpkgs#nix-update -- --flake automic-vault --use-github-releases
nix flake check
```

Compare the new hash with the release's `SHA256SUMS` before committing.

## License

The Nix code in this repository is licensed under the Apache License 2.0 (see
[LICENSE](LICENSE)). Automic Vault itself carries its own Apache-2.0 license.
