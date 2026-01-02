//! AtomTable: High-performance string interning for CSS engines
//!
//! All strings (tags, classes, IDs, property names) are converted to u32 Atom IDs
//! immediately upon parsing. This eliminates string comparisons during matching
//! and enables cache-efficient DOM traversal.
//!
//! Known CSS keywords are hashed at comptime for zero-cost lookup.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Atom ID - a unique identifier for an interned string
/// Using u32 limits us to ~4 billion unique strings, which is sufficient
/// for any real-world CSS engine use case.
pub const AtomId = u32;

/// Sentinel value for "no atom" / null reference
pub const NULL_ATOM: AtomId = 0;

/// FNV-1a hash - excellent distribution, simple implementation
/// Using u32 for compactness in the hash table
pub fn fnv1a(bytes: []const u8) u32 {
    const FNV_OFFSET: u32 = 2166136261;
    const FNV_PRIME: u32 = 16777619;

    var hash: u32 = FNV_OFFSET;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }
    return hash;
}

/// Comptime FNV-1a hash for static strings
pub fn comptimeHash(comptime str: []const u8) u32 {
    return comptime fnv1a(str);
}

// ============================================================================
// Known CSS Keywords - Hashed at Comptime
// ============================================================================

/// HTML Tag atoms - precomputed at compile time
pub const tags = struct {
    pub const html = comptimeHash("html");
    pub const head = comptimeHash("head");
    pub const body = comptimeHash("body");
    pub const div = comptimeHash("div");
    pub const span = comptimeHash("span");
    pub const p = comptimeHash("p");
    pub const a = comptimeHash("a");
    pub const img = comptimeHash("img");
    pub const ul = comptimeHash("ul");
    pub const ol = comptimeHash("ol");
    pub const li = comptimeHash("li");
    pub const table = comptimeHash("table");
    pub const tr = comptimeHash("tr");
    pub const td = comptimeHash("td");
    pub const th = comptimeHash("th");
    pub const form = comptimeHash("form");
    pub const input = comptimeHash("input");
    pub const button = comptimeHash("button");
    pub const h1 = comptimeHash("h1");
    pub const h2 = comptimeHash("h2");
    pub const h3 = comptimeHash("h3");
    pub const h4 = comptimeHash("h4");
    pub const h5 = comptimeHash("h5");
    pub const h6 = comptimeHash("h6");
    pub const header = comptimeHash("header");
    pub const footer = comptimeHash("footer");
    pub const nav = comptimeHash("nav");
    pub const main_ = comptimeHash("main");
    pub const section = comptimeHash("section");
    pub const article = comptimeHash("article");
    pub const aside = comptimeHash("aside");
};

