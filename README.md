# rules_cross_rs

A Bazel module for automatically configuring C++ cross-compilation toolchains when using `cross-rs`.

## Motivation

This project originated from the development of [cel-cxx](https://github.com/xjasonli/cel-cxx), specifically the `cel-cxx-ffi` component which needs to invoke Bazel to build C++ dependencies (CEL-Cpp) from within a Rust `build.rs` script.

The challenge: Most Bazel rulesets assume Bazel is the top-level build system. However, `cel-cxx` represents the **reverse scenario** - integrating Bazel as a subordinate build step within a Cargo-based project using `cross-rs` for cross-compilation.

When `cross-rs` provides a pre-configured container environment with specific C++ toolchains, Bazel's hermetic design prevents it from automatically discovering these tools. `rules_cross_rs` bridges this gap by automatically configuring Bazel to use the cross-compilation environment provided by `cross-rs`.

## Features

- **Zero Configuration**: Automatically detects and configures C++ toolchains from `cross-rs` environment variables
- **Self-Adaptive**: Only activates when `CROSS_TOOLCHAIN_PREFIX` is defined, allowing safe inclusion in any project
- **Cross-rs Compliant**: Properly handles `CROSS_TOOLCHAIN_PREFIX`, `CROSS_TOOLCHAIN_SUFFIX`, and `TARGET` environment variables
- **Comprehensive Support**: Works with all major cross-compilation scenarios:
  - Native compilation (no interference when `CROSS_TOOLCHAIN_PREFIX` is unset)
  - Standard cross-compilation (ARM, x86, etc.)
  - Linux musl targets (the cross-rs musl images ship GCC with C++ support)
  - Emscripten WebAssembly
  - Windows MinGW
- **Host-Adaptive Exec Constraints**: The generated toolchain's execution
  constraints describe the host it was created on, so aarch64 cross-rs
  containers (e.g. Apple Silicon) work too
- **Modern Bazel Integration**: Uses Bzlmod and follows official Bazel toolchain configuration practices

## Adaptive Behavior

The module automatically adapts to your environment:

- **Cross-compilation mode**: When both `TARGET` and `CROSS_TOOLCHAIN_PREFIX` are set (including empty string), creates and registers a cross-compilation toolchain
- **Native mode**: When `TARGET` or `CROSS_TOOLCHAIN_PREFIX` are completely unset, creates a stub toolchain that won't interfere with native compilation
- **Safe inclusion**: Can be safely included in any project without breaking native builds

**Important**: Empty string (`""`) for `CROSS_TOOLCHAIN_PREFIX` is valid and means native compilation with no prefix. Only completely unset variables trigger stub mode.

## Quick Start

### 1. Add Dependency

In your `MODULE.bazel`:

```bazel
module(name = "my_project")

bazel_dep(name = "rules_cross_rs", version = "0.2.0")
```

### 2. Register the Toolchain From the Root Module

**Required.** Bzlmod ranks toolchains registered by the *root* module above those
registered by dependencies, and above the auto-configured local toolchain.
rules_cross_rs' own registration only takes effect as a last-resort candidate,
which loses whenever the local toolchain also matches the target platform
(e.g. building `x86_64-unknown-linux-musl` inside an x86_64 glibc cross-rs
container, where both toolchains match `[cpu:x86_64, os:linux]` — the local
glibc toolchain would win and silently mis-compile your library).

Registering from the root module fixes the priority and is inert for native
builds (the extension generates a stub with impossible constraints when
`CROSS_TOOLCHAIN_PREFIX` is unset, so hosts whose native toolchain already
matches — including native musl hosts like Alpine — are unaffected):

```bazel
cross_rs_ext = use_extension("@rules_cross_rs//:rules.bzl", "cross_rs_extension")
use_repo(cross_rs_ext, "cross_rs_toolchain")
register_toolchains("@cross_rs_toolchain//:toolchain_definition")
```

When your root module registers other toolchains that may match the same
platforms (e.g. an Android NDK toolchain), register those **first** if they
should keep winning on those platforms.

### 3. Define Platform Targets

In your `BUILD.bazel`:

```bazel
load("@rules_cross_rs//:rules.bzl", "cross_rs_targets")

# Define the targets you want to support
SUPPORTED_TARGETS = [
    "aarch64-unknown-linux-gnu",
    "x86_64-unknown-linux-gnu", 
    "armv7-linux-androideabi",
    "wasm32-unknown-emscripten",
]

cross_rs_targets(
    name = "targets",
    targets = SUPPORTED_TARGETS,
)

# Your C++ library
cc_library(
    name = "my_cpp_lib",
    srcs = ["src/lib.cpp"],
    hdrs = ["include/lib.h"],
)
```

### 3. Use in build.rs

```rust
use std::process::Command;

fn main() {
    let target = std::env::var("TARGET").unwrap();
    
    let status = Command::new("bazel")
        .args([
            "build",
            &format!("--platforms=//:{}", target),
            "//:my_cpp_lib",
        ])
        .status()
        .expect("Failed to run Bazel");
        
    assert!(status.success());
}
```

## How It Works

`rules_cross_rs` uses Bazel's module extension mechanism to:

1. **Detect Environment**: Checks for `TARGET` and `CROSS_TOOLCHAIN_PREFIX` environment variables
2. **Adaptive Response**: 
   - If `CROSS_TOOLCHAIN_PREFIX` is set: Creates a full cross-compilation toolchain
   - If `CROSS_TOOLCHAIN_PREFIX` is not set: Creates a stub toolchain that won't interfere
3. **Discover Tools**: Locates cross-compilation tools (gcc, g++, ar, ld, etc.) in PATH
4. **Generate Toolchain**: Creates a complete `cc_toolchain` configuration with proper flags and include paths
5. **Auto-Register**: Registers the toolchain for Bazel's platform resolution — note that
   under Bzlmod only root-module registrations take priority, so consumers must also
   register the toolchain from their root `MODULE.bazel` (see Quick Start step 2)

## Cross-rs Environment Variables

| Variable | Purpose | Example | Required | Notes |
|----------|---------|---------|----------|-------|
| `TARGET` | Target triple | `aarch64-unknown-linux-gnu` | Yes | Must be set for activation |
| `CROSS_TOOLCHAIN_PREFIX` | Tool prefix | `aarch64-linux-gnu-` | Yes | Empty string `""` is valid for native compilation |
| `CROSS_TOOLCHAIN_SUFFIX` | Tool suffix | `-posix` | No | Optional suffix for tools |

## Supported Scenarios

### Native Compilation (No Interference)
```bash
# No cross-rs environment variables set (both unset)
# Module creates stub toolchain, native compilation works normally
```

### Native Compilation with cross-rs
```bash
TARGET=x86_64-unknown-linux-gnu
CROSS_TOOLCHAIN_PREFIX=""  # Empty string means no prefix
```

### Standard Cross-compilation
```bash
TARGET=aarch64-unknown-linux-gnu
CROSS_TOOLCHAIN_PREFIX="aarch64-linux-gnu-"
```

### Linux musl
```bash
TARGET=x86_64-unknown-linux-musl
CROSS_TOOLCHAIN_PREFIX="x86_64-linux-musl-"
```

The cross-rs `*-musl` images build their toolchain with
[musl-cross-make](https://github.com/richfelker/musl-cross-make)
(`--enable-languages=c,c++`), so `$(prefix)g++` and a static `libstdc++.a`
are available. Native musl hosts (e.g. Alpine) don't need this module at
all: their auto-configured local toolchain already targets musl.

### Emscripten WebAssembly
```bash
TARGET=wasm32-unknown-emscripten
CROSS_TOOLCHAIN_PREFIX="em"
```

### Windows MinGW
```bash
TARGET=x86_64-pc-windows-gnu
CROSS_TOOLCHAIN_PREFIX="x86_64-w64-mingw32-"
CROSS_TOOLCHAIN_SUFFIX="-posix"
```

## Architecture

The implementation follows best practices from `rules_android_ndk` and `apple_support`:

- **Single-file design**: All functionality in `rules.bzl`
- **Environment-driven**: Automatically adapts to `cross-rs` environment
- **Official Action Names**: Uses `@bazel_tools//tools/build_defs/cc:action_names.bzl`
- **Modern Toolchain Config**: Based on official Bazel C++ toolchain tutorial

## Troubleshooting

### Common Issues

1. **Tool not found**: Ensure cross-compilation tools are in PATH
2. **Include errors**: Verify `gcc -E -v` works in your environment  
3. **Linking errors**: Check that standard libraries are available

### Debug Information

Use `--toolchain_resolution_debug` to see toolchain selection:

```bash
bazel build --toolchain_resolution_debug='@bazel_tools//tools/cpp:toolchain_type' //...
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or submit a pull request. 
