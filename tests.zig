const std = @import("std");
const skills = @import("root.zig");
const t = std.testing;
const a = t.allocator;
const io = t.io;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = try a.dupe(u8, buffer[0..n]) };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: Fixture, file: []const u8, contents: []const u8) !void {
        if (std.Io.Dir.path.dirname(file)) |parent| try self.tmp.dir.createDirPath(io, parent);
        try self.tmp.dir.writeFile(io, .{ .sub_path = file, .data = contents });
    }

    fn skill(self: Fixture, name: []const u8, description: []const u8, body: []const u8) !void {
        const file = try a.print("{s}/SKILL.md", .{name});
        defer a.free(file);
        const contents = try a.print("---\nname: {s}\ndescription: {s}\n---\n{s}", .{ name, description, body });
        defer a.free(contents);
        try self.write(file, contents);
    }

    fn catalog(self: Fixture, limits: skills.Limits) !skills.Catalog {
        return skills.discover(a, io, &.{self.root}, limits);
    }
};

fn expectDiagnostic(catalog: skills.Catalog, code: anyerror) !void {
    for (catalog.diagnostics) |diagnostic| if (diagnostic.code == code) return;
    std.debug.print("missing diagnostic {s}; actual: {any}\n", .{ @errorName(code), catalog.diagnostics });
    return error.TestUnexpectedResult;
}

test "plain quoted and block YAML preserve metadata and lazy body bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.skill("plain", "Simple text", "# Plain\n");
    try f.write("quoted/SKILL.md", "---\nname: 'quoted'\ndescription: \"Colon: # escaped \\nline\"\nlicense: MIT\ncompatibility: 'Zig 0.17'\nmetadata:\n  version: \"1.0\"\n  author: 'Example'\nallowed-tools: Read Bash(git:*)\n---\n\n# Body\r\n\x00\xff");
    try f.write("block/SKILL.md", "---\nname: block\ndescription: |\n  first line\n  second line\n---\nbody\n");
    try f.write("folded/SKILL.md", "---\nname: folded\ndescription: >-\n  first line\n  second line\n---\n");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 4), catalog.skills.len);
    try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
    try t.expectEqualStrings("block", catalog.skills[0].name);
    try t.expectEqualStrings("first line\nsecond line\n", catalog.skills[0].description);
    try t.expectEqualStrings("first line second line", catalog.skills[1].description);
    const quoted = catalog.skills[3];
    try t.expectEqualStrings("Colon: # escaped \nline", quoted.description);
    try t.expectEqualStrings("MIT", quoted.license.?);
    try t.expectEqualStrings("Zig 0.17", quoted.compatibility.?);
    try t.expectEqualStrings("author", quoted.metadata[0].key);
    try t.expectEqualStrings("1.0", quoted.metadata[1].value);
    try t.expectEqualStrings("Read Bash(git:*)", quoted.allowed_tools.?);
    const body = try quoted.loadBody(a, io, .{});
    defer a.free(body);
    try t.expectEqualStrings("\n# Body\r\n\x00\xff", body);
}