/// CSS Property atoms - precomputed at compile time
pub const props = struct {
    // Display & Layout
    pub const display = comptimeHash("display");
    pub const position = comptimeHash("position");
    pub const top = comptimeHash("top");
    pub const right = comptimeHash("right");
    pub const bottom = comptimeHash("bottom");
    pub const left = comptimeHash("left");
    pub const z_index = comptimeHash("z-index");
    pub const float = comptimeHash("float");
    pub const clear = comptimeHash("clear");

    // Flexbox
    pub const flex = comptimeHash("flex");
    pub const flex_direction = comptimeHash("flex-direction");
    pub const flex_wrap = comptimeHash("flex-wrap");
    pub const flex_grow = comptimeHash("flex-grow");
    pub const flex_shrink = comptimeHash("flex-shrink");
    pub const flex_basis = comptimeHash("flex-basis");
    pub const justify_content = comptimeHash("justify-content");
    pub const align_items = comptimeHash("align-items");
    pub const align_content = comptimeHash("align-content");
    pub const align_self = comptimeHash("align-self");
    pub const gap = comptimeHash("gap");

    // Grid
    pub const grid = comptimeHash("grid");
    pub const grid_template_columns = comptimeHash("grid-template-columns");
    pub const grid_template_rows = comptimeHash("grid-template-rows");
    pub const grid_column = comptimeHash("grid-column");
    pub const grid_row = comptimeHash("grid-row");

    // Box Model
    pub const width = comptimeHash("width");
    pub const height = comptimeHash("height");
    pub const min_width = comptimeHash("min-width");
    pub const min_height = comptimeHash("min-height");
    pub const max_width = comptimeHash("max-width");
    pub const max_height = comptimeHash("max-height");
    pub const margin = comptimeHash("margin");
    pub const margin_top = comptimeHash("margin-top");
    pub const margin_right = comptimeHash("margin-right");
    pub const margin_bottom = comptimeHash("margin-bottom");
    pub const margin_left = comptimeHash("margin-left");
    pub const padding = comptimeHash("padding");
    pub const padding_top = comptimeHash("padding-top");
    pub const padding_right = comptimeHash("padding-right");
    pub const padding_bottom = comptimeHash("padding-bottom");
    pub const padding_left = comptimeHash("padding-left");
    pub const border = comptimeHash("border");
    pub const border_width = comptimeHash("border-width");
    pub const border_style = comptimeHash("border-style");
    pub const border_color = comptimeHash("border-color");
    pub const border_radius = comptimeHash("border-radius");
    pub const box_sizing = comptimeHash("box-sizing");

    // Typography
    pub const color = comptimeHash("color");
    pub const font = comptimeHash("font");
    pub const font_family = comptimeHash("font-family");
    pub const font_size = comptimeHash("font-size");
    pub const font_weight = comptimeHash("font-weight");
    pub const font_style = comptimeHash("font-style");
    pub const line_height = comptimeHash("line-height");
    pub const text_align = comptimeHash("text-align");
    pub const text_decoration = comptimeHash("text-decoration");
    pub const text_transform = comptimeHash("text-transform");
    pub const letter_spacing = comptimeHash("letter-spacing");
    pub const word_spacing = comptimeHash("word-spacing");
    pub const white_space = comptimeHash("white-space");

    // Visual
    pub const background = comptimeHash("background");
    pub const background_color = comptimeHash("background-color");
    pub const background_image = comptimeHash("background-image");
    pub const background_position = comptimeHash("background-position");
    pub const background_size = comptimeHash("background-size");
    pub const background_repeat = comptimeHash("background-repeat");
    pub const opacity = comptimeHash("opacity");
    pub const visibility = comptimeHash("visibility");
    pub const overflow = comptimeHash("overflow");
    pub const overflow_x = comptimeHash("overflow-x");
    pub const overflow_y = comptimeHash("overflow-y");
    pub const cursor = comptimeHash("cursor");
    pub const box_shadow = comptimeHash("box-shadow");

    // Transforms & Animations
    pub const transform = comptimeHash("transform");
    pub const transform_origin = comptimeHash("transform-origin");
    pub const transition = comptimeHash("transition");
    pub const animation = comptimeHash("animation");
};

/// CSS Value keywords - precomputed at compile time
pub const values = struct {
    // Display values
    pub const none = comptimeHash("none");
    pub const block = comptimeHash("block");
    pub const inline_ = comptimeHash("inline");
    pub const inline_block = comptimeHash("inline-block");
    pub const flex_ = comptimeHash("flex");
    pub const inline_flex = comptimeHash("inline-flex");
    pub const grid_ = comptimeHash("grid");
    pub const inline_grid = comptimeHash("inline-grid");
    pub const table_ = comptimeHash("table");
    pub const contents = comptimeHash("contents");

    // Position values
    pub const static = comptimeHash("static");
    pub const relative = comptimeHash("relative");
    pub const absolute = comptimeHash("absolute");
    pub const fixed = comptimeHash("fixed");
    pub const sticky = comptimeHash("sticky");

    // Common values
    pub const auto = comptimeHash("auto");
    pub const inherit = comptimeHash("inherit");
    pub const initial = comptimeHash("initial");
    pub const unset = comptimeHash("unset");
    pub const revert = comptimeHash("revert");

    // Flex values
    pub const row = comptimeHash("row");
    pub const row_reverse = comptimeHash("row-reverse");
    pub const column = comptimeHash("column");
    pub const column_reverse = comptimeHash("column-reverse");
    pub const wrap = comptimeHash("wrap");
    pub const nowrap = comptimeHash("nowrap");
    pub const wrap_reverse = comptimeHash("wrap-reverse");
    pub const flex_start = comptimeHash("flex-start");
    pub const flex_end = comptimeHash("flex-end");
    pub const center = comptimeHash("center");
    pub const space_between = comptimeHash("space-between");
    pub const space_around = comptimeHash("space-around");
    pub const space_evenly = comptimeHash("space-evenly");
    pub const stretch = comptimeHash("stretch");
    pub const baseline = comptimeHash("baseline");

    // Visibility/Overflow
    pub const visible = comptimeHash("visible");
    pub const hidden = comptimeHash("hidden");
    pub const scroll = comptimeHash("scroll");
    pub const clip = comptimeHash("clip");

    // Font
    pub const normal = comptimeHash("normal");
    pub const bold = comptimeHash("bold");
    pub const bolder = comptimeHash("bolder");
    pub const lighter = comptimeHash("lighter");
    pub const italic = comptimeHash("italic");
    pub const oblique = comptimeHash("oblique");

    // Text
    pub const left = comptimeHash("left");
    pub const right = comptimeHash("right");
    pub const justify = comptimeHash("justify");
    pub const underline = comptimeHash("underline");
    pub const overline = comptimeHash("overline");
    pub const line_through = comptimeHash("line-through");
    pub const uppercase = comptimeHash("uppercase");
    pub const lowercase = comptimeHash("lowercase");
    pub const capitalize = comptimeHash("capitalize");

    // Box sizing
    pub const content_box = comptimeHash("content-box");
    pub const border_box = comptimeHash("border-box");

    // Colors
    pub const transparent = comptimeHash("transparent");
    pub const currentcolor = comptimeHash("currentcolor");
};

