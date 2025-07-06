"""
rules.bzl - Cross-rs toolchain integration for Bazel

This module provides a clean, self-contained implementation that correctly handles
the cross-rs environment variables and toolchain configuration.

Key features:
1. Correct handling of CROSS_TOOLCHAIN_PREFIX and CROSS_TOOLCHAIN_SUFFIX
2. Automatic builtin include directory detection
3. Robust error handling and validation
4. Comprehensive tool discovery for various cross-compilation scenarios
5. Modern architecture inspired by apple_support and rules_android_ndk
6. Self-adaptive behavior - only activates when CROSS_TOOLCHAIN_PREFIX is defined
"""

load("@rules_cc//cc:defs.bzl", "cc_common")
load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load(
    "@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl",
    "feature",
    flag_set_ = "flag_set",
    "flag_group",
    "tool_path",
    "with_feature_set",
)

# ==============================================================================
# Constants and Utilities
# ==============================================================================

_ALL_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.lto_backend,
    ACTION_NAMES.clif_match,
]

_ALL_CXX_COMPILE_ACTIONS = [
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
]

_ALL_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

def _get_target_constraints(target_triple):
    """Convert a Rust target triple to Bazel platform constraints."""
    parts = target_triple.split("-")
    if len(parts) < 2:
        fail("Invalid target triple: {}".format(target_triple))
    
    arch = parts[0]
    
    # CPU mapping from Rust arch to Bazel CPU
    # Based on: https://github.com/bazelbuild/platforms/blob/main/cpu/BUILD
    # Only using officially defined CPU constraints
    cpu_map = {
        # x86 architectures
        "i386": "i386",              # Official constraint
        "i586": "x86_32",            # Map to x86_32 
        "i686": "x86_32",            # Map to x86_32
        "x86_64": "x86_64",          # Official constraint
        
        # ARM 64-bit architectures  
        "aarch64": "aarch64",        # Official constraint
        "arm64": "aarch64",          # Alias -> aarch64
        "arm64_32": "arm64_32",      # Official constraint
        "arm64e": "arm64e",          # Official constraint
        
        # ARM 32-bit architectures - only official constraints
        "armv8-m": "armv8-m",        # Official: Cortex-M23, Cortex-M33, Cortex-M35P
        "armv7e-mf": "armv7e-mf",    # Official: Cortex-M4, Cortex-M7 with FPU
        "armv7e-m": "armv7e-m",      # Official: Cortex-M4, Cortex-M7
        "armv7-m": "armv7-m",        # Official: Cortex-M3
        "armv7k": "armv7k",          # Official: Apple Watch
        "armv7": "armv7",            # Official: General ARMv7
        "armv6-m": "armv6-m",        # Official: Cortex-M0, Cortex-M0+, Cortex-M1
        "arm": "aarch32",            # Official: Generic ARM 32-bit
        
        # WebAssembly
        "wasm32": "wasm32",          # Official constraint
        "wasm64": "wasm64",          # Official constraint
        
        # PowerPC
        "ppc": "ppc",                # Official constraint
        "ppc32": "ppc32",            # Official constraint
        "ppc64le": "ppc64le",        # Official constraint
        
        # RISC-V
        "riscv32": "riscv32",        # Official constraint
        "riscv64": "riscv64",        # Official constraint
        
        # MIPS
        "mips64": "mips64",          # Official constraint
        
        # IBM System z
        "s390x": "s390x",            # Official constraint
        
        # Cortex-R series
        "cortex-r52": "cortex-r52",  # Official: 32-bit
        "cortex-r82": "cortex-r82",  # Official: 64-bit
    }
    
    # Handle arch extraction and mapping
    bazel_cpu = "x86_64"  # default fallback
    
    # First try exact match
    if arch in cpu_map:
        bazel_cpu = cpu_map[arch]
    else:
        # Try prefix matching for more complex arch strings
        for cpu_key, cpu_value in cpu_map.items():
            if arch.startswith(cpu_key):
                bazel_cpu = cpu_value
                break
        
        # If still no match, try some fallback logic for common patterns
        if bazel_cpu == "x86_64":  # Still default
            if arch.startswith("armv"):
                # Map common ARM variants to official constraints
                if "armv8" in arch:
                    if "m" in arch:
                        bazel_cpu = "armv8-m"
                    else:
                        bazel_cpu = "aarch64"  # ARMv8 64-bit
                elif "armv7" in arch:
                    if "m" in arch:
                        bazel_cpu = "armv7-m"
                    elif "k" in arch:
                        bazel_cpu = "armv7k"
                    else:
                        bazel_cpu = "armv7"
                elif "armv6" in arch:
                    bazel_cpu = "armv6-m"
                else:
                    bazel_cpu = "aarch32"  # Generic ARM fallback
            elif arch.startswith("thumb"):
                # Map Thumb variants to corresponding ARM-M constraints
                if "v8" in arch:
                    bazel_cpu = "armv8-m"
                elif "v7" in arch:
                    if "em" in arch:
                        bazel_cpu = "armv7e-m"
                    else:
                        bazel_cpu = "armv7-m"
                elif "v6" in arch:
                    bazel_cpu = "armv6-m"
                else:
                    bazel_cpu = "aarch32"
            else:
                # For unknown architectures, try to use a reasonable default
                bazel_cpu = "x86_64"  # Keep default
    
    # OS mapping from target triple to Bazel OS
    # Order matters! More specific patterns should come first
    # Note: Starlark dict preserves insertion order (unlike old Python versions)
    # Based on: https://github.com/bazelbuild/platforms/blob/main/os/BUILD
    # Target triple format: <arch>-<vendor>-<sys>-<abi>
    # We only match against the <sys> (system/OS) part, not vendor fields like "pc" or "apple"
    # We also don't match ABI fields like "gnu" or "musl"
    os_map = {
        "android": "android",        # Must come before "linux"
        "emscripten": "emscripten",  # Emscripten has its own constraint
        "wasi": "wasi",              # WebAssembly System Interface
        "fuchsia": "fuchsia",        # Google Fuchsia OS
        "ios": "ios",                # Apple iOS
        "tvos": "tvos",              # Apple TV OS
        "watchos": "watchos",        # Apple Watch OS  
        "visionos": "visionos",      # Apple Vision OS
        "darwin": "osx",             # macOS (still named osx in platforms)
        "qnx": "qnx",                # QNX real-time OS
        "windows": "windows",        # Windows OS
        "nixos": "nixos",            # NixOS (Linux-based but not ABI compatible)
        "linux": "linux",            # Linux OS
        "freebsd": "freebsd",        # FreeBSD
        "netbsd": "netbsd",          # NetBSD
        "openbsd": "openbsd",        # OpenBSD
        "haiku": "haiku",            # Haiku OS
        "vxworks": "vxworks",        # VxWorks embedded OS
        "chromiumos": "chromiumos",  # Chrome OS
        "uefi": "uefi",              # UEFI environment
    }
    
    # Find OS from target triple
    bazel_os = "linux"  # default
    for os_key, os_value in os_map.items():
        if os_key in target_triple:
            bazel_os = os_value
            break
    
    cpu_constraint = "@platforms//cpu:" + bazel_cpu
    os_constraint = "@platforms//os:" + bazel_os
    
    return [cpu_constraint, os_constraint]

