const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    const host_exe = addHpackExecutable(b, "hpack", host_target, optimize);

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });

    const windows_exe = addHpackExecutable(b, "hpack-windows-x64", windows_target, optimize);
    const linux_exe = addHpackExecutable(b, "hpack-linux-x64", linux_target, optimize);

    const windows_install = b.addInstallArtifact(windows_exe, .{
        .dest_sub_path = "windows-x64/hpack.exe",
        .pdb_dir = .disabled,
    });
    const linux_install = b.addInstallArtifact(linux_exe, .{
        .dest_sub_path = "linux-x64/hpack",
    });

    b.getInstallStep().dependOn(&windows_install.step);
    b.getInstallStep().dependOn(&linux_install.step);

    const export_step = b.step("export", "Export windows-x64 and linux-x64 binaries");
    export_step.dependOn(&windows_install.step);
    export_step.dependOn(&linux_install.step);

    const run_cmd = b.addRunArtifact(host_exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run hpack on the host platform");
    run_step.dependOn(&run_cmd.step);
}

fn addHpackExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addAnonymousImport("hdiffz_bin", .{
        .root_source_file = b.path(prebuiltToolRelPath(target, "hdiffz")),
    });
    exe.root_module.addAnonymousImport("hpatchz_bin", .{
        .root_source_file = b.path(prebuiltToolRelPath(target, "hpatchz")),
    });
    exe.root_module.addAnonymousImport("startup_banner_ansi", .{
        .root_source_file = b.path("src/banner_ansi.txt"),
    });

    return exe;
}

fn prebuiltToolRelPath(target: std.Build.ResolvedTarget, comptime tool_name: []const u8) []const u8 {
    return switch (target.result.os.tag) {
        .windows => "deps/windows64/" ++ tool_name ++ ".exe",
        .linux => "deps/linux64/" ++ tool_name,
        else => @panic("unsupported prebuilt helper target"),
    };
}
