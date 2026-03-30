const builtin = @import("builtin");
const std = @import("std");
const sevenzip = @import("7z.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const startup_banner_ansi = @embedFile("startup_banner_ansi");

const readme_text =
    \\This is an hdiff update package created by HPack. 
    \\For using, you may download our patcher release here: 
    \\https://git.zenless.app/RoxyTheProxy/HPack
    \\Then run hpack to perform a update.
    \\
    \\Have a good day! Thanks for using!
;

const embedded_hdiff = @embedFile("hdiffz_bin");
const embedded_hpatch = @embedFile("hpatchz_bin");
const hdiff_name = if (builtin.os.tag == .windows) "hdiffz.exe" else "hdiffz";
const hpatch_name = if (builtin.os.tag == .windows) "hpatchz.exe" else "hpatchz";

const certain_games = [_][]const u8{
    "genshinimpact",
    "yuanshen",
    "StarRail",
    "JueQuLing",
    "ZenlessZoneZero",
};

const PkgVersionEntry = struct {
    remoteName: []const u8,
    md5: []const u8,
    fileSize: u64,
};

const RemoteNameEntry = struct {
    remoteName: []const u8,
};

const CheckMode = enum {
    none,
    basic,
    full,
};

const FileRecord = struct {
    rel_slash: []const u8,
    abs_path: []const u8,
    size: u64,
    md5_hex: ?[32]u8 = null,
};

const PackageFile = struct {
    native_rel: []const u8,
    rel_slash: []const u8,
};

const ApplyOptions = struct {
    game_dir: []const u8,
    archive_paths: [][]const u8,
    check_mode: CheckMode = .none,
    delete_packages: bool = false,
    executable_skip: bool = false,
};

const CheckOptions = struct {
    game_dir: []const u8,
    check_mode: CheckMode = .none,
    output_dir: ?[]const u8 = null,
    executable_skip: bool = false,
};

const CreateOptions = struct {
    from_dir: []const u8,
    to_dir: []const u8,
    version_from: ?[]const u8 = null,
    version_to: ?[]const u8 = null,
    auto_version: bool = false,
    output_dir: []const u8 = ".",
    prefix: []const u8 = "game",
    archive_type: []const u8 = "7z",
    reverse: bool = false,
    skip_check: bool = false,
    only_package: bool = false,
    include_audios: bool = false,
    force_equal: bool = false,
    executable_skip: bool = false,
};

fn termPrint(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printBanner() void {
    termPrint("{s}", .{startup_banner_ansi});
}

const FileProgress = struct {
    io: Io,
    root_name: []const u8,
    root: std.Progress.Node = std.Progress.Node.none,
    phase: std.Progress.Node = std.Progress.Node.none,
    current: std.Progress.Node = std.Progress.Node.none,
    phase_name: []const u8 = "",
    total_items: usize = 0,
    completed_items: usize = 0,
    current_name: []const u8 = "",
    use_fallback: bool = false,
    root_started: bool = false,
    fallback_root_rendered: bool = false,

    fn init(io: Io, root_name: []const u8) FileProgress {
        return .{
            .io = io,
            .root_name = root_name,
        };
    }

    fn deinit(self: *FileProgress) void {
        self.finishPhase();
        if (self.root.index != .none) self.root.end();
    }

    pub fn beginStage(self: *FileProgress, name: []const u8) void {
        self.beginPhaseInternal(name, 0);
    }

    pub fn beginPhase(self: *FileProgress, name: []const u8, total_items: usize) void {
        self.beginPhaseInternal(name, total_items);
    }

    pub fn setCurrent(self: *FileProgress, name: []const u8) void {
        self.current_name = name;
        if (self.phase.index != .none) {
            if (self.current.index == .none) {
                self.current = self.phase.start(name, 0);
            } else {
                self.current.setName(name);
            }
        }
        self.renderFallbackCurrent();
    }

    pub fn completeOne(self: *FileProgress) void {
        self.finishCurrent();
        if (self.completed_items < self.total_items) self.completed_items += 1;
        self.current_name = "";
        if (self.phase.index != .none) self.phase.setCompletedItems(self.completed_items);
    }

    pub fn hasCurrent(self: *const FileProgress) bool {
        return self.current.index != .none or self.current_name.len != 0;
    }

    pub fn finishPhase(self: *FileProgress) void {
        self.finishCurrent();
        if (self.use_fallback and self.phase_name.len != 0) {
            if (self.total_items == 0) {
                termPrint("[progress]   {s} done\n", .{
                    self.phase_name,
                });
            } else {
                termPrint("[progress]   {s} {d}/{d}\n", .{
                    self.phase_name,
                    self.total_items,
                    self.total_items,
                });
            }
        }
        if (self.phase.index != .none) {
            self.phase.setCompletedItems(self.total_items);
            self.phase.end();
        }
        self.phase = std.Progress.Node.none;
        self.phase_name = "";
        self.total_items = 0;
        self.completed_items = 0;
        self.current_name = "";
    }

    fn finishCurrent(self: *FileProgress) void {
        if (self.current.index == .none) return;
        self.current.end();
        self.current = std.Progress.Node.none;
        if (self.phase.index != .none) self.phase.setCompletedItems(self.completed_items);
    }

    fn beginPhaseInternal(self: *FileProgress, name: []const u8, total_items: usize) void {
        self.finishPhase();
        self.ensureRoot();
        self.phase_name = name;
        self.total_items = total_items;
        self.completed_items = 0;
        self.current_name = "";
        if (self.root.index != .none) {
            self.phase = self.root.start(name, total_items);
        }
        self.renderFallbackPhaseStart();
    }

    fn ensureRoot(self: *FileProgress) void {
        if (self.root_started) return;
        self.root_started = true;
        self.root = std.Progress.start(self.io, .{ .root_name = self.root_name });
        self.use_fallback = self.root.index == .none;
        self.renderFallbackRoot();
    }

    fn renderFallbackRoot(self: *FileProgress) void {
        if (!self.use_fallback) return;
        if (self.fallback_root_rendered) return;
        termPrint("[progress] {s}\n", .{self.root_name});
        self.fallback_root_rendered = true;
    }

    fn renderFallbackPhaseStart(self: *FileProgress) void {
        if (!self.use_fallback) return;
        if (self.total_items == 0) {
            termPrint("[progress]   {s}\n", .{
                self.phase_name,
            });
        } else {
            termPrint("[progress]   {s} 0/{d}\n", .{
                self.phase_name,
                self.total_items,
            });
        }
    }

    fn renderFallbackCurrent(self: *const FileProgress) void {
        if (!self.use_fallback) return;
        if (self.total_items == 0) {
            termPrint("[progress]   {s}: {s}\n", .{
                self.phase_name,
                self.current_name,
            });
        } else {
            termPrint("[progress]   {s} {d}/{d} {s}\n", .{
                self.phase_name,
                self.completed_items + 1,
                self.total_items,
                self.current_name,
            });
        }
    }
};

const App = struct {
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    temp_paths: std.ArrayList([]const u8) = .empty,
    temp_counter: usize = 0,
    hdiff_path: ?[]const u8 = null,
    hpatch_path: ?[]const u8 = null,
    archive_tool_path: ?[]const u8 = null,

    fn deinit(self: *App) void {
        var i = self.temp_paths.items.len;
        while (i > 0) {
            i -= 1;
            const path = self.temp_paths.items[i];
            deleteBestEffort(self.io, path);
        }
        self.temp_paths.deinit(self.arena);
    }

    fn ensureTools(self: *App) !void {
        if (self.hdiff_path != null and self.hpatch_path != null and self.archive_tool_path != null) return;

        const temp_root = self.env.get("TEMP") orelse
            self.env.get("TMP") orelse
            self.env.get("TMPDIR") orelse
            if (builtin.os.tag == .windows) "." else "/tmp";
        self.temp_counter += 1;

        const hdiff_base = try std.fmt.allocPrint(self.arena, "hpackzig_{d}_{s}", .{ self.temp_counter, hdiff_name });
        const hpatch_base = try std.fmt.allocPrint(self.arena, "hpackzig_{d}_{s}", .{ self.temp_counter, hpatch_name });
        const archive_tool_base = try std.fmt.allocPrint(self.arena, "hpackzig_{d}_{s}", .{ self.temp_counter, sevenzip.archive_tool_name });

        const hdiff_path = try std.fs.path.join(self.arena, &.{ temp_root, hdiff_base });
        const hpatch_path = try std.fs.path.join(self.arena, &.{ temp_root, hpatch_base });
        const archive_tool_path = try std.fs.path.join(self.arena, &.{ temp_root, archive_tool_base });

        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = hdiff_path, .data = embedded_hdiff });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = hpatch_path, .data = embedded_hpatch });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = archive_tool_path, .data = sevenzip.embedded_archive_tool });
        try makeExecutableIfNeeded(self.io, hdiff_path);
        try makeExecutableIfNeeded(self.io, hpatch_path);
        try makeExecutableIfNeeded(self.io, archive_tool_path);

        try self.temp_paths.append(self.arena, hdiff_path);
        try self.temp_paths.append(self.arena, hpatch_path);
        try self.temp_paths.append(self.arena, archive_tool_path);

        self.hdiff_path = hdiff_path;
        self.hpatch_path = hpatch_path;
        self.archive_tool_path = archive_tool_path;
    }

    pub fn makeTempDir(self: *App, parent: []const u8, label: []const u8) ![]const u8 {
        self.temp_counter += 1;
        const name = try std.fmt.allocPrint(self.arena, "hpackzig_{s}_{d}", .{ label, self.temp_counter });
        const path = try std.fs.path.join(self.arena, &.{ parent, name });
        try std.Io.Dir.cwd().createDirPath(self.io, path);
        try self.temp_paths.append(self.arena, path);
        return path;
    }

    fn tempRoot(self: *App) []const u8 {
        return self.env.get("TEMP") orelse
            self.env.get("TMP") orelse
            self.env.get("TMPDIR") orelse
            if (builtin.os.tag == .windows) "." else "/tmp";
    }

    pub fn makeSystemTempDir(self: *App, label: []const u8) ![]const u8 {
        return self.makeTempDir(self.tempRoot(), label);
    }

    pub fn forgetTempPath(self: *App, path: []const u8) void {
        for (self.temp_paths.items, 0..) |temp_path, i| {
            if (!std.mem.eql(u8, temp_path, path)) continue;
            _ = self.temp_paths.swapRemove(i);
            return;
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    var app = App{
        .arena = init.arena.allocator(),
        .gpa = init.gpa,
        .io = init.io,
        .env = init.environ_map,
    };
    defer app.deinit();

    const args = try init.minimal.args.toSlice(app.arena);
    const exit_code = run(&app, args) catch |e| blk: {
        termPrint("Error: {s}\n", .{@errorName(e)});
        break :blk 1;
    };
    return exit_code;
}

fn run(app: *App, args: []const [:0]const u8) !u8 {
    if (args.len <= 1) {
        printBanner();
        printUsage();
        return 0;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printBanner();
        printUsage();
        return 0;
    }

    if (std.mem.eql(u8, command, "apply")) {
        printBanner();
        var opts = try parseApplyOptions(app.arena, args[2..]);
        opts.game_dir = try makeAbsolute(app.arena, app.io, opts.game_dir);
        for (opts.archive_paths) |*archive_path| archive_path.* = try makeAbsolute(app.arena, app.io, archive_path.*);
        try validateGameDir(app.io, opts.game_dir, opts.executable_skip);
        return if (try applyUpdates(app, opts)) 0 else 1;
    }
    if (std.mem.eql(u8, command, "check")) {
        printBanner();
        var opts = try parseCheckOptions(args[2..]);
        opts.game_dir = try makeAbsolute(app.arena, app.io, opts.game_dir);
        if (opts.output_dir) |output_dir| opts.output_dir = try makeAbsolute(app.arena, app.io, output_dir);
        try validateGameDir(app.io, opts.game_dir, opts.executable_skip);
        return if (try runCheckCommand(app, opts)) 0 else 1;
    }
    if (std.mem.eql(u8, command, "create")) {
        printBanner();
        var opts = try parseCreateOptions(args[2..]);
        opts.from_dir = try makeAbsolute(app.arena, app.io, opts.from_dir);
        opts.to_dir = try makeAbsolute(app.arena, app.io, opts.to_dir);
        opts.output_dir = try makeAbsolute(app.arena, app.io, opts.output_dir);
        const created = createPackages(app, opts) catch |e| switch (e) {
            error.VersionDetectFailed => {
                errorLog("Error auto detecting version from game folders, specify --version-change manually.");
                return 1;
            },
            error.InvalidVersionString => {
                errorLog("Error parsing version, it must be on format 'x.x.x.x'.");
                return 1;
            },
            error.ArchiveCreateFailed => {
                errorLog("Error creating output archive for patch package.");
                return 1;
            },
            error.ArchiveExtractFailed => {
                errorLog("Error extracting archive input for create.");
                return 1;
            },
            error.UnsupportedArchiveType => {
                errorFmt("Unsupported archive type. Use {s}.", .{sevenzip.package_archive_type_usage});
                return 1;
            },
            else => return e,
        };
        return if (created) 0 else 1;
    }

    printBanner();
    printUsage();
    return 1;
}

fn parseApplyOptions(arena: Allocator, args: []const [:0]const u8) !ApplyOptions {
    var opts = ApplyOptions{
        .game_dir = "",
        .archive_paths = &.{},
    };
    var archives: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (matches(arg, "--game-dir", "-d")) {
            i += 1;
            if (i >= args.len) return error.MissingGameDir;
            opts.game_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--archives") or matches(arg, "--zips", "-z")) {
            i += 1;
            while (i < args.len and !looksLikeFlag(args[i])) : (i += 1) {
                try archives.append(arena, args[i]);
            }
            continue;
        } else if (matches(arg, "--check-mode", "-c")) {
            i += 1;
            if (i >= args.len) return error.MissingCheckMode;
            opts.check_mode = try parseCheckMode(args[i]);
        } else if (matches(arg, "--delete-packages", "-r")) {
            opts.delete_packages = true;
        } else if (matches(arg, "--executable-skip", "-e")) {
            opts.executable_skip = true;
        } else if (try parseApplyShortFlagGroup(arg, &opts)) {} else {
            return error.UnknownArgument;
        }
        i += 1;
    }

    if (opts.game_dir.len == 0) return error.MissingGameDir;
    if (archives.items.len == 0) return error.MissingArchives;
    opts.archive_paths = try archives.toOwnedSlice(arena);
    return opts;
}

