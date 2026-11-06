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
zig build test
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

## Frontmatter

The library reads the Agent Skills fields and accepts common
[Claude Code frontmatter](https://code.claude.com/docs/en/skills#frontmatter-reference).
Unknown fields are ignored, including nested hooks, lists, and booleans. They
are never executed or used to change permissions or model settings.

```yaml
---
description: >-
  Review changes and explain what needs attention.
allowed-tools: [Read, Grep]
disable-model-invocation: true
---
```

A missing `name` defaults to the installed folder name. An explicit name may
differ from the folder, as in Claude Code. Names retain the Agent Skills syntax
of 1 to 64 lowercase ASCII letters, digits, and single internal hyphens.
`description` remains a required string of 1 to 1024 Unicode characters.
`compatibility`, when present, is a string of 1 to 500 characters. `metadata`
must map strings to strings. Numeric and boolean values in these fields are
not converted to strings.

`allowed-tools` accepts a string with spaces or commas, or a list of strings.
The existing `Skill.allowed_tools` field preserves strings and joins list items
with spaces. It is metadata only and grants no permissions.

Libyaml handles quoted Unicode escapes, literal and folded block descriptions,
and anchors and aliases. Unknown values still count toward YAML byte, node,
and nesting budgets. Invalid YAML, duplicate frontmatter or metadata keys,
and invalid known fields produce diagnostics without blocking valid skills in
later roots. The library does not repair malformed YAML or read a description
from the Markdown body.

## Filesystem boundaries

Explicit roots may follow directory symlinks. Child directory symlinks require
`.symlinks = .allow_directory_links`, which permits targets outside the root.
`SKILL.md` itself must never be a symlink. Body loading rejects changes to known
metadata or the canonical directory path, but permits body edits and changes
to ignored fields. These checks are not a sandbox against concurrent filesystem
replacement. Canonical paths require support from `std.Io` on the target platform.
