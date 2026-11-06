const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const path = Io.Dir.path;

pub const SymlinkPolicy = enum { reject, allow_directory_links };

pub const Limits = struct {
    max_roots: usize = 64,
    max_entries: usize = 10_000,
    max_skills: usize = 1024,
    max_diagnostics: usize = 1024,
    /// Root is depth zero. One discovers immediate child skill directories.
    /// The hard ceiling is 64, to bound the recursive call stack.
    max_depth: usize = 1,
    /// Includes opening and closing delimiters.
    max_frontmatter_bytes: usize = 64 * 1024,
    /// Actual header bytes read across all candidates. No body read-ahead.
    max_discovery_bytes: usize = 8 * 1024 * 1024,
    max_body_bytes: usize = 1024 * 1024,
    max_yaml_nodes: usize = 4096,
    max_yaml_depth: usize = 8,
    symlinks: SymlinkPolicy = .reject,
};

pub const Entry = struct { key: []const u8, value: []const u8 };
pub const Diagnostic = struct {
    path: []const u8,
    code: anyerror,
    /// One-based YAML positions, zero when not available. Lines are relative
    /// to the YAML, excluding the opening frontmatter delimiter.
    line: usize = 0,
    column: usize = 0,
};

/// All slices belong to the containing Catalog. Do not free them separately.
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    license: ?[]const u8 = null,
    compatibility: ?[]const u8 = null,
    metadata: []const Entry = &.{},
    /// Strings are preserved; YAML string lists are joined with spaces.
    /// This package grants no permissions.
    allowed_tools: ?[]const u8 = null,
    source_path: []const u8 = "",
    directory_path: []const u8 = "",
    resolved_directory_path: []const u8 = "",

    /// Returns only the Markdown body, byte for byte. Caller frees the result
    /// with allocator.free(). Metadata and the opened directory are revalidated.
    /// Catalog must remain alive for the duration of this call.
    pub fn loadBody(self: Skill, allocator: Allocator, io: Io, limits: Limits) ![]u8 {
        const dir = try Io.Dir.openDirAbsolute(io, self.directory_path, .{});
        defer dir.close(io);
        var canonical_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = try dir.realPath(io, &canonical_buffer);
        if (!std.mem.eql(u8, canonical_buffer[0..n], self.resolved_directory_path)) return error.PathChanged;
        const file = try openSource(dir, io);
        defer file.close(io);
        var budget: usize = std.math.maxInt(usize);
        const header = try readHeader(allocator, io, file, limits, &budget);
        defer allocator.free(header.bytes);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var issue: Issue = .{};
        const current = try parse(arena.allocator(), header.yaml(), installedName(self.directory_path, self.resolved_directory_path), limits, &issue);
        if (!sameMetadata(self, current)) return error.MetadataChanged;
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            // Probe one byte beyond the limit without allocating beyond it.
            const available = limits.max_body_bytes - body.items.len;
            const size = if (available < buffer.len) available + 1 else buffer.len;
            const count = try file.readPositional(io, &.{buffer[0..size]}, header.body_offset + body.items.len);
            if (count == 0) break;
            if (count > available) return error.BodyLimit;
            try body.appendSlice(allocator, buffer[0..count]);
        }
        return body.toOwnedSlice(allocator);
    }
};