fn parseCheckOptions(args: []const [:0]const u8) !CheckOptions {
    var opts = CheckOptions{ .game_dir = "" };

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (matches(arg, "--game-dir", "-d")) {
            i += 1;
            if (i >= args.len) return error.MissingGameDir;
            opts.game_dir = args[i];
        } else if (matches(arg, "--check-mode", "-c")) {
            i += 1;
            if (i >= args.len) return error.MissingCheckMode;
            opts.check_mode = try parseCheckMode(args[i]);
        } else if (matches(arg, "--output", "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputDir;
            opts.output_dir = args[i];
        } else if (matches(arg, "--executable-skip", "-e")) {
            opts.executable_skip = true;
        } else if (try parseCheckShortFlagGroup(arg, &opts)) {} else {
            return error.UnknownArgument;
        }
        i += 1;
    }

    if (opts.game_dir.len == 0) return error.MissingGameDir;
    return opts;
}

fn parseCreateOptions(args: []const [:0]const u8) !CreateOptions {
    var opts = CreateOptions{
        .from_dir = "",
        .to_dir = "",
    };

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (matches(arg, "--from", "-f")) {
            i += 1;
            if (i >= args.len) return error.MissingFromDir;
            opts.from_dir = args[i];
        } else if (matches(arg, "--to", "-t")) {
            i += 1;
            if (i >= args.len) return error.MissingToDir;
            opts.to_dir = args[i];
        } else if (matches(arg, "--version-change", "-c")) {
            if (i + 2 >= args.len) return error.MissingVersionChange;
            opts.version_from = args[i + 1];
            opts.version_to = args[i + 2];
            i += 2;
        } else if (matches(arg, "--auto-version", "-a")) {
            opts.auto_version = true;
        } else if (matches(arg, "--output", "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputDir;
            opts.output_dir = args[i];
        } else if (matches(arg, "--prefix", "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingPrefix;
            opts.prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--archive-type") or std.mem.eql(u8, arg, "--archivetype")) {
            i += 1;
            if (i >= args.len) return error.MissingArchiveType;
            opts.archive_type = args[i];
        } else if (matches(arg, "--reverse", "-r")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--skipCheck") or std.mem.eql(u8, arg, "-s")) {
            opts.skip_check = true;
        } else if (std.mem.eql(u8, arg, "--only-include-pkg-defined-files") or std.mem.eql(u8, arg, "-d")) {
            opts.only_package = true;
        } else if (std.mem.eql(u8, arg, "--include-audios") or std.mem.eql(u8, arg, "-i")) {
            opts.include_audios = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force_equal = true;
        } else if (matches(arg, "--executable-skip", "-e")) {
            opts.executable_skip = true;
        } else if (try parseCreateShortFlagGroup(arg, &opts)) {} else {
            return error.UnknownArgument;
        }
        i += 1;
    }

    if (opts.from_dir.len == 0) return error.MissingFromDir;
    if (opts.to_dir.len == 0) return error.MissingToDir;
    return opts;
}

fn parseApplyShortFlagGroup(arg: []const u8, opts: *ApplyOptions) !bool {
    if (!isShortFlagGroup(arg)) return false;

    for (arg[1..]) |flag| switch (flag) {
        'r' => opts.delete_packages = true,
        'e' => opts.executable_skip = true,
        'd', 'z', 'c' => return error.ShortFlagRequiresSeparateArgument,
        else => return error.UnknownArgument,
    };
    return true;
}

fn parseCheckShortFlagGroup(arg: []const u8, opts: *CheckOptions) !bool {
    if (!isShortFlagGroup(arg)) return false;

    for (arg[1..]) |flag| switch (flag) {
        'e' => opts.executable_skip = true,
        'd', 'c', 'o' => return error.ShortFlagRequiresSeparateArgument,
        else => return error.UnknownArgument,
    };
    return true;
}

fn parseCreateShortFlagGroup(arg: []const u8, opts: *CreateOptions) !bool {
    if (!isShortFlagGroup(arg)) return false;

    for (arg[1..]) |flag| switch (flag) {
        'a' => opts.auto_version = true,
        'r' => opts.reverse = true,
        's' => opts.skip_check = true,
        'd' => opts.only_package = true,
        'i' => opts.include_audios = true,
        'e' => opts.executable_skip = true,
        'f', 't', 'c', 'o', 'p' => return error.ShortFlagRequiresSeparateArgument,
        else => return error.UnknownArgument,
    };
    return true;
}

fn runCheckCommand(app: *App, opts: CheckOptions) !bool {
    var progress = FileProgress.init(app.io, "Checking files");
    defer progress.deinit();

    var bad_files: std.ArrayList([]const u8) = .empty;
    defer bad_files.deinit(app.arena);

    const passed = try doCheck(app, opts.game_dir, opts.check_mode, &bad_files, &progress);
    if (passed) {
        info("All files are correct.");
    } else {
        errorLog("Some files are incorrect.");
    }

    if (opts.output_dir) |output_dir| {
        if (bad_files.items.len == 0) return passed;
        try std.Io.Dir.cwd().createDirPath(app.io, output_dir);
        const save_path = try std.fs.path.join(app.arena, &.{ output_dir, "badfiles.txt" });
        const bad_data = try joinLines(app.arena, bad_files.items);
        try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = save_path, .data = bad_data });
        infoFmt("Saved bad file list to {s}", .{save_path});
    }
    return passed;
}

