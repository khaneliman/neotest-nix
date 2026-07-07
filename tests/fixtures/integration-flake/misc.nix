# Stand-in for a Nixpkgs `lib/tests/misc.nix`-style file: hand-rolled so this
# fixture never fetches nixpkgs, but shaped exactly like `lib.runTests`'
# output contract (an empty list means every case passed; each failing case
# reports `name`/`expected`/`result`). This is what
# `neotest-nix.results.nix_eval_results` parses, and what `nix-instantiate
# --eval --strict --json` produces for a real run against this file -- the
# eval-style leg of the discover -> build_spec -> execute -> results pipeline.
let
  cases = {
    testPass = {
      expr = 1;
      expected = 1;
    };
    testFail = {
      expr = 1;
      expected = 2;
    };
  };
  failures = builtins.filter (failure: failure != null) (
    builtins.attrValues (
      builtins.mapAttrs (
        name: case:
        if case.expr == case.expected then
          null
        else
          {
            inherit name;
            inherit (case) expected;
            result = case.expr;
          }
      ) cases
    )
  );
in
failures
