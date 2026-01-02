//! SelectorVM: Bytecode Virtual Machine for CSS Selector Matching
//!
//! CSS selectors are compiled into bytecode opcodes to avoid recursive
//! function calls during matching. The VM executes matching right-to-left
//! (from the key selector towards ancestors).
//!
//! Key optimizations:
//! - Bloom filter pre-check for ancestor matching
//! - Flat bytecode avoids function call overhead
//! - Register-based VM with node stack for combinators

const std = @import("std");
const Allocator = std.mem.Allocator;
const atom = @import("atom.zig");
const bloom = @import("bloom.zig");
const flat_dom = @import("flat_dom.zig");
const AtomId = atom.AtomId;
const BloomFilter = bloom.BloomFilter;
const FlatDOM = flat_dom.FlatDOM;
const NodeId = flat_dom.NodeId;
const NULL_NODE = flat_dom.NULL_NODE;

// ============================================================================
// Bytecode Opcodes
// ============================================================================

/// Opcode definitions for the selector VM
/// Using u8 for opcode to pack instructions tightly
pub const Opcode = enum(u8) {
    // === Match Operations (test current node) ===

    /// Match tag name: [MATCH_TAG, atom_id (u32)]
    match_tag = 0x01,
    /// Match ID: [MATCH_ID, atom_id (u32)]
    match_id = 0x02,
    /// Match class: [MATCH_CLASS, atom_id (u32)]
    match_class = 0x03,
    /// Match attribute existence: [MATCH_ATTR, name_atom (u32)]
    match_attr = 0x04,
    /// Match attribute value exactly: [MATCH_ATTR_EQ, name_atom (u32), value_atom (u32)]
    match_attr_eq = 0x05,
    /// Match attribute value contains word: [MATCH_ATTR_WORD, name_atom (u32), value_atom (u32)]
    match_attr_word = 0x06,
    /// Match attribute value starts with: [MATCH_ATTR_PREFIX, name_atom (u32), value_atom (u32)]
    match_attr_prefix = 0x07,
    /// Match attribute value ends with: [MATCH_ATTR_SUFFIX, name_atom (u32), value_atom (u32)]
    match_attr_suffix = 0x08,
    /// Match attribute value contains: [MATCH_ATTR_SUBSTR, name_atom (u32), value_atom (u32)]
    match_attr_substr = 0x09,
    /// Match universal selector (*): [MATCH_ANY]
    match_any = 0x0A,

    // === Pseudo-class Operations ===

    /// Match :first-child: [PSEUDO_FIRST_CHILD]
    pseudo_first_child = 0x10,
    /// Match :last-child: [PSEUDO_LAST_CHILD]
    pseudo_last_child = 0x11,
    /// Match :only-child: [PSEUDO_ONLY_CHILD]
    pseudo_only_child = 0x12,
    /// Match :nth-child(an+b): [PSEUDO_NTH_CHILD, a (i16), b (i16)]
    pseudo_nth_child = 0x13,
    /// Match :nth-last-child(an+b): [PSEUDO_NTH_LAST_CHILD, a (i16), b (i16)]
    pseudo_nth_last_child = 0x14,
    /// Match :empty: [PSEUDO_EMPTY]
    pseudo_empty = 0x15,
    /// Match :root: [PSEUDO_ROOT]
    pseudo_root = 0x16,

    // === Combinator Operations (navigate tree) ===

    /// Descendant combinator (space): [COMB_DESCENDANT]
    /// Uses bloom filter for early rejection
    comb_descendant = 0x20,
    /// Child combinator (>): [COMB_CHILD]
    comb_child = 0x21,
    /// Adjacent sibling combinator (+): [COMB_ADJACENT]
    comb_adjacent = 0x22,
    /// General sibling combinator (~): [COMB_SIBLING]
    comb_sibling = 0x23,

    // === Control Flow ===

    /// Jump if match failed: [JUMP_FAIL, offset (i16)]
    jump_fail = 0x30,
    /// Unconditional jump: [JUMP, offset (i16)]
    jump = 0x31,
    /// Jump to try alternative (for :is(), :where()): [JUMP_ALT, offset (i16)]
    jump_alt = 0x32,

    // === Bloom Filter Operations ===

    /// Pre-check bloom filter for class: [BLOOM_CHECK_CLASS, hash (u32)]
    bloom_check_class = 0x40,
    /// Pre-check bloom filter for ID: [BLOOM_CHECK_ID, hash (u32)]
    bloom_check_id = 0x41,
    /// Pre-check bloom filter for tag: [BLOOM_CHECK_TAG, hash (u32)]
    bloom_check_tag = 0x42,

    // === Terminal Operations ===

    /// Match succeeded: [MATCH_SUCCESS]
    match_success = 0xFE,
    /// Match failed: [MATCH_FAIL]
    match_fail = 0xFF,
};