fn matches(arg: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, arg, long) or std.mem.eql(u8, arg, short);
}

fn looksLikeFlag(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn isShortFlagGroup(arg: []const u8) bool {
    return arg.len > 2 and arg[0] == '-' and arg[1] != '-';
}

fn parseCheckMode(text: []const u8) !CheckMode {
    if (std.ascii.eqlIgnoreCase(text, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(text, "basic")) return .basic;
    if (std.ascii.eqlIgnoreCase(text, "full")) return .full;
    return error.InvalidCheckMode;
}

fn printUsage() void {
    termPrint(
        \\HPack Zig
        \\
        \\Commands:
        \\  hpack apply --game-dir <path> (--archives <file...> | --zips <file...>) [--check-mode None|Basic|Full] [--delete-packages] [-e]
        \\  hpack check --game-dir <path> [--check-mode None|Basic|Full] [--output <dir>] [-e]
        \\  hpack create --from <old-dir-or-archive> --to <new-dir-or-archive> (--auto-version | --version-change <old> <new>) [options]
        \\
        \\Create options:
        \\  --output, -o <dir>
        \\  --prefix, -p <name>
        \\  --archive-type, --archivetype <type>
        \\    {s}
        \\  --reverse, -r
        \\  --skipCheck, -s
        \\  --only-include-pkg-defined-files, -d
        \\  --include-audios, -i
        \\  --force
        \\  --executable-skip, -e
        \\
    , .{sevenzip.package_archive_type_usage});
}

fn info(message: []const u8) void {
    termPrint("[info] {s}\n", .{message});
}

fn warn(message: []const u8) void {
    termPrint("[warn] {s}\n", .{message});
}

fn errorLog(message: []const u8) void {
    termPrint("[error] {s}\n", .{message});
}

fn infoFmt(comptime fmt: []const u8, args: anytype) void {
    termPrint("[info] " ++ fmt ++ "\n", args);
}

fn warnFmt(comptime fmt: []const u8, args: anytype) void {
    termPrint("[warn] " ++ fmt ++ "\n", args);
}

fn errorFmt(comptime fmt: []const u8, args: anytype) void {
    termPrint("[error] " ++ fmt ++ "\n", args);
}

fn applyUpdates(app: *App, opts: ApplyOptions) !bool {
    var progress = FileProgress.init(app.io, "Applying patch");
    defer progress.deinit();

    progress.beginStage("Preparing tools");
    try app.ensureTools();

    progress.beginStage("Backing up version files");
    const backup_dir = try app.makeTempDir(opts.game_dir, "backup");
    const pkg_paths = try getPkgVersionPaths(app.arena, app.io, opts.game_dir, true);

    for (pkg_paths.items) |pkg_path| {
        const basename = std.fs.path.basename(pkg_path);
        const backup_path = try std.fs.path.join(app.arena, &.{ backup_dir, basename });
        try std.Io.Dir.copyFileAbsolute(pkg_path, backup_path, app.io, .{ .replace = true, .make_path = true });
    }

    var delete_delays: std.ArrayList([]const u8) = .empty;
    defer delete_delays.deinit(app.arena);

    for (opts.archive_paths) |archive_path| {
        infoFmt("Applying {s}", .{archive_path});
        const extract_dir = try sevenzip.prepareApplyInput(app, &progress, archive_path, opts.game_dir) orelse {
            warnFmt("The file {s} is not a supported archive or failed to extract.", .{archive_path});
            continue;
        };

        var hdiff_names = try readRemoteNameSet(app.arena, app.io, extract_dir, "hdifffiles.txt");
        defer hdiff_names.deinit();
        var delete_list = try readPlainLinesFromFile(app.arena, app.io, extract_dir, "deletefiles.txt");
        defer delete_list.deinit(app.arena);
        var package_files = try collectPackageFiles(app.arena, app.io, extract_dir);
        defer package_files.deinit(app.arena);

        progress.beginPhase(std.fs.path.basename(archive_path), delete_list.items.len + package_files.items.len);

        for (delete_list.items) |delete_rel_slash| {
            progress.setCurrent(delete_rel_slash);
            const delete_rel_native = try slashToNative(app.arena, delete_rel_slash);
            const delete_abs = try std.fs.path.join(app.arena, &.{ opts.game_dir, delete_rel_native });
            if (pathExists(app.io, delete_abs)) {
                deleteBestEffort(app.io, delete_abs);
            } else {
                try delete_delays.append(app.arena, delete_abs);
            }
            progress.completeOne();
        }

        for (package_files.items) |package_file| {
            progress.setCurrent(package_file.rel_slash);
            const src_abs = try std.fs.path.join(app.arena, &.{ extract_dir, package_file.native_rel });
            const rel_slash = package_file.rel_slash;
            if (std.mem.endsWith(u8, rel_slash, ".hdiff")) {
                const target_rel_slash = rel_slash[0 .. rel_slash.len - ".hdiff".len];
                if (hdiff_names.contains(target_rel_slash)) {
                    const target_rel_native = try slashToNative(app.arena, target_rel_slash);
                    const target_abs = try std.fs.path.join(app.arena, &.{ opts.game_dir, target_rel_native });
                    if (!pathExists(app.io, target_abs)) {
                        progress.completeOne();
                        continue;
                    }
                    if (!try runPatchTool(app, target_abs, src_abs, target_abs)) {
                        warnFmt("Failed to patch {s}", .{target_abs});
                    }
                    progress.completeOne();
                    continue;
                }
            }

            const rel_native = try slashToNative(app.arena, rel_slash);
            const dest_abs = try std.fs.path.join(app.arena, &.{ opts.game_dir, rel_native });
            try std.Io.Dir.copyFileAbsolute(src_abs, dest_abs, app.io, .{ .replace = true, .make_path = true });
            progress.completeOne();
        }

        _ = opts.delete_packages;
    }

    const check_ok = try doCheck(app, opts.game_dir, opts.check_mode, null, &progress);
    if (!check_ok) {
        errorLog("File check failed after patching.");
        return false;
    }

    for (pkg_paths.items) |pkg_path| {
        const basename = std.fs.path.basename(pkg_path);
        if (std.mem.eql(u8, basename, "pkg_version")) continue;
        if (pathExists(app.io, pkg_path)) continue;

        const backup_path = try std.fs.path.join(app.arena, &.{ backup_dir, basename });
        if (!pathExists(app.io, backup_path)) continue;
        try std.Io.Dir.copyFileAbsolute(backup_path, pkg_path, app.io, .{ .replace = true, .make_path = true });

        if (opts.check_mode == .none) {
            warnFmt("{s} restored without re-checking.", .{basename});
        } else {
            const restored_ok = try checkByPkgVersion(app, opts.game_dir, pkg_path, opts.check_mode, null, null);
            if (!restored_ok) warnFmt("{s} may not match the current version anymore.", .{basename});
        }
    }

    for (delete_delays.items) |delete_path| {
        if (pathExists(app.io, delete_path)) deleteBestEffort(app.io, delete_path);
    }

    info("Update applied successfully.");
    return true;
}

fn createPackages(app: *App, opts: CreateOptions) !bool {
    var progress = FileProgress.init(app.io, "Creating patch");
    defer progress.deinit();

    const from_input_is_dir = isDirectory(app.io, opts.from_dir);
    const to_input_is_dir = isDirectory(app.io, opts.to_dir);
    if (!from_input_is_dir or !to_input_is_dir) {
        progress.beginStage("Preparing tools");
        try app.ensureTools();
    }

    const from_root = try sevenzip.resolveCreateInputDir(app, &progress, opts.from_dir, "old", opts.executable_skip, validateGameDir);
    const to_root = try sevenzip.resolveCreateInputDir(app, &progress, opts.to_dir, "new", opts.executable_skip, validateGameDir);

    var version_from = opts.version_from;
    var version_to = opts.version_to;

    if (opts.auto_version) {
        progress.beginStage("Detecting versions");
        version_from = try autoDetectVersion(app.arena, app.io, from_root);
        version_to = try autoDetectVersion(app.arena, app.io, to_root);
    } else if (version_from == null or version_to == null) {
        return error.MissingVersionChange;
    }

    if (!isValidVersionString(version_from.?) or !isValidVersionString(version_to.?)) {
        return error.InvalidVersionString;
    }
    const archive_spec = try sevenzip.normalizePackageArchiveType(opts.archive_type);

    if (!opts.skip_check) {
        info("Checking old version game files");
        if (!try doCheck(app, from_root, .basic, null, &progress)) {
            errorLog("Original files not correct.");
            return false;
        }
        info("Checking new version game files");
        if (!try doCheck(app, to_root, .basic, null, &progress)) {
            errorLog("Original files not correct.");
            return false;
        }
    }

    var allowed_from: ?std.StringHashMap(u8) = null;
    var allowed_to: ?std.StringHashMap(u8) = null;
    defer if (allowed_from) |*m| m.deinit();
    defer if (allowed_to) |*m| m.deinit();

    if (opts.only_package) {
        var old_pkg_versions = try getPkgVersionPaths(app.arena, app.io, from_root, opts.include_audios);
        defer old_pkg_versions.deinit(app.arena);
        var new_pkg_versions = try getPkgVersionPaths(app.arena, app.io, to_root, opts.include_audios);
        defer new_pkg_versions.deinit(app.arena);
        if (old_pkg_versions.items.len == 0 or new_pkg_versions.items.len == 0) {
            warn("Can't find pkg_version file. No files are selected.");
            return true;
        }
        progress.beginStage("Loading pkg-defined file list");
        allowed_from = try collectAllowedFiles(app.arena, app.io, from_root, opts.include_audios);
        allowed_to = try collectAllowedFiles(app.arena, app.io, to_root, opts.include_audios);
    }

    var from_files = try enumerateFiles(
        app.arena,
        app.io,
        &progress,
        "Enumerating old files",
        from_root,
        if (allowed_from) |*m| m else null,
    );
    defer from_files.deinit();
    var to_files = try enumerateFiles(
        app.arena,
        app.io,
        &progress,
        "Enumerating new files",
        to_root,
        if (allowed_to) |*m| m else null,
    );
    defer to_files.deinit();

    progress.beginStage("Comparing file lists");
    if (!opts.force_equal and try fileMapsEqual(app, &from_files, &to_files)) {
        warn("The two folders are identical. Use --force to create a package anyway.");
        return false;
    }

    if (from_input_is_dir and to_input_is_dir) progress.beginStage("Preparing tools");
    try app.ensureTools();
    progress.beginStage("Preparing output");
    try std.Io.Dir.cwd().createDirPath(app.io, opts.output_dir);

    const main_name = try sevenzip.makePackageOutputName(app.arena, opts.prefix, version_from.?, version_to.?, archive_spec);
    const main_out = try std.fs.path.join(app.arena, &.{ opts.output_dir, main_name });
    try createDiffPackage(app, &progress, &from_files, &to_files, main_out, archive_spec);

    if (opts.reverse) {
        const reverse_name = try sevenzip.makePackageOutputName(app.arena, opts.prefix, version_to.?, version_from.?, archive_spec);
        const reverse_out = try std.fs.path.join(app.arena, &.{ opts.output_dir, reverse_name });
        try createDiffPackage(app, &progress, &to_files, &from_files, reverse_out, archive_spec);
    }

    return true;
}

fn createDiffPackage(
    app: *App,
    progress: *FileProgress,
    from_files: *std.StringHashMap(FileRecord),
    to_files: *std.StringHashMap(FileRecord),
    output_archive_path: []const u8,
    archive_spec: sevenzip.PackageArchiveSpec,
) !void {
    infoFmt("Creating {s}", .{output_archive_path});
    const output_parent = std.fs.path.dirname(output_archive_path) orelse ".";
    const temp_dir = try app.makeTempDir(output_parent, "package");

    var delete_lines: std.ArrayList([]const u8) = .empty;
    defer delete_lines.deinit(app.arena);

    var hdiff_lines: std.ArrayList([]const u8) = .empty;
    defer hdiff_lines.deinit(app.arena);

    var delete_count: usize = 0;
    var copy_count: usize = 0;
    var common_count: usize = 0;

    var from_it = from_files.iterator();
    while (from_it.next()) |entry| {
        if (!to_files.contains(entry.key_ptr.*)) {
            delete_count += 1;
        } else {
            common_count += 1;
        }
    }

    var to_it = to_files.iterator();
    while (to_it.next()) |entry| {
        if (!from_files.contains(entry.key_ptr.*)) {
            copy_count += 1;
        }
    }

    progress.beginPhase(std.fs.path.basename(output_archive_path), delete_count + copy_count + common_count);

    from_it = from_files.iterator();
    while (from_it.next()) |entry| {
        if (!to_files.contains(entry.key_ptr.*)) {
            progress.setCurrent(entry.key_ptr.*);
            try delete_lines.append(app.arena, entry.key_ptr.*);
            progress.completeOne();
        }
    }

    to_it = to_files.iterator();
    while (to_it.next()) |entry| {
        if (!from_files.contains(entry.key_ptr.*)) {
            progress.setCurrent(entry.key_ptr.*);
            try copyIntoPackage(app, temp_dir, entry.value_ptr.*);
            progress.completeOne();
        }
    }

    from_it = from_files.iterator();
    while (from_it.next()) |entry| {
        const rel_slash = entry.key_ptr.*;
        const to_rec = to_files.getPtr(rel_slash) orelse continue;
        const from_rec = entry.value_ptr;

        progress.setCurrent(rel_slash);

        if (try filesEqual(app, from_rec, to_rec)) {
            progress.completeOne();
            continue;
        }

        if (std.mem.endsWith(u8, rel_slash, "pkg_version")) {
            try copyIntoPackage(app, temp_dir, to_rec.*);
            progress.completeOne();
            continue;
        }

        const rel_native = try slashToNative(app.arena, rel_slash);
        const diff_rel_native = try std.fmt.allocPrint(app.arena, "{s}.hdiff", .{rel_native});
        const diff_abs = try std.fs.path.join(app.arena, &.{ temp_dir, diff_rel_native });
        try ensureParentDir(app.io, diff_abs);

        if (try runDiffTool(app, from_rec.abs_path, to_rec.abs_path, diff_abs)) {
            const diff_stat = try std.Io.Dir.cwd().statFile(app.io, diff_abs, .{});
            if (diff_stat.size >= to_rec.size) {
                deleteBestEffort(app.io, diff_abs);
                try copyIntoPackage(app, temp_dir, to_rec.*);
            } else {
                const json_line = try std.fmt.allocPrint(app.arena, "{{\"remoteName\": \"{s}\"}}", .{rel_slash});
                try hdiff_lines.append(app.arena, json_line);
            }
        } else {
            warnFmt("Diff failed for {s}, copying full file instead.", .{rel_slash});
            try copyIntoPackage(app, temp_dir, to_rec.*);
        }
        progress.completeOne();
    }

    const delete_text = try joinLines(app.arena, delete_lines.items);
    const hdiff_text = try joinLines(app.arena, hdiff_lines.items);

    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = try std.fs.path.join(app.arena, &.{ temp_dir, "deletefiles.txt" }), .data = delete_text });
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = try std.fs.path.join(app.arena, &.{ temp_dir, "hdifffiles.txt" }), .data = hdiff_text });
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = try std.fs.path.join(app.arena, &.{ temp_dir, "README.txt" }), .data = readme_text });

    try sevenzip.writePackageOutput(app, progress, temp_dir, output_archive_path, archive_spec);
}

