//! The Flat Engine: Ultra-High-Performance CSS Engine
//!
//! A Data-Oriented Design (DoD) CSS engine targeting WebAssembly.
//! Optimized for execution speed through:
//! - Structure of Arrays (SoA) memory layout
//! - String interning with comptime-hashed keywords
//! - Bloom filters for early selector rejection
//! - Bytecode VM for selector matching
//! - SIMD operations for style computation
//!
//! Architecture:
//! - No pointers: All references use u32 indices
//! - Arena allocation for bulk memory management
//! - Right-to-left selector matching

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Public API Exports
// ============================================================================

pub const atom = @import("atom.zig");
pub const bloom = @import("bloom.zig");
pub const flat_dom = @import("flat_dom.zig");
pub const selector_vm = @import("selector_vm.zig");

// Re-export commonly used types
pub const AtomId = atom.AtomId;
pub const AtomTable = atom.AtomTable;
pub const BloomFilter = bloom.BloomFilter;
pub const FlatDOM = flat_dom.FlatDOM;
pub const NodeId = flat_dom.NodeId;
pub const SelectorVM = selector_vm.SelectorVM;
pub const CompiledSelector = selector_vm.CompiledSelector;
pub const SelectorCompiler = selector_vm.SelectorCompiler;

// Constants
pub const NULL_ATOM = atom.NULL_ATOM;
pub const NULL_NODE = flat_dom.NULL_NODE;

// Comptime hashes for known keywords
pub const tags = atom.tags;
pub const props = atom.props;
pub const values = atom.values;

// ============================================================================
// Engine State (Global for Wasm)
// ============================================================================

/// Global engine state for Wasm exports
/// Using a single global state simplifies the Wasm interface
var global_state: ?*EngineState = null;

const EngineState = struct {
    allocator: std.mem.Allocator,
    atoms: AtomTable,
    dom: ?FlatDOM,
    vm: SelectorVM,
    selectors: std.ArrayList(CompiledSelector),
    compiler: ?SelectorCompiler,

    fn init(allocator: std.mem.Allocator) !*EngineState {
        const state = try allocator.create(EngineState);
        state.* = .{
            .allocator = allocator,
            .atoms = try AtomTable.init(allocator),
            .dom = null,
            .vm = SelectorVM.init(allocator),
            .selectors = std.ArrayList(CompiledSelector).init(allocator),
            .compiler = null,
        };
        return state;
    }

    fn deinit(self: *EngineState) void {
        for (self.selectors.items) |selector| {
            self.allocator.free(selector.bytecode);
        }
        self.selectors.deinit();
        if (self.dom) |*dom| {
            dom.deinit();
        }
        self.atoms.deinit();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Wasm Allocator
// ============================================================================

/// Wasm-compatible allocator using the memory.grow instruction
const WasmAllocator = struct {
    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
        // Simple bump allocator - in production, use a proper allocator
        const pages_needed = (len + 65535) / 65536;
        const result = @wasmMemoryGrow(0, pages_needed);
        if (result == -1) return null;
        const base: usize = @intCast(result * 65536);
        return @ptrFromInt(base);
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {
        // No-op for wasm bump allocator
    }

    fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &vtable,
        };
    }
};

fn getDefaultAllocator() std.mem.Allocator {
    if (builtin.target.isWasm()) {
        return WasmAllocator.allocator();
    } else {
        return std.heap.page_allocator;
    }
}

// ============================================================================
// Wasm Export Functions
// ============================================================================

/// Initialize the engine
export fn flat_engine_init() i32 {
    const allocator = getDefaultAllocator();
    global_state = EngineState.init(allocator) catch return -1;
    return 0;
}

/// Create a new DOM
export fn flat_engine_create_dom() i32 {
    const state = global_state orelse return -1;
    if (state.dom != null) {
        state.dom.?.deinit();
    }
    state.dom = FlatDOM.init(state.allocator, &state.atoms) catch return -1;
    state.compiler = SelectorCompiler.init(state.allocator, &state.atoms);
    return 0;
}

/// Add a node to the DOM
/// Returns the node ID or -1 on error
export fn flat_engine_add_node(tag_atom: u32, parent: u32) i32 {
    const state = global_state orelse return -1;
    var dom = &(state.dom orelse return -1);
    const node = dom.createElement(tag_atom, parent) catch return -1;
    return @intCast(node);
}

/// Intern a string and return its atom ID
export fn flat_engine_intern_string(ptr: [*]const u8, len: u32) i32 {
    const state = global_state orelse return -1;
    const str = ptr[0..len];
    const atom_id = state.atoms.intern(str) catch return -1;
    return @intCast(atom_id);
}

/// Compile a selector
/// Returns selector index or -1 on error
export fn flat_engine_compile_selector(ptr: [*]const u8, len: u32) i32 {
    const state = global_state orelse return -1;
    var compiler = state.compiler orelse return -1;
    const selector_str = ptr[0..len];
    const selector = compiler.compileSimple(selector_str) catch return -1;
    state.selectors.append(selector) catch {
        state.allocator.free(selector.bytecode);
        return -1;
    };
    return @intCast(state.selectors.items.len - 1);
}