test "invalid YAML types duplicates syntax and delimiters are diagnostics" {
    var f = try Fixture.init();
    defer f.deinit();
    const cases = [_]struct { dir: []const u8, yaml: []const u8 }{
        .{ .dir = "array", .yaml = "name: array\ndescription: [one, two]" },
        .{ .dir = "number", .yaml = "name: number\ndescription: 12" },
        .{ .dir = "boolean", .yaml = "name: boolean\ndescription: true" },
        .{ .dir = "null", .yaml = "name: 'null'\ndescription: null" },
        .{ .dir = "nested", .yaml = "name: nested\ndescription: ok\nmetadata: {key: {nested: bad}}" },
        .{ .dir = "meta-number", .yaml = "name: meta-number\ndescription: ok\nmetadata: {version: 1.0}" },
        .{ .dir = "dupe", .yaml = "name: dupe\nname: dupe\ndescription: ok" },
        .{ .dir = "meta-dupe", .yaml = "name: meta-dupe\ndescription: ok\nmetadata: {key: one, 'key': two}" },
        .{ .dir = "syntax", .yaml = "name: syntax\ndescription: [unclosed" },
        .{ .dir = "root-list", .yaml = "- name: root-list" },
        .{ .dir = "tag", .yaml = "name: tag\ndescription: !!int '12'" },
        .{ .dir = "custom-tag", .yaml = "name: custom-tag\ndescription: !custom 12" },
        .{ .dir = "tools-number", .yaml = "name: tools-number\ndescription: ok\nallowed-tools: [Read, 12]" },
        .{ .dir = "tools-map", .yaml = "name: tools-map\ndescription: ok\nallowed-tools: {tool: Read}" },
        .{ .dir = "tools-recursive", .yaml = "name: tools-recursive\ndescription: ok\nallowed-tools: &tools [*tools]" },
        .{ .dir = "alias-number", .yaml = "name: alias-number\ncustom: &n 12\ndescription: *n" },
        .{ .dir = "tools-tag", .yaml = "name: tools-tag\ndescription: ok\nallowed-tools: !custom [Read]" },
    };
    for (cases) |case| {
        const file = try a.print("{s}/SKILL.md", .{case.dir});
        defer a.free(file);
        const contents = try a.print("---\n{s}\n---\n", .{case.yaml});
        defer a.free(contents);
        try f.write(file, contents);
    }
    try f.write("unclosed/SKILL.md", "---\nname: unclosed\ndescription: ok\n");
    try f.write("missing/SKILL.md", "# Not frontmatter\n");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 0), catalog.skills.len);
    try t.expectEqual(cases.len + 2, catalog.diagnostics.len);
    try expectDiagnostic(catalog, error.UnsupportedFieldType);
    try expectDiagnostic(catalog, error.DuplicateKey);
    try expectDiagnostic(catalog, error.YamlSyntax);
    try expectDiagnostic(catalog, error.UnterminatedFrontmatter);
    try expectDiagnostic(catalog, error.MissingFrontmatter);
    for (catalog.diagnostics) |diagnostic| {
        if (diagnostic.code == error.YamlSyntax) try t.expect(diagnostic.line > 0 and diagnostic.column > 0);
    }
}

test "empty YAML unresolved aliases and recursive metadata reject safely" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("empty/SKILL.md", "---\n---\n");
    try f.write("alias/SKILL.md", "---\nname: alias\ndescription: *missing\n---\n");
    try f.write("recursive/SKILL.md", "---\nname: recursive\ndescription: ok\nmetadata: &m {key: *m}\n---\n");
    try f.write("missing-description/SKILL.md", "---\nname: missing-description\n---\n");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 0), catalog.skills.len);
    try t.expectEqual(@as(usize, 4), catalog.diagnostics.len);
    try expectDiagnostic(catalog, error.UnsupportedFieldType);
    try expectDiagnostic(catalog, error.YamlSyntax);
    try expectDiagnostic(catalog, error.InvalidLength);
}

test "exact frontmatter discovery byte and empty body limits" {
    var f = try Fixture.init();
    defer f.deinit();
    const contents = "---\nname: exact\ndescription: ok\n---";
    try f.write("exact/SKILL.md", contents);
    var catalog = try f.catalog(.{ .max_discovery_bytes = contents.len, .max_frontmatter_bytes = contents.len });
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    const body = try catalog.skills[0].loadBody(a, io, .{ .max_body_bytes = 0 });
    defer a.free(body);
    try t.expectEqual(@as(usize, 0), body.len);
    try f.skill("exact", "ok", "a");
    try t.expectError(error.BodyLimit, catalog.skills[0].loadBody(a, io, .{ .max_body_bytes = 0 }));
    try t.expectError(error.FrontmatterLimit, catalog.skills[0].loadBody(a, io, .{ .max_frontmatter_bytes = 1 }));
    try t.expectError(error.YamlLimit, catalog.skills[0].loadBody(a, io, .{ .max_yaml_nodes = 0 }));
}

test "explicit strings anchors CRLF and closing delimiter at EOF" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("yes/SKILL.md", "---\r\nname: yes\r\ndescription: !!str 12\r\nmetadata: {a: &s \"true\", b: *s}\r\n---");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    try t.expectEqualStrings("12", catalog.skills[0].description);
    try t.expectEqualStrings("true", catalog.skills[0].metadata[1].value);
    const body = try catalog.skills[0].loadBody(a, io, .{});
    defer a.free(body);
    try t.expectEqual(@as(usize, 0), body.len);
}