fn copyIntoPackage(app: *App, package_dir: []const u8, record: FileRecord) !void {
    const rel_native = try slashToNative(app.arena, record.rel_slash);
    const dest_abs = try std.fs.path.join(app.arena, &.{ package_dir, rel_native });
    try std.Io.Dir.copyFileAbsolute(record.abs_path, dest_abs, app.io, .{ .replace = true, .make_path = true });
}

fn enumerateFiles(
    arena: Allocator,
    io: Io,
    progress: *FileProgress,
    phase_name: []const u8,
    root_dir_path: []const u8,
    allowed: ?*std.StringHashMap(u8),
) !std.StringHashMap(FileRecord) {
    var map = std.StringHashMap(FileRecord).init(arena);

    const total_files = try countFilesInTree(io, root_dir_path);
    progress.beginPhase(phase_name, total_files);

    var root_dir = try std.Io.Dir.openDirAbsolute(io, root_dir_path, .{ .iterate = true });
    defer root_dir.close(io);

    var walker = try root_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const rel_slash = try normalizeRelativePath(arena, entry.path);
        progress.setCurrent(rel_slash);
        if (allowed) |allow_map| {
            if (!allow_map.contains(rel_slash)) {
                progress.completeOne();
                continue;
            }
        }

        const abs_path = try std.fs.path.join(arena, &.{ root_dir_path, entry.path });
        const stat = try std.Io.Dir.cwd().statFile(io, abs_path, .{});

        try map.put(rel_slash, .{
            .rel_slash = rel_slash,
            .abs_path = abs_path,
            .size = stat.size,
        });
        progress.completeOne();
    }

    return map;
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

