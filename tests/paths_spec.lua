local paths = require("neotest-nix.paths")

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "checks"), "p")
  vim.fn.writefile({ "{}" }, vim.fs.joinpath(root, "checks", "unit.nix"))
  return root
end

describe("paths", function()
  it("translates source store paths to local files", function()
    local root = project()
    local store_path = "/nix/store/abc123-source/checks/unit.nix"

    assert.are.equal(
      vim.fs.joinpath(root, "checks", "unit.nix"),
      paths.translate_store_path(store_path, root)
    )
  end)

  it("leaves missing reconstructed files unchanged", function()
    local root = project()
    local store_path = "/nix/store/abc123-source/checks/missing.nix"

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("leaves non-source paths unchanged", function()
    local root = project()
    local store_path = "/nix/store/abc123-neotest-nix/checks/unit.nix"

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("translates store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local output = "error: " .. "/nix/store/abc123-source/checks/unit.nix:2:3: failed"

    assert.are.equal(
      "error: " .. local_path .. ":2:3: failed",
      paths.translate_string(output, root)
    )
  end)

  it("translates quoted store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local output = 'error: "' .. "/nix/store/abc123-source/checks/unit.nix" .. '":2:3'

    assert.are.equal('error: "' .. local_path .. '":2:3', paths.translate_string(output, root))
  end)

  it("translates parenthesized store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local output = "error: (" .. "/nix/store/abc123-source/checks/unit.nix" .. ")"

    assert.are.equal("error: (" .. local_path .. ")", paths.translate_string(output, root))
  end)

  it("translates comma-punctuated store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local output = "trace: " .. "/nix/store/abc123-source/checks/unit.nix" .. ", failed"

    assert.are.equal("trace: " .. local_path .. ", failed", paths.translate_string(output, root))
  end)

  it("mutates nested result tables", function()
    local root = project()
    local result = {
      output = "trace: /nix/store/abc123-source/checks/unit.nix",
      errors = {
        {
          message = "failed",
          path = "/nix/store/abc123-source/checks/unit.nix",
        },
      },
    }

    assert.are.same(result, paths.translate_result_paths(result, root))
    assert.are.equal(vim.fs.joinpath(root, "checks", "unit.nix"), result.errors[1].path)
    assert.are.equal("trace: " .. vim.fs.joinpath(root, "checks", "unit.nix"), result.output)
  end)
end)
