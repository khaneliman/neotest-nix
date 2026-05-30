# Changelog

## [2.1.2](https://github.com/khaneliman/neotest-nix/compare/v2.1.1...v2.1.2) (2026-05-30)


### Bug Fixes

* namespace eval-discovered position ids per flake file ([2167506](https://github.com/khaneliman/neotest-nix/commit/21675061735cf78f17fabe058f834d7ea5c78791))
* stop test runs from writing flake.lock to the repo ([1a0dc28](https://github.com/khaneliman/neotest-nix/commit/1a0dc2859de063814881e95d4d2bcbf45989ea0b))
* use Lua 5.1 unicode escapes ([79966f9](https://github.com/khaneliman/neotest-nix/commit/79966f98f4135557f02b16a888c77a67c421e645))

## [2.1.1](https://github.com/khaneliman/neotest-nix/compare/v2.1.0...v2.1.1) (2026-05-30)


### Bug Fixes

* stop discovery from writing flake.lock to the repo ([b5c8014](https://github.com/khaneliman/neotest-nix/commit/b5c80148f79a3936d1bf083d8fdd16c7303a3c25))

## [2.1.0](https://github.com/khaneliman/neotest-nix/compare/v2.0.0...v2.1.0) (2026-05-30)


### Features

* auto-detect the flake output for wrapped nix-unit suites ([5d13b3a](https://github.com/khaneliman/neotest-nix/commit/5d13b3a0945b434a269658acbb12d548ce6325cb))
* run wrapped nix-unit suites via flake with per-attribute results ([272f383](https://github.com/khaneliman/neotest-nix/commit/272f38308526e26dbdf89493f622aa8686fb3375))


### Bug Fixes

* discover nix-unit files in test-named directories ([3177910](https://github.com/khaneliman/neotest-nix/commit/31779105dce13d471aedf415d96b6c3a2256cc64))

## [2.0.0](https://github.com/khaneliman/neotest-nix/compare/v1.0.0...v2.0.0) (2026-05-30)


### ⚠ BREAKING CHANGES

* validate adapter config in setup()

### Features

* **dev:** add pre-commit CLI to dev shell ([8202f26](https://github.com/khaneliman/neotest-nix/commit/8202f2642c40d7b820f766cf93da86b2e32ac15d))
* **dev:** generate vimdoc from LuaCATS with vimcats ([944266c](https://github.com/khaneliman/neotest-nix/commit/944266c10ff18027395e8ef599b4a0312e23e390))
* validate adapter config in checkhealth ([49a9c63](https://github.com/khaneliman/neotest-nix/commit/49a9c63e7c24e19da1f31fd6c12aae9516ad4cc4))
* validate adapter config in setup() ([5f28fa5](https://github.com/khaneliman/neotest-nix/commit/5f28fa535af145fe220e66c0d1695b224f1a7c01))


### Bug Fixes

* make bare module a working adapter ([da8c684](https://github.com/khaneliman/neotest-nix/commit/da8c684ccd996bdd9f845fed124c1a033ac2fc8d))

## 1.0.0 (2026-05-29)


### Features

* **discovery:** add adapter skeleton ([f5e13d9](https://github.com/khaneliman/neotest-nix/commit/f5e13d9f3f338c2fc1fca063915af59046c2ef59))
* **discovery:** configurable eval_outputs with name filter ([eb40b7f](https://github.com/khaneliman/neotest-nix/commit/eb40b7f09101e617e99a52905c599216aea9e859))
* **discovery:** find arbitrary nix-unit suites ([7e641b7](https://github.com/khaneliman/neotest-nix/commit/7e641b7346c6bf6b08e60e0de16720cec2cd180f))
* **discovery:** opt-in eval discovery of generated checks ([96815cf](https://github.com/khaneliman/neotest-nix/commit/96815cf13800019c665a63d287b960240684a7c6))
* **flake:** pre-stage future runtime dirs with maybeMissing ([37d91e7](https://github.com/khaneliman/neotest-nix/commit/37d91e75abfb7d9b5ff84d9d569c1716cb647fd5))
* **health:** add :checkhealth neotest-nix ([ae68728](https://github.com/khaneliman/neotest-nix/commit/ae68728b042e5756043f55d1920177791a160e1b))
* initialize nix flake ([c57de9e](https://github.com/khaneliman/neotest-nix/commit/c57de9e345908ccc417304d9b1716f7524699878))
* **paths:** translate nix store paths ([84bddb7](https://github.com/khaneliman/neotest-nix/commit/84bddb75155e6989b856e4f0a7dbbd94c9f421dc))
* **process:** run specs with vim system ([59afec3](https://github.com/khaneliman/neotest-nix/commit/59afec37ef3a49916bf7237f31dd7a47156c6dc3))
* **results:** include streamed output snippets ([067b526](https://github.com/khaneliman/neotest-nix/commit/067b526ba370d23e4a7b9d6656a5e9c250ba2d8e))
* **results:** map vm tracebacks ([fa53065](https://github.com/khaneliman/neotest-nix/commit/fa5306515274ad91099db4392d73c3db0d818783))
* **results:** parse nix diagnostics ([fbec4e1](https://github.com/khaneliman/neotest-nix/commit/fbec4e14e2c3f9061452306e7c66c73a8b5dbf96))
* **results:** stream early diagnostics ([9a6a21c](https://github.com/khaneliman/neotest-nix/commit/9a6a21c22f3b7db6a5a7b49867e943725639e95c))
* **spec:** build nix run specs ([ca6c98a](https://github.com/khaneliman/neotest-nix/commit/ca6c98a5f9a5e4b92830c1fa236acce30cfb61a0))
* **spec:** run targeted nix-unit tests ([9a930b4](https://github.com/khaneliman/neotest-nix/commit/9a930b4444be85ee65205f5a412bb2695eb57cd2))


### Bug Fixes

* **discovery:** gate test-named files on nix-unit content ([20532cd](https://github.com/khaneliman/neotest-nix/commit/20532cd1c5592e19f7ddcda3b90869a0fb30cdc6))
* **discovery:** require expr/expected for nix-unit tests ([e04c0a6](https://github.com/khaneliman/neotest-nix/commit/e04c0a6dadc326026cee3ed396469b748052d40c))
* resolve lua-language-server diagnostics in init.lua ([5486a74](https://github.com/khaneliman/neotest-nix/commit/5486a74baddb6f0c970b12ff657ceb1c383cedc9))
* **results:** attribute VM tracebacks to the targeted test only ([09e2bf5](https://github.com/khaneliman/neotest-nix/commit/09e2bf5947a4e12d526df5947e1d8f3d1c4c35ee))
* **results:** report the first nix error, not the last ([c5f34d3](https://github.com/khaneliman/neotest-nix/commit/c5f34d36605be0385a9fc8fe4588f5888607cd18))
* **spec:** resolve nix-unit runs by reachability ([457ed04](https://github.com/khaneliman/neotest-nix/commit/457ed04a65d276741c351f8b4dba8b711955f7c1))


### Performance Improvements

* **process:** hold one output file handle for the run ([ad9593b](https://github.com/khaneliman/neotest-nix/commit/ad9593b9d9ac6c3c552ab924b3331e56bf7cdca9))