test "nonspecific scalar tags and explicit string tags preserve strings" {
    var f = try Fixture.init();
    defer f.deinit();
    const descriptions = [_][]const u8{ "! 12", "! true", "!!str 12", "!!str true" };
    for (descriptions, 0..) |description, i| {
        const file = try a.print("tagged-{d}/SKILL.md", .{i});
        defer a.free(file);
        const contents = try a.print("---\nname: tagged-{d}\ndescription: {s}\nmetadata:\n  ! 12: ! true\n  value: ! 12\n---\nbody", .{ i, description });
        defer a.free(contents);
        try f.write(file, contents);
    }
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(descriptions.len, catalog.skills.len);
    try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
    for (catalog.skills, 0..) |skill, i| {
        try t.expectEqualStrings(if (i % 2 == 0) "12" else "true", skill.description);
        try t.expectEqualStrings("12", skill.metadata[0].key);
        try t.expectEqualStrings("true", skill.metadata[0].value);
        try t.expectEqualStrings("12", skill.metadata[1].value);
        const body = try skill.loadBody(a, io, .{});
        defer a.free(body);
        try t.expectEqualStrings("body", body);
    }
    try t.checkAllAllocationFailures(a, allocationRun, .{catalog.skills[0].directory_path});
}

test "nonspecific mapping tags preserve root and metadata mappings" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root-map/SKILL.md", "---\n! {name: root-map, description: ok, metadata: {version: \"1.0\"}}\n---\nbody");
    try f.write("metadata-map/SKILL.md", "---\nname: metadata-map\ndescription: ok\nmetadata: ! {version: \"1.0\"}\n---\nbody");
    try f.write("custom-root/SKILL.md", "---\n!custom {name: custom-root, description: ok}\n---\n");
    try f.write("custom-metadata/SKILL.md", "---\nname: custom-metadata\ndescription: ok\nmetadata: !custom {version: \"1.0\"}\n---\n");
    try f.write("sequence/SKILL.md", "---\nname: sequence\ndescription: ok\nmetadata: ! [one, two]\n---\n");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 2), catalog.skills.len);
    try t.expectEqual(@as(usize, 3), catalog.diagnostics.len);
    for (catalog.diagnostics) |diagnostic| try t.expectEqual(error.UnsupportedFieldType, diagnostic.code);
    for (catalog.skills) |skill| {
        try t.expectEqualStrings("version", skill.metadata[0].key);
        try t.expectEqualStrings("1.0", skill.metadata[0].value);
        const body = try skill.loadBody(a, io, .{});
        defer a.free(body);
        try t.expectEqualStrings("body", body);
        try t.checkAllAllocationFailures(a, allocationRun, .{skill.directory_path});
    }
}

test "YAML core scalar resolution never coerces values into strings" {
    var f = try Fixture.init();
    defer f.deinit();
    const nonstrings = [_][]const u8{ "0", "-42", "+3", "0xFA", "0o17", "1.0", ".5", "5.", "2e3", "-.inf", ".NaN", "False", "NULL", "~" };
    for (nonstrings, 0..) |value, i| {
        const name = try a.print("bad-{d}", .{i});
        defer a.free(name);
        try f.skill(name, value, "");
    }
    const strings = [_][]const u8{ "yes", "on", "2026-11-01", "1.2.3", "!!str true", "'null'", "\"12\"" };
    for (strings, 0..) |value, i| {
        const name = try a.print("good-{d}", .{i});
        defer a.free(name);
        try f.skill(name, value, "");
    }
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(strings.len, catalog.skills.len);
    try t.expectEqual(nonstrings.len, catalog.diagnostics.len);
    for (catalog.diagnostics) |diagnostic| try t.expectEqual(error.UnsupportedFieldType, diagnostic.code);
}

test "names retain spec syntax but may differ from directory names" {
    var f = try Fixture.init();
    defer f.deinit();
    const invalid = [_][]const u8{ "Upper", "-start", "end-", "a--b", "ümlaut", "under_score", "", "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklm" };
    for (invalid, 0..) |name, i| {
        const file = try a.print("case-{d}/SKILL.md", .{i});
        defer a.free(file);
        const contents = try a.print("---\nname: '{s}'\ndescription: ok\n---\n", .{name});
        defer a.free(contents);
        try f.write(file, contents);
    }
    try f.write("mismatch/SKILL.md", "---\nname: other\ndescription: ok\n---\n");
    try f.skill("a-1", "ok", "");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 2), catalog.skills.len);
    try t.expectEqual(invalid.len, catalog.diagnostics.len);
    try expectDiagnostic(catalog, error.InvalidName);
    try t.expectEqualStrings("other", catalog.skills[1].name);
}

