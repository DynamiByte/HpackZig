const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const embedded_archive_tool = @embedFile("archive_tool_bin");
pub const archive_tool_name = if (builtin.os.tag == .windows) "7zz.exe" else "7zz";
pub const package_archive_type_usage = "[7z (default) | zip | tar | gz | bz2 | xz | none]";

pub const PackageOutputKind = enum {
    archive,
    directory,
};

pub const PackageArchiveSpec = struct {
    kind: PackageOutputKind,
    extension: []const u8,
    tool_type: []const u8,
    single_file_wrapper: bool,
};

pub fn prepareApplyInput(
    app: anytype,
    progress: anytype,
    archive_path: []const u8,
    parent_dir: []const u8,
) !?[]const u8 {
    if (isDirectory(app.io, archive_path)) {
        const use_phase = try std.fmt.allocPrint(app.arena, "Using package folder {s}", .{
            std.fs.path.basename(archive_path),
        });
        progress.beginStage(use_phase);
        return archive_path;
    }

    const extract_dir = try app.makeTempDir(parent_dir, "extract");
    if (!try extractArchive(app, progress, archive_path, extract_dir)) return null;
    return extract_dir;
}

pub fn resolveCreateInputDir(
    app: anytype,
    progress: anytype,
    input_path: []const u8,
    comptime label: []const u8,
    executable_skip: bool,
    validate_game_dir: anytype,
) ![]const u8 {
    if (isDirectory(app.io, input_path)) {
        try validate_game_dir(app.io, input_path, executable_skip);
        return input_path;
    }

    if (!pathExists(app.io, input_path)) return error.FileNotFound;

    const phase_name = try std.fmt.allocPrint(app.arena, "Extracting {s} archive {s}", .{
        label,
        std.fs.path.basename(input_path),
    });
    const extract_dir = try app.makeSystemTempDir(label ++ "_archive");
    if (!try extractArchiveWithPhase(app, progress, phase_name, input_path, extract_dir)) {
        return error.ArchiveExtractFailed;
    }

    const root_dir = try unwrapSingleRootDir(app.arena, app.io, extract_dir);
    try validate_game_dir(app.io, root_dir, executable_skip);
    return root_dir;
}

pub fn writePackageOutput(
    app: anytype,
    progress: anytype,
    source_dir_path: []const u8,
    output_archive_path: []const u8,
    archive_spec: PackageArchiveSpec,
) !void {
    if (archive_spec.kind == .directory) {
        const phase_name = try std.fmt.allocPrint(app.arena, "Writing folder {s}", .{
            std.fs.path.basename(output_archive_path),
        });
        progress.beginStage(phase_name);
        deleteBestEffort(app.io, output_archive_path);
        try std.Io.Dir.renameAbsolute(source_dir_path, output_archive_path, app.io);
        app.forgetTempPath(source_dir_path);
        return;
    }

    const phase_name = try std.fmt.allocPrint(app.arena, "Archiving {s}", .{
        std.fs.path.basename(output_archive_path),
    });

    if (!try writeArchivePackage(app, progress, phase_name, source_dir_path, output_archive_path, archive_spec)) {
        return error.ArchiveCreateFailed;
    }
}

