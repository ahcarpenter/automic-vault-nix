{
  pkgs,
  nix-darwin,
  nix-homebrew,
  automic-vault,
  module,
}:

let
  inherit (pkgs) lib;

  app = "${automic-vault}/Applications/Automic Vault.app";

  # An older release, to test replacing one install with another.
  previous =
    pkgs.runCommand "automic-vault-4.20.1-app"
      {
        nativeBuildInputs = [ pkgs.undmg ];
        src = pkgs.fetchurl {
          url = "https://github.com/automic-vault/automic-vault/releases/download/4.20.1/Automic-Vault-4.20.1.dmg";
          hash = "sha256-+kO+51BYUcEUv20PUElRoXroqXWCyXF5ovwjxjn9d20=";
        };
      }
      ''
        mkdir $out
        cd $out
        undmg $src
      '';

  # These run Apple's own codesign and dscl, which a sandboxed build cannot reach.
  impure = {
    __noChroot = true;
  };
in
{
  inherit automic-vault;

  signature = pkgs.runCommand "automic-vault-signature" impure ''
    bash ${./signature.sh} ${automic-vault}
    touch $out
  '';

  install = pkgs.runCommand "automic-vault-install-test" impure ''
    bash ${./install.sh} \
      ${lib.getExe (pkgs.callPackage ../modules/darwin/automic-vault/install.nix { })} \
      ${lib.escapeShellArg app} \
      ${lib.escapeShellArg "${previous}/Automic Vault.app"}
    touch $out
  '';

  brew-sync = pkgs.runCommand "brew-sync-test" { } ''
    bash ${./brew-sync.sh} ${
      lib.getExe (pkgs.callPackage ../modules/darwin/automic-vault/brew-sync.nix { })
    }
    touch $out
  '';

  check-hardened = pkgs.runCommand "automic-vault-check-hardened-test" impure ''
    bash ${./check-hardened.sh} ${
      lib.getExe (pkgs.callPackage ../modules/darwin/automic-vault/check-hardened.nix { })
    }
    touch $out
  '';

  # writeShellApplication already lints the module's own scripts.
  lint =
    pkgs.runCommand "automic-vault-lint"
      {
        nativeBuildInputs = [
          pkgs.nixfmt
          pkgs.shellcheck
        ];
      }
      ''
        cd ${../.}
        find . -name '*.nix' -exec nixfmt --check {} +
        shellcheck tests/*.sh
        touch $out
      '';

  module = import ./module.nix {
    inherit
      pkgs
      nix-darwin
      nix-homebrew
      module
      ;
  };
}
