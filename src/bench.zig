//! Benchmarks for The Flat Engine
//!
//! Run with: zig build bench

const std = @import("std");
const root = @import("root.zig");
const AtomTable = root.AtomTable;
const FlatDOM = root.FlatDOM;
const SelectorVM = root.SelectorVM;
const SelectorCompiler = root.SelectorCompiler;
const AtomId = root.AtomId;
const NULL_NODE = root.NULL_NODE;

const WARMUP_ITERATIONS = 100;
const BENCH_ITERATIONS = 10_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n=== The Flat Engine Benchmarks ===\n\n", .{});

    try benchAtomTable(allocator, stdout);
    try benchDOMCreation(allocator, stdout);
    try benchSelectorMatching(allocator, stdout);
    try benchBloomFilter(stdout);
}

fn benchAtomTable(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("--- AtomTable ---\n", .{});

    var atoms = try AtomTable.init(allocator);
    defer atoms.deinit();

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "warmup-{d}", .{i}) catch unreachable;
        _ = try atoms.intern(str);
    }

    // Benchmark interning new strings
    var timer = try std.time.Timer.start();
    for (0..BENCH_ITERATIONS) |i| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "bench-string-{d}", .{i}) catch unreachable;
        _ = try atoms.intern(str);
    }
    const intern_ns = timer.read();

    try writer.print("  Intern {d} strings: {d:.2} ms ({d:.0} ns/op)\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(intern_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(intern_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS)),
    });

    // Benchmark lookups (deduplication)
    timer.reset();
    for (0..BENCH_ITERATIONS) |i| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "bench-string-{d}", .{i % 1000}) catch unreachable;
        _ = try atoms.intern(str);
    }
    const lookup_ns = timer.read();

    try writer.print("  Lookup {d} strings: {d:.2} ms ({d:.0} ns/op)\n\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(lookup_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(lookup_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS)),
    });
}

fn benchDOMCreation(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("--- DOM Creation ---\n", .{});

    var atoms = try AtomTable.init(allocator);
    defer atoms.deinit();

    const div_tag = try atoms.intern("div");
    const span_tag = try atoms.intern("span");
    const p_tag = try atoms.intern("p");
    const container = try atoms.intern("container");
    const flex = try atoms.intern("flex");

    var dom = try FlatDOM.init(allocator, &atoms);
    defer dom.deinit();

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        _ = try dom.createElement(div_tag, NULL_NODE);
    }

    // Benchmark element creation
    var timer = try std.time.Timer.start();
    var parent = NULL_NODE;
    for (0..BENCH_ITERATIONS) |i| {
        const tag = switch (i % 3) {
            0 => div_tag,
            1 => span_tag,
            else => p_tag,
        };
        const node = try dom.createElement(tag, parent);
        if (i % 10 == 0) parent = node; // Create some hierarchy
    }
    const create_ns = timer.read();

    try writer.print("  Create {d} nodes: {d:.2} ms ({d:.0} ns/op)\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(create_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(create_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS)),
    });

    // Benchmark class assignment
    const classes = [_]AtomId{ container, flex };
    timer.reset();
    for (1..@min(BENCH_ITERATIONS + 1, dom.nodeCount())) |i| {
        try dom.setClasses(@intCast(i), &classes);
    }
    const class_ns = timer.read();

    try writer.print("  Set classes on {d} nodes: {d:.2} ms ({d:.0} ns/op)\n\n", .{
        @min(BENCH_ITERATIONS, dom.nodeCount() - 1),
        @as(f64, @floatFromInt(class_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(class_ns)) / @as(f64, @floatFromInt(@min(BENCH_ITERATIONS, dom.nodeCount() - 1))),
    });
}

