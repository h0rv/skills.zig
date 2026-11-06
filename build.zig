const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const source = b.dependency("libyaml", .{});
    const yaml_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    yaml_module.addIncludePath(source.path("include"));
    yaml_module.addIncludePath(source.path("src"));
    yaml_module.addCMacro("YAML_DECLARE_STATIC", "1");
    yaml_module.addCMacro("YAML_VERSION_MAJOR", "0");
    yaml_module.addCMacro("YAML_VERSION_MINOR", "2");
    yaml_module.addCMacro("YAML_VERSION_PATCH", "5");
    yaml_module.addCMacro("YAML_VERSION_STRING", "\"0.2.5\"");
    yaml_module.addCSourceFiles(.{
        .root = source.path(""),
        .files = &.{ "src/api.c", "src/dumper.c", "src/emitter.c", "src/loader.c", "src/parser.c", "src/reader.c", "src/scanner.c", "src/writer.c" },
        .flags = &.{"-std=gnu11"},
    });
    const yaml = b.addLibrary(.{
        .name = "yaml",
        .linkage = .static,
        .root_module = yaml_module,
    });
    const module = b.addModule("skills", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{ .file = b.path("yaml_shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addIncludePath(source.path("include"));
    module.addCMacro("YAML_DECLARE_STATIC", "1");
    module.linkLibrary(yaml);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run independent skills tests").dependOn(&b.addRunArtifact(tests).step);
}
