//! FlatDOM: Structure of Arrays (SoA) DOM representation
//!
//! The DOM tree is stored as flat arrays for maximum cache locality.
//! No pointers - all references use u32 indices.
//!
//! Memory layout optimized for selector matching:
//! - Hot data (tags, classes, parents) packed together
//! - Cold data (attributes, text) in separate arrays
//! - Bloom filters for O(1) ancestor rejection

const std = @import("std");
const Allocator = std.mem.Allocator;
const atom = @import("atom.zig");
const bloom = @import("bloom.zig");
const AtomId = atom.AtomId;
const BloomFilter = bloom.BloomFilter;

/// Node index type - u32 supports ~4 billion nodes
pub const NodeId = u32;

/// Sentinel value for "no node" / null reference
pub const NULL_NODE: NodeId = 0;

/// Node flags packed into a single byte
pub const NodeFlags = packed struct {
    /// Node type (element, text, comment, etc.)
    node_type: NodeType,
    /// Has ID attribute
    has_id: bool = false,
    /// Has class attribute
    has_classes: bool = false,
    /// Has inline style
    has_style: bool = false,
    /// Is part of shadow DOM
    in_shadow: bool = false,
    /// Reserved for future use
    _reserved: u1 = 0,

    pub const NodeType = enum(u3) {
        element = 1,
        text = 3,
        cdata = 4,
        comment = 8,
        document = 9,
        document_type = 10,
        document_fragment = 11,
    };
};

/// Class list entry - stores offset and count into class_atoms array
pub const ClassList = packed struct {
    /// Start offset in the global class_atoms array
    offset: u24,
    /// Number of classes
    count: u8,

    pub const EMPTY: ClassList = .{ .offset = 0, .count = 0 };
};

/// Attribute entry (stored separately due to variable size)
pub const Attribute = struct {
    name: AtomId,
    value_offset: u32,
    value_len: u16,
};

/// Per-node data structure (SoA will split this into arrays)
pub const Node = struct {
    /// Tag name atom (e.g., "div", "span")
    tag: AtomId,
    /// ID attribute atom (or NULL_ATOM)
    id: AtomId,
    /// Parent node index (NULL_NODE for root)
    parent: NodeId,
    /// First child node index (NULL_NODE if leaf)
    first_child: NodeId,
    /// Next sibling node index (NULL_NODE if last)
    next_sibling: NodeId,
    /// Previous sibling node index (NULL_NODE if first)
    prev_sibling: NodeId,
    /// Class list reference
    classes: ClassList,
    /// Bloom filter of ancestor classes/IDs/tags
    ancestor_filter: BloomFilter,
    /// Node flags
    flags: NodeFlags,
    /// Depth in tree (root = 0)
    depth: u16,
};