fn collectAllowedFiles(
    arena: Allocator,
    io: Io,
    dir_path: []const u8,
    include_audios: bool,
) !std.StringHashMap(u8) {
    var set = std.StringHashMap(u8).init(arena);
    var pkg_paths = try getPkgVersionPaths(arena, io, dir_path, include_audios);
    defer pkg_paths.deinit(arena);

    if (pkg_paths.items.len == 0) {
        warn("Can't find pkg_version file. No files are selected.");
        return set;
    }

    for (pkg_paths.items) |pkg_path| {
        const basename = std.fs.path.basename(pkg_path);
        try set.put(basename, 1);

        const text = try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, arena, .limited(std.math.maxInt(u32)));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(RemoteNameEntry, arena, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try set.put(parsed.value.remoteName, 1);
        }
    }

    return set;
}

fn collectPackageFiles(arena: Allocator, io: Io, extract_dir: []const u8) !std.ArrayList(PackageFile) {
    var files: std.ArrayList(PackageFile) = .empty;

    var dir = try std.Io.Dir.openDirAbsolute(io, extract_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const rel_slash = try normalizeRelativePath(arena, entry.path);
        if (isPackageMetadata(rel_slash)) continue;

        try files.append(arena, .{
            .native_rel = try arena.dupe(u8, entry.path),
            .rel_slash = rel_slash,
        });
    }

    return files;
}

