{ writeShellApplication }:

writeShellApplication {
  name = "automic-vault-install";
  text = builtins.readFile ./install.sh;
}
