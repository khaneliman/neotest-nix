{
  testBare = {
    expr = 1 + 1;
    expected = 2;
  };

  nested = {
    testNested = {
      expr = "ok";
      expected = "ok";
    };
  };
}