/// FlatDOM - The complete DOM tree in SoA layout
///
/// Uses MultiArrayList for automatic SoA transformation.
/// Each field of Node becomes a separate contiguous array.
pub const FlatDOM = struct {
    /// SoA storage for all nodes
    nodes: std.MultiArrayList(Node),

    /// Flat array of all class atoms (ClassList.offset indexes into this)
    class_atoms: std.ArrayList(AtomId),

    /// Attribute storage (variable length per node)
    attributes: std.ArrayList(Attribute),

    /// Attribute values (raw string bytes)
    attribute_values: std.ArrayList(u8),

    /// Per-node attribute list (offset, count)
    node_attributes: std.ArrayList(AttrList),

    /// Text content storage
    text_content: std.ArrayList(u8),

    /// Per-node text content (offset, length)
    node_text: std.ArrayList(TextRef),

    /// String interning table
    atoms: *atom.AtomTable,

    /// Memory allocator
    allocator: Allocator,

    const Self = @This();

    /// Attribute list reference
    pub const AttrList = packed struct {
        offset: u24,
        count: u8,

        pub const EMPTY: AttrList = .{ .offset = 0, .count = 0 };
    };

    /// Text content reference
    pub const TextRef = packed struct {
        offset: u32,
        length: u32,

        pub const EMPTY: TextRef = .{ .offset = 0, .length = 0 };
    };

    /// Initialize a new FlatDOM
    pub fn init(allocator: Allocator, atoms_table: *atom.AtomTable) !Self {
        var dom = Self{
            .nodes = std.MultiArrayList(Node){},
            .class_atoms = std.ArrayList(AtomId).init(allocator),
            .attributes = std.ArrayList(Attribute).init(allocator),
            .attribute_values = std.ArrayList(u8).init(allocator),
            .node_attributes = std.ArrayList(AttrList).init(allocator),
            .text_content = std.ArrayList(u8).init(allocator),
            .node_text = std.ArrayList(TextRef).init(allocator),
            .atoms = atoms_table,
            .allocator = allocator,
        };

        // Reserve index 0 as null node
        try dom.nodes.append(allocator, .{
            .tag = atom.NULL_ATOM,
            .id = atom.NULL_ATOM,
            .parent = NULL_NODE,
            .first_child = NULL_NODE,
            .next_sibling = NULL_NODE,
            .prev_sibling = NULL_NODE,
            .classes = ClassList.EMPTY,
            .ancestor_filter = BloomFilter.empty(),
            .flags = .{ .node_type = .document },
            .depth = 0,
        });
        try dom.node_attributes.append(AttrList.EMPTY);
        try dom.node_text.append(TextRef.EMPTY);

        return dom;
    }

    /// Free all resources
    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
        self.class_atoms.deinit();
        self.attributes.deinit();
        self.attribute_values.deinit();
        self.node_attributes.deinit();
        self.text_content.deinit();
        self.node_text.deinit();
    }

    /// Create a new element node
    pub fn createElement(self: *Self, tag: AtomId, parent: NodeId) !NodeId {
        const node_id: NodeId = @intCast(self.nodes.len);

        // Get parent's bloom filter and depth
        var ancestor_filter = BloomFilter.empty();
        var depth: u16 = 0;
        if (parent != NULL_NODE) {
            const slice = self.nodes.slice();
            ancestor_filter = slice.items(.ancestor_filter)[parent];
            ancestor_filter.add(slice.items(.tag)[parent]);
            if (slice.items(.id)[parent] != atom.NULL_ATOM) {
                ancestor_filter.add(slice.items(.id)[parent]);
            }
            // Add parent's classes to bloom filter
            const parent_classes = slice.items(.classes)[parent];
            if (parent_classes.count > 0) {
                const class_slice = self.class_atoms.items[parent_classes.offset .. parent_classes.offset + parent_classes.count];
                for (class_slice) |class_atom| {
                    ancestor_filter.add(class_atom);
                }
            }
            depth = slice.items(.depth)[parent] + 1;
        }

        try self.nodes.append(self.allocator, .{
            .tag = tag,
            .id = atom.NULL_ATOM,
            .parent = parent,
            .first_child = NULL_NODE,
            .next_sibling = NULL_NODE,
            .prev_sibling = NULL_NODE,
            .classes = ClassList.EMPTY,
            .ancestor_filter = ancestor_filter,
            .flags = .{ .node_type = .element },
            .depth = depth,
        });

        try self.node_attributes.append(AttrList.EMPTY);
        try self.node_text.append(TextRef.EMPTY);

        // Update parent's first_child or last sibling's next_sibling
        if (parent != NULL_NODE) {
            self.linkToParent(node_id, parent);
        }

        return node_id;
    }

    /// Create a text node
    pub fn createTextNode(self: *Self, parent: NodeId, text: []const u8) !NodeId {
        const node_id: NodeId = @intCast(self.nodes.len);

        // Store text content
        const text_offset: u32 = @intCast(self.text_content.items.len);
        try self.text_content.appendSlice(text);

        var depth: u16 = 0;
        if (parent != NULL_NODE) {
            depth = self.nodes.items(.depth)[parent] + 1;
        }

        try self.nodes.append(self.allocator, .{
            .tag = atom.NULL_ATOM,
            .id = atom.NULL_ATOM,
            .parent = parent,
            .first_child = NULL_NODE,
            .next_sibling = NULL_NODE,
            .prev_sibling = NULL_NODE,
            .classes = ClassList.EMPTY,
            .ancestor_filter = BloomFilter.empty(),
            .flags = .{ .node_type = .text },
            .depth = depth,
        });

        try self.node_attributes.append(AttrList.EMPTY);
        try self.node_text.append(.{
            .offset = text_offset,
            .length = @intCast(text.len),
        });

        if (parent != NULL_NODE) {
            self.linkToParent(node_id, parent);
        }

        return node_id;
    }

    /// Link a new node to its parent
    fn linkToParent(self: *Self, node_id: NodeId, parent: NodeId) void {
        const slice = self.nodes.slice();
        const first_child = slice.items(.first_child)[parent];

        if (first_child == NULL_NODE) {
            // First child
            slice.items(.first_child)[parent] = node_id;
        } else {
            // Find last sibling and link
            var last = first_child;
            while (slice.items(.next_sibling)[last] != NULL_NODE) {
                last = slice.items(.next_sibling)[last];
            }
            slice.items(.next_sibling)[last] = node_id;
            slice.items(.prev_sibling)[node_id] = last;
        }
    }

    /// Set the ID of a node
    pub fn setId(self: *Self, node_id: NodeId, id: AtomId) void {
        const slice = self.nodes.slice();
        slice.items(.id)[node_id] = id;
        var flags = slice.items(.flags)[node_id];
        flags.has_id = true;
        slice.items(.flags)[node_id] = flags;
    }

    /// Set classes for a node
    pub fn setClasses(self: *Self, node_id: NodeId, classes: []const AtomId) !void {
        if (classes.len == 0) return;
        if (classes.len > 255) return error.TooManyClasses;

        const offset: u24 = @intCast(self.class_atoms.items.len);
        try self.class_atoms.appendSlice(classes);

        const slice = self.nodes.slice();
        slice.items(.classes)[node_id] = .{
            .offset = offset,
            .count = @intCast(classes.len),
        };
        var flags = slice.items(.flags)[node_id];
        flags.has_classes = true;
        slice.items(.flags)[node_id] = flags;
    }

    /// Add an attribute to a node
    pub fn addAttribute(self: *Self, node_id: NodeId, name: AtomId, value: []const u8) !void {
        const value_offset: u32 = @intCast(self.attribute_values.items.len);
        try self.attribute_values.appendSlice(value);

        const attr_offset: u24 = @intCast(self.attributes.items.len);
        try self.attributes.append(.{
            .name = name,
            .value_offset = value_offset,
            .value_len = @intCast(value.len),
        });

        // Update node's attribute list
        var attr_list = self.node_attributes.items[node_id];
        if (attr_list.count == 0) {
            attr_list.offset = attr_offset;
        }
        attr_list.count += 1;
        self.node_attributes.items[node_id] = attr_list;
    }

    // ========================================================================
    // Query Methods (Hot Path - Optimized for Selector Matching)
    // ========================================================================

    /// Get the tag atom of a node
    pub inline fn getTag(self: *const Self, node_id: NodeId) AtomId {
        return self.nodes.items(.tag)[node_id];
    }

    /// Get the ID atom of a node
    pub inline fn getId(self: *const Self, node_id: NodeId) AtomId {
        return self.nodes.items(.id)[node_id];
    }

    /// Get the parent of a node
    pub inline fn getParent(self: *const Self, node_id: NodeId) NodeId {
        return self.nodes.items(.parent)[node_id];
    }

    /// Get the first child of a node
    pub inline fn getFirstChild(self: *const Self, node_id: NodeId) NodeId {
        return self.nodes.items(.first_child)[node_id];
    }

    /// Get the next sibling of a node
    pub inline fn getNextSibling(self: *const Self, node_id: NodeId) NodeId {
        return self.nodes.items(.next_sibling)[node_id];
    }

    /// Get the previous sibling of a node
    pub inline fn getPrevSibling(self: *const Self, node_id: NodeId) NodeId {
        return self.nodes.items(.prev_sibling)[node_id];
    }

    /// Get the ancestor bloom filter for a node
    pub inline fn getAncestorFilter(self: *const Self, node_id: NodeId) BloomFilter {
        return self.nodes.items(.ancestor_filter)[node_id];
    }

    /// Get the depth of a node
    pub inline fn getDepth(self: *const Self, node_id: NodeId) u16 {
        return self.nodes.items(.depth)[node_id];
    }

    /// Get classes for a node (returns slice of class atoms)
    pub fn getClasses(self: *const Self, node_id: NodeId) []const AtomId {
        const class_list = self.nodes.items(.classes)[node_id];
        if (class_list.count == 0) return &[_]AtomId{};
        return self.class_atoms.items[class_list.offset .. class_list.offset + class_list.count];
    }

    /// Check if a node has a specific class
    pub fn hasClass(self: *const Self, node_id: NodeId, class_atom: AtomId) bool {
        const classes = self.getClasses(node_id);
        for (classes) |c| {
            if (c == class_atom) return true;
        }
        return false;
    }

    /// Check if any ancestor might have a class (via bloom filter)
    pub fn ancestorMightHaveClass(self: *const Self, node_id: NodeId, class_hash: u32) bool {
        return self.nodes.items(.ancestor_filter)[node_id].mightContain(class_hash);
    }

    /// Get node count
    pub fn nodeCount(self: *const Self) u32 {
        return @intCast(self.nodes.len);
    }

    /// Check if a node is an element
    pub fn isElement(self: *const Self, node_id: NodeId) bool {
        return self.nodes.items(.flags)[node_id].node_type == .element;
    }

    /// Get text content of a text node
    pub fn getTextContent(self: *const Self, node_id: NodeId) ?[]const u8 {
        const text_ref = self.node_text.items[node_id];
        if (text_ref.length == 0) return null;
        return self.text_content.items[text_ref.offset .. text_ref.offset + text_ref.length];
    }

    // ========================================================================
    // Iteration Helpers
    // ========================================================================

    /// Iterator for children of a node
    pub const ChildIterator = struct {
        dom: *const FlatDOM,
        current: NodeId,

        pub fn next(self: *ChildIterator) ?NodeId {
            if (self.current == NULL_NODE) return null;
            const result = self.current;
            self.current = self.dom.getNextSibling(self.current);
            return result;
        }
    };

    /// Get an iterator over a node's children
    pub fn children(self: *const Self, node_id: NodeId) ChildIterator {
        return .{
            .dom = self,
            .current = self.getFirstChild(node_id),
        };
    }

    /// Iterator for ancestors of a node (bottom-up)
    pub const AncestorIterator = struct {
        dom: *const FlatDOM,
        current: NodeId,

        pub fn next(self: *AncestorIterator) ?NodeId {
            if (self.current == NULL_NODE) return null;
            const result = self.current;
            self.current = self.dom.getParent(self.current);
            return result;
        }
    };

    /// Get an iterator over a node's ancestors
    pub fn ancestors(self: *const Self, node_id: NodeId) AncestorIterator {
        return .{
            .dom = self,
            .current = self.getParent(node_id),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FlatDOM basic creation" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    // Create: <html><body><div></div></body></html>
    const html_tag = try atoms_table.intern("html");
    const body_tag = try atoms_table.intern("body");
    const div_tag = try atoms_table.intern("div");

    const html = try dom.createElement(html_tag, NULL_NODE);
    const body = try dom.createElement(body_tag, html);
    const div = try dom.createElement(div_tag, body);

    try std.testing.expect(dom.getParent(div) == body);
    try std.testing.expect(dom.getParent(body) == html);
    try std.testing.expect(dom.getFirstChild(html) == body);
    try std.testing.expect(dom.getFirstChild(body) == div);
}

test "FlatDOM classes" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const class1 = try atoms_table.intern("container");
    const class2 = try atoms_table.intern("flex");

    const div = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(div, &[_]AtomId{ class1, class2 });

    const classes = dom.getClasses(div);
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    try std.testing.expect(dom.hasClass(div, class1));
    try std.testing.expect(dom.hasClass(div, class2));
}