pub const Catalog = struct {
    skills: []const Skill,
    diagnostics: []const Diagnostic,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Roots must be absolute and may be skill directories or containers of skills.
/// Explicit roots are followed, including root symlinks. Child directory links
/// require opt-in. SKILL.md itself must always be a regular, non-symlink file.
/// Results follow root order, then sorted depth-first directory order. A
/// directory containing SKILL.md stops descent, even if its metadata is invalid.
/// The first VALID instance of each name wins.
/// Global count/byte exhaustion returns error.DiscoveryLimit (no partial catalog).
/// Per-file failures and depth pruning are diagnostics. No implicit roots exist.
pub fn discover(allocator: Allocator, io: Io, roots: []const []const u8, limits: Limits) !Catalog {
    if (roots.len > limits.max_roots or limits.max_depth > 64) return error.DiscoveryLimit;
    for (roots) |root| if (!path.isAbsolute(root)) return error.RootMustBeAbsolute;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var walker: Discovery = .{ .allocator = allocator, .a = arena.allocator(), .io = io, .limits = limits, .bytes_left = limits.max_discovery_bytes };
    for (roots) |root| try walker.walk(root, rootName(root), 0, true);
    return .{
        .skills = try walker.skills.toOwnedSlice(walker.a),
        .diagnostics = try walker.diagnostics.toOwnedSlice(walker.a),
        .arena = arena,
    };
}

/// Remove only trailing current-directory components when choosing an installed
/// name. Never normalize the opened path or cancel '..' across a symlink.
fn rootName(root: []const u8) []const u8 {
    var remaining = root;
    while (true) {
        const name = path.basename(remaining);
        if (!std.mem.eql(u8, name, ".")) return name;
        remaining = path.dirname(remaining) orelse return name;
    }
}

fn installedName(source: []const u8, resolved: []const u8) []const u8 {
    const name = rootName(source);
    return if (std.mem.eql(u8, name, "..")) path.basename(resolved) else name;
}

const Discovery = struct {
    allocator: Allocator,
    a: Allocator,
    io: Io,
    limits: Limits,
    bytes_left: usize,
    entries: usize = 0,
    skills: std.ArrayList(Skill) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    ancestors: [65][]const u8 = undefined,

    fn diagnostic(self: *Discovery, source: []const u8, code: anyerror, issue: Issue) !void {
        if (code == error.OutOfMemory) return error.OutOfMemory;
        if (code == error.Canceled) return error.Canceled;
        if (code == error.DiscoveryLimit) return error.DiscoveryLimit;
        if (self.diagnostics.items.len >= self.limits.max_diagnostics) return error.DiscoveryLimit;
        try self.diagnostics.append(self.a, .{ .path = try self.a.dupe(u8, source), .code = code, .line = issue.line, .column = issue.column });
    }

    fn walk(self: *Discovery, source: []const u8, name: []const u8, depth: usize, explicit: bool) anyerror!void {
        if (depth > self.limits.max_depth) return self.diagnostic(source, error.DepthLimit, .{});
        const dir = Io.Dir.openDirAbsolute(self.io, source, .{
            .iterate = true,
            .follow_symlinks = explicit or self.limits.symlinks == .allow_directory_links,
        }) catch |err| return self.diagnostic(source, err, .{});
        defer dir.close(self.io);
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = dir.realPath(self.io, &buffer) catch |err| return self.diagnostic(source, err, .{});
        const resolved = buffer[0..n];
        for (self.ancestors[0..depth]) |ancestor| {
            if (std.mem.eql(u8, ancestor, resolved)) return self.diagnostic(source, error.SymlinkLoop, .{});
        }
        // Temporary canonical paths need only survive recursive children.
        const canonical = try self.allocator.dupe(u8, resolved);
        defer self.allocator.free(canonical);
        self.ancestors[depth] = canonical;
        const file = openSource(dir, self.io) catch |err| switch (err) {
            error.FileNotFound => return self.children(dir, source, depth),
            else => return self.diagnostic(source, err, .{}),
        };
        defer file.close(self.io);
        const source_path = try path.join(self.a, &.{ source, "SKILL.md" });
        const header = readHeader(self.allocator, self.io, file, self.limits, &self.bytes_left) catch |err| return self.diagnostic(source_path, err, .{});
        defer self.allocator.free(header.bytes);
        var issue: Issue = .{};
        const installed_name = if (explicit) installedName(source, canonical) else name;
        var skill = parse(self.a, header.yaml(), installed_name, self.limits, &issue) catch |err| return self.diagnostic(source_path, err, issue);
        for (self.skills.items) |existing| {
            if (std.mem.eql(u8, existing.name, skill.name)) return self.diagnostic(source_path, error.DuplicateName, .{});
        }
        if (self.skills.items.len >= self.limits.max_skills) return error.DiscoveryLimit;
        skill.source_path = source_path;
        skill.directory_path = try self.a.dupe(u8, source);
        skill.resolved_directory_path = try self.a.dupe(u8, canonical);
        try self.skills.append(self.a, skill);
    }

    fn children(self: *Discovery, dir: Io.Dir, source: []const u8, depth: usize) !void {
        var names: std.ArrayList(struct { name: []const u8, link: bool }) = .empty;
        defer {
            for (names.items) |entry| self.allocator.free(entry.name);
            names.deinit(self.allocator);
        }
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch |err| return self.diagnostic(source, err, .{})) |entry| {
            if (self.entries >= self.limits.max_entries) return error.DiscoveryLimit;
            self.entries += 1;
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            const owned = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(owned);
            try names.append(self.allocator, .{ .name = owned, .link = entry.kind == .sym_link });
        }
        std.mem.sort(@TypeOf(names.items[0]), names.items, {}, struct {
            fn less(_: void, a: @TypeOf(names.items[0]), b: @TypeOf(names.items[0])) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        for (names.items) |entry| {
            const child = try path.join(self.allocator, &.{ source, entry.name });
            defer self.allocator.free(child);
            if (entry.link and self.limits.symlinks == .reject) {
                try self.diagnostic(child, error.SymlinkRejected, .{});
                continue;
            }
            try self.walk(child, entry.name, depth + 1, false);
        }
    }
};

fn openSource(dir: Io.Dir, io: Io) !Io.File {
    // Stat before opening avoids blocking on a pre-existing FIFO/device.
    const stat = try dir.statFile(io, "SKILL.md", .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.SourceNotRegular;
    const file = try dir.openFile(io, "SKILL.md", .{ .follow_symlinks = false, .allow_directory = false });
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.SourceNotRegular;
    return file;
}

const Header = struct {
    bytes: []u8,
    yaml_start: usize,
    yaml_end: usize,
    body_offset: usize,
    fn yaml(self: Header) []const u8 {
        return self.bytes[self.yaml_start..self.yaml_end];
    }
};

fn delimiter(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), "---");
}

fn readHeader(a: Allocator, io: Io, file: Io.File, limits: Limits, budget: *usize) !Header {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    // A single-byte read avoids pulling any body bytes into discovery. The
    // explicit byte budgets also bound the number of these small reads.
    var buffer: [1]u8 = undefined;
    var offset: usize = 0;
    var line_start: usize = 0;
    var yaml_start: ?usize = null;
    while (true) {
        // At an exact byte budget, stat can establish EOF without reading an
        // extra byte. Otherwise an unclosed header requires more budget.
        const count = if (budget.* == 0) blk: {
            if ((try file.stat(io)).size != offset) return error.DiscoveryLimit;
            break :blk @as(usize, 0);
        } else try file.readPositional(io, &.{buffer[0..@min(buffer.len, budget.*)]}, offset);
        budget.* -= count;
        offset += count;
        for (buffer[0..count]) |byte| {
            if (bytes.items.len >= limits.max_frontmatter_bytes) return error.FrontmatterLimit;
            try bytes.append(a, byte);
            if (byte != '\n') continue;
            const line = bytes.items[line_start .. bytes.items.len - 1];
            if (yaml_start == null) {
                if (!delimiter(line)) return error.MissingFrontmatter;
                yaml_start = bytes.items.len;
            } else if (delimiter(line)) {
                const body_offset = bytes.items.len;
                const yaml_end = line_start;
                return .{ .bytes = try bytes.toOwnedSlice(a), .yaml_start = yaml_start.?, .yaml_end = yaml_end, .body_offset = body_offset };
            }
            line_start = bytes.items.len;
        }
        if (count == 0) {
            if (yaml_start != null and delimiter(bytes.items[line_start..])) {
                const body_offset = bytes.items.len;
                return .{ .bytes = try bytes.toOwnedSlice(a), .yaml_start = yaml_start.?, .yaml_end = line_start, .body_offset = body_offset };
            }
            return error.UnterminatedFrontmatter;
        }
    }
}

const CDocument = opaque {};
const Node = extern struct { kind: c_int, data: ?[*]const u8, len: usize, id: c_int };
const Issue = extern struct { line: usize = 0, column: usize = 0 };
extern fn sy_parse([*]const u8, usize, usize, usize, *?*CDocument, *Issue) c_int;
extern fn sy_free(*CDocument) void;
extern fn sy_root(*CDocument) Node;
extern fn sy_pair(*CDocument, c_int, usize, *Node, *Node) void;
extern fn sy_item(*CDocument, c_int, usize) Node;

fn scalar(node: Node) ![]const u8 {
    if (node.kind != 1) return error.UnsupportedFieldType;
    return node.data.?[0..node.len];
}

fn pair(doc: *CDocument, map: Node, index: usize) struct { key: Node, value: Node } {
    var key: Node = undefined;
    var value: Node = undefined;
    sy_pair(doc, map.id, index, &key, &value);
    return .{ .key = key, .value = value };
}

fn checkMap(doc: *CDocument, map: Node) !void {
    if (map.kind != 3) return error.UnsupportedFieldType;
    for (0..map.len) |i| {
        const key = try scalar(pair(doc, map, i).key);
        for (0..i) |j| {
            if (std.mem.eql(u8, key, try scalar(pair(doc, map, j).key))) return error.DuplicateKey;
        }
    }
}

const Field = enum { name, description, license, compatibility, metadata, @"allowed-tools" };

fn allowedTools(a: Allocator, doc: *CDocument, node: Node) ![]const u8 {
    if (node.kind != 2) return a.dupe(u8, try scalar(node));
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(a);
    for (0..node.len) |i| {
        const item = try scalar(sy_item(doc, node.id, i));
        if (i != 0) try value.append(a, ' ');
        try value.appendSlice(a, item);
    }
    return value.toOwnedSlice(a);
}

fn parse(a: Allocator, yaml: []const u8, directory_name: []const u8, limits: Limits, issue: *Issue) !Skill {
    var document: ?*CDocument = null;
    switch (sy_parse(yaml.ptr, yaml.len, limits.max_yaml_nodes, limits.max_yaml_depth, &document, issue)) {
        0 => {},
        1 => return error.YamlSyntax,
        2 => return error.UnsupportedFieldType,
        3 => return error.YamlLimit,
        4 => return error.OutOfMemory,
        5 => return error.MultipleYamlDocuments,
        else => unreachable,
    }
    const doc = document.?;
    defer sy_free(doc);
    const root = sy_root(doc);
    try checkMap(doc, root);
    var skill: Skill = .{ .name = directory_name, .description = "" };
    for (0..root.len) |i| {
        const field = pair(doc, root, i);
        const key = try scalar(field.key);
        // The bounded libyaml document is already parsed. Do not traverse or
        // interpret unknown extension values, including aliases and tags.
        const known = std.meta.stringToEnum(Field, key) orelse continue;
        if (known == .metadata) {
            try checkMap(doc, field.value);
            const entries = try a.alloc(Entry, field.value.len);
            for (entries, 0..) |*entry, j| {
                const item = pair(doc, field.value, j);
                entry.* = .{ .key = try a.dupe(u8, try scalar(item.key)), .value = try a.dupe(u8, try scalar(item.value)) };
            }
            std.mem.sort(Entry, entries, {}, struct {
                fn less(_: void, x: Entry, y: Entry) bool {
                    return std.mem.lessThan(u8, x.key, y.key);
                }
            }.less);
            skill.metadata = entries;
        } else if (known == .@"allowed-tools") {
            skill.allowed_tools = try allowedTools(a, doc, field.value);
        } else {
            const value = try scalar(field.value);
            switch (known) {
                .name => skill.name = value,
                .description => skill.description = try a.dupe(u8, value),
                .license => skill.license = try a.dupe(u8, value),
                .compatibility => skill.compatibility = try a.dupe(u8, value),
                .metadata, .@"allowed-tools" => unreachable,
            }
        }
    }
    if (!validName(skill.name)) return error.InvalidName;
    skill.name = try a.dupe(u8, skill.name);
    try characterLimit(skill.description, 1024);
    if (skill.compatibility) |value| try characterLimit(value, 500);
    return skill;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-' or name[name.len - 1] == '-') return false;
    var hyphen = false;
    for (name) |byte| {
        if (byte == '-') {
            if (hyphen) return false;
            hyphen = true;
        } else {
            if (!(byte >= 'a' and byte <= 'z') and !(byte >= '0' and byte <= '9')) return false;
            hyphen = false;
        }
    }
    return true;
}

/// Counts Unicode scalar values, not UTF-8 bytes or grapheme clusters.
fn characterLimit(value: []const u8, maximum: usize) !void {
    const count = std.unicode.utf8CountCodepoints(value) catch return error.InvalidUtf8;
    if (count == 0 or count > maximum) return error.InvalidLength;
}

fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}

fn sameMetadata(a: Skill, b: Skill) bool {
    if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.description, b.description) or
        !sameOptional(a.license, b.license) or !sameOptional(a.compatibility, b.compatibility) or
        !sameOptional(a.allowed_tools, b.allowed_tools) or a.metadata.len != b.metadata.len) return false;
    for (a.metadata, b.metadata) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key) or !std.mem.eql(u8, left.value, right.value)) return false;
    }
    return true;
}

test {
    _ = @import("tests.zig");
}