test "Unicode scalar length limits including compatibility" {
    var f = try Fixture.init();
    defer f.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..1024) |_| try text.appendSlice(a, "é");
    try f.skill("valid", text.items, "");
    try text.appendSlice(a, "é");
    try f.skill("long", text.items, "");
    try f.skill("empty", "''", "");
    const compatibility = try a.alloc(u8, 501);
    defer a.free(compatibility);
    @memset(compatibility, 'x');
    const contents = try a.print("---\nname: incompatible\ndescription: ok\ncompatibility: {s}\n---\n", .{compatibility});
    defer a.free(contents);
    try f.write("incompatible/SKILL.md", contents);
    try f.write("empty-compat/SKILL.md", "---\nname: empty-compat\ndescription: ok\ncompatibility: ''\n---\n");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    try t.expectEqual(@as(usize, 4), catalog.diagnostics.len);
    try expectDiagnostic(catalog, error.InvalidLength);
}

test "maximum name and compatibility lengths are inclusive" {
    var f = try Fixture.init();
    defer f.deinit();
    const name = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl";
    try t.expectEqual(@as(usize, 64), name.len);
    const compatibility = try a.alloc(u8, 500);
    defer a.free(compatibility);
    @memset(compatibility, 'x');
    const contents = try a.print("---\nname: {s}\ndescription: x\ncompatibility: {s}\n---\n", .{ name, compatibility });
    defer a.free(contents);
    const file = try a.print("{s}/SKILL.md", .{name});
    defer a.free(file);
    try f.write(file, contents);
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
}

test "ordered roots first VALID name wins absent roots and deterministic duplicates" {
    var first = try Fixture.init();
    defer first.deinit();
    var second = try Fixture.init();
    defer second.deinit();
    try first.skill("same", "first", "one");
    try first.write("fallback/SKILL.md", "---\nname: fallback\ndescription: []\n---\n");
    try second.skill("same", "second", "two");
    try second.skill("fallback", "valid fallback", "");
    const absent = try a.print("{s}/absent", .{first.root});
    defer a.free(absent);
    const roots = &.{ absent, first.root, second.root, first.root };
    var catalog = try skills.discover(a, io, roots, .{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 2), catalog.skills.len);
    try t.expectEqualStrings("same", catalog.skills[0].name);
    try t.expectEqualStrings("first", catalog.skills[0].description);
    try t.expectEqualStrings("fallback", catalog.skills[1].name);
    try expectDiagnostic(catalog, error.FileNotFound);
    try expectDiagnostic(catalog, error.DuplicateName);
    var again = try skills.discover(a, io, roots, .{});
    defer again.deinit();
    try t.expectEqual(catalog.diagnostics.len, again.diagnostics.len);
    for (catalog.diagnostics, again.diagnostics) |left, right| {
        try t.expectEqualStrings(left.path, right.path);
        try t.expectEqual(left.code, right.code);
    }
    var empty = try skills.discover(a, io, &.{}, .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.skills.len);
    try t.expectError(error.RootMustBeAbsolute, skills.discover(a, io, &.{"relative"}, .{}));
}

test "explicit root dots and trailing separators preserve installed names and paths" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("example/SKILL.md", "---\ndescription: ok\n---\nbody");
    try f.tmp.dir.createDirPath(io, "example/child");
    const spellings = [_][]const u8{ "example", "example/.", "example/", "example///", "./example/././/", "example/child/..", "./example/child/.././/" };
    for (spellings) |spelling| {
        const root = try a.print("{s}/{s}", .{ f.root, spelling });
        defer a.free(root);
        var catalog = try skills.discover(a, io, &.{root}, .{});
        defer catalog.deinit();
        try t.expectEqual(@as(usize, 1), catalog.skills.len);
        try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
        try t.expectEqualStrings("example", catalog.skills[0].name);
        try t.expectEqualStrings(root, catalog.skills[0].directory_path);
        const body = try catalog.skills[0].loadBody(a, io, .{});
        defer a.free(body);
        try t.expectEqualStrings("body", body);
    }
    const dotted = try a.print("{s}/example/./.", .{f.root});
    defer a.free(dotted);
    try t.checkAllAllocationFailures(a, allocationRun, .{dotted});
}