/// Match a selector against a node
/// Returns 1 if matched, 0 if not, -1 on error
export fn flat_engine_match_selector(selector_idx: u32, node: u32) i32 {
    const state = global_state orelse return -1;
    const dom = &(state.dom orelse return -1);

    if (selector_idx >= state.selectors.items.len) return -1;
    const selector = state.selectors.items[selector_idx];

    const matched = state.vm.execute(selector, dom, node);
    return if (matched) 1 else 0;
}

// ============================================================================
// Native API (for non-Wasm usage)
// ============================================================================

/// Create a new engine instance for native usage
pub fn createEngine(allocator: std.mem.Allocator) !*EngineState {
    return EngineState.init(allocator);
}

/// Destroy an engine instance
pub fn destroyEngine(state: *EngineState) void {
    state.deinit();
}

// ============================================================================
// SIMD Utilities (for style computation)
// ============================================================================

/// 4-component vector for RGBA colors and geometry
pub const Vec4 = @Vector(4, f32);

/// RGBA color operations using SIMD
pub const Color = struct {
    /// Create color from RGBA values (0-255)
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Vec4 {
        return Vec4{
            @as(f32, @floatFromInt(r)) / 255.0,
            @as(f32, @floatFromInt(g)) / 255.0,
            @as(f32, @floatFromInt(b)) / 255.0,
            @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Blend two colors
    pub fn blend(src: Vec4, dst: Vec4) Vec4 {
        const src_alpha: Vec4 = @splat(src[3]);
        const one_minus_alpha: Vec4 = @splat(1.0 - src[3]);
        return src * src_alpha + dst * one_minus_alpha;
    }

    /// Premultiply alpha
    pub fn premultiply(color: Vec4) Vec4 {
        const alpha: Vec4 = @splat(color[3]);
        return Vec4{
            color[0] * alpha[0],
            color[1] * alpha[1],
            color[2] * alpha[2],
            color[3],
        };
    }

    /// Convert to packed u32 (ARGB)
    pub fn toU32(color: Vec4) u32 {
        const r: u32 = @intFromFloat(color[0] * 255.0);
        const g: u32 = @intFromFloat(color[1] * 255.0);
        const b: u32 = @intFromFloat(color[2] * 255.0);
        const a: u32 = @intFromFloat(color[3] * 255.0);
        return (a << 24) | (r << 16) | (g << 8) | b;
    }
};

/// Geometry operations using SIMD (x, y, width, height)
pub const Rect = struct {
    pub fn create(x: f32, y: f32, w: f32, h: f32) Vec4 {
        return Vec4{ x, y, w, h };
    }

    pub fn translate(rect: Vec4, offset: Vec4) Vec4 {
        return rect + Vec4{ offset[0], offset[1], 0, 0 };
    }

    pub fn scale(rect: Vec4, factor: f32) Vec4 {
        const s: Vec4 = @splat(factor);
        return rect * s;
    }

    pub fn contains(rect: Vec4, point: Vec4) bool {
        return point[0] >= rect[0] and
            point[0] <= rect[0] + rect[2] and
            point[1] >= rect[1] and
            point[1] <= rect[1] + rect[3];
    }

    pub fn intersects(a: Vec4, b: Vec4) bool {
        return !(a[0] + a[2] < b[0] or
            b[0] + b[2] < a[0] or
            a[1] + a[3] < b[1] or
            b[1] + b[3] < a[1]);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "all modules" {
    _ = atom;
    _ = bloom;
    _ = flat_dom;
    _ = selector_vm;
}

test "SIMD color operations" {
    const red = Color.rgba(255, 0, 0, 255);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), red[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), red[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), red[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), red[3], 0.01);

    const packed = Color.toU32(red);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), packed);
}

test "SIMD rect operations" {
    const rect = Rect.create(10, 20, 100, 50);
    const point_inside = Vec4{ 50, 30, 0, 0 };
    const point_outside = Vec4{ 200, 30, 0, 0 };

    try std.testing.expect(Rect.contains(rect, point_inside));
    try std.testing.expect(!Rect.contains(rect, point_outside));
}

test "end-to-end selector matching" {
    var atoms_table = try AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    // Build: <div class="container"><span class="item"></span></div>
    const div_tag = try atoms_table.intern("div");
    const span_tag = try atoms_table.intern("span");
    const container = try atoms_table.intern("container");
    const item = try atoms_table.intern("item");

    const div = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(div, &[_]AtomId{container});

    const span = try dom.createElement(span_tag, div);
    try dom.setClasses(span, &[_]AtomId{item});

    // Compile and test selector
    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple(".container");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);

    try std.testing.expect(vm.execute(selector, &dom, div));
    try std.testing.expect(!vm.execute(selector, &dom, span));
}