// ============================================================================
// AtomTable - Runtime String Interning
// ============================================================================

/// Entry in the hash table - stores string data and next pointer for chaining
const Entry = struct {
    /// Hash of the string (cached for rehashing)
    hash: u32,
    /// Start offset in the string storage buffer
    str_offset: u32,
    /// Length of the string
    str_len: u16,
    /// Next entry index in chain (for collision resolution), 0 = end
    next: u32,
};

/// AtomTable provides O(1) average-case string interning
///
/// Implementation uses open addressing with linear probing.
/// String data is stored in a separate contiguous buffer for cache efficiency.
pub const AtomTable = struct {
    /// Hash table buckets (indices into entries array)
    /// 0 = empty bucket, actual indices are stored as index + 1
    buckets: []u32,

    /// Flat array of all entries
    entries: std.ArrayList(Entry),

    /// Contiguous storage for all interned strings
    string_storage: std.ArrayList(u8),

    /// Number of interned strings
    count: u32,

    /// Allocator for dynamic memory
    allocator: Allocator,

    const Self = @This();

    /// Initial bucket count (must be power of 2)
    const INITIAL_BUCKETS: u32 = 1024;

    /// Load factor threshold for rehashing (75%)
    const LOAD_FACTOR_NUM: u32 = 3;
    const LOAD_FACTOR_DEN: u32 = 4;

    /// Create a new AtomTable
    pub fn init(allocator: Allocator) !Self {
        const buckets = try allocator.alloc(u32, INITIAL_BUCKETS);
        @memset(buckets, 0);

        var entries = std.ArrayList(Entry).init(allocator);
        // Reserve entry 0 as the null entry
        try entries.append(.{
            .hash = 0,
            .str_offset = 0,
            .str_len = 0,
            .next = 0,
        });

        return Self{
            .buckets = buckets,
            .entries = entries,
            .string_storage = std.ArrayList(u8).init(allocator),
            .count = 0,
            .allocator = allocator,
        };
    }

    /// Free all resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buckets);
        self.entries.deinit();
        self.string_storage.deinit();
    }

    /// Intern a string, returning its unique AtomId
    /// If the string was already interned, returns the existing AtomId
    pub fn intern(self: *Self, str: []const u8) !AtomId {
        if (str.len == 0) return NULL_ATOM;
        if (str.len > std.math.maxInt(u16)) return error.StringTooLong;

        const hash = fnv1a(str);

        // Check if already interned
        if (self.lookup(str, hash)) |existing| {
            return existing;
        }

        // Check if we need to rehash
        if (self.count * LOAD_FACTOR_DEN >= self.buckets.len * LOAD_FACTOR_NUM) {
            try self.rehash();
        }

        // Store the string
        const str_offset: u32 = @intCast(self.string_storage.items.len);
        try self.string_storage.appendSlice(str);

        // Create new entry
        const entry_idx: u32 = @intCast(self.entries.items.len);
        const bucket_idx = hash & (@as(u32, @intCast(self.buckets.len)) - 1);

        try self.entries.append(.{
            .hash = hash,
            .str_offset = str_offset,
            .str_len = @intCast(str.len),
            .next = self.buckets[bucket_idx],
        });

        self.buckets[bucket_idx] = entry_idx;
        self.count += 1;

        return entry_idx;
    }

    /// Look up a string by its hash, returns AtomId if found
    fn lookup(self: *const Self, str: []const u8, hash: u32) ?AtomId {
        const bucket_idx = hash & (@as(u32, @intCast(self.buckets.len)) - 1);
        var entry_idx = self.buckets[bucket_idx];

        while (entry_idx != 0) {
            const entry = &self.entries.items[entry_idx];
            if (entry.hash == hash and entry.str_len == str.len) {
                const stored = self.string_storage.items[entry.str_offset .. entry.str_offset + entry.str_len];
                if (std.mem.eql(u8, stored, str)) {
                    return entry_idx;
                }
            }
            entry_idx = entry.next;
        }

        return null;
    }

    /// Get the string for an AtomId
    pub fn getString(self: *const Self, atom: AtomId) ?[]const u8 {
        if (atom == NULL_ATOM or atom >= self.entries.items.len) {
            return null;
        }
        const entry = &self.entries.items[atom];
        return self.string_storage.items[entry.str_offset .. entry.str_offset + entry.str_len];
    }

    /// Get the hash for an AtomId (useful for bloom filters)
    pub fn getHash(self: *const Self, atom: AtomId) u32 {
        if (atom == NULL_ATOM or atom >= self.entries.items.len) {
            return 0;
        }
        return self.entries.items[atom].hash;
    }

    /// Rehash the table to a larger size
    fn rehash(self: *Self) !void {
        const new_size = self.buckets.len * 2;
        const new_buckets = try self.allocator.alloc(u32, new_size);
        @memset(new_buckets, 0);

        const mask: u32 = @intCast(new_size - 1);

        // Reinsert all entries
        for (self.entries.items[1..], 1..) |*entry, i| {
            const bucket_idx = entry.hash & mask;
            entry.next = new_buckets[bucket_idx];
            new_buckets[bucket_idx] = @intCast(i);
        }

        self.allocator.free(self.buckets);
        self.buckets = new_buckets;
    }

    /// Intern a string known at comptime - returns the hash directly
    /// This skips the hash table entirely for known keywords
    pub fn comptimeIntern(comptime str: []const u8) AtomId {
        return comptimeHash(str);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AtomTable basic interning" {
    var table = try AtomTable.init(std.testing.allocator);
    defer table.deinit();

    const atom1 = try table.intern("hello");
    const atom2 = try table.intern("world");
    const atom3 = try table.intern("hello"); // Duplicate

    try std.testing.expect(atom1 != atom2);
    try std.testing.expect(atom1 == atom3); // Same string = same atom

    try std.testing.expectEqualStrings("hello", table.getString(atom1).?);
    try std.testing.expectEqualStrings("world", table.getString(atom2).?);
}

test "AtomTable null atom" {
    var table = try AtomTable.init(std.testing.allocator);
    defer table.deinit();

    const empty = try table.intern("");
    try std.testing.expect(empty == NULL_ATOM);
    try std.testing.expect(table.getString(NULL_ATOM) == null);
}

test "AtomTable comptime hashes are consistent" {
    // Verify that comptime and runtime hashing produce the same results
    try std.testing.expectEqual(comptimeHash("div"), fnv1a("div"));
    try std.testing.expectEqual(comptimeHash("display"), fnv1a("display"));
    try std.testing.expectEqual(tags.div, fnv1a("div"));
    try std.testing.expectEqual(props.display, fnv1a("display"));
}

test "AtomTable handles collisions" {
    var table = try AtomTable.init(std.testing.allocator);
    defer table.deinit();

    // Insert many strings to force collisions
    var atoms: [100]AtomId = undefined;
    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        atoms[i] = try table.intern(str);
    }

    // Verify all are unique and retrievable
    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        const actual = table.getString(atoms[i]).?;
        try std.testing.expectEqualStrings(expected, actual);
    }
}