fn benchSelectorMatching(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("--- Selector Matching ---\n", .{});

    var atoms = try AtomTable.init(allocator);
    defer atoms.deinit();

    var dom = try FlatDOM.init(allocator, &atoms);
    defer dom.deinit();

    // Build a DOM tree
    const div_tag = try atoms.intern("div");
    const span_tag = try atoms.intern("span");
    const container = try atoms.intern("container");
    const item = try atoms.intern("item");
    const active = try atoms.intern("active");

    // Create 1000 nodes in a tree structure
    var nodes: [1000]root.NodeId = undefined;
    nodes[0] = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(nodes[0], &[_]AtomId{container});

    for (1..1000) |i| {
        const parent_idx = (i - 1) / 10;
        const tag = if (i % 2 == 0) div_tag else span_tag;
        nodes[i] = try dom.createElement(tag, nodes[parent_idx]);
        if (i % 3 == 0) {
            try dom.setClasses(nodes[i], &[_]AtomId{item});
        } else if (i % 5 == 0) {
            try dom.setClasses(nodes[i], &[_]AtomId{ item, active });
        }
    }

    var compiler = SelectorCompiler.init(allocator, &atoms);
    const vm = SelectorVM.init(allocator);

    // Simple tag selector
    const tag_selector = try compiler.compileSimple("div");
    defer allocator.free(tag_selector.bytecode);

    var timer = try std.time.Timer.start();
    var matches: u32 = 0;
    for (0..BENCH_ITERATIONS) |_| {
        for (nodes) |node| {
            if (vm.execute(tag_selector, &dom, node)) {
                matches += 1;
            }
        }
    }
    const tag_ns = timer.read();

    try writer.print("  Tag selector ({d}x1000 nodes): {d:.2} ms ({d:.0} ns/match)\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(tag_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(tag_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS * 1000)),
    });

    // Class selector
    const class_selector = try compiler.compileSimple(".item");
    defer allocator.free(class_selector.bytecode);

    timer.reset();
    matches = 0;
    for (0..BENCH_ITERATIONS) |_| {
        for (nodes) |node| {
            if (vm.execute(class_selector, &dom, node)) {
                matches += 1;
            }
        }
    }
    const class_ns = timer.read();

    try writer.print("  Class selector ({d}x1000 nodes): {d:.2} ms ({d:.0} ns/match)\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(class_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(class_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS * 1000)),
    });

    // Compound selector
    const compound_selector = try compiler.compileSimple("div.item.active");
    defer allocator.free(compound_selector.bytecode);

    timer.reset();
    matches = 0;
    for (0..BENCH_ITERATIONS) |_| {
        for (nodes) |node| {
            if (vm.execute(compound_selector, &dom, node)) {
                matches += 1;
            }
        }
    }
    const compound_ns = timer.read();

    try writer.print("  Compound selector ({d}x1000 nodes): {d:.2} ms ({d:.0} ns/match)\n\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(compound_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(compound_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS * 1000)),
    });
}

fn benchBloomFilter(writer: anytype) !void {
    try writer.print("--- Bloom Filter ---\n", .{});

    const root_mod = @import("root.zig");
    const BloomFilter = root_mod.BloomFilter;
    const fnv1a = root_mod.atom.fnv1a;

    var filter = BloomFilter.empty();

    // Add items
    var timer = try std.time.Timer.start();
    for (0..BENCH_ITERATIONS) |i| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "class-{d}", .{i}) catch unreachable;
        filter.add(fnv1a(str));
    }
    const add_ns = timer.read();

    try writer.print("  Add {d} items: {d:.2} ms ({d:.0} ns/op)\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(add_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(add_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS)),
    });

    // Query items
    timer.reset();
    var found: u32 = 0;
    for (0..BENCH_ITERATIONS) |i| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "class-{d}", .{i % 1000}) catch unreachable;
        if (filter.mightContain(fnv1a(str))) {
            found += 1;
        }
    }
    const query_ns = timer.read();

    try writer.print("  Query {d} items: {d:.2} ms ({d:.0} ns/op)\n\n", .{
        BENCH_ITERATIONS,
        @as(f64, @floatFromInt(query_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(query_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS)),
    });
}
