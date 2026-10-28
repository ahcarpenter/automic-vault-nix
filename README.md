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
  and the CLI where Automic Vault expects them and can run a Mac whose
  Homebrew is hardened by `av harden brew`.

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
    automic-vault.inputs.nix-darwin.follows = "nix-darwin";
    # Only the checks use nix-darwin and nix-homebrew; with nix-homebrew,
    # also add: automic-vault.inputs.nix-homebrew.follows = "nix-homebrew";
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
- puts `/usr/local/bin` first in `PATH`, as Automic Vault asks for the tools
  it hardens there.

Do not also add the package to `environment.systemPackages`: that would put a
second copy of the app in `/Applications/Nix Apps`. The module warns if you do.

### Hardened Homebrew

Once you have run `av harden brew`, set:

```nix
{
  programs.automic-vault.homebrew.hardened = true;
}
```

This only declares that Homebrew is hardened; it never hardens it. Keep it
`false` on a Mac where `av harden brew` has not run, including a fresh one:
the switch stops if there is no `automic` user or `vault` group. When it is
`true`:

- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew), if imported,
  sets up the Homebrew prefix as Automic Vault's `automic` user and `vault`
  group from the start, so nothing changes ownership afterwards. Its
  `brew shellenv` shell hooks are turned off. Its `/usr/local` prefix, which
  `enableRosetta` or an Intel Mac turns on, must be off: it would put
  Homebrew's `brew` where the guarded one lives and hand `/usr/local/bin`,
  which must stay root-owned, to `automic:vault`, so evaluation fails if both
  are set.
- nix-darwin's own Homebrew module is turned off rather than overridden,
  because hardened Homebrew refuses `brew bundle` and root.
- A `brew-sync` command installs whatever is missing from `homebrew.taps`,
  `homebrew.brews` and `homebrew.casks` through the guarded
  `/usr/local/bin/brew`, one approval per command, two for trusted items. Run
  it as yourself after each switch:

  ```sh
  sudo darwin-rebuild switch --flake .#mac && brew-sync
  ```

  It installs by name, trusting taps and fully qualified formulae and casks
  where nix-darwin would. It never upgrades or removes anything. A denied or
  failed item prints a warning and the rest carry on.
- `/usr/local/bin`, then Homebrew's `bin` and `sbin`, come first in `PATH`,
  and `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR` and `INFOPATH` are set, in place of
  `brew shellenv`.

`homebrew.masApps`, `vscode`, `goPackages`, `cargoPackages` and `extraConfig`
are not installed when hardened; the module warns if any are set.

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
- `brew-sync`: against a sample prefix and a stand-in `brew`. It covers install
  order, trust, clone URLs, refusals and an up-to-date run.
- `check-hardened`: the switch-time check for the `automic` user and `vault`
  group, run with `root` and `wheel`, which every Mac has, and with names no
  Mac has.
- `module`: the nix-darwin module evaluated with it off, enabled and hardened,
  with and without nix-homebrew. It checks what each sets, that each system
  evaluates, and that the snippets it adds to activation pass `shellcheck`.
- `lint`: `nixfmt` and `shellcheck`.

The checks call Apple's `/usr/bin/codesign` and `/usr/bin/dscl`, so they need the Nix sandbox off
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
- `brew-sync` has only run against a stand-in `brew` in tests, not against the
  guarded one.

## Updating

```sh
nix run nixpkgs#nix-update -- --flake automic-vault --use-github-releases
nix flake check
```

Compare the new hash with the release's `SHA256SUMS` before committing.

## License

The Nix code in this repository is licensed under the Apache License 2.0 (see
[LICENSE](LICENSE)). Automic Vault itself carries its own Apache-2.0 license.