pub fn normalizePackageArchiveType(archive_type: []const u8) !PackageArchiveSpec {
    if (std.ascii.eqlIgnoreCase(archive_type, "7z")) return .{ .kind = .archive, .extension = "7z", .tool_type = "7z", .single_file_wrapper = false };
    if (std.ascii.eqlIgnoreCase(archive_type, "zip")) return .{ .kind = .archive, .extension = "zip", .tool_type = "zip", .single_file_wrapper = false };
    if (std.ascii.eqlIgnoreCase(archive_type, "tar")) return .{ .kind = .archive, .extension = "tar", .tool_type = "tar", .single_file_wrapper = false };
    if (std.ascii.eqlIgnoreCase(archive_type, "gz") or std.ascii.eqlIgnoreCase(archive_type, "gzip")) {
        return .{ .kind = .archive, .extension = "gz", .tool_type = "gzip", .single_file_wrapper = true };
    }
    if (std.ascii.eqlIgnoreCase(archive_type, "bz2") or std.ascii.eqlIgnoreCase(archive_type, "bzip2")) {
        return .{ .kind = .archive, .extension = "bz2", .tool_type = "bzip2", .single_file_wrapper = true };
    }
    if (std.ascii.eqlIgnoreCase(archive_type, "xz")) return .{ .kind = .archive, .extension = "xz", .tool_type = "xz", .single_file_wrapper = true };
    if (std.ascii.eqlIgnoreCase(archive_type, "none")) return .{ .kind = .directory, .extension = "", .tool_type = "", .single_file_wrapper = false };
    return error.UnsupportedArchiveType;
}

pub fn makePackageOutputName(
    arena: Allocator,
    prefix: []const u8,
    version_from: []const u8,
    version_to: []const u8,
    archive_spec: PackageArchiveSpec,
) ![]const u8 {
    if (archive_spec.kind == .directory) {
        return try std.fmt.allocPrint(arena, "{s}_{s}_{s}_hdiff", .{
            prefix,
            version_from,
            version_to,
        });
    }

    return try std.fmt.allocPrint(arena, "{s}_{s}_{s}_hdiff.{s}", .{
        prefix,
        version_from,
        version_to,
        archive_spec.extension,
    });
}

fn extractArchive(
    app: anytype,
    progress: anytype,
    archive_path: []const u8,
    dest_dir: []const u8,
) !bool {
    const phase_name = try std.fmt.allocPrint(app.arena, "Extracting {s}", .{
        std.fs.path.basename(archive_path),
    });
    return extractArchiveWithPhase(app, progress, phase_name, archive_path, dest_dir);
}

fn extractArchiveWithPhase(
    app: anytype,
    progress: anytype,
    phase_name: []const u8,
    archive_path: []const u8,
    dest_dir: []const u8,
) !bool {
    progress.beginStage(phase_name);
    defer progress.finishPhase();

    if (!try extractArchiveOnce(app, progress, archive_path, dest_dir)) return false;

    var current_archive_name = std.fs.path.basename(archive_path);
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        const nested_name = try findSingleNestedArchiveCandidate(app.arena, app.io, dest_dir, current_archive_name) orelse break;
        const nested_path = try std.fs.path.join(app.arena, &.{ dest_dir, nested_name });
        if (!try extractArchiveOnce(app, progress, nested_path, dest_dir)) return false;
        deleteBestEffort(app.io, nested_path);
        current_archive_name = nested_name;
    }

    return true;
}

fn extractArchiveOnce(
    app: anytype,
    progress: anytype,
    archive_path: []const u8,
    dest_dir: []const u8,
) !bool {
    const output_arg = try std.fmt.allocPrint(app.arena, "-o{s}", .{dest_dir});
    const argv = [_][]const u8{
        "x",
        "-y",
        "-aoa",
        output_arg,
        archive_path,
    };
    return runArchiveTool(app, progress, null, 0, dest_dir, &argv);
}

fn writeArchivePackage(
    app: anytype,
    progress: anytype,
    phase_name: []const u8,
    source_dir_path: []const u8,
    output_archive_path: []const u8,
    archive_spec: PackageArchiveSpec,
) !bool {
    if (!archive_spec.single_file_wrapper) {
        return try writeDirectoryArchive(app, progress, phase_name, source_dir_path, output_archive_path, archive_spec.tool_type);
    }

    const wrap_dir = try app.makeSystemTempDir("archive_wrap");
    const wrapped_name = try std.fmt.allocPrint(app.arena, "{s}.7z.7z", .{
        trimFinalExtension(std.fs.path.basename(output_archive_path)),
    });
    const wrapped_path = try std.fs.path.join(app.arena, &.{ wrap_dir, wrapped_name });

    if (!try writeDirectoryArchive(app, progress, phase_name, source_dir_path, wrapped_path, "7z")) return false;

    const compress_phase = try std.fmt.allocPrint(app.arena, "Compressing {s}", .{
        std.fs.path.basename(output_archive_path),
    });
    return try writeSingleFileArchive(app, progress, compress_phase, wrap_dir, output_archive_path, archive_spec.tool_type, wrapped_name);
}