def _detect_builtin_include_directories(repository_ctx, gcc_path):
    """Detect builtin include directories from the toolchain."""
    if not gcc_path:
        return []
    
    # Run gcc with -E -v to get include search paths
    result = repository_ctx.execute([
        gcc_path, 
        "-E", "-v", "-x", "c++", "/dev/null"
    ], timeout = 10)
    
    if result.return_code != 0:
        # Could not detect builtin include directories from gcc
        return []
    
    # Parse the output to extract include directories
    lines = result.stderr.split('\n')
    include_dirs = []
    in_include_section = False
    
    for line in lines:
        line = line.strip()
        if line == "#include <...> search starts here:":
            in_include_section = True
            continue
        elif line == "End of search list.":
            in_include_section = False
            break
        elif in_include_section and line.startswith('/'):
            # Remove any trailing annotations like (framework directory)
            parts = line.split(" ")
            path = parts[0] if parts else line
            if path.startswith('/'):
                include_dirs.append(path)
    
    return include_dirs

def _detect_tool_paths(repository_ctx, target_triple):
    """Detect tool paths based on cross-rs environment variables."""
    prefix = repository_ctx.os.environ.get("CROSS_TOOLCHAIN_PREFIX", "")
    suffix = repository_ctx.os.environ.get("CROSS_TOOLCHAIN_SUFFIX", "")
    
    # Tool name mapping based on cross-rs rules
    if prefix == "em":
        # Emscripten special case
        tool_names = {
            "gcc": "emcc",
            "g++": "em++",
            "ar": "emar",
            "ld": "emcc",
            "strip": "emstrip",
            "nm": "emnm",
            "objcopy": "emcopy",
            "objdump": "emdump",
        }
    else:
        # Standard cross-compilation or native
        tool_names = {
            "gcc": prefix + "gcc" + suffix,
            "g++": prefix + "g++" + suffix,
            "ar": prefix + "ar" + suffix,
            "ld": prefix + "ld" + suffix,
            "strip": prefix + "strip" + suffix,
            "nm": prefix + "nm" + suffix,
            "objcopy": prefix + "objcopy" + suffix,
            "objdump": prefix + "objdump" + suffix,
        }
    
    # Find tools in PATH - required tools
    tool_paths = {}
    required_tools = ["gcc", "g++", "ar", "ld"]
    
    for tool_type, tool_name in tool_names.items():
        tool_path = repository_ctx.which(tool_name)
        if not tool_path:
            if tool_type in required_tools:
                fail("Required tool '{}' not found in PATH for target '{}'".format(tool_name, target_triple))
            else:
                # Use fallback for optional tools
                if tool_type in ["strip", "nm", "objcopy", "objdump"]:
                    # Try to find alternative tools or use gcc as fallback
                    fallback_tool = repository_ctx.which("gcc")
                    if fallback_tool:
                        tool_paths[tool_type] = str(fallback_tool)
                    else:
                        tool_paths[tool_type] = "/usr/bin/true"  # Safe fallback
                continue
        tool_paths[tool_type] = str(tool_path)
    
    # Add additional required tools with fallbacks
    tool_paths["gcov"] = tool_paths.get("gcov", tool_paths["gcc"])
    tool_paths["dwp"] = tool_paths.get("dwp", tool_paths["gcc"])
    
    return tool_paths

