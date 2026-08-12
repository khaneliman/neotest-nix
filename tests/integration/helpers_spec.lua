local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

describe("integration helpers", function()
  local original_execute
  local original_tempname
  local temp_dir

  setup(function()
    original_execute = os.execute
    original_tempname = vim.fn.tempname
    temp_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "neotest-nix-helper-spec")
    vim.fn.delete(temp_dir, "rf")
    vim.fn.tempname = function()
      return temp_dir
    end
  end)

  teardown(function()
    os.execute = original_execute
    vim.fn.tempname = original_tempname
    vim.fn.delete(temp_dir, "rf")
  end)

  it("rejects a failed numeric os.execute status", function()
    os.execute = function()
      return 256
    end

    assert.has_error(function()
      helpers.materialize_fixture("integration-flake")
    end, "neotest-nix integration: failed to copy fixture `integration-flake`")
  end)

  it("accepts a successful numeric os.execute status", function()
    os.execute = function()
      return 0
    end

    local dir, cleanup = helpers.materialize_fixture("integration-flake")
    assert.are.equal(temp_dir, dir)
    cleanup()
  end)
end)
