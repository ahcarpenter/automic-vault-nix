{
  pkgs,
  nix-darwin,
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

  # These run Apple's own codesign, which a sandboxed build cannot reach.
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

  module = import ./module.nix { inherit pkgs nix-darwin module; };
}