# ==============================================================================
# Toolchain Configuration Rule
# ==============================================================================

def _cross_rs_toolchain_config_impl(ctx):
    """Implementation for cross_rs_toolchain_config rule."""
    
    # Tool paths from attributes
    tool_paths = [
        tool_path(name = "gcc", path = ctx.attr.gcc_path),
        tool_path(name = "g++", path = ctx.attr.gxx_path),
        tool_path(name = "cpp", path = ctx.attr.gxx_path),  # Use g++ for cpp preprocessor
        tool_path(name = "ar", path = ctx.attr.ar_path),
        tool_path(name = "ld", path = ctx.attr.ld_path),
        tool_path(name = "strip", path = ctx.attr.strip_path),
        tool_path(name = "nm", path = ctx.attr.nm_path),
        tool_path(name = "objcopy", path = ctx.attr.objcopy_path),
        tool_path(name = "objdump", path = ctx.attr.objdump_path),
        tool_path(name = "gcov", path = ctx.attr.gcov_path),
        tool_path(name = "dwp", path = ctx.attr.dwp_path),
    ]
    
    # Features configuration - following official Bazel tutorial pattern
    features = []
    
    # Default compiler flags feature
    features.append(
        feature(
            name = "default_compile_flags",
            enabled = True,
            flag_sets = [
                # Common flags for all compile actions
                flag_set(
                    actions = _ALL_COMPILE_ACTIONS,
                    flags = [
                        "-no-canonical-prefixes",
                        "-fdata-sections",
                        "-ffunction-sections", 
                        "-g",
                        "-fPIC",
                    ],
                ),
                # C++ specific flags
                flag_set(
                    actions = _ALL_CXX_COMPILE_ACTIONS,
                    flags = [
                        "-std=c++17",
                    ],
                ),
            ],
        ),
    )
    
    # Default linker flags feature
    features.append(
        feature(
            name = "default_link_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_LINK_ACTIONS,
                    flags = [
                        "-no-canonical-prefixes",
                        "-Wl,--gc-sections",
                        "-Wl,--build-id=md5",
                        "-lc",
                        "-lm", 
                        "-latomic",
                        "-ldl",
                        "-lstdc++",
                    ],
                ),
            ],
        ),
    )
    
    # User compile flags feature
    features.append(
        feature(
            name = "user_compile_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_COMPILE_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["%{user_compile_flags}"],
                            iterate_over = "user_compile_flags",
                            expand_if_available = "user_compile_flags",
                        ),
                    ],
                ),
            ],
        ),
    )
    
    # User link flags feature
    features.append(
        feature(
            name = "user_link_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_LINK_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["%{user_link_flags}"],
                            iterate_over = "user_link_flags",
                            expand_if_available = "user_link_flags",
                        ),
                    ],
                ),
            ],
        ),
    )
    
    # Preprocessor defines feature
    features.append(
        feature(
            name = "preprocessor_defines",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_COMPILE_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["-D%{preprocessor_defines}"],
                            iterate_over = "preprocessor_defines",
                        ),
                    ],
                ),
            ],
        ),
    )
    
    # Include paths feature
    features.append(
        feature(
            name = "include_paths",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_COMPILE_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["-include", "%{includes}"],
                            iterate_over = "includes",
                            expand_if_available = "includes",
                        ),
                    ],
                ),
                flag_set(
                    actions = _ALL_COMPILE_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["-iquote", "%{quote_include_paths}"],
                            iterate_over = "quote_include_paths",
                        ),
                        flag_group(
                            flags = ["-I%{include_paths}"],
                            iterate_over = "include_paths",
                        ),
                        flag_group(
                            flags = ["-isystem", "%{system_include_paths}"],
                            iterate_over = "system_include_paths",
                        ),
                    ],
                ),
            ],
        ),
    )
    
    # Library search paths feature
    features.append(
        feature(
            name = "library_search_directories",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_LINK_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["-L%{library_search_directories}"],
                            iterate_over = "library_search_directories",
                            expand_if_available = "library_search_directories",
                        ),
                    ],
                ),
            ],
        ),
    )
    
    # Linkstamp paths feature
    features.append(
        feature(
            name = "linkstamp_paths",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _ALL_LINK_ACTIONS,
                    flag_groups = [
                        flag_group(
                            flags = ["%{linkstamp_paths}"],
                            iterate_over = "linkstamp_paths",
                            expand_if_available = "linkstamp_paths",
                        ),
                    ],
                ),
            ],
        ),
    )

    # Create toolchain config
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        features = features,
        toolchain_identifier = "cross_rs_toolchain_" + ctx.attr.target_triple,
        host_system_name = "local",
        target_system_name = ctx.attr.target_triple,
        target_cpu = ctx.attr.target_triple.split("-")[0],
        target_libc = "glibc",  # This could be made configurable
        compiler = "gcc",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        tool_paths = tool_paths,
        cxx_builtin_include_directories = ctx.attr.builtin_include_directories,
    )

