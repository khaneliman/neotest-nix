{
  description = ''
    neotest-nix integration fixture: demonstrates `inputs.nixpkgs.follows`
    when a check genuinely needs nixpkgs (here, just `pkgs.runCommand`). The
    `root` input is this repository itself (`path:../../..`), and `nixpkgs`
    follows *its* already-locked nixpkgs input instead of fetching an
    independent copy. Because `root` resolves to a real checkout that this
    project's own flake.lock has already pinned and (in CI) already fetched
    to build the plugin package and run the other flake checks, evaluating
    this fixture costs no additional nixpkgs download: it reuses the same
    /nix/store paths.

    This fixture is *not* nixpkgs-free (unlike tests/fixtures/integration-flake),
    so it is intentionally the second, heavier example rather than the
    default: only reach for this pattern when a check truly needs nixpkgs.

    Because `root` is a relative `path:` input, this flake only evaluates
    correctly from its committed location inside the neotest-nix checkout (it
    is not relocatable to an isolated temp directory the way the input-free
    fixture is), and it requires this fixture's own files to be visible to
    Git (tracked -- staged is enough, a commit is not required) the same way
    every local flake does.
  '';

  inputs = {
    root.url = "path:../../..";
    nixpkgs.follows = "root/nixpkgs";
  };

  outputs =
    { nixpkgs, ... }:
    {
      checks.x86_64-linux.unit =
        nixpkgs.legacyPackages.x86_64-linux.runCommand "integration-follows-unit" { }
          ''
            touch $out
          '';
    };
}
