local modrev = "scm"
local specrev = "1"

rockspec_format = "3.0"
package = "neotest-nix"
version = modrev .. "-" .. specrev

description = {
  summary = "A Neotest adapter for Nix flakes.",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
  "neotest",
  "nvim-nio",
}

test_dependencies = {
  "neotest",
  "nvim-nio",
}

source = {
  url = "git+https://github.com/khaneliman/neotest-nix",
}

build = {
  type = "builtin",
  copy_directories = {
    "queries",
  },
}

test = {
  type = "command",
  command = "busted --lua=nlua tests/",
}