cross_rs_toolchain_config = rule(
    implementation = _cross_rs_toolchain_config_impl,
    attrs = {
        "target_triple": attr.string(mandatory = True),
        "gcc_path": attr.string(),
        "gxx_path": attr.string(),
        "ar_path": attr.string(),
        "ld_path": attr.string(),
        "strip_path": attr.string(),
        "nm_path": attr.string(),
        "objcopy_path": attr.string(),
        "objdump_path": attr.string(),
        "gcov_path": attr.string(),
        "dwp_path": attr.string(),
        "builtin_include_directories": attr.string_list(),
    },
    provides = [CcToolchainConfigInfo],
) 

# ==============================================================================
# Repository Rule
# ==============================================================================

_BUILD_TEMPLATE = '''# Generated by cross_rs_toolchain_repository
load("@rules_cross_rs//:rules.bzl", "cross_rs_toolchain_config")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")

package(default_visibility = ["//visibility:public"])

cross_rs_toolchain_config(
    name = "toolchain_config",
    target_triple = "{target_triple}",
    gcc_path = "{gcc_path}",
    gxx_path = "{gxx_path}",
    ar_path = "{ar_path}",
    ld_path = "{ld_path}",
    strip_path = "{strip_path}",
    nm_path = "{nm_path}",
    objcopy_path = "{objcopy_path}",
    objdump_path = "{objdump_path}",
    gcov_path = "{gcov_path}",
    dwp_path = "{dwp_path}",
    builtin_include_directories = {builtin_include_directories},
)

cc_toolchain(
    name = "toolchain",
    toolchain_identifier = "cross_rs_toolchain_{target_triple}",
    toolchain_config = ":toolchain_config",
    all_files = ":empty",
    compiler_files = ":empty",
    linker_files = ":empty",
    dwp_files = ":empty",
    objcopy_files = ":empty",
    strip_files = ":empty",
    supports_param_files = 1,
)

filegroup(name = "empty")

toolchain(
    name = "toolchain_definition",
    toolchain = ":toolchain",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = {constraints},
)
'''

_STUB_BUILD_TEMPLATE = '''# Stub repository for cross_rs_toolchain when not in cross-rs environment
# This allows the module to be loaded without errors when TARGET or CROSS_TOOLCHAIN_PREFIX are unset
# Note: Empty string for CROSS_TOOLCHAIN_PREFIX is valid and means native compilation

package(default_visibility = ["//visibility:public"])

filegroup(name = "empty")

# Stub toolchain that will never be selected due to impossible constraints
toolchain(
    name = "toolchain_definition",
    toolchain = ":empty",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    exec_compatible_with = [
        "@platforms//os:none",  # Impossible constraint
    ],
    target_compatible_with = [
        "@platforms//os:none",  # Impossible constraint
    ],
)
'''