fn writeDirectoryArchive(
    app: anytype,
    progress: anytype,
    phase_name: []const u8,
    source_dir_path: []const u8,
    output_archive_path: []const u8,
    archive_type: []const u8,
) !bool {
    deleteBestEffort(app.io, output_archive_path);
    const total_files = try countFilesInTree(app.io, source_dir_path);
    const type_arg = try std.fmt.allocPrint(app.arena, "-t{s}", .{archive_type});
    const argv = [_][]const u8{
        "a",
        type_arg,
        "-y",
        output_archive_path,
        "*",
    };
    return runArchiveTool(app, progress, phase_name, total_files, source_dir_path, &argv);
}

fn writeSingleFileArchive(
    app: anytype,
    progress: anytype,
    phase_name: []const u8,
    source_dir_path: []const u8,
    output_archive_path: []const u8,
    archive_type: []const u8,
    input_name: []const u8,
) !bool {
    deleteBestEffort(app.io, output_archive_path);
    const type_arg = try std.fmt.allocPrint(app.arena, "-t{s}", .{archive_type});
    const argv = [_][]const u8{
        "a",
        type_arg,
        "-y",
        output_archive_path,
        input_name,
    };
    return runArchiveTool(app, progress, phase_name, 1, source_dir_path, &argv);
}

fn runArchiveTool(
    app: anytype,
    progress: anytype,
    phase_name: ?[]const u8,
    total_items: usize,
    cwd_path: []const u8,
    base_argv: []const []const u8,
) !bool {
    const allocator = app.gpa;
    const owns_phase = phase_name != null;

    if (phase_name) |name| {
        if (total_items == 0) {
            progress.beginStage(name);
        } else {
            progress.beginPhase(name, total_items);
        }
    }
    defer if (owns_phase) {
        if (progress.hasCurrent()) progress.completeOne();
        progress.finishPhase();
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, app.archive_tool_path.?);
    try argv.appendSlice(allocator, base_argv);
    try argv.appendSlice(allocator, &.{
        "-bb1",
        "-bso1",
        "-bse1",
        "-bsp1",
    });

    var child = std.process.spawn(app.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd_path },
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch return false;
    defer child.kill(app.io);

    var stdout_reader = child.stdout.?.readerStreaming(app.io, &.{});
    var read_buffer: [4096]u8 = undefined;
    var line_buffer: std.ArrayList(u8) = .empty;
    defer line_buffer.deinit(allocator);
    var raw_output: std.ArrayList(u8) = .empty;
    defer raw_output.deinit(allocator);

    while (true) {
        const amt = stdout_reader.interface.readSliceShort(&read_buffer) catch |e| switch (e) {
            error.ReadFailed => return stdout_reader.err.?,
        };
        if (amt == 0) break;

        try raw_output.appendSlice(allocator, read_buffer[0..amt]);
        for (read_buffer[0..amt]) |byte| {
            switch (byte) {
                '\r', '\n' => try flushArchiveToolLine(allocator, progress, &line_buffer),
                0x08 => {},
                else => try line_buffer.append(allocator, byte),
            }
        }
    }
    try flushArchiveToolLine(allocator, progress, &line_buffer);

    const term = child.wait(app.io) catch return false;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok and raw_output.items.len != 0) std.debug.print("{s}", .{raw_output.items});
    return ok;
}

