const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "minecraft_again",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    b.installArtifact(exe);

    if (tracy_enabled) {
        // The user asked to enable Tracy, use the real implementation
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        // The user asked to disable Tracy, use the dummy implementation
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    const slang_dep = b.dependency("slang-linux-x86_64", .{});
    const slangc_path = slang_dep.path("bin/slangc");

    exe.root_module.addAnonymousImport("vertex_shader", .{ .root_source_file = compileShader(b, slangc_path, "main.vert.slang") });
    exe.root_module.addAnonymousImport("fragment_shader", .{ .root_source_file = compileShader(b, slangc_path, "main.frag.slang") });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn compileShader(b: *std.Build, slangc_path: std.Build.LazyPath, shader_name: []const u8) std.Build.LazyPath {
    const shader_cmd = std.Build.Step.Run.create(b, "run slangc on shader");
    shader_cmd.addFileArg(slangc_path);
    shader_cmd.addFileArg(b.path(b.fmt("shaders/{s}", .{shader_name})));
    shader_cmd.addArgs(&.{
        "-target",
        "spirv",
        "-o",
    });
    return shader_cmd.addOutputFileArg(b.fmt("{s}.spv", .{shader_name}));
}
