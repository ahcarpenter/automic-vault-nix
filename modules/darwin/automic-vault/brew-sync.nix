{ writeShellApplication }:

writeShellApplication {
  name = "brew-sync";
  text = builtins.readFile ./brew-sync.sh;
}
