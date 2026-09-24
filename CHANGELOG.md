# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-23

### Fixed
- Report `target_libc = "musl"` for `*-musl` target triples instead of a
  hardcoded `"glibc"`, so rules selecting on libc type see the right value.
- Derive the generated toolchain's `exec_compatible_with` constraints from
  the host Bazel runs on instead of hardcoding `linux/x86_64`. aarch64
  cross-rs containers (e.g. Apple Silicon) can now select the toolchain.

### Changed
- Documented that consumers must register the toolchain from their root
  `MODULE.bazel`: Bzlmod ranks root-module registrations above non-root ones
  and the auto-configured local toolchain, which is required for targets
  where the cross toolchain and the local toolchain match the same platform
  (e.g. `x86_64-unknown-linux-musl` built inside an x86_64 glibc container).
  Native builds are unaffected — the stub toolchain never matches.

## [0.1.0] - 2025-07-05

### Added
- Initial release of `rules_cross_rs`
- Zero-configuration C++ cross-compilation toolchain for `cross-rs` environments
- Automatic detection of `cross-rs` environment variables (`TARGET`, `CROSS_TOOLCHAIN_PREFIX`, `CROSS_TOOLCHAIN_SUFFIX`)
- Support for all major cross-compilation scenarios:
  - Native compilation
  - Standard cross-compilation (ARM, x86, etc.)
  - Emscripten WebAssembly
  - Windows MinGW
- Automatic tool discovery and toolchain configuration
- Builtin include directory detection using `gcc -E -v`
- Modern Bazel integration using Bzlmod module extensions
- Official Bazel action names integration (`ACTION_NAMES`)
- CPU and OS constraint mapping based on official Bazel platforms
- Comprehensive feature-based toolchain configuration
- Standard library linking support (`-lc`, `-lm`, `-latomic`, `-ldl`, `-lstdc++`)

### Architecture
- Single-file design (`rules.bzl`) for simplicity
- Environment-driven configuration
- Inspired by best practices from `rules_android_ndk` and `apple_support`
- Custom `flag_set` wrapper for simplified configuration syntax
- Proper separation of compile and link features

### Documentation
- Comprehensive README with quick start guide
- Examples for common use cases
- Troubleshooting section
- Apache 2.0 license

## Background

This project originated from the development of [cel-cxx](https://github.com/xjasonli/cel-cxx), specifically the need to build C++ dependencies (CEL-Cpp) from within Rust `build.rs` scripts when using `cross-rs` for cross-compilation. The challenge was bridging the gap between `cross-rs`'s pre-configured container environments and Bazel's hermetic build system. 
