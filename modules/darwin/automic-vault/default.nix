{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.programs.automic-vault;
  brew = config.homebrew;

  # Automic Vault's own code hard-codes both paths: `av harden brew` copies its
  # brew stub out of the app there, and hardened tools run that av.
  appPath = "/Applications/Automic Vault.app";
  cliPath = "/usr/local/bin/av";
  # Installed by `av harden brew`; once there, it is the only brew that may
  # change Homebrew.
  brewStub = "/usr/local/bin/brew";

  sourceApp = lib.escapeShellArg "${cfg.package}/Applications/Automic Vault.app";

  installer = lib.getExe (pkgs.callPackage ./install.nix { });
  install = action: ''
    ${installer} ${action} app ${sourceApp} ${lib.escapeShellArg appPath}
    ${installer} ${action} cli ${sourceApp}/Contents/MacOS/av ${cliPath}
  '';

  hasNixHomebrew = options ? nix-homebrew;
  nixHomebrewPrefix =
    if hasNixHomebrew && config.nix-homebrew.enable then
      config.nix-homebrew.prefixes.${brew.prefix} or null
    else
      null;
  # Homebrew's Library directory, which is not under the prefix on Intel Macs.
  brewLibrary =
    if nixHomebrewPrefix != null then
      nixHomebrewPrefix.library
    else if brew.prefix == "/usr/local" then
      "/usr/local/Homebrew/Library"
    else
      "${brew.prefix}/Library";

  # Like nix-darwin's Homebrew module, trust a formula or cask on its own only
  # when its name is fully qualified (`user/repo/name`).
  qualified = name: lib.length (lib.splitString "/" name) == 3;
  tapItem =
    tap:
    "${lib.optionalString (tap.trusted or false) "trusted-"}tap:${tap.name}"
    + lib.optionalString (tap.clone_target != null) ":${tap.clone_target}";
  packageItem =
    kind: entry:
    let
      trusted = (entry.trusted or false) && qualified entry.name;
    in
    "${lib.optionalString trusted "trusted-"}${kind}:${entry.name}";

  brewSync = pkgs.callPackage ./brew-sync.nix { };
  brewSyncCommand = pkgs.writeShellScriptBin "brew-sync" ''
    exec ${lib.getExe brewSync} ${
      lib.escapeShellArgs (
        [
          brew.prefix
          brewLibrary
          brewStub
        ]
        ++ map tapItem brew.taps
        ++ map (packageItem "formula") brew.brews
        ++ map (packageItem "cask") brew.casks
      )
    }
  '';

  # What nix-darwin's Homebrew step installs that brew-sync does not.
  isEmpty = value: value == [ ] || value == { } || value == "";
  unsyncedLists = lib.filter (name: brew ? ${name} && !isEmpty brew.${name}) [
    "masApps"
    "vscode"
    "goPackages"
    "cargoPackages"
    "extraConfig"
  ];
in
{
  options.programs.automic-vault = {
    enable = lib.mkEnableOption "Automic Vault" // {
      description = ''
        Whether to install Automic Vault where its own code expects it: the app
        at {file}`/Applications/Automic Vault.app` and a root-owned copy of its
        {command}`av` CLI at {file}`/usr/local/bin/av`, as the app's own
        "Install av CLI" puts it. An app already at that path must be Automic
        Vault (any version); it is replaced when it differs from this
        package's.

        This also puts {file}`/usr/local/bin` first in {env}`PATH`, where
        Automic Vault puts the tools it hardens.

        Do not also add the package to
        {option}`environment.systemPackages`, which would put a second copy of
        the app in {file}`/Applications/Nix Apps`.
      '';
    };

    package = lib.mkPackageOption pkgs "automic-vault" { };

    homebrew.hardened = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether {command}`av harden brew` has hardened this Mac's Homebrew,
        handing its prefix to Automic Vault's `automic` user and `vault` group
        and putting a guarded {command}`brew` at {file}`/usr/local/bin/brew`.
        This does not harden Homebrew; run {command}`av harden brew` first,
        then set this. Keep it false on a Mac where that hasn't happened,
        including a fresh one.

        When true:

        - nix-homebrew, if imported, sets up the prefix as `automic:vault`
          from the start, with its shell integrations off.
        - nix-darwin's Homebrew module is turned off, since hardened Homebrew
          refuses {command}`brew bundle` and root.
        - {command}`brew-sync` installs what is missing from
          {option}`homebrew.taps`, {option}`homebrew.brews` and
          {option}`homebrew.casks` through the guarded {command}`brew`, one
          approval per item. Run it as yourself after each switch. It
          installs by name and never upgrades or removes anything.
        - {file}`/usr/local/bin` and then Homebrew's own {file}`bin` and
          {file}`sbin` come first in {env}`PATH`, in place of
          {command}`brew shellenv`.
      '';
    };
  };

  config = lib.mkMerge [
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

    (lib.mkIf (cfg.enable || cfg.homebrew.hardened) {
      environment.systemPath = lib.mkBefore (
        [ "/usr/local/bin" ]
        ++ lib.optionals cfg.homebrew.hardened [
          "${brew.prefix}/bin"
          "${brew.prefix}/sbin"
        ]
      );
    })

    (lib.mkIf cfg.homebrew.hardened (
      lib.mkMerge [
        {
          system.checks.text = ''
            if ! /usr/bin/dscl . -read /Users/automic UniqueID >/dev/null 2>&1 \
              || ! /usr/bin/dscl . -read /Groups/vault PrimaryGroupID >/dev/null 2>&1; then
              printf >&2 '\e[1;31merror: programs.automic-vault.homebrew.hardened is set, but there is no automic user or vault group\e[0m\n'
              printf >&2 'Run `av harden brew` first, or set it to false.\n'
              exit 2
            fi
          '';

          homebrew.enable = lib.mkForce false;

          environment.systemPackages = [ brewSyncCommand ];
          environment.variables = {
            HOMEBREW_PREFIX = brew.prefix;
            HOMEBREW_CELLAR = "${brew.prefix}/Cellar";
            INFOPATH = "${brew.prefix}/share/info:";
          };

          warnings = lib.optional (unsyncedLists != [ ]) ''
            With programs.automic-vault.homebrew.hardened, brew-sync installs only
            homebrew.taps, homebrew.brews and homebrew.casks; nothing installs
            ${lib.concatMapStringsSep ", " (name: "homebrew.${name}") unsyncedLists}.
          '';
        }

        (lib.optionalAttrs hasNixHomebrew {
          nix-homebrew = {
            user = lib.mkForce "automic";
            group = lib.mkForce "vault";
            # `brew shellenv` would put Homebrew's bin ahead of the guarded
            # brew and add Homebrew's zsh completions, which zsh refuses once
            # Automic Vault owns them.
            enableBashIntegration = lib.mkForce false;
            enableFishIntegration = lib.mkForce false;
            enableZshIntegration = lib.mkForce false;
          };
        })
      ]
    ))
  ];
}
