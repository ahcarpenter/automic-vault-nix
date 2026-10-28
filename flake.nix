{
  description = "Nix package and nix-darwin module for Automic Vault";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Only the checks use this, to evaluate the nix-darwin module.
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [ "aarch64-darwin" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        automic-vault = pkgs.callPackage ./pkgs/by-name/au/automic-vault/package.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.automic-vault;
      });

      overlays.default = final: prev: {
        automic-vault = final.callPackage ./pkgs/by-name/au/automic-vault/package.nix { };
      };

      darwinModules = {
        automic-vault =
          { lib, pkgs, ... }:
          {
            imports = [ ./modules/darwin/automic-vault ];
            programs.automic-vault.package = lib.mkDefault (
              pkgs.callPackage ./pkgs/by-name/au/automic-vault/package.nix { }
            );
          };
        default = self.darwinModules.automic-vault;
      };

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs nix-darwin;
          automic-vault = self.packages.${pkgs.stdenv.hostPlatform.system}.automic-vault;
          module = self.darwinModules.default;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
