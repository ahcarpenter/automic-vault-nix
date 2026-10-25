{
  lib,
  stdenvNoCC,
  fetchurl,
  undmg,
  versionCheckHook,
  nix-update-script,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "automic-vault";
  version = "4.20.2";

  src = fetchurl {
    url = "https://github.com/automic-vault/automic-vault/releases/download/${finalAttrs.version}/Automic-Vault-${finalAttrs.version}.dmg";
    hash = "sha256-soDXHQt/t6AdYw+I3D5n+w9CDx+cA2Ceg+2BgQC+I9c=";
  };

  nativeBuildInputs = [ undmg ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications $out/bin
    cp -R "Automic Vault.app" $out/Applications
    # A copy, as Automic Vault installs at /usr/local/bin/av, not a link into
    # the bundle: once code inside a notarized bundle runs, macOS protects the
    # bundle with com.apple.macl, and the Nix daemon can no longer delete it.
    cp "Automic Vault.app/Contents/MacOS/av" $out/bin/av

    runHook postInstall
  '';

  # The bundle is signed and notarized by Automic Vault, and the app and the
  # av CLI check each other's signatures at runtime. Changing any file in it,
  # as patching shebangs or stripping would, breaks that signature.
  dontFixup = true;

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;
  versionCheckProgramArg = "--version";

  passthru.updateScript = nix-update-script { extraArgs = [ "--use-github-releases" ]; };

  meta = {
    description = "Credential vault that hardens command-line tools on macOS";
    longDescription = ''
      Automic Vault moves the credentials that command-line tools keep in
      plain files into the macOS Keychain and changes how supported tools
      request them, so each use of a protected credential needs approval in
      its menu bar app or a preset access level. It ships as an app bundle
      with the `av` CLI.

      Several features expect the app at /Applications/Automic Vault.app and a
      root-owned copy of `av` at /usr/local/bin/av, which this package does
      not create on its own.
    '';
    homepage = "https://www.automicvault.com";
    downloadPage = "https://github.com/automic-vault/automic-vault/releases";
    changelog = "https://github.com/automic-vault/automic-vault/releases/tag/${finalAttrs.version}";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "aarch64-darwin" ];
    mainProgram = "av";
    maintainers = [ ];
  };
})