fn countPkgVersionEntries(arena: Allocator, io: Io, pkg_paths: []const []const u8) !usize {
    var total: usize = 0;
    for (pkg_paths) |pkg_path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, arena, .limited(std.math.maxInt(u32)));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            if (trimLine(raw_line).len != 0) total += 1;
        }
    }
    return total;
}

fn doCheck(
    app: *App,
    dir_path: []const u8,
    mode: CheckMode,
    bad_files: ?*std.ArrayList([]const u8),
    progress: ?*FileProgress,
) !bool {
    if (mode == .none) return true;
    defer if (progress) |p| p.finishPhase();

    if (progress) |p| p.beginStage("Finding version files");
    var pkg_paths = try getPkgVersionPaths(app.arena, app.io, dir_path, true);
    defer pkg_paths.deinit(app.arena);

    if (pkg_paths.items.len == 0) {
        warn("Can't find version file. No checks are performed.");
        return true;
    }

    if (progress) |p| {
        const total_entries = try countPkgVersionEntries(app.arena, app.io, pkg_paths.items);
        p.beginPhase("Checking files", total_entries);
    }

    var all_ok = true;
    for (pkg_paths.items) |pkg_path| {
        const ok = try checkByPkgVersion(app, dir_path, pkg_path, mode, bad_files, progress);
        all_ok = all_ok and ok;
    }
    return all_ok;
}

