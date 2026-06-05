{
  testBare = {
    expr = 1 + 1;
    expected = 2;
  };

  bareCase = {
    expr = 2 + 2;
    expected = 4;
  };

  nested = {
    testNested = {
      expr = "ok";
      expected = "ok";
    };

    nestedCase = {
      expr = "nested";
      expected = "nested";
    };
  };
}
