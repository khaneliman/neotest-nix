local vm = require("neotest-nix.vm")

local function position(test_script_range)
  return {
    id = "vm",
    name = "vm",
    path = "flake.nix",
    range = { 0, 0, 4, 0 },
    test_script_range = test_script_range,
    type = "test",
  }
end

describe("vm", function()
  it("parses embedded Python traceback lines", function()
    local tracebacks = vm.parse_python_tracebacks(table.concat({
      "machine: waiting",
      "Traceback (most recent call last):",
      '  File "/nix/store/hash-source/test-script.py", line 3, in <module>',
      '    machine.succeed("false")',
      "AssertionError: command failed",
    }, "\n"))

    assert.are.same({
      {
        line = 3,
        message = "AssertionError: command failed",
      },
    }, tracebacks)
  end)

  it("maps Python traceback lines into testScript ranges", function()
    assert.are.equal(12, vm.test_script_line(position({ 9, 17, 13, 6 }), 3))
  end)

  it("ignores invalid traceback lines without testScript metadata", function()
    assert.is_nil(vm.test_script_line(position(nil), 1))
    assert.is_nil(vm.test_script_line(position({ 9, 17, 13, 6 }), 0))
  end)
end)
