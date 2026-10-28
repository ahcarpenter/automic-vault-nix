# automic-vault-nix

A Nix package and nix-darwin module for [Automic Vault](https://github.com/automic-vault/automic-vault),
the macOS credential vault that ships as a menu bar app plus the `av` CLI.

Automic Vault's app and `av` check each other's code signature at runtime, so
the package is the signed release repackaged unchanged, for Apple silicon only.
Automic Vault also expects the app at `/Applications/Automic Vault.app` and a
root-owned `av` at `/usr/local/bin/av`, which neither
`environment.systemPackages` nor `nix profile` provides. The module puts both
where they belong.

Experimental. The plan is to propose the package to
[nixpkgs](https://github.com/NixOS/nixpkgs) and the module to
[nix-darwin](https://github.com/nix-darwin/nix-darwin) once it has proven
itself.

## nix-darwin

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    automic-vault.url = "github:ahcarpenter/automic-vault-nix";
    automic-vault.inputs.nixpkgs.follows = "nixpkgs";
    automic-vault.inputs.nix-darwin.follows = "nix-darwin"; # only its checks use it
  };

  outputs = { nix-darwin, automic-vault, ... }: {
    darwinConfigurations.mac = nix-darwin.lib.darwinSystem {
      modules = [
        automic-vault.darwinModules.default
        { programs.automic-vault.enable = true; }
      ];
    };
  };
}
```

`programs.automic-vault.enable` copies the app to `/Applications/Automic Vault.app`
and installs `/usr/local/bin/av` the way the app's own "Install av CLI" does.
Whatever is already at the app path must be Automic Vault (any version, for
example a manual install), or the switch stops before changing anything; it is
replaced when it differs from the packaged one. Every switch resets the app to
the packaged version, so update the flake input instead of using the app's own
updater.

> [!IMPORTANT]
> Do not also add the package to `environment.systemPackages`. That puts a
> second copy of the app in `/Applications/Nix Apps`; the module warns if you do.

The module leaves `PATH` alone: nix-darwin's default already has `/usr/local/bin`
after the Nix profiles, so `av` is found. Automic Vault's hardened command links
also live in `/usr/local/bin` and must come before any Nix or Homebrew copy of
the same command (`av doctor <command>` checks). If you install such a tool
through Nix too, put `/usr/local/bin` first:

```nix
environment.systemPath = lib.mkBefore [ "/usr/local/bin" ];
```

## nix profile

```sh
nix profile add github:ahcarpenter/automic-vault-nix
```

This puts `av` on your `PATH` (`nix profile install` on older Nix). Copy the
app to where Automic Vault expects it instead of opening it from the Nix store:
once code in a notarized bundle has run, macOS protects the bundle and Nix can
no longer garbage-collect that store path.

```sh
ditto ~/.nix-profile/Applications/Automic\ Vault.app /Applications/Automic\ Vault.app
chmod -R u+w /Applications/Automic\ Vault.app
open /Applications/Automic\ Vault.app
```

Then choose "Install av CLI" in the app to get `/usr/local/bin/av`. Nix does
not update that copy; the module does.

## Flake outputs

- `packages.aarch64-darwin.automic-vault` (also `default`):
  `Applications/Automic Vault.app` and `bin/av` from the signed release.
- `overlays.default`: adds `automic-vault` to nixpkgs.
- `darwinModules.default`: the `programs.automic-vault` module.

## Development

`nix flake check` builds the package and runs the signature, installer, module
and lint checks. They call Apple's `codesign`, so the Nix sandbox must be off
or `relaxed`. To move to a new release, run the update script and compare the
hash it writes with the release's `SHA256SUMS`:

```sh
nix run nixpkgs#nix-update -- --flake automic-vault --use-github-releases
```

## License

[Apache-2.0](LICENSE). Automic Vault itself is Apache-2.0 as well.
