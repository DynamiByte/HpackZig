const std = @import("std");

const sdk_root = "deps/7z";
const sdk_console_subdir = "CPP/7zip/UI/Console";
const sdk_bundle_makefile = sdk_root ++ "/CPP/7zip/Bundles/Alone2/makefile.gcc";
const sdk_arc_makefile = sdk_root ++ "/CPP/7zip/Bundles/Format7zF/Arc_gcc.mak";
const sdk_source_map_makefile = sdk_root ++ "/CPP/7zip/7zip_gcc.mak";

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
    const archive_tool = addArchiveToolExecutable(b, name, target, optimize);
    exe.root_module.addAnonymousImport("archive_tool_bin", .{
        .root_source_file = archive_tool.getEmittedBin(),
    });
    exe.root_module.addAnonymousImport("startup_banner_ansi", .{
        .root_source_file = b.path("src/banner_ansi.txt"),
    });

    return exe;
}

fn prebuiltToolRelPath(target: std.Build.ResolvedTarget, comptime tool_name: []const u8) []const u8 {
    return switch (target.result.os.tag) {
        .windows => "deps/hdiffpatch/windows64/" ++ tool_name ++ ".exe",
        .linux => "deps/hdiffpatch/linux64/" ++ tool_name,
        else => @panic("unsupported prebuilt helper target"),
    };
}

fn addArchiveToolExecutable(
    b: *std.Build,
    hpack_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const helper_optimize = switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };
    const tool_name = switch (target.result.os.tag) {
        .windows => b.fmt("{s}-archive-tool", .{hpack_name}),
        .linux => b.fmt("{s}-archive-tool", .{hpack_name}),
        else => @panic("unsupported archive tool target"),
    };

    const exe = b.addExecutable(.{
        .name = tool_name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = helper_optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "ole32", "oleaut32", "uuid", "advapi32", "user32", "shell32" }) |lib| {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    } else {
        for ([_][]const u8{ "pthread", "dl" }) |lib| {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    }

    for ([_][]const u8{
        sdk_root,
        sdk_root ++ "/C",
        sdk_root ++ "/CPP",
        sdk_root ++ "/CPP/Common",
        sdk_root ++ "/CPP/Windows",
        sdk_root ++ "/CPP/7zip",
        sdk_root ++ "/CPP/7zip/Common",
        sdk_root ++ "/CPP/7zip/Archive",
        sdk_root ++ "/CPP/7zip/Compress",
        sdk_root ++ "/CPP/7zip/Crypto",
        sdk_root ++ "/CPP/7zip/UI/Common",
        sdk_root ++ "/CPP/7zip/UI/Console",
    }) |include_path| {
        exe.root_module.addIncludePath(b.path(include_path));
    }

    const source_files = collectArchiveToolSources(b, target) catch |err| {
        std.debug.panic("failed to collect SDK archive sources: {s}", .{@errorName(err)});
    };
    var c_files: std.ArrayList([]const u8) = .empty;
    var cpp_files: std.ArrayList([]const u8) = .empty;
    for (source_files) |source_file| {
        if (std.mem.endsWith(u8, source_file, ".c")) {
            c_files.append(b.allocator, source_file) catch @panic("oom");
        } else {
            cpp_files.append(b.allocator, source_file) catch @panic("oom");
        }
    }

    const c_flags = archiveToolCFlags(b, target) catch |err| {
        std.debug.panic("failed to prepare SDK archive C flags: {s}", .{@errorName(err)});
    };
    const cpp_flags = archiveToolCppFlags(b, target) catch |err| {
        std.debug.panic("failed to prepare SDK archive C++ flags: {s}", .{@errorName(err)});
    };
    if (c_files.items.len != 0) {
        exe.root_module.addCSourceFiles(.{
            .root = b.path(sdk_root),
            .files = c_files.items,
            .flags = c_flags,
        });
    }
    if (cpp_files.items.len != 0) {
        exe.root_module.addCSourceFiles(.{
            .root = b.path(sdk_root),
            .files = cpp_files.items,
            .flags = cpp_flags,
        });
    }

    return exe;
}

fn archiveToolBaseFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(b.allocator, &.{
        "-DNDEBUG",
        "-D_REENTRANT",
        "-D_FILE_OFFSET_BITS=64",
        "-D_LARGEFILE_SOURCE",
        "-DZ7_PROG_VARIANT_Z",
    });
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DZ7_DEVICE_FILE",
            "-DUNICODE",
            "-D_UNICODE",
        });
    }
    return flags.toOwnedSlice(b.allocator);
}

fn archiveToolCFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const []const u8 {
    return archiveToolBaseFlags(b, target);
}

fn archiveToolCppFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(b.allocator, try archiveToolBaseFlags(b, target));
    try flags.append(b.allocator, "-std=c++17");
    return flags.toOwnedSlice(b.allocator);
}

