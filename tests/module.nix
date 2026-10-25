# Evaluates the nix-darwin module in a few configurations and checks what it
# sets, without activating anything.
{
  pkgs,
  nix-darwin,
  nix-homebrew,
  module,
}:

let
  inherit (pkgs) lib;

  evalDarwin =
    modules:
    (nix-darwin.lib.darwinSystem {
      inherit pkgs;
      modules = [
        module
        {
          system.stateVersion = 6;
          system.primaryUser = "alice";
          homebrew = {
            enable = true;
            taps = [
              {
                name = "acme/tools";
                trusted = true;
              }
              {
                name = "acme/private";
                clone_target = "https://git.example.com/acme/homebrew-private.git";
              }
            ];
            brews = [
              "jq"
              "acme/tools/widget"
            ];
            casks = [ "claude-code@latest" ];
          };
        }
      ]
      ++ modules;
    }).config;

  withNixHomebrew = [
    nix-homebrew.darwinModules.nix-homebrew
    {
      nix-homebrew = {
        enable = true;
        user = "alice";
      };
    }
  ];

  plain = evalDarwin withNixHomebrew;
  enabled = evalDarwin (withNixHomebrew ++ [ { programs.automic-vault.enable = true; } ]);
  hardened = evalDarwin (
    withNixHomebrew
    ++ [
      {
        programs.automic-vault = {
          enable = true;
          homebrew.hardened = true;
        };
      }
    ]
  );
  rosetta = [ { nix-homebrew.enableRosetta = true; } ];
  rosettaOnly = evalDarwin (withNixHomebrew ++ rosetta);
  hardenedWithRosetta = evalDarwin (
    withNixHomebrew ++ rosetta ++ [ { programs.automic-vault.homebrew.hardened = true; } ]
  );
  hardenedWithoutNixHomebrew = evalDarwin [ { programs.automic-vault.homebrew.hardened = true; } ];
  hardenedWithMasApps = evalDarwin [
    {
      programs.automic-vault.homebrew.hardened = true;
      homebrew.masApps.Xcode = 497799835;
    }
  ];
  duplicated = evalDarwin [
    (
      { config, ... }:
      {
        programs.automic-vault.enable = true;
        environment.systemPackages = [ config.programs.automic-vault.package ];
      }
    )
  ];

  applications = config: config.system.activationScripts.applications.text;
  installTargets = config: config.programs.automic-vault.installTargets;
  syncArgs = config: config.programs.automic-vault.homebrew.syncArgs;
  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  rosettaRefused =
    config: lib.any (lib.hasInfix "nix-homebrew.enableRosetta") (failedAssertions config);

  expectedInstallTargets =
    config:
    let
      app = "${config.programs.automic-vault.package}/Applications/Automic Vault.app";
    in
    [
      [
        "app"
        app
        "/Applications/Automic Vault.app"
      ]
      [
        "cli"
        "${app}/Contents/MacOS/av"
        "/usr/local/bin/av"
      ]
    ];
  expectedSyncArgs = [
    "/opt/homebrew"
    "/opt/homebrew/Library"
    "/usr/local/bin/brew"
    "trusted-tap:acme/tools"
    "tap:acme/private:https://git.example.com/acme/homebrew-private.git"
    "formula:jq"
    "trusted-formula:acme/tools/widget"
    "cask:claude-code@latest"
  ];
  brewSyncIn =
    config: lib.findFirst (p: lib.getName p == "brew-sync") null config.environment.systemPackages;
  hasBrewSync = config: brewSyncIn config != null;

  # Each case: [ description, result ].
  cases = [
    # Without the module enabled, nothing changes.
    [
      "plain: nix-darwin's Homebrew module stays on"
      plain.homebrew.enable
    ]
    [
      "plain: nix-homebrew keeps its user and group"
      (plain.nix-homebrew.user == "alice" && plain.nix-homebrew.group == "admin")
    ]
    [
      "plain: the app is not installed"
      (installTargets plain == [ ])
    ]
    [
      "plain: PATH is unchanged"
      (!lib.hasPrefix "/usr/local/bin:" plain.environment.systemPath)
    ]
    [
      "plain: no brew-sync"
      (!hasBrewSync plain)
    ]

    # enable installs the app and the CLI, and leaves Homebrew alone.
    [
      "enabled: the app and the CLI are installed from the package where Automic Vault expects them"
      (installTargets enabled == expectedInstallTargets enabled)
    ]
    [
      "enabled: /usr/local/bin comes first in PATH"
      (lib.hasPrefix "/usr/local/bin:" enabled.environment.systemPath)
    ]
    [
      "enabled: the app is not in /Applications/Nix Apps"
      (!lib.elem enabled.programs.automic-vault.package enabled.environment.systemPackages)
    ]
    [
      "enabled: nix-darwin's Homebrew module stays on"
      enabled.homebrew.enable
    ]
    [
      "enabled: nix-homebrew keeps its user"
      (enabled.nix-homebrew.user == "alice")
    ]
    [
      "enabled: no warnings"
      (enabled.warnings == [ ])
    ]

    # hardened hands the prefix to automic:vault and installs through brew-sync.
    [
      "hardened: nix-darwin's Homebrew module is off"
      (!hardened.homebrew.enable)
    ]
    [
      "hardened: nix-homebrew still sets up the prefix"
      hardened.nix-homebrew.enable
    ]
    [
      "hardened: nix-homebrew owns the prefix as automic:vault"
      (hardened.nix-homebrew.user == "automic" && hardened.nix-homebrew.group == "vault")
    ]
    [
      "hardened: nix-homebrew's shell integrations are off"
      (
        !hardened.nix-homebrew.enableBashIntegration
        && !hardened.nix-homebrew.enableFishIntegration
        && !hardened.nix-homebrew.enableZshIntegration
      )
    ]
    [
      "hardened: the guarded brew, then Homebrew's bin and sbin, come first in PATH"
      (lib.hasPrefix "/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:" hardened.environment.systemPath)
    ]
    [
      "hardened: Homebrew's variables are set"
      (
        hardened.environment.variables.HOMEBREW_PREFIX == "/opt/homebrew"
        && hardened.environment.variables.HOMEBREW_CELLAR == "/opt/homebrew/Cellar"
      )
    ]
    [
      "hardened: brew-sync is installed"
      (hasBrewSync hardened)
    ]
    [
      "hardened: brew-sync gets the lists in order, with trust where nix-darwin would trust"
      (syncArgs hardened == expectedSyncArgs)
    ]
    [
      "hardened: still installs the app and the CLI"
      (installTargets hardened == expectedInstallTargets hardened)
    ]
    [
      "hardened: no warnings"
      (hardened.warnings == [ ])
    ]

    # hardened works without nix-homebrew too.
    [
      "hardened without nix-homebrew: nix-darwin's Homebrew module is off"
      (!hardenedWithoutNixHomebrew.homebrew.enable)
    ]
    [
      "hardened without nix-homebrew: brew-sync is installed"
      (hasBrewSync hardenedWithoutNixHomebrew)
    ]
    [
      "hardened without nix-homebrew: brew-sync gets the same arguments"
      (syncArgs hardenedWithoutNixHomebrew == expectedSyncArgs)
    ]
    [
      "hardened without nix-homebrew: the app is not installed"
      (installTargets hardenedWithoutNixHomebrew == [ ])
    ]

    # nix-homebrew's Rosetta prefix is /usr/local, where the guarded brew lives.
    [
      "Rosetta alone: allowed"
      (!rosettaRefused rosettaOnly)
    ]
    [
      "hardened: allowed without Rosetta"
      (!rosettaRefused hardened)
    ]
    [
      "hardened with Rosetta: refused"
      (rosettaRefused hardenedWithRosetta)
    ]

    # Misconfigurations warn.
    [
      "hardened with masApps: warns that nothing installs them"
      (lib.any (lib.hasInfix "homebrew.masApps") hardenedWithMasApps.warnings)
    ]
    [
      "enabled with the package in systemPackages: warns about the second copy"
      (lib.any (lib.hasInfix "/Applications/Nix Apps") duplicated.warnings)
    ]
  ];

  failed = lib.filter (case: !(lib.elemAt case 1)) cases;

  # Forces every configuration through nix-darwin's own assertions.
  toplevels = map (config: builtins.unsafeDiscardStringContext config.system.build.toplevel.drvPath) [
    plain
    enabled
    hardened
    hardenedWithoutNixHomebrew
  ];
in
assert lib.assertMsg (failed == [ ]) ''
  module tests failed:
  ${lib.concatMapStringsSep "\n" (case: "  - ${lib.head case}") failed}
'';
pkgs.runCommand "automic-vault-module"
  {
    nativeBuildInputs = [ pkgs.shellcheck ];
    passAsFile = [
      "enabledScript"
      "hardenedScript"
    ];
    # The snippets the module adds, with enough of nix-darwin's activation
    # around them to lint them as one script.
    enabledScript = ''
      #!/usr/bin/env bash
      set -e
      ${enabled.system.checks.text}
      ${applications enabled}
    '';
    hardenedScript = ''
      #!/usr/bin/env bash
      set -e
      ${hardened.system.checks.text}
    '';
    toplevels = toplevels;
    brewSync = brewSyncIn hardened;
  }
  ''
    bash -n "$enabledScriptPath"
    bash -n "$hardenedScriptPath"
    bash -n "$brewSync/bin/brew-sync"

    echo "${toString (lib.length cases)} module tests passed"
    touch $out
  ''