// ============================================================================
// Compiled Selector
// ============================================================================

/// A compiled CSS selector ready for VM execution
pub const CompiledSelector = struct {
    /// Bytecode instructions
    bytecode: []const u8,
    /// Specificity (a, b, c) packed into u32: a*65536 + b*256 + c
    specificity: u32,
    /// Source selector string (for debugging)
    source: ?[]const u8,

    const Self = @This();

    /// Get specificity components
    pub fn getSpecificity(self: Self) struct { a: u8, b: u8, c: u8 } {
        return .{
            .a = @intCast((self.specificity >> 16) & 0xFF),
            .b = @intCast((self.specificity >> 8) & 0xFF),
            .c = @intCast(self.specificity & 0xFF),
        };
    }
};

// ============================================================================
// Bytecode Builder
// ============================================================================

/// Builder for creating selector bytecode
pub const BytecodeBuilder = struct {
    buffer: std.ArrayList(u8),
    specificity_a: u8,
    specificity_b: u8,
    specificity_c: u8,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
            .specificity_a = 0,
            .specificity_b = 0,
            .specificity_c = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    /// Emit a single opcode
    pub fn emit(self: *Self, op: Opcode) !void {
        try self.buffer.append(@intFromEnum(op));
    }

    /// Emit opcode with u32 operand
    pub fn emitWithU32(self: *Self, op: Opcode, operand: u32) !void {
        try self.buffer.append(@intFromEnum(op));
        try self.buffer.appendSlice(&std.mem.toBytes(operand));
    }

    /// Emit opcode with two u32 operands
    pub fn emitWithU32U32(self: *Self, op: Opcode, op1: u32, op2: u32) !void {
        try self.buffer.append(@intFromEnum(op));
        try self.buffer.appendSlice(&std.mem.toBytes(op1));
        try self.buffer.appendSlice(&std.mem.toBytes(op2));
    }

    /// Emit opcode with i16 operand
    pub fn emitWithI16(self: *Self, op: Opcode, operand: i16) !void {
        try self.buffer.append(@intFromEnum(op));
        try self.buffer.appendSlice(&std.mem.toBytes(operand));
    }

    /// Emit opcode with two i16 operands (for nth-child)
    pub fn emitWithI16I16(self: *Self, op: Opcode, a: i16, b: i16) !void {
        try self.buffer.append(@intFromEnum(op));
        try self.buffer.appendSlice(&std.mem.toBytes(a));
        try self.buffer.appendSlice(&std.mem.toBytes(b));
    }

    /// Emit tag match (contributes to specificity c)
    pub fn emitMatchTag(self: *Self, tag_atom: AtomId) !void {
        try self.emitWithU32(.match_tag, tag_atom);
        self.specificity_c +|= 1;
    }

    /// Emit ID match (contributes to specificity a)
    pub fn emitMatchId(self: *Self, id_atom: AtomId) !void {
        try self.emitWithU32(.match_id, id_atom);
        self.specificity_a +|= 1;
    }

    /// Emit class match (contributes to specificity b)
    pub fn emitMatchClass(self: *Self, class_atom: AtomId) !void {
        try self.emitWithU32(.match_class, class_atom);
        self.specificity_b +|= 1;
    }

    /// Emit bloom filter pre-check for class
    pub fn emitBloomCheckClass(self: *Self, hash: u32) !void {
        try self.emitWithU32(.bloom_check_class, hash);
    }

    /// Emit descendant combinator with bloom filter hint
    pub fn emitDescendantWithBloom(self: *Self, required_hash: u32) !void {
        try self.emitWithU32(.bloom_check_class, required_hash);
        try self.emit(.comb_descendant);
    }

    /// Current bytecode offset (for jump calculations)
    pub fn currentOffset(self: Self) u32 {
        return @intCast(self.buffer.items.len);
    }

    /// Patch a jump offset at a given position
    pub fn patchJump(self: *Self, pos: u32, target: u32) void {
        const offset: i16 = @intCast(@as(i32, @intCast(target)) - @as(i32, @intCast(pos)) - 3);
        const bytes = std.mem.toBytes(offset);
        self.buffer.items[pos + 1] = bytes[0];
        self.buffer.items[pos + 2] = bytes[1];
    }

    /// Finalize and return the compiled selector
    pub fn build(self: *Self, source: ?[]const u8) CompiledSelector {
        const specificity = (@as(u32, self.specificity_a) << 16) |
            (@as(u32, self.specificity_b) << 8) |
            @as(u32, self.specificity_c);

        return .{
            .bytecode = self.buffer.toOwnedSlice() catch &[_]u8{},
            .specificity = specificity,
            .source = source,
        };
    }
};

