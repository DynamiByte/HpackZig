# HPack Zig

Zig rewrite of [HPack](https://git.zenless.app/RoxyTheProxy/HPack/releases) by [RoxyTheProxy](https://git.zenless.app/RoxyTheProxy) for creating, applying, and checking update packages of certain games.

This is CLI-only. Running without arguments prints usage.

## Build

You'll need Zig 0.16.0-dev.3028+a85495ca2

- [Linux](https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.3028+a85495ca2.tar.xz)
- [Windows](https://ziglang.org/builds/zig-x86_64-windows-0.16.0-dev.3028+a85495ca2.zip)

From the `hpackzig` directory, run `zig build`

For smaller release artifacts, use `-Doptimize=ReleaseSmall`

This relies on prebuilt binaries of [HDiffPatch](https://github.com/sisong/HDiffPatch/),
and it source-builds the archive helper from the bundled full 7-Zip source tree under `./deps/7z`.

If you want a different startup banner, replace `src/banner_ansi.txt`.
`./banner_ansi_alt.txt` is an extra banner asset in the repo if you want to use that. :yuzuha_doro:

Build outputs:

- `zig-out/bin/windows-x64/hpack.exe`
- `zig-out/bin/linux-x64/hpack`

## Commands

### Apply

Apply one or more update archives to a game directory.

```bash
hpack apply --game-dir <path> --archives <archive...> [--check-mode None|Basic|Full] [--delete-packages] [-e]
```

Options:

- `-d`, `--game-dir` - target game directory
- `--archives` - one or more update archives or already-extracted package folders, applied in order
- `-z`, `--zips` - compatibility alias for `--archives`
- `-c`, `--check-mode` - verification mode after apply
- `-r`, `--delete-packages` - delete package files after they are processed
- `-e`, `--executable-skip` - skip known-game executable validation

Tested input archive formats are `7z`, `zip`, `tar`, `gz`, `bz2`, `xz`, and split `*.001` sets.
The bundled 7-Zip helper can also open more formats than that, but those are the ones verified in HPack's create/apply flow.

Default apply check mode is `None`.

### Check

Check a game directory against its `pkg_version` files.

```bash
hpack check --game-dir <path> [--check-mode None|Basic|Full] [--output <dir>] [-e]
```

Options:

- `-d`, `--game-dir` - target game directory
- `-c`, `--check-mode` - verification mode
- `-o`, `--output` - output directory for `badfiles.txt`
- `-e`, `--executable-skip` - skip known-game executable validation

Default check mode is `None`, so pass `Basic` or `Full` when you actually want verification.

### Create

Create an update archive from an old game directory and a new one.

```bash
hpack create --from <old> --to <new> (--auto-version | --version-change <old> <new>) [options]
```

Options:

- `-f`, `--from` - old version directory
- `-t`, `--to` - new version directory
- `-c`, `--version-change` - explicit version pair
- `-a`, `--auto-version` - detect versions automatically
- `-o`, `--output` - output directory, default current directory
- `-p`, `--prefix` - package prefix, default `game`
- `--archive-type`, `--archivetype` - package archive type: `7z`, `zip`, `tar`, `gz`, `bz2`, `xz`, or `none`
- `-r`, `--reverse` - also create the reverse package
- `-s`, `--skipCheck` - skip the initial basic validation of both directories
- `-d`, `--only-include-pkg-defined-files` - only include files present in `pkg_version`
- `-i`, `--include-audios` - also include `Audio_*_pkg_version` manifests when filtering by pkg-defined files
- `--force` - create a package even if the two directories are identical
- `-e`, `--executable-skip` - skip known-game executable validation

Output package name:

```bash
<prefix>_<fromVersion>_<toVersion>_hdiff.<archiveType>
```

For `--archive-type none`, the output is a folder named:

```bash
<prefix>_<fromVersion>_<toVersion>_hdiff
```

## Check Modes

- `None` - skip verification
- `Basic` - verify file presence and file size
- `Full` - verify file presence, file size, and MD5

## Notes

- `pkg_version` files are newline-delimited JSON entries, not one big JSON document.
- `create` stores changed files as `.hdiff` when the diff is smaller than the full file; otherwise it falls back to copying the full file into the package.
- `apply` restores missing non-main `*_pkg_version` files from backup after patching.
- Version auto-detection checks `config.ini`, `version_info`, `version`, and `version.txt`.
- Known game executable validation can be bypassed with `-e` when working on extracted samples or test folders.
- `create --from` and `create --to` accept directories or archives.
- `apply --archives` also accepts an already-extracted package folder.
- The common archive inputs verified in HPack are `7z`, `zip`, `tar`, `gz`, `bz2`, and `xz`.
- `create --archive-type gz`, `bz2`, and `xz` wrap the package as a single compressed `7z`, so `7z` remains the native package layout inside those single-stream formats.