fn collectArchiveToolSources(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const []const u8 {
    const io = b.graph.io;
    const bundle_text = try std.Io.Dir.cwd().readFileAlloc(io, sdk_bundle_makefile, b.allocator, .limited(std.math.maxInt(u32)));
    const arc_text = try std.Io.Dir.cwd().readFileAlloc(io, sdk_arc_makefile, b.allocator, .limited(std.math.maxInt(u32)));
    const map_text = try std.Io.Dir.cwd().readFileAlloc(io, sdk_source_map_makefile, b.allocator, .limited(std.math.maxInt(u32)));

    var object_names = std.StringArrayHashMap(void).init(b.allocator);

    inline for ([_][]const u8{
        "CONSOLE_OBJS",
        "UI_COMMON_OBJS",
        "COMMON_OBJS_2",
        "WIN_OBJS_2",
        "7ZIP_COMMON_OBJS_2",
    }) |var_name| {
        try appendMakeObjectNames(&object_names, bundle_text, var_name);
    }

    inline for ([_][]const u8{
        "COMMON_OBJS",
        "WIN_OBJS",
        "7ZIP_COMMON_OBJS",
        "AR_COMMON_OBJS",
        "AR_OBJS",
        "7Z_OBJS",
        "CAB_OBJS",
        "CHM_OBJS",
        "COM_OBJS",
        "ISO_OBJS",
        "NSIS_OBJS",
        "RAR_OBJS",
        "TAR_OBJS",
        "UDF_OBJS",
        "WIM_OBJS",
        "ZIP_OBJS",
        "COMPRESS_OBJS",
        "CRYPTO_OBJS",
        "C_OBJS",
    }) |var_name| {
        try appendMakeObjectNames(&object_names, arc_text, var_name);
    }

    for (sdk_mt_objects) |name| {
        try object_names.put(name, {});
    }
    switch (target.result.os.tag) {
        .windows => for (sdk_windows_sys_objects) |name| try object_names.put(name, {}),
        .linux => for (sdk_linux_sys_objects) |name| try object_names.put(name, {}),
        else => {},
    }

    var source_map = try parseSourceMap(b.allocator, map_text);
    defer source_map.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    try files.append(b.allocator, sdk_console_subdir ++ "/StdAfx.cpp");
    if (object_names.swapRemove("resource")) {}

    for (object_names.keys()) |name| {
        const raw_path = source_map.get(name) orelse return error.MissingSdkSource;
        const project_relative = try resolveSdkPathFromConsoleDir(b.allocator, raw_path);
        try files.append(b.allocator, project_relative);
    }

    return files.toOwnedSlice(b.allocator);
}

fn appendMakeObjectNames(
    set: *std.StringArrayHashMap(void),
    text: []const u8,
    comptime var_name: []const u8,
) !void {
    const start = std.mem.indexOf(u8, text, var_name ++ " =") orelse return;
    const body = text[start..];
    const next_marker = std.mem.indexOfPos(u8, body, var_name.len + 1, "\n\n") orelse body.len;
    const block = body[0..next_marker];

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, " \t\r\\");
        if (!std.mem.startsWith(u8, trimmed, "$O/")) continue;
        trimmed = trimmed[3..];
        const suffix = std.mem.lastIndexOf(u8, trimmed, ".o") orelse continue;
        try set.put(trimmed[0..suffix], {});
    }
}

fn parseSourceMap(
    allocator: std.mem.Allocator,
    text: []const u8,
) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "$O/")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const obj_part = trimmed[3..colon];
        const suffix = std.mem.lastIndexOf(u8, obj_part, ".o") orelse continue;
        const obj_name = try allocator.dupe(u8, obj_part[0..suffix]);

        var rhs = std.mem.tokenizeAny(u8, trimmed[colon + 1 ..], " \t\r");
        while (rhs.next()) |token| {
            if (std.mem.endsWith(u8, token, ".cpp") or std.mem.endsWith(u8, token, ".c")) {
                try map.put(obj_name, try allocator.dupe(u8, token));
                break;
            }
        }
    }

    return map;
}

fn resolveSdkPathFromConsoleDir(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
) ![]const u8 {
    return try std.fs.path.resolvePosix(allocator, &.{ sdk_console_subdir, raw_path });
}

const sdk_mt_objects = [_][]const u8{
    "LzFindMt",
    "LzFindOpt",
    "Threads",
    "MemBlocks",
    "OutMemStream",
    "ProgressMt",
    "StreamBinder",
    "Synchronization",
    "VirtThread",
};

const sdk_windows_sys_objects = [_][]const u8{
    "FileSystem",
    "Registry",
    "MemoryLock",
    "DLL",
    "DllSecur",
};

const sdk_linux_sys_objects = [_][]const u8{
    "MyWindows",
};
