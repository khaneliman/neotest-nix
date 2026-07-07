# Zero-arg `lib.runTests`-shaped suite under a test-named path so generic
# non-flake discovery can claim it without a flake. This hand-rolls the
# `lib.runTests` output contract instead of importing `<nixpkgs>`, because CI
# does not guarantee `NIX_PATH`.
let
  runTests =
    tests:
    builtins.filter (failure: failure != null) (
      builtins.attrValues (
        builtins.mapAttrs (
          name: test:
          if test.expr == test.expected then
            null
          else
            {
              inherit name;
              inherit (test) expected;
              result = test.expr;
            }
        ) tests
      )
    );
in
runTests {
  testPass = {
    expr = 1 + 1;
    expected = 2;
  };
  testFail = {
    expr = 1 + 1;
    expected = 3;
  };
}
