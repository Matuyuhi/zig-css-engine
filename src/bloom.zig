//! Bloom Filter: Fast probabilistic set membership testing
//!
//! Used for early rejection during selector matching. Each DOM node stores
//! a bloom filter of its ancestor chain's classes, IDs, and tags.
//!
//! When matching a selector like `.container .item`, we first check if
//! "container" exists in the ancestor bloom filter. False positives are
//! acceptable (we fall back to full traversal), but false negatives are not.
//!
//! Using a 64-bit bloom filter per node provides good space efficiency
//! while maintaining acceptable false positive rates for typical DOM depths.

const std = @import("std");
const atom = @import("atom.zig");
const AtomId = atom.AtomId;

/// 64-bit bloom filter - fits in a single register for fast operations
pub const BloomFilter = packed struct {
    bits: u64,

    const Self = @This();

    /// Number of hash functions (k). Using 3 provides good false positive rates.
    const K: u32 = 3;

    /// Create an empty bloom filter
    pub fn empty() Self {
        return .{ .bits = 0 };
    }

    /// Create a bloom filter with a single item
    pub fn single(hash: u32) Self {
        var bf = empty();
        bf.add(hash);
        return bf;
    }

    /// Add a hash to the bloom filter
    /// Uses multiple bit positions derived from the single hash
    pub fn add(self: *Self, hash: u32) void {
        // Extract 3 independent 6-bit positions from the 32-bit hash
        // Position 0: bits 0-5
        // Position 1: bits 8-13
        // Position 2: bits 16-21
        const pos0 = @as(u6, @truncate(hash));
        const pos1 = @as(u6, @truncate(hash >> 8));
        const pos2 = @as(u6, @truncate(hash >> 16));

        self.bits |= (@as(u64, 1) << pos0);
        self.bits |= (@as(u64, 1) << pos1);
        self.bits |= (@as(u64, 1) << pos2);
    }

    /// Add an atom to the bloom filter
    pub fn addAtom(self: *Self, atom_hash: u32) void {
        self.add(atom_hash);
    }

    /// Check if a hash might be in the bloom filter
    /// Returns false if definitely not present, true if possibly present
    pub fn mightContain(self: Self, hash: u32) bool {
        const pos0 = @as(u6, @truncate(hash));
        const pos1 = @as(u6, @truncate(hash >> 8));
        const pos2 = @as(u6, @truncate(hash >> 16));

        const mask: u64 = (@as(u64, 1) << pos0) |
            (@as(u64, 1) << pos1) |
            (@as(u64, 1) << pos2);

        return (self.bits & mask) == mask;
    }

    /// Merge two bloom filters (union)
    pub fn merge(self: Self, other: Self) Self {
        return .{ .bits = self.bits | other.bits };
    }

    /// Combine this filter with another in place
    pub fn mergeInPlace(self: *Self, other: Self) void {
        self.bits |= other.bits;
    }

    /// Check if empty
    pub fn isEmpty(self: Self) bool {
        return self.bits == 0;
    }

    /// Count approximate number of bits set (population count)
    pub fn popCount(self: Self) u7 {
        return @popCount(self.bits);
    }

    /// Estimate false positive rate given expected number of items
    /// Formula: (1 - e^(-k*n/m))^k where k=3, m=64
    pub fn estimatedFPRate(num_items: u32) f32 {
        const k: f32 = @floatFromInt(K);
        const m: f32 = 64.0;
        const n: f32 = @floatFromInt(num_items);

        const exp_term = @exp(-k * n / m);
        const base = 1.0 - exp_term;
        return std.math.pow(f32, base, k);
    }
};

