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

; Anchor to the first attrpath component so a dotted binding like
; `checks.x86_64-linux.foo = ...` yields exactly one match; Lua derives the
; full name from the binding. Quoted names (`"my check" = ...`) match via
; string_expression and are decoded (or rejected) in Lua.
(binding
  attrpath: (attrpath
    .
    [
      (identifier)
      (string_expression)
    ] @test.name)
  expression: (_) @test.definition)
