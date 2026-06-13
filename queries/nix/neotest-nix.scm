; Capture flake output checks as a nested Neotest tree:
; outputs -> checks -> system -> derivation/test attribute.
; Also capture flake-level nix-unit tests under outputs.tests.

(binding
  attrpath: (attrpath
    (identifier) @namespace.name)
  expression: (_) @namespace.definition
  (#eq? @namespace.name "outputs"))

(binding
  attrpath: (attrpath
    (identifier) @namespace.name)
  expression: (_) @namespace.definition
  (#eq? @namespace.name "checks"))

(binding
  attrpath: (attrpath
    (identifier) @namespace.name)
  expression: (_) @namespace.definition
  (#eq? @namespace.name "tests"))

(binding
  attrpath: (attrpath
    (identifier) @namespace.name)
  expression: [
    (attrset_expression)
    (rec_attrset_expression)
  ] @namespace.definition
  (#match? @namespace.name "^[a-z0-9_]+-[a-z0-9_]+$"))

(binding
  attrpath: (attrpath
    (identifier) @test.name)
  expression: (_) @test.definition)