/// Extended 256-bit bloom filter for scenarios with deep DOM trees
/// or many classes. Uses SIMD for fast operations when available.
pub const BloomFilter256 = struct {
    bits: @Vector(4, u64),

    const Self = @This();

    pub fn empty() Self {
        return .{ .bits = @splat(0) };
    }

    pub fn add(self: *Self, hash: u32) void {
        // Use different bits of the hash for different u64 segments
        const segment = @as(u2, @truncate(hash >> 6));
        const pos = @as(u6, @truncate(hash));

        var bits_array: [4]u64 = self.bits;
        bits_array[segment] |= (@as(u64, 1) << pos);
        self.bits = bits_array;

        // Also set bits in adjacent segments for better coverage
        const pos2 = @as(u6, @truncate(hash >> 12));
        const segment2 = @as(u2, @truncate(hash >> 18));
        bits_array = self.bits;
        bits_array[segment2] |= (@as(u64, 1) << pos2);
        self.bits = bits_array;
    }

    pub fn mightContain(self: Self, hash: u32) bool {
        const segment = @as(u2, @truncate(hash >> 6));
        const pos = @as(u6, @truncate(hash));
        const segment2 = @as(u2, @truncate(hash >> 18));
        const pos2 = @as(u6, @truncate(hash >> 12));

        const bits_array: [4]u64 = self.bits;
        const bit1 = (bits_array[segment] >> pos) & 1;
        const bit2 = (bits_array[segment2] >> pos2) & 1;

        return bit1 == 1 and bit2 == 1;
    }

    pub fn merge(self: Self, other: Self) Self {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn mergeInPlace(self: *Self, other: Self) void {
        self.bits |= other.bits;
    }

    /// Convert to compact 64-bit filter (lossy)
    pub fn toCompact(self: Self) BloomFilter {
        const bits_array: [4]u64 = self.bits;
        return .{
            .bits = bits_array[0] | bits_array[1] | bits_array[2] | bits_array[3],
        };
    }
};

/// Bloom filter builder for constructing ancestor filters during DOM construction
pub const BloomFilterBuilder = struct {
    filter: BloomFilter,
    count: u32,

    const Self = @This();

    pub fn init() Self {
        return .{
            .filter = BloomFilter.empty(),
            .count = 0,
        };
    }

    /// Add a class atom
    pub fn addClass(self: *Self, class_hash: u32) void {
        self.filter.add(class_hash);
        self.count += 1;
    }

    /// Add an ID atom
    pub fn addId(self: *Self, id_hash: u32) void {
        self.filter.add(id_hash);
        self.count += 1;
    }

    /// Add a tag atom
    pub fn addTag(self: *Self, tag_hash: u32) void {
        self.filter.add(tag_hash);
        self.count += 1;
    }

    /// Incorporate parent's bloom filter
    pub fn inheritFrom(self: *Self, parent_filter: BloomFilter) void {
        self.filter.mergeInPlace(parent_filter);
    }

    /// Get the final bloom filter
    pub fn build(self: Self) BloomFilter {
        return self.filter;
    }

    /// Get estimated false positive rate
    pub fn estimatedFPRate(self: Self) f32 {
        return BloomFilter.estimatedFPRate(self.count);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BloomFilter basic operations" {
    var bf = BloomFilter.empty();
    try std.testing.expect(bf.isEmpty());

    const hash1 = atom.fnv1a("container");
    const hash2 = atom.fnv1a("item");
    const hash3 = atom.fnv1a("unknown");

    bf.add(hash1);
    bf.add(hash2);

    try std.testing.expect(!bf.isEmpty());
    try std.testing.expect(bf.mightContain(hash1));
    try std.testing.expect(bf.mightContain(hash2));
    // hash3 might give false positive, but let's check the logic is correct
}

test "BloomFilter single creation" {
    const hash = atom.fnv1a("test");
    const bf = BloomFilter.single(hash);

    try std.testing.expect(!bf.isEmpty());
    try std.testing.expect(bf.mightContain(hash));
}

test "BloomFilter merge" {
    var bf1 = BloomFilter.empty();
    var bf2 = BloomFilter.empty();

    const hash1 = atom.fnv1a("class1");
    const hash2 = atom.fnv1a("class2");

    bf1.add(hash1);
    bf2.add(hash2);

    const merged = bf1.merge(bf2);
    try std.testing.expect(merged.mightContain(hash1));
    try std.testing.expect(merged.mightContain(hash2));
}

test "BloomFilterBuilder inheritance" {
    // Simulate building ancestor filters
    var parent_builder = BloomFilterBuilder.init();
    parent_builder.addClass(atom.fnv1a("parent-class"));
    parent_builder.addId(atom.fnv1a("parent-id"));
    const parent_filter = parent_builder.build();

    var child_builder = BloomFilterBuilder.init();
    child_builder.inheritFrom(parent_filter);
    child_builder.addClass(atom.fnv1a("child-class"));
    const child_filter = child_builder.build();

    // Child filter should contain both parent and child items
    try std.testing.expect(child_filter.mightContain(atom.fnv1a("parent-class")));
    try std.testing.expect(child_filter.mightContain(atom.fnv1a("parent-id")));
    try std.testing.expect(child_filter.mightContain(atom.fnv1a("child-class")));
}

test "BloomFilter256 basic operations" {
    var bf = BloomFilter256.empty();

    const hash1 = atom.fnv1a("item1");
    const hash2 = atom.fnv1a("item2");

    bf.add(hash1);
    bf.add(hash2);

    try std.testing.expect(bf.mightContain(hash1));
    try std.testing.expect(bf.mightContain(hash2));
}

test "BloomFilter false positive rate estimation" {
    // With 10 items in a 64-bit filter with k=3, FP rate should be reasonable
    const fp_rate = BloomFilter.estimatedFPRate(10);
    try std.testing.expect(fp_rate > 0.0 and fp_rate < 1.0);

    // Higher item count should increase FP rate
    const fp_rate_high = BloomFilter.estimatedFPRate(50);
    try std.testing.expect(fp_rate_high > fp_rate);
}
