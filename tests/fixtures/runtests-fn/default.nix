# Function-wrapped `lib.runTests` suite over a single, fully-defaulted
# attrset parameter: must be applied with `{ }` (and evaluated `--impure`,
# since the default reaches for the impure `<nixpkgs>` lookup path) before
# `lib.runTests` runs.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.lib.runTests {
  testPass = {
    expr = 1 + 1;
    expected = 2;
  };
  testFail = {
    expr = 1 + 1;
    expected = 3;
  };
}