// ============================================================================
// Selector VM
// ============================================================================

/// Execution context for the selector VM
pub const VMContext = struct {
    /// Current node being matched
    node: NodeId,
    /// Reference to the DOM
    dom: *const FlatDOM,
    /// Match result
    matched: bool,
    /// Node stack for backtracking (descendant combinator)
    node_stack: [32]NodeId,
    /// Node stack pointer
    stack_ptr: u8,
};

/// The Selector Virtual Machine
pub const SelectorVM = struct {
    /// Memory allocator
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Execute a compiled selector against a node
    /// Returns true if the selector matches
    pub fn execute(self: *const Self, selector: CompiledSelector, dom: *const FlatDOM, node: NodeId) bool {
        _ = self;

        if (selector.bytecode.len == 0) return false;
        if (node == NULL_NODE) return false;

        var ctx = VMContext{
            .node = node,
            .dom = dom,
            .matched = true,
            .node_stack = undefined,
            .stack_ptr = 0,
        };

        var ip: u32 = 0;
        const code = selector.bytecode;

        while (ip < code.len) {
            const op: Opcode = @enumFromInt(code[ip]);
            ip += 1;

            switch (op) {
                // === Match Operations ===
                .match_tag => {
                    const tag_atom = readU32(code, ip);
                    ip += 4;
                    ctx.matched = dom.getTag(ctx.node) == tag_atom;
                },
                .match_id => {
                    const id_atom = readU32(code, ip);
                    ip += 4;
                    ctx.matched = dom.getId(ctx.node) == id_atom;
                },
                .match_class => {
                    const class_atom = readU32(code, ip);
                    ip += 4;
                    ctx.matched = dom.hasClass(ctx.node, class_atom);
                },
                .match_attr => {
                    const _name_atom = readU32(code, ip);
                    ip += 4;
                    // TODO: Implement attribute checking
                    ctx.matched = false;
                },
                .match_any => {
                    ctx.matched = dom.isElement(ctx.node);
                },

                // === Pseudo-classes ===
                .pseudo_first_child => {
                    ctx.matched = dom.getPrevSibling(ctx.node) == NULL_NODE;
                },
                .pseudo_last_child => {
                    ctx.matched = dom.getNextSibling(ctx.node) == NULL_NODE;
                },
                .pseudo_only_child => {
                    ctx.matched = dom.getPrevSibling(ctx.node) == NULL_NODE and
                        dom.getNextSibling(ctx.node) == NULL_NODE;
                },
                .pseudo_nth_child => {
                    const a = readI16(code, ip);
                    const b = readI16(code, ip + 2);
                    ip += 4;
                    ctx.matched = matchNthChild(dom, ctx.node, a, b);
                },
                .pseudo_nth_last_child => {
                    const a = readI16(code, ip);
                    const b = readI16(code, ip + 2);
                    ip += 4;
                    ctx.matched = matchNthLastChild(dom, ctx.node, a, b);
                },
                .pseudo_empty => {
                    ctx.matched = dom.getFirstChild(ctx.node) == NULL_NODE;
                },
                .pseudo_root => {
                    ctx.matched = dom.getParent(ctx.node) == NULL_NODE or
                        dom.getDepth(ctx.node) == 1;
                },

                // === Combinators ===
                .comb_descendant => {
                    if (!ctx.matched) {
                        // Try backtracking
                        if (ctx.stack_ptr > 0) {
                            ctx.stack_ptr -= 1;
                            ctx.node = ctx.node_stack[ctx.stack_ptr];
                            ctx.matched = true;
                            // Re-execute from the same position
                            ip -= 1;
                            continue;
                        }
                        return false;
                    }
                    // Push current node for backtracking
                    if (ctx.stack_ptr < ctx.node_stack.len) {
                        ctx.node_stack[ctx.stack_ptr] = dom.getParent(ctx.node);
                        ctx.stack_ptr += 1;
                    }
                    // Move to parent
                    ctx.node = dom.getParent(ctx.node);
                    if (ctx.node == NULL_NODE) return false;
                    ctx.matched = true;
                },
                .comb_child => {
                    if (!ctx.matched) return false;
                    ctx.node = dom.getParent(ctx.node);
                    if (ctx.node == NULL_NODE) return false;
                    ctx.matched = true;
                },
                .comb_adjacent => {
                    if (!ctx.matched) return false;
                    ctx.node = dom.getPrevSibling(ctx.node);
                    if (ctx.node == NULL_NODE) return false;
                    // Skip non-element siblings
                    while (ctx.node != NULL_NODE and !dom.isElement(ctx.node)) {
                        ctx.node = dom.getPrevSibling(ctx.node);
                    }
                    if (ctx.node == NULL_NODE) return false;
                    ctx.matched = true;
                },
                .comb_sibling => {
                    if (!ctx.matched) return false;
                    // Find any previous sibling that matches
                    ctx.node = dom.getPrevSibling(ctx.node);
                    if (ctx.node == NULL_NODE) return false;
                    ctx.matched = true;
                },

                // === Bloom Filter ===
                .bloom_check_class, .bloom_check_id, .bloom_check_tag => {
                    const hash = readU32(code, ip);
                    ip += 4;
                    // Early rejection: if bloom filter says no, definitely no ancestor has it
                    if (!dom.getAncestorFilter(ctx.node).mightContain(hash)) {
                        return false;
                    }
                },

                // === Control Flow ===
                .jump_fail => {
                    const offset = readI16(code, ip);
                    ip += 2;
                    if (!ctx.matched) {
                        ip = @intCast(@as(i32, @intCast(ip)) + offset);
                    }
                },
                .jump => {
                    const offset = readI16(code, ip);
                    ip = @intCast(@as(i32, @intCast(ip)) + 2 + offset);
                },
                .jump_alt => {
                    const offset = readI16(code, ip);
                    ip += 2;
                    if (!ctx.matched) {
                        ip = @intCast(@as(i32, @intCast(ip)) + offset);
                        ctx.matched = true; // Reset for alternative
                    }
                },

                // === Terminal ===
                .match_success => {
                    return ctx.matched;
                },
                .match_fail => {
                    return false;
                },

                else => {
                    // Unknown opcode
                    return false;
                },
            }

            // Check for failed match after each operation (except combinators)
            if (!ctx.matched and op != .comb_descendant) {
                // For simple selectors, fail immediately
                // For complex selectors with alternatives, jump_fail handles it
            }
        }

        return ctx.matched;
    }

    /// Match multiple selectors and return the highest-specificity match
    pub fn matchSelectors(
        self: *const Self,
        selectors: []const CompiledSelector,
        dom: *const FlatDOM,
        node: NodeId,
    ) ?struct { index: usize, specificity: u32 } {
        var best_index: ?usize = null;
        var best_specificity: u32 = 0;

        for (selectors, 0..) |selector, i| {
            if (self.execute(selector, dom, node)) {
                if (best_index == null or selector.specificity > best_specificity) {
                    best_index = i;
                    best_specificity = selector.specificity;
                }
            }
        }

        if (best_index) |idx| {
            return .{ .index = idx, .specificity = best_specificity };
        }
        return null;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn readU32(code: []const u8, offset: u32) u32 {
    const bytes: *const [4]u8 = @ptrCast(code[offset..][0..4]);
    return std.mem.bytesToValue(u32, bytes);
}

fn readI16(code: []const u8, offset: u32) i16 {
    const bytes: *const [2]u8 = @ptrCast(code[offset..][0..2]);
    return std.mem.bytesToValue(i16, bytes);
}

/// Match :nth-child(an+b)
fn matchNthChild(dom: *const FlatDOM, node: NodeId, a: i16, b: i16) bool {
    // Count position among siblings
    var pos: i32 = 1;
    var sibling = dom.getPrevSibling(node);
    while (sibling != NULL_NODE) {
        if (dom.isElement(sibling)) {
            pos += 1;
        }
        sibling = dom.getPrevSibling(sibling);
    }

    return matchNthFormula(pos, a, b);
}

/// Match :nth-last-child(an+b)
fn matchNthLastChild(dom: *const FlatDOM, node: NodeId, a: i16, b: i16) bool {
    // Count position from end
    var pos: i32 = 1;
    var sibling = dom.getNextSibling(node);
    while (sibling != NULL_NODE) {
        if (dom.isElement(sibling)) {
            pos += 1;
        }
        sibling = dom.getNextSibling(sibling);
    }

    return matchNthFormula(pos, a, b);
}

/// Check if position matches formula an+b
fn matchNthFormula(pos: i32, a: i16, b: i16) bool {
    const a32: i32 = a;
    const b32: i32 = b;

    if (a32 == 0) {
        return pos == b32;
    }

    const diff = pos - b32;
    if (a32 > 0) {
        return diff >= 0 and @mod(diff, a32) == 0;
    } else {
        return diff <= 0 and @mod(diff, -a32) == 0;
    }
}

// ============================================================================
// Selector Compiler (Simple DSL)
// ============================================================================

/// Simple selector compiler for common patterns
/// Note: A full CSS selector parser would be more complex
pub const SelectorCompiler = struct {
    allocator: Allocator,
    atoms: *atom.AtomTable,

    const Self = @This();

    pub fn init(allocator: Allocator, atoms_table: *atom.AtomTable) Self {
        return .{
            .allocator = allocator,
            .atoms = atoms_table,
        };
    }

    /// Compile a simple selector: "tag", ".class", "#id", or combinations
    pub fn compileSimple(self: *Self, selector: []const u8) !CompiledSelector {
        var builder = BytecodeBuilder.init(self.allocator);
        errdefer builder.deinit();

        var i: usize = 0;
        while (i < selector.len) {
            switch (selector[i]) {
                '.' => {
                    // Class selector
                    const start = i + 1;
                    i += 1;
                    while (i < selector.len and isIdentChar(selector[i])) {
                        i += 1;
                    }
                    const class_name = selector[start..i];
                    const class_atom = try self.atoms.intern(class_name);
                    try builder.emitMatchClass(class_atom);
                },
                '#' => {
                    // ID selector
                    const start = i + 1;
                    i += 1;
                    while (i < selector.len and isIdentChar(selector[i])) {
                        i += 1;
                    }
                    const id_name = selector[start..i];
                    const id_atom = try self.atoms.intern(id_name);
                    try builder.emitMatchId(id_atom);
                },
                '*' => {
                    // Universal selector
                    try builder.emit(.match_any);
                    i += 1;
                },
                ' ' => {
                    // Descendant combinator
                    try builder.emit(.comb_descendant);
                    i += 1;
                    // Skip extra spaces
                    while (i < selector.len and selector[i] == ' ') {
                        i += 1;
                    }
                },
                '>' => {
                    // Child combinator
                    try builder.emit(.comb_child);
                    i += 1;
                    // Skip spaces
                    while (i < selector.len and selector[i] == ' ') {
                        i += 1;
                    }
                },
                '+' => {
                    // Adjacent sibling combinator
                    try builder.emit(.comb_adjacent);
                    i += 1;
                    while (i < selector.len and selector[i] == ' ') {
                        i += 1;
                    }
                },
                '~' => {
                    // General sibling combinator
                    try builder.emit(.comb_sibling);
                    i += 1;
                    while (i < selector.len and selector[i] == ' ') {
                        i += 1;
                    }
                },
                ':' => {
                    // Pseudo-class
                    i += 1;
                    const start = i;
                    while (i < selector.len and isIdentChar(selector[i])) {
                        i += 1;
                    }
                    const pseudo = selector[start..i];

                    if (std.mem.eql(u8, pseudo, "first-child")) {
                        try builder.emit(.pseudo_first_child);
                    } else if (std.mem.eql(u8, pseudo, "last-child")) {
                        try builder.emit(.pseudo_last_child);
                    } else if (std.mem.eql(u8, pseudo, "only-child")) {
                        try builder.emit(.pseudo_only_child);
                    } else if (std.mem.eql(u8, pseudo, "empty")) {
                        try builder.emit(.pseudo_empty);
                    } else if (std.mem.eql(u8, pseudo, "root")) {
                        try builder.emit(.pseudo_root);
                    }
                    // TODO: Handle :nth-child() with argument parsing
                },
                else => {
                    // Tag name
                    if (isIdentStartChar(selector[i])) {
                        const start = i;
                        while (i < selector.len and isIdentChar(selector[i])) {
                            i += 1;
                        }
                        const tag_name = selector[start..i];
                        const tag_atom = try self.atoms.intern(tag_name);
                        try builder.emitMatchTag(tag_atom);
                    } else {
                        // Skip unknown character
                        i += 1;
                    }
                },
            }
        }

        try builder.emit(.match_success);
        return builder.build(selector);
    }
};

fn isIdentStartChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-' or c > 127;
}

fn isIdentChar(c: u8) bool {
    return isIdentStartChar(c) or (c >= '0' and c <= '9');
}

// ============================================================================
// Tests
// ============================================================================

test "SelectorVM basic tag match" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const div = try dom.createElement(div_tag, NULL_NODE);

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple("div");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);
    try std.testing.expect(vm.execute(selector, &dom, div));
}