fn flushArchiveToolLine(
    allocator: Allocator,
    progress: anytype,
    line_buffer: *std.ArrayList(u8),
) !void {
    const line = std.mem.trim(u8, line_buffer.items, " \t");
    if (line.len != 0) {
        try handleArchiveToolLine(progress, line);
    }
    line_buffer.clearRetainingCapacity();
    _ = allocator;
}

fn handleArchiveToolLine(progress: anytype, line: []const u8) !void {
    if (line.len < 3) return;
    if (line[1] != ' ') return;

    switch (line[0]) {
        '+', '-', 'U' => {
            if (progress.hasCurrent()) progress.completeOne();
            progress.setCurrent(line[2..]);
        },
        else => {},
    }
}

fn countFilesInTree(io: Io, root_dir_path: []const u8) !usize {
    var total: usize = 0;

    var root_dir = try std.Io.Dir.openDirAbsolute(io, root_dir_path, .{ .iterate = true });
    defer root_dir.close(io);

    var walker = try root_dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) total += 1;
    }

    return total;
}

fn findSingleFileName(arena: Allocator, io: Io, dir_path: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    var single_name: ?[]const u8 = null;

    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind != .file) return null;
        if (single_name != null) return null;
        single_name = try arena.dupe(u8, entry.name);
    }

    return single_name;
}

fn findSingleNestedArchiveCandidate(
    arena: Allocator,
    io: Io,
    dir_path: []const u8,
    parent_archive_name: []const u8,
) !?[]const u8 {
    const single_name = try findSingleFileName(arena, io, dir_path) orelse return null;
    if (isArchiveCandidateName(single_name)) return single_name;
    if (isSingleStreamArchiveName(parent_archive_name)) return single_name;
    return null;
}

fn unwrapSingleRootDir(arena: Allocator, io: Io, dir_path: []const u8) ![]const u8 {
    var current = dir_path;

    while (true) {
        var dir = try std.Io.Dir.openDirAbsolute(io, current, .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        var only_dir_name: ?[]const u8 = null;
        var entry_count: usize = 0;

        while (try iter.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            entry_count += 1;
            if (entry_count > 1) return current;
            if (entry.kind != .directory) return current;
            only_dir_name = try arena.dupe(u8, entry.name);
        }

        const dir_name = only_dir_name orelse return current;
        current = try std.fs.path.join(arena, &.{ current, dir_name });
    }
}

fn trimFinalExtension(name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..index];
}

fn isArchiveCandidateName(name: []const u8) bool {
    return endsWithIgnoreCase(name, ".7z") or
        endsWithIgnoreCase(name, ".zip") or
        endsWithIgnoreCase(name, ".tar") or
        endsWithIgnoreCase(name, ".gz") or
        endsWithIgnoreCase(name, ".bz2") or
        endsWithIgnoreCase(name, ".xz") or
        endsWithIgnoreCase(name, ".wim") or
        endsWithIgnoreCase(name, ".rar") or
        endsWithIgnoreCase(name, ".cab") or
        endsWithIgnoreCase(name, ".arj") or
        endsWithIgnoreCase(name, ".cpio") or
        endsWithIgnoreCase(name, ".lzma") or
        endsWithIgnoreCase(name, ".zst") or
        endsWithIgnoreCase(name, ".zstd") or
        endsWithIgnoreCase(name, ".001");
}

fn isSingleStreamArchiveName(name: []const u8) bool {
    return endsWithIgnoreCase(name, ".gz") or
        endsWithIgnoreCase(name, ".bz2") or
        endsWithIgnoreCase(name, ".xz") or
        endsWithIgnoreCase(name, ".lzma") or
        endsWithIgnoreCase(name, ".zst") or
        endsWithIgnoreCase(name, ".zstd");
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    defer dir.close(io);
    return true;
}

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn deleteBestEffort(io: Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}
