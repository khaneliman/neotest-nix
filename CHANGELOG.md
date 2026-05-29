# Changelog

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