test "explicit symlink root dots keep aliases and dotdot follows filesystem semantics" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var installed = try Fixture.init();
    defer installed.deinit();
    var source = try Fixture.init();
    defer source.deinit();
    try source.write("target/SKILL.md", "---\ndescription: ok\n---\nbody");
    try source.skill("destination", "ok", "body");
    try source.tmp.dir.createDirPath(io, "destination/child");
    const target = try a.print("{s}/target", .{source.root});
    defer a.free(target);
    const child = try a.print("{s}/destination/child", .{source.root});
    defer a.free(child);
    try installed.tmp.dir.symLink(io, target, "alias", .{ .is_directory = true });
    try installed.tmp.dir.symLink(io, child, "jump", .{ .is_directory = true });
    const spellings = [_][]const u8{ "alias", "alias/.", "alias///", "./alias/././/", "jump/..", "jump/.././/" };
    for (spellings, 0..) |spelling, i| {
        const root = try a.print("{s}/{s}", .{ installed.root, spelling });
        defer a.free(root);
        var catalog = try skills.discover(a, io, &.{root}, .{});
        defer catalog.deinit();
        try t.expectEqual(@as(usize, 1), catalog.skills.len);
        try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
        try t.expectEqualStrings(if (i < 4) "alias" else "destination", catalog.skills[0].name);
        try t.expectEqualStrings(root, catalog.skills[0].directory_path);
        const body = try catalog.skills[0].loadBody(a, io, .{});
        defer a.free(body);
        try t.expectEqualStrings("body", body);
    }
    const dotted = try a.print("{s}/alias/.", .{installed.root});
    defer a.free(dotted);
    try t.checkAllAllocationFailures(a, allocationRun, .{dotted});
    const parent = try a.print("{s}/jump/..", .{installed.root});
    defer a.free(parent);
    try t.checkAllAllocationFailures(a, allocationRun, .{parent});
}

test "discovery byte count depth YAML and frontmatter budgets" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.skill("alpha", "ok", "body");
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_roots = 0 }));
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_entries = 0 }));
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_skills = 0 }));
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_discovery_bytes = 1 }));
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_depth = 65 }));
    var too_small = try f.catalog(.{ .max_frontmatter_bytes = 4 });
    defer too_small.deinit();
    try expectDiagnostic(too_small, error.FrontmatterLimit);
    var too_few_nodes = try f.catalog(.{ .max_yaml_nodes = 1 });
    defer too_few_nodes.deinit();
    try expectDiagnostic(too_few_nodes, error.YamlLimit);
    var too_shallow = try f.catalog(.{ .max_yaml_depth = 0 });
    defer too_shallow.deinit();
    try expectDiagnostic(too_shallow, error.YamlLimit);
    var depth_zero = try f.catalog(.{ .max_depth = 0 });
    defer depth_zero.deinit();
    try expectDiagnostic(depth_zero, error.DepthLimit);
    try t.expectError(error.DiscoveryLimit, f.catalog(.{ .max_frontmatter_bytes = 4, .max_diagnostics = 0 }));
}

test "nested discovery has bounded depth and sorted order" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("group/zeta/SKILL.md", "---\nname: zeta\ndescription: ok\n---\n");
    try f.write("group/alpha/SKILL.md", "---\nname: alpha\ndescription: ok\n---\n");
    var shallow = try f.catalog(.{});
    defer shallow.deinit();
    try t.expectEqual(@as(usize, 0), shallow.skills.len);
    try expectDiagnostic(shallow, error.DepthLimit);
    var deep = try f.catalog(.{ .max_depth = 2 });
    defer deep.deinit();
    try t.expectEqual(@as(usize, 2), deep.skills.len);
    try t.expectEqualStrings("alpha", deep.skills[0].name);
    try t.expectEqualStrings("zeta", deep.skills[1].name);
}

