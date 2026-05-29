{
  description = "fixture";

  outputs =
    { self, nixpkgs }:
    {
      packages.aarch64-darwin.default = self;

      checks = {
        aarch64-darwin = {
          unit = nixpkgs.legacyPackages.aarch64-darwin.runCommand "unit" { } "";
        };

        x86_64-linux = {
          integration = nixpkgs.legacyPackages.x86_64-linux.runCommand "integration" { } "";
        };
      };
    };
}
