# Zero-arg `lib.runTests` suite: the file's top-level expression evaluates
# directly to the runTests result, no function application needed.
let
  inherit ((import <nixpkgs> { })) lib;
in
lib.runTests {
  testPass = {
    expr = 1 + 1;
    expected = 2;
  };
  testFail = {
    expr = 1 + 1;
    expected = 3;
  };
}