fn checkByPkgVersion(
    app: *App,
    dir_path: []const u8,
    pkg_path: []const u8,
    mode: CheckMode,
    bad_files: ?*std.ArrayList([]const u8),
    progress: ?*FileProgress,
) !bool {
    if (mode == .none) return true;

    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, pkg_path, app.arena, .limited(std.math.maxInt(u32)));
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ok = true;

    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(PkgVersionEntry, app.arena, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (progress) |p| {
            p.setCurrent(parsed.value.remoteName);
            defer p.completeOne();
        }

        const rel_native = try slashToNative(app.arena, parsed.value.remoteName);
        const check_path = try std.fs.path.join(app.arena, &.{ dir_path, rel_native });

        if (!pathExists(app.io, check_path)) {
            warnFmt("Missing file: {s}", .{check_path});
            if (bad_files) |list| try list.append(app.arena, rel_native);
            ok = false;
            continue;
        }

        const stat = try std.Io.Dir.cwd().statFile(app.io, check_path, .{});
        if (stat.size != parsed.value.fileSize) {
            warnFmt("Wrong size: {s}", .{check_path});
            if (bad_files) |list| try list.append(app.arena, rel_native);
            ok = false;
            continue;
        }

        if (mode == .full) {
            const md5 = try md5HexOfFile(app.io, check_path);
            if (!std.mem.eql(u8, md5[0..], parsed.value.md5)) {
                warnFmt("Wrong MD5: {s}", .{check_path});
                if (bad_files) |list| try list.append(app.arena, rel_native);
                ok = false;
            }
        }
    }

    return ok;
}

fn autoDetectVersion(arena: Allocator, io: Io, dir_path: []const u8) ![]const u8 {
    const config_path = try std.fs.path.join(arena, &.{ dir_path, "config.ini" });
    if (pathExists(io, config_path)) {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(1024 * 1024));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (std.mem.startsWith(u8, line, "game_version=")) {
                const version = line["game_version=".len..];
                if (!isValidVersionString(version)) return error.VersionDetectFailed;
                return version;
            }
        }
    }

    const version_info = try std.fs.path.join(arena, &.{ dir_path, "version_info" });
    if (pathExists(io, version_info)) {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, version_info, arena, .limited(1024 * 1024));
        if (extractVersionFromVersionInfo(text)) |version| {
            if (!isValidVersionString(version)) return error.VersionDetectFailed;
            return version;
        }
    }

    const plain_version = try std.fs.path.join(arena, &.{ dir_path, "version" });
    if (pathExists(io, plain_version)) {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, plain_version, arena, .limited(1024));
        const version = trimLine(text);
        if (!isValidVersionString(version)) return error.VersionDetectFailed;
        return version;
    }

    const plain_version_txt = try std.fs.path.join(arena, &.{ dir_path, "version.txt" });
    if (pathExists(io, plain_version_txt)) {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, plain_version_txt, arena, .limited(1024));
        const version = trimLine(text);
        if (!isValidVersionString(version)) return error.VersionDetectFailed;
        return version;
    }

    return error.VersionDetectFailed;
}

