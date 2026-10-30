{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.automic-vault;

  # Automic Vault's own code hard-codes both paths: `av harden brew` copies its
  # brew stub out of the app there, and hardened tools run that av.
  appPath = "/Applications/Automic Vault.app";
  cliPath = "/usr/local/bin/av";

  sourceApp = "${cfg.package}/Applications/Automic Vault.app";

  installer = lib.getExe (pkgs.callPackage ./install.nix { });
  install =
    action:
    lib.concatMapStrings (target: ''
      ${installer} ${action} ${lib.escapeShellArgs target}
    '') cfg.installTargets;
in
{
  options.programs.automic-vault = {
    enable = lib.mkEnableOption "Automic Vault" // {
      description = ''
        Whether to install Automic Vault where its own code expects it: the app
        at {file}`/Applications/Automic Vault.app` and a root-owned copy of its
        {command}`av` CLI at {file}`/usr/local/bin/av`, as the app's own
        "Install av CLI" puts it. An app already at that path must be Automic
        Vault (any version). Automic Vault updates itself, so this package's
        version is a minimum: an older app or {command}`av` is replaced, but a
        newer one stays, and each switch warns that the package is behind.

        Do not also add the package to
        {option}`environment.systemPackages`, which would put a second copy of
        the app in {file}`/Applications/Nix Apps`.
      '';
    };

    package = lib.mkPackageOption pkgs "automic-vault" { };

    installTargets = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      internal = true;
      readOnly = true;
      description = ''
        What the checks and activation run the installer on, each as its
        kind, the packaged app and the path it installs to.
      '';
    };
  };

  config = lib.mkMerge [
    {
      programs.automic-vault.installTargets = lib.optionals cfg.enable [
        [
          "app"
          sourceApp
          appPath
        ]
        [
          "cli"
          sourceApp
          cliPath
        ]
      ];
    }

    (lib.mkIf cfg.enable {
      system.checks.text = install "check";

      system.activationScripts.applications.text = lib.mkAfter ''
        echo "setting up Automic Vault..." >&2
        ${install "install"}
      '';

      warnings = lib.optional (lib.elem cfg.package config.environment.systemPackages) ''
        programs.automic-vault installs Automic Vault itself; remove it from
        environment.systemPackages, which puts a second copy in
        /Applications/Nix Apps.
      '';
    })
  ];
}
