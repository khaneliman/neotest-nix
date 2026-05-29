# Changelog

## 1.0.0 (2026-05-29)


### Features

* **discovery:** add adapter skeleton ([8d3d499](https://github.com/khaneliman/neotest-nix/commit/8d3d499c0c3832ff7e094451ab8ddee92509dd27))
* **discovery:** configurable eval_outputs with name filter ([faae03d](https://github.com/khaneliman/neotest-nix/commit/faae03dc63c9d6fd46a98d8750dc18e55667aac6))
* **discovery:** find arbitrary nix-unit suites ([ea5a106](https://github.com/khaneliman/neotest-nix/commit/ea5a1060333b9ccc11d386cab44c07f9c6d39251))
* **discovery:** opt-in eval discovery of generated checks ([00bc857](https://github.com/khaneliman/neotest-nix/commit/00bc857e9cad88083385a7c25cfc877052eb4b05))
* **flake:** pre-stage future runtime dirs with maybeMissing ([8f827ed](https://github.com/khaneliman/neotest-nix/commit/8f827edc5fba7867ee9cc64f2fc5fde492631ef0))
* initialize nix flake ([4769137](https://github.com/khaneliman/neotest-nix/commit/4769137085fd61ac598d46e3e19490d76bb5cf9d))
* **paths:** translate nix store paths ([7b7b6f4](https://github.com/khaneliman/neotest-nix/commit/7b7b6f4e2a1d8eb06e8a4b38625d60e788b1b1df))
* **process:** run specs with vim system ([f50c464](https://github.com/khaneliman/neotest-nix/commit/f50c464fbe9041c47ec731d295d31dbf83ce5deb))
* **results:** include streamed output snippets ([dfcdad5](https://github.com/khaneliman/neotest-nix/commit/dfcdad5c1e176c21dc3d9374d2ad871ec6b705bb))
* **results:** map vm tracebacks ([b400955](https://github.com/khaneliman/neotest-nix/commit/b400955d03e701d4ac8303d89edc7d92e883db9d))
* **results:** parse nix diagnostics ([380182d](https://github.com/khaneliman/neotest-nix/commit/380182d1e0ef0654e075a6e199ca60e1bf36bd8e))
* **results:** stream early diagnostics ([dbd9940](https://github.com/khaneliman/neotest-nix/commit/dbd9940424412a72caac755d31cbbcfd64eac357))
* **spec:** build nix run specs ([9092295](https://github.com/khaneliman/neotest-nix/commit/9092295001478bf0a30373351b89bf1c4375327d))
* **spec:** run targeted nix-unit tests ([7341403](https://github.com/khaneliman/neotest-nix/commit/7341403bd4fd5a960ed12939b3fec781958c6a01))


### Bug Fixes

* **discovery:** gate test-named files on nix-unit content ([ec37475](https://github.com/khaneliman/neotest-nix/commit/ec374759bce4c981a1fa6858c3fdae150c398f1b))
* **discovery:** require expr/expected for nix-unit tests ([7cc45a5](https://github.com/khaneliman/neotest-nix/commit/7cc45a5d058e6c9f114e8156912367b0e0727373))
* **results:** attribute VM tracebacks to the targeted test only ([5f1bd3c](https://github.com/khaneliman/neotest-nix/commit/5f1bd3c0035ba5e92a2c0fe83180bc9df714502b))
* **results:** report the first nix error, not the last ([6c9fed6](https://github.com/khaneliman/neotest-nix/commit/6c9fed6a137a3d6df1043c70a17be0e6b1073cd7))
* **spec:** resolve nix-unit runs by reachability ([19cb420](https://github.com/khaneliman/neotest-nix/commit/19cb420b9eaef26010415db5294f852f62dd97c8))


### Performance Improvements

* **process:** hold one output file handle for the run ([27ec0d4](https://github.com/khaneliman/neotest-nix/commit/27ec0d411d4fc94718ac5fd0b63f06dd1938ceca))
