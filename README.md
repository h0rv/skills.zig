# skills.zig

A Zig library for discovering [Agent Skills](https://agentskills.io/specification)
and loading their Markdown instructions when needed. You choose the search roots.
Discovery reads `SKILL.md` frontmatter without reading the body. This library does
not execute skills or make permission decisions.

## Build and test

Use Zig 0.17.0. Zig fetches [libyaml](https://github.com/yaml/libyaml) source
and compiles it into the binary. No system libyaml installation or pkg-config
is needed. Include [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) when redistributing
binaries or source bundles containing libyaml.

```sh
zig build test -j2
zig build test -j2 -Doptimize=ReleaseSafe
```

Once you declare `skills` as a dependency in `build.zig.zon`, import its module
in your `build.zig`.

```zig
const dependency = b.dependency("skills", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("skills", dependency.module("skills"));
```

## API

```zig
const std = @import("std");
const skills = @import("skills");

pub fn main(init: std.process.Init) !void {
    var catalog = try skills.discover(init.gpa, init.io, &.{"/absolute/skills"}, .{});
    defer catalog.deinit();

    for (catalog.skills) |skill| {
        const body = try skill.loadBody(init.gpa, init.io, .{});
        defer init.gpa.free(body);
        std.debug.print("{s}\n{s}\n", .{ skill.name, body });
    }
}
```

`Catalog` owns skill metadata, paths, and diagnostics. Keep it alive while using
its skills. Free each body with the allocator passed to `loadBody`. Body bytes
are returned unchanged.

Roots must be absolute paths to skill directories or containers. Results follow
root order, then sorted depth-first directory order. The first valid skill with
a given name wins. A directory containing `SKILL.md` stops descent even if its
frontmatter is invalid. Inspect `catalog.diagnostics` for rejected entries.
Use `Limits` to set discovery, YAML, and body budgets. Global discovery exhaustion
returns `DiscoveryLimit` without a partial catalog.

## Limitations

The parser rejects unknown frontmatter fields and duplicate keys. Fields must
be strings, except `metadata`, which must map strings to strings. Numeric and
boolean values are not converted to strings. Names must match the installed
directory and use lowercase ASCII letters, digits, and single internal hyphens.
Explicit roots may follow directory symlinks. Child directory symlinks require
`.symlinks = .allow_directory_links`, which permits targets outside the root.
`SKILL.md` itself must never be a symlink. Body loading rejects changed metadata
or a changed canonical directory path, but permits body edits. These checks are
not a sandbox against concurrent filesystem replacement. Canonical paths require
support from `std.Io` on the target platform.