test "body loading is lazy bounded and revalidates all metadata" {
    var f = try Fixture.init();
    defer f.deinit();
    const large = try a.alloc(u8, 100_000);
    defer a.free(large);
    @memset(large, 'b');
    try f.skill("lazy", "initial", large);
    var catalog = try f.catalog(.{ .max_discovery_bytes = 512 });
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    const skill = catalog.skills[0];
    try t.expectError(error.BodyLimit, skill.loadBody(a, io, .{ .max_body_bytes = 5000 }));
    const exact = try skill.loadBody(a, io, .{ .max_body_bytes = large.len });
    defer a.free(exact);
    try t.expectEqualSlices(u8, large, exact);
    try f.skill("lazy", "changed", "body");
    try t.expectError(error.MetadataChanged, skill.loadBody(a, io, .{}));
    try f.write("lazy/SKILL.md", "---\nname: lazy\ndescription: initial\nlicense: MIT\n---\nbody");
    try t.expectError(error.MetadataChanged, skill.loadBody(a, io, .{}));
    try f.write("lazy/SKILL.md", "---\nname: lazy\ndescription: initial\nmetadata: {version: one}\n---\nbody");
    try t.expectError(error.MetadataChanged, skill.loadBody(a, io, .{}));
    try f.write("lazy/SKILL.md", "---\nname: lazy\ndescription: initial\n");
    try t.expectError(error.UnterminatedFrontmatter, skill.loadBody(a, io, .{}));
    try f.tmp.dir.deleteFile(io, "lazy/SKILL.md");
    try t.expectError(error.FileNotFound, skill.loadBody(a, io, .{}));
}

test "directory symlink opt-in explicit roots loops and retargeting" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var installed = try Fixture.init();
    defer installed.deinit();
    var source = try Fixture.init();
    defer source.deinit();
    var replacement = try Fixture.init();
    defer replacement.deinit();
    try source.skill("linked", "installed", "external body");
    try replacement.skill("linked", "installed", "replacement body");
    const target = try std.Io.Dir.path.join(a, &.{ source.root, "linked" });
    defer a.free(target);
    const other = try std.Io.Dir.path.join(a, &.{ replacement.root, "linked" });
    defer a.free(other);
    try installed.tmp.dir.symLink(io, target, "linked", .{ .is_directory = true });
    var denied = try installed.catalog(.{});
    defer denied.deinit();
    try t.expectEqual(@as(usize, 0), denied.skills.len);
    try expectDiagnostic(denied, error.SymlinkRejected);
    var allowed = try installed.catalog(.{ .symlinks = .allow_directory_links });
    defer allowed.deinit();
    try t.expectEqual(@as(usize, 1), allowed.skills.len);
    const body = try allowed.skills[0].loadBody(a, io, .{});
    defer a.free(body);
    try t.expectEqualStrings("external body", body);
    const explicit = try std.Io.Dir.path.join(a, &.{ installed.root, "linked" });
    defer a.free(explicit);
    var explicit_catalog = try skills.discover(a, io, &.{explicit}, .{});
    defer explicit_catalog.deinit();
    try t.expectEqual(@as(usize, 1), explicit_catalog.skills.len);
    try installed.tmp.dir.deleteFile(io, "linked");
    try installed.tmp.dir.symLink(io, other, "linked", .{ .is_directory = true });
    try t.expectError(error.PathChanged, allowed.skills[0].loadBody(a, io, .{}));
    try installed.tmp.dir.symLink(io, installed.root, "loop", .{ .is_directory = true });
    var loop = try installed.catalog(.{ .symlinks = .allow_directory_links, .max_depth = 4 });
    defer loop.deinit();
    try expectDiagnostic(loop, error.SymlinkLoop);
}

test "body revalidation compares metadata values without depending on YAML spelling" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("stable/SKILL.md", "---\nname: stable\ndescription: ok\nmetadata: {a: one, b: two}\n---\nold");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try f.write("stable/SKILL.md", "---\nmetadata:\n  b: 'two'\n  a: one\ndescription: \"ok\"\nname: stable\n---\nnew\r\n");
    const body = try catalog.skills[0].loadBody(a, io, .{});
    defer a.free(body);
    try t.expectEqualStrings("new\r\n", body);
    try f.write("stable/SKILL.md", "---\nname: stable\ndescription: ok\nmetadata: {a: one, b: changed}\n---\nnew");
    try t.expectError(error.MetadataChanged, catalog.skills[0].loadBody(a, io, .{}));
}