def _cross_rs_toolchain_repository_impl(repository_ctx):
    """Repository rule implementation for cross-rs toolchain."""
    
    # Get target triple from environment
    target_triple = repository_ctx.os.environ.get("TARGET")
    cross_toolchain_prefix = repository_ctx.os.environ.get("CROSS_TOOLCHAIN_PREFIX")
    
    # Only create stub repository if environment variables are completely unset
    # Empty string is valid for CROSS_TOOLCHAIN_PREFIX (means no prefix for native compilation)
    if target_triple == None or cross_toolchain_prefix == None:
        repository_ctx.file("BUILD.bazel", _STUB_BUILD_TEMPLATE)
        return
    
    # Detect tool paths
    tool_paths = _detect_tool_paths(repository_ctx, target_triple)
    
    # Detect builtin include directories
    builtin_include_dirs = _detect_builtin_include_directories(repository_ctx, tool_paths["gcc"])
    
    # Get platform constraints
    constraints = _get_target_constraints(target_triple)
    
    # Generate BUILD file from template
    build_content = _BUILD_TEMPLATE.format(
        target_triple = target_triple,
        gcc_path = tool_paths["gcc"],
        gxx_path = tool_paths["g++"],
        ar_path = tool_paths["ar"],
        ld_path = tool_paths["ld"],
        strip_path = tool_paths["strip"],
        nm_path = tool_paths["nm"],
        objcopy_path = tool_paths["objcopy"],
        objdump_path = tool_paths["objdump"],
        gcov_path = tool_paths["gcov"],
        dwp_path = tool_paths["dwp"],
        builtin_include_directories = repr(builtin_include_dirs),
        constraints = repr(constraints),
    )
    
    repository_ctx.file("BUILD.bazel", build_content)

cross_rs_toolchain_repository = repository_rule(
    implementation = _cross_rs_toolchain_repository_impl,
    local = True,
    environ = [
        "TARGET",
        "CROSS_TOOLCHAIN_PREFIX",
        "CROSS_TOOLCHAIN_SUFFIX", 
        "PATH",
    ],
)

# ==============================================================================
# Module Extension
# ==============================================================================

def _cross_rs_extension_impl(module_ctx):
    """Module extension implementation for cross-rs toolchain."""
    
    # Always create the repository, but it will be a stub if not in cross-rs environment
    # This ensures use_repo() in MODULE.bazel always succeeds
    cross_rs_toolchain_repository(
        name = "cross_rs_toolchain",
    )

cross_rs_extension = module_extension(
    implementation = _cross_rs_extension_impl,
    environ = [
        "TARGET",
        "CROSS_TOOLCHAIN_PREFIX",
        "CROSS_TOOLCHAIN_SUFFIX",
        "CROSS_SYSROOT",
        "PATH",
    ],
)

# ==============================================================================
# Public API
# ==============================================================================

def cross_rs_target(name):
    """Create a platform definition for a cross-rs target."""
    constraints = _get_target_constraints(name)
    native.platform(
        name = name,
        constraint_values = constraints,
    )

def cross_rs_targets(name, targets):
    """Public API for creating cross-rs toolchains.
    
    Args:
        name: The name of the macro (unused but required by convention).
        targets: List of target triples to create platforms for.
    """
    for target in targets:
        cross_rs_target(name = target) 


def flag_set(flags = None, features = None, not_features = None, **kwargs):
    """Extension to flag_set which allows for a "simple" form.

    The simple form allows specifying flags as a simple list instead of a flag_group
    if enable_if or expand_if semantics are not required.

    Similarly, the simple form allows passing features/not_features if they are a simple
    list of semantically "and" features.
    (i.e. "asan" and "dbg", rather than "asan" or "dbg")

    Args:
      flags: list, set of flags
      features: list, set of features required to be enabled.
      not_features: list, set of features required to not be enabled.
      **kwargs: The rest of the args for flag_set.

    Returns:
      flag_set
    """
    if flags:
        if kwargs.get("flag_groups"):
            fail("Cannot set flags and flag_groups")
        else:
            kwargs["flag_groups"] = [flag_group(flags = flags)]

    if features or not_features:
        if kwargs.get("with_features"):
            fail("Cannot set features/not_feature and with_features")
        kwargs["with_features"] = [with_feature_set(
            features = features or [],
            not_features = not_features or [],
        )]
    return flag_set_(**kwargs)
