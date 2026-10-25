{ writeShellApplication }:

writeShellApplication {
  name = "automic-vault-check-hardened";
  text = builtins.readFile ./check-hardened.sh;
}