test "SKILL.md file symlinks cannot escape a skill directory" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.skill("safe", "ok", "body");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try f.tmp.dir.rename("safe/SKILL.md", f.tmp.dir, "outside.md", io);
    try f.tmp.dir.symLink(io, "../outside.md", "safe/SKILL.md", .{});
    try t.expectError(error.SourceNotRegular, catalog.skills[0].loadBody(a, io, .{}));
    var redirected = try f.catalog(.{ .symlinks = .allow_directory_links });
    defer redirected.deinit();
    try t.expectEqual(@as(usize, 0), redirected.skills.len);
    try expectDiagnostic(redirected, error.SourceNotRegular);
}

fn allocationRun(allocator: std.mem.Allocator, root: []const u8) !void {
    var catalog = try skills.discover(allocator, io, &.{ root, root }, .{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    const body = try catalog.skills[0].loadBody(allocator, io, .{});
    defer allocator.free(body);
    try t.expectEqualStrings("body", body);
}

test "Claude extensions are ignored as bounded data while known fields stay typed" {
    var f = try Fixture.init();
    defer f.deinit();
    // Synthetic frontmatter based on Claude Code's frontmatter reference.
    try f.write("review/SKILL.md",
        \\---
        \\description: >-
        \\  Review changes and explain
        \\  what needs attention.
        \\argument-hint: "[filename] [format]"
        \\arguments: [filename, format]
        \\disable-model-invocation: true
        \\user-invocable: false
        \\model: inherit
        \\context: fork
        \\agent: Explore
        \\hooks:
        \\  PreToolUse:
        \\    - matcher: Bash
        \\      hooks:
        \\        - type: command
        \\          command: "printf 'synthetic only'"
        \\          once: true
        \\future-version: 2
        \\future-null: null
        \\future-tag: !custom {value: !another false}
        \\future-recursive: &loop [*loop]
        \\allowed-tools:
        \\  - Read
        \\  - Bash(git:*)
        \\metadata: {author: Example, version: "1.0"}
        \\---
        \\body
    );
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
    try t.expectEqualStrings("review", catalog.skills[0].name);
    try t.expectEqualStrings("Review changes and explain what needs attention.", catalog.skills[0].description);
    try t.expectEqualStrings("Read Bash(git:*)", catalog.skills[0].allowed_tools.?);
    try t.checkAllAllocationFailures(a, allocationRun, .{f.root});
}

test "allowed tools strings lists and aliases retain the existing string API" {
    var f = try Fixture.init();
    defer f.deinit();
    const cases = [_]struct { yaml: []const u8, expected: []const u8 }{
        .{ .yaml = "Read Bash(git:*)", .expected = "Read Bash(git:*)" },
        .{ .yaml = "Read, Bash(git:*)", .expected = "Read, Bash(git:*)" },
        .{ .yaml = "[Read, 'Bash(git:*)']", .expected = "Read Bash(git:*)" },
        .{ .yaml = "[]", .expected = "" },
        .{ .yaml = "*tools", .expected = "Read Grep" },
    };
    for (cases, 0..) |case, i| {
        const file = try a.print("tools-{d}/SKILL.md", .{i});
        defer a.free(file);
        const contents = try a.print("---\ndescription: \"Caf\\u00e9 \\U0001F600\"\nextension: &tools [Read, Grep]\nallowed-tools: {s}\n---\nbody", .{case.yaml});
        defer a.free(contents);
        try f.write(file, contents);
    }
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(cases.len, catalog.skills.len);
    try t.expectEqual(@as(usize, 0), catalog.diagnostics.len);
    for (catalog.skills, cases) |skill, case| {
        try t.expectEqualStrings("Café 😀", skill.description);
        try t.expectEqualStrings(case.expected, skill.allowed_tools.?);
        try t.checkAllAllocationFailures(a, allocationRun, .{skill.directory_path});
    }
}

test "unknown extension graphs retain syntax node depth and byte budgets" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("bounded/SKILL.md", "---\ndescription: ok\nextension: &shared [true, false, null, 12]\naliases: [*shared, *shared, *shared]\n---\nbody");
    var normal = try f.catalog(.{});
    defer normal.deinit();
    try t.expectEqual(@as(usize, 1), normal.skills.len);
    var nodes = try f.catalog(.{ .max_yaml_nodes = 13 });
    defer nodes.deinit();
    try expectDiagnostic(nodes, error.YamlLimit);
    var depth = try f.catalog(.{ .max_yaml_depth = 1 });
    defer depth.deinit();
    try expectDiagnostic(depth, error.YamlLimit);
    var bytes = try f.catalog(.{ .max_frontmatter_bytes = 32 });
    defer bytes.deinit();
    try expectDiagnostic(bytes, error.FrontmatterLimit);
    try f.write("bounded/SKILL.md", "---\ndescription: ok\nextension: *undefined\n---\nbody");
    var unresolved = try f.catalog(.{});
    defer unresolved.deinit();
    try expectDiagnostic(unresolved, error.YamlSyntax);
    try f.write("bounded/SKILL.md", "---\ndescription: ok\nextension: [broken\n---\nbody");
    var broken = try f.catalog(.{});
    defer broken.deinit();
    try expectDiagnostic(broken, error.YamlSyntax);
}

test "extensions cannot hide duplicate known fields or invalid required metadata" {
    var first = try Fixture.init();
    defer first.deinit();
    var second = try Fixture.init();
    defer second.deinit();
    const cases = [_][]const u8{
        "description: ok\ndescription: also ok",
        "name: valid\nname: valid\ndescription: ok",
        "description: [not, text]",
        "description: true",
        "description: ''",
        "description: unquoted: colon",
        "name: valid",
        "name: ''\ndescription: ok",
    };
    for (cases) |yaml| {
        const contents = try a.print("---\n{s}\nhooks: {{PreToolUse: [{{once: true}}]}}\n---\n# Body must not become a description", .{yaml});
        defer a.free(contents);
        try first.write("valid/SKILL.md", contents);
        try second.skill("valid", "valid fallback", "body");
        var catalog = try skills.discover(a, io, &.{ first.root, second.root }, .{});
        defer catalog.deinit();
        try t.expectEqual(@as(usize, 1), catalog.skills.len);
        try t.expectEqual(@as(usize, 1), catalog.diagnostics.len);
        try t.expectEqualStrings("valid fallback", catalog.skills[0].description);
    }
}

test "name defaults and explicit aliases revalidate using the installed folder" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("folder/SKILL.md", "---\nname: renamed\ndescription: ok\n---\nbody");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqualStrings("renamed", catalog.skills[0].name);
    const original = try catalog.skills[0].loadBody(a, io, .{});
    defer a.free(original);
    try t.expectEqualStrings("body", original);
    try t.checkAllAllocationFailures(a, allocationRun, .{f.root});
    try f.write("folder/SKILL.md", "---\ndescription: ok\n---\nbody");
    try t.expectError(error.MetadataChanged, catalog.skills[0].loadBody(a, io, .{}));
    var fallback = try f.catalog(.{});
    defer fallback.deinit();
    try t.expectEqualStrings("folder", fallback.skills[0].name);
    try t.checkAllAllocationFailures(a, allocationRun, .{f.root});
    try f.write("folder/SKILL.md", "---\nname: folder\ndescription: ok\nunknown: [true, 42]\n---\nbody");
    const explicit = try fallback.skills[0].loadBody(a, io, .{});
    defer a.free(explicit);
    try t.expectEqualStrings("body", explicit);
}

test "different folders with one explicit name keep deterministic first valid precedence" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("a-invalid/SKILL.md", "---\nname: shared\ndescription: false\n---\nbody");
    try f.write("b-first/SKILL.md", "---\nname: shared\ndescription: first\n---\nbody");
    try f.write("c-second/SKILL.md", "---\nname: shared\ndescription: second\n---\nbody");
    var catalog = try f.catalog(.{});
    defer catalog.deinit();
    try t.expectEqual(@as(usize, 1), catalog.skills.len);
    try t.expectEqual(@as(usize, 2), catalog.diagnostics.len);
    try t.expectEqualStrings("shared", catalog.skills[0].name);
    try t.expectEqualStrings("first", catalog.skills[0].description);
    try expectDiagnostic(catalog, error.UnsupportedFieldType);
    try expectDiagnostic(catalog, error.DuplicateName);
}

test "caller allocator failures clean discovery diagnostics and body allocations" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.skill("valid", "ok", "body");
    try f.write("invalid/SKILL.md", "---\nname: invalid\ndescription: ok\nmetadata: {bad: []}\n---\n");
    try t.checkAllAllocationFailures(a, allocationRun, .{f.root});
}