fn extractVersionFromVersionInfo(text: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (std.ascii.isDigit(text[i])) {
            start = i;
            break;
        }
    }
    const s = start orelse return null;
    var end = s;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) : (end += 1) {}
    if (end == s) return null;
    return trimLine(text[s..end]);
}

fn isValidVersionString(text: []const u8) bool {
    if (text.len == 0) return false;

    var part_count: usize = 1;
    var saw_digit = false;
    for (text) |ch| {
        if (std.ascii.isDigit(ch)) {
            saw_digit = true;
            continue;
        }
        if (ch != '.') return false;
        if (!saw_digit) return false;
        part_count += 1;
        saw_digit = false;
    }

    if (!saw_digit) return false;
    return part_count >= 2 and part_count <= 4;
}

fn fileMapsEqual(app: *App, lhs: *std.StringHashMap(FileRecord), rhs: *std.StringHashMap(FileRecord)) !bool {
    if (lhs.count() != rhs.count()) return false;

    var it = lhs.iterator();
    while (it.next()) |entry| {
        const rhs_rec = rhs.getPtr(entry.key_ptr.*) orelse return false;
        if (!try filesEqual(app, entry.value_ptr, rhs_rec)) return false;
    }

    return true;
}

fn filesEqual(app: *App, lhs: *FileRecord, rhs: *FileRecord) !bool {
    if (lhs.size != rhs.size) return false;
    if (lhs.md5_hex == null) lhs.md5_hex = try md5HexOfFile(app.io, lhs.abs_path);
    if (rhs.md5_hex == null) rhs.md5_hex = try md5HexOfFile(app.io, rhs.abs_path);
    return std.mem.eql(u8, lhs.md5_hex.?[0..], rhs.md5_hex.?[0..]);
}

fn runDiffTool(app: *App, from_path: []const u8, to_path: []const u8, diff_path: []const u8) !bool {
    try ensureParentDir(app.io, diff_path);
    const argv = [_][]const u8{ app.hdiff_path.?, "-f", from_path, to_path, diff_path };
    const result = std.process.run(app.gpa, app.io, .{ .argv = &argv }) catch return false;
    defer app.gpa.free(result.stdout);
    defer app.gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runPatchTool(app: *App, from_path: []const u8, diff_path: []const u8, to_path: []const u8) !bool {
    try ensureParentDir(app.io, to_path);
    const argv = [_][]const u8{ app.hpatch_path.?, "-f", from_path, diff_path, to_path };
    const result = std.process.run(app.gpa, app.io, .{ .argv = &argv }) catch return false;
    defer app.gpa.free(result.stdout);
    defer app.gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn getPkgVersionPaths(arena: Allocator, io: Io, dir_path: []const u8, include_audios: bool) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;

    const pkg_path = try std.fs.path.join(arena, &.{ dir_path, "pkg_version" });
    if (pathExists(io, pkg_path)) try list.append(arena, pkg_path);

    if (!include_audios) return list;

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "Audio_")) continue;
        if (!std.mem.endsWith(u8, entry.name, "_pkg_version")) continue;
        const abs = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        try list.append(arena, abs);
    }

    return list;
}

fn readRemoteNameSet(arena: Allocator, io: Io, root_dir: []const u8, file_name: []const u8) !std.StringHashMap(u8) {
    var set = std.StringHashMap(u8).init(arena);
    const path = try std.fs.path.join(arena, &.{ root_dir, file_name });
    if (!pathExists(io, path)) return set;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(std.math.maxInt(u32)));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(RemoteNameEntry, arena, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try set.put(parsed.value.remoteName, 1);
    }
    return set;
}

fn readPlainLinesFromFile(arena: Allocator, io: Io, root_dir: []const u8, file_name: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const path = try std.fs.path.join(arena, &.{ root_dir, file_name });
    if (!pathExists(io, path)) return list;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(std.math.maxInt(u32)));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;
        try list.append(arena, line);
    }
    return list;
}

fn validateGameDir(io: Io, dir_path: []const u8, executable_skip: bool) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    if (executable_skip) return;

    for (certain_games) |name| {
        const exe = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.exe", .{name});
        defer std.heap.page_allocator.free(exe);
        const beta = try std.fmt.allocPrint(std.heap.page_allocator, "{s}Beta.exe", .{name});
        defer std.heap.page_allocator.free(beta);

        const exe_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, exe });
        defer std.heap.page_allocator.free(exe_path);
        const beta_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, beta });
        defer std.heap.page_allocator.free(beta_path);

        if (pathExists(io, exe_path) or pathExists(io, beta_path)) return;
    }

    return error.NoKnownGameExecutableFound;
}

fn md5HexOfFile(io: Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var reader_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var hasher = std.crypto.hash.Md5.init(.{});
    var buf: [16 * 1024]u8 = undefined;

    while (true) {
        const amt = reader.interface.readSliceShort(&buf) catch |e| switch (e) {
            error.ReadFailed => return reader.err.?,
        };
        if (amt == 0) break;
        hasher.update(buf[0..amt]);
    }

    var digest: [16]u8 = undefined;
    hasher.final(&digest);

    var hex: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        digest[0], digest[1], digest[2],  digest[3],  digest[4],  digest[5],  digest[6],  digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15],
    });
    return hex;
}

fn ensureParentDir(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn makeAbsolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return try arena.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, arena);
    return try std.fs.path.resolve(arena, &.{ cwd, path });
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

fn makeExecutableIfNeeded(io: Io, path: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
}

fn normalizeRelativePath(arena: Allocator, rel_native: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, rel_native);
    std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

fn slashToNative(arena: Allocator, rel_slash: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, rel_slash);
    std.mem.replaceScalar(u8, out, '/', std.fs.path.sep);
    return out;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \r\t");
}

fn joinLines(arena: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    for (lines) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return try out.toOwnedSlice(arena);
}

fn isPackageMetadata(rel_slash: []const u8) bool {
    return std.mem.eql(u8, rel_slash, "deletefiles.txt") or
        std.mem.eql(u8, rel_slash, "hdifffiles.txt") or
        std.mem.eql(u8, rel_slash, "README.txt");
}