test "FlatDOM ancestor bloom filter" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const div_tag = try atoms_table.intern("div");
    const span_tag = try atoms_table.intern("span");
    const container = try atoms_table.intern("container");

    const div = try dom.createElement(div_tag, NULL_NODE);
    try dom.setClasses(div, &[_]AtomId{container});

    const span = try dom.createElement(span_tag, div);

    // Span's ancestor filter should contain parent's info
    try std.testing.expect(dom.ancestorMightHaveClass(span, container));
    try std.testing.expect(dom.ancestorMightHaveClass(span, div_tag));
}

test "FlatDOM child iteration" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const ul_tag = try atoms_table.intern("ul");
    const li_tag = try atoms_table.intern("li");

    const ul = try dom.createElement(ul_tag, NULL_NODE);
    _ = try dom.createElement(li_tag, ul);
    _ = try dom.createElement(li_tag, ul);
    _ = try dom.createElement(li_tag, ul);

    var iter = dom.children(ul);
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "FlatDOM text nodes" {
    var atoms_table = try atom.AtomTable.init(std.testing.allocator);
    defer atoms_table.deinit();

    var dom = try FlatDOM.init(std.testing.allocator, &atoms_table);
    defer dom.deinit();

    const p_tag = try atoms_table.intern("p");
    const p = try dom.createElement(p_tag, NULL_NODE);
    const text = try dom.createTextNode(p, "Hello, World!");

    try std.testing.expect(!dom.isElement(text));
    try std.testing.expectEqualStrings("Hello, World!", dom.getTextContent(text).?);
}
