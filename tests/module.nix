# Evaluates the nix-darwin module in a few configurations and checks what it
# sets, without activating anything.
{
  pkgs,
  nix-darwin,
  module,
}:

let
  inherit (pkgs) lib;

  evalDarwinWithout =
    modules:
    (nix-darwin.lib.darwinSystem {
      inherit pkgs;
      modules = [ { system.stateVersion = 6; } ] ++ modules;
    }).config;

  evalDarwin = modules: evalDarwinWithout ([ module ] ++ modules);

  baseline = evalDarwinWithout [ ];
  plain = evalDarwin [ ];
  enabled = evalDarwin [ { programs.automic-vault.enable = true; } ];
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
        app
        "/Applications/Automic Vault.app"
        "/usr/local/bin/av"
      ]
    ];

  # Each case: [ description, result ].
  cases = [
    # Without the module enabled, nothing changes.
    [
      "plain: the app is not installed"
      (installTargets plain == [ ])
    ]
    [
      "plain: activation is the same as without the module"
      (applications plain == applications baseline)
    ]
    [
      "plain: the checks are the same as without the module"
      (plain.system.checks.text == baseline.system.checks.text)
    ]

    # enable installs the app and the CLI, and nothing else.
    [
      "enabled: the app and the CLI are installed from the package where Automic Vault expects them"
      (installTargets enabled == expectedInstallTargets enabled)
    ]
    [
      "enabled: the app is not in /Applications/Nix Apps"
      (!lib.elem enabled.programs.automic-vault.package enabled.environment.systemPackages)
    ]
    [
      "enabled: PATH is left alone"
      (enabled.environment.systemPath == plain.environment.systemPath)
    ]
    [
      "enabled: no warnings"
      (enabled.warnings == [ ])
    ]

    # Misconfigurations warn.
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
  ];
in
assert lib.assertMsg (failed == [ ]) ''
  module tests failed:
  ${lib.concatMapStringsSep "\n" (case: "  - ${lib.head case}") failed}
'';
pkgs.runCommand "automic-vault-module"
  {
    nativeBuildInputs = [ pkgs.shellcheck ];
    passAsFile = [ "enabledScript" ];
    # The snippets the module adds, with enough of nix-darwin's activation
    # around them to lint them as one script.
    enabledScript = ''
      #!/usr/bin/env bash
      set -e
      ${enabled.system.checks.text}
      ${applications enabled}
    '';
    toplevels = toplevels;
  }
  ''
    shellcheck --severity=warning --exclude=SC1112 "$enabledScriptPath"

    echo "${toString (lib.length cases)} module tests passed"
    touch $out
  ''
