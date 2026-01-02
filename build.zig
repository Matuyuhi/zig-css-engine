const std = @import("std");

pub fn build(b: *std.Build) void {
    // Primary target: wasm32-freestanding for maximum portability
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .simd128, // Enable SIMD for vector operations
            .bulk_memory, // Enable bulk memory operations
        }),
    });

    // Native target for testing
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================
    // Wasm Library (Primary Build)
    // ========================================
    const wasm_lib = b.addStaticLibrary(.{
        .name = "flat_engine",
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast, // Always optimize for speed in wasm
    });

    // Wasm-specific settings
    wasm_lib.rdynamic = true; // Export all public functions
    wasm_lib.entry = .disabled; // No entry point for library
    wasm_lib.root_module.export_symbol_names = &.{
        "flat_engine_init",
        "flat_engine_create_dom",
        "flat_engine_add_node",
        "flat_engine_compile_selector",
        "flat_engine_match_selector",
        "flat_engine_intern_string",
    };

    b.installArtifact(wasm_lib);

    // ========================================
    // Native Library (for testing/benchmarking)
    // ========================================
    const native_lib = b.addStaticLibrary(.{
        .name = "flat_engine_native",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });

    b.installArtifact(native_lib);

    // ========================================
    // Unit Tests
    // ========================================
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ========================================
    // Benchmarks
    // ========================================
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ========================================
    // Documentation
    // ========================================
    const docs = b.addStaticLibrary(.{
        .name = "flat_engine_docs",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = .Debug,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
