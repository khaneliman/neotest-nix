{ inputs, ... }:
{
  imports = [
    inputs.git-hooks.flakeModule
    inputs.treefmt-nix.flakeModule
    ./treefmt.nix
    ./checks.nix
    ./shell.nix
  ];
}
