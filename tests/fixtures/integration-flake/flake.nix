{
  description = ''
    neotest-nix integration fixture: checks and nix-unit tests built entirely
    from `derivation`/plain attrsets, so a real `nix build` / `nix-unit` run
    against this flake never fetches nixpkgs. Kept input-free on purpose (see
    tests/integration/README in the integration specs) so the CI job that
    exercises real nix stays cheap and hermetic. No flake.lock is committed
    alongside this file: with zero inputs `nix flake lock` has nothing to
    record.
  '';

  outputs =
    { self }:
    {
      checks.x86_64-linux = {
        # A trivially successful build: exercises the `nix build` success path
        # (spec.lua's flake-check command, process.lua's real vim.system spawn,
        # results.lua's exit-code-0 branch) end to end.
        passing = derivation {
          name = "integration-passing";
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [
            "-c"
            "echo ok > $out"
          ];
        };

        # A deterministic build failure: exercises results.lua's error-parsing
        # fallback for a real `nix build` failure message (a builder failure
        # has no `at <file>:<line>:<col>:` frame, unlike an evaluation error).
        failing = derivation {
          name = "integration-failing";
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [
            "-c"
            "echo 'deliberate integration-test failure' 1>&2; exit 1"
          ];
        };
      };

      # nix-unit runs these directly against the flake (`nix-unit --flake
      # .#tests`); no nixpkgs needed since the values under test are literals.
      tests = {
        testPass = {
          expr = 1;
          expected = 1;
        };

        testFail = {
          expr = 1;
          expected = 2;
        };
      };
    };
}