test "SelectorVM class match" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const container_class = try atoms_table.intern("container");
    const div = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(div, &[_]AtomId{container_class});

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple(".container");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);
    try std.testing.expect(vm.execute(selector, &dom, div));
}

test "SelectorVM ID match" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const main_id = try atoms_table.intern("main");
    const div = try dom.createElement(div_tag, NULL_NODE);
    dom.setId(div, main_id);

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple("#main");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);
    try std.testing.expect(vm.execute(selector, &dom, div));
}

test "SelectorVM compound selector" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const container = try atoms_table.intern("container");
    const flex = try atoms_table.intern("flex");
    const div = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(div, &[_]AtomId{ container, flex });

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple("div.container.flex");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);
    try std.testing.expect(vm.execute(selector, &dom, div));

    // Should not match span
    const span_tag = try atoms_table.intern("span");
    const span = try dom.createElement(span_tag, NULL_NODE);
    try dom.setClasses(span, &[_]AtomId{ container, flex });
    try std.testing.expect(!vm.execute(selector, &dom, span));
}

test "SelectorVM specificity calculation" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);

    // "div" -> (0, 0, 1)
    const s1 = try compiler.compileSimple("div");
    defer std.testing.allocator.free(s1.bytecode);
    const spec1 = s1.getSpecificity();
    try std.testing.expectEqual(@as(u8, 0), spec1.a);
    try std.testing.expectEqual(@as(u8, 0), spec1.b);
    try std.testing.expectEqual(@as(u8, 1), spec1.c);

    // ".class" -> (0, 1, 0)
    const s2 = try compiler.compileSimple(".class");
    defer std.testing.allocator.free(s2.bytecode);
    const spec2 = s2.getSpecificity();
    try std.testing.expectEqual(@as(u8, 0), spec2.a);
    try std.testing.expectEqual(@as(u8, 1), spec2.b);
    try std.testing.expectEqual(@as(u8, 0), spec2.c);

    // "#id" -> (1, 0, 0)
    const s3 = try compiler.compileSimple("#id");
    defer std.testing.allocator.free(s3.bytecode);
    const spec3 = s3.getSpecificity();
    try std.testing.expectEqual(@as(u8, 1), spec3.a);
    try std.testing.expectEqual(@as(u8, 0), spec3.b);
    try std.testing.expectEqual(@as(u8, 0), spec3.c);

    // "div.class#id" -> (1, 1, 1)
    const s4 = try compiler.compileSimple("div.class#id");
    defer std.testing.allocator.free(s4.bytecode);
    const spec4 = s4.getSpecificity();
    try std.testing.expectEqual(@as(u8, 1), spec4.a);
    try std.testing.expectEqual(@as(u8, 1), spec4.b);
    try std.testing.expectEqual(@as(u8, 1), spec4.c);
}

test "SelectorVM pseudo-class first-child" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const ul_tag = try atoms_table.intern("ul");
    const li_tag = try atoms_table.intern("li");

    const ul = try dom.createElement(ul_tag, NULL_NODE);
    const li1 = try dom.createElement(li_tag, ul);
    const li2 = try dom.createElement(li_tag, ul);
    const li3 = try dom.createElement(li_tag, ul);

    var compiler = SelectorCompiler.init(std.testing.allocator, &atoms_table);
    const selector = try compiler.compileSimple("li:first-child");
    defer std.testing.allocator.free(selector.bytecode);

    const vm = SelectorVM.init(std.testing.allocator);
    try std.testing.expect(vm.execute(selector, &dom, li1));
    try std.testing.expect(!vm.execute(selector, &dom, li2));
    try std.testing.expect(!vm.execute(selector, &dom, li3));
}
