const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.option(bool, "dependency", "build the module as a dependency") orelse false;

    // Nothing to do if we are a dependency
    if (dep) {
        return;
    }

    var aio_opts = b.addOptions();
    {
        const debug = b.option(bool, "aio:debug", "enable debug prints") orelse false;
        aio_opts.addOption(bool, "debug", debug);

        const PosixMode = enum { auto, force, disable };
        const posix = b.option(PosixMode, "aio:posix", "posix mode") orelse .auto;
        aio_opts.addOption(PosixMode, "posix", posix);

        const WasiMode = enum { wasi, wasix };
        const wasi = b.option(WasiMode, "aio:wasi", "wasi mode") orelse .wasi;
        aio_opts.addOption(WasiMode, "wasi", wasi);
    }

    const minilib = b.addModule("minilib", .{
        .root_source_file = b.path("src/minilib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aio = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.query.os_tag orelse builtin.os.tag) {
            .windows => true,
            .freebsd, .openbsd, .dragonfly, .netbsd => true,
            else => false,
        },
    });
    aio.addImport("minilib", minilib);
    aio.addImport("build_options", aio_opts.createModule());

    if (target.query.os_tag orelse builtin.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
            aio.addImport("win32", zigwin32.module("win32"));
        }
    }
}

fn addImportsFrom(dst: *std.Build.Module, src: *std.Build.Module) void {
    var iter = src.import_table.iterator();
    while (iter.next()) |e| dst.addImport(e.key_ptr.*, e.value_ptr.*);
}

const RunStepOptions = struct {
    wasm_max_memory: usize = 1e+9, // 1GiB
};

fn runArtifactForStep(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile, opts: RunStepOptions) *std.Build.Step.Run {
    return switch (target.query.os_tag orelse builtin.os.tag) {
        .wasi => blk: {
            step.max_memory = std.mem.alignForward(usize, opts.wasm_max_memory, 65536);
            const wasmtime = b.addSystemCommand(&.{ "wasmtime", "-W", "trap-on-grow-failure=y", "--dir", ".", "--" });
            wasmtime.addArtifactArg(step);
            break :blk wasmtime;
        },
        else => b.addRunArtifact(step),
    };
}

fn makeRunStep(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile, name: []const u8, description: []const u8, opts: RunStepOptions) *std.Build.Step.Run {
    const cmd = runArtifactForStep(b, target, step, opts);
    if (b.args) |args| cmd.addArgs(args);
    const run = b.step(name, description);
    run.dependOn(&cmd.step);
    return cmd;
}

// All dependencies that are BUILT need to be declared here
// This is to avoid conflicts which will occur when building the same project twice
const Dependencies = struct {
    zigwin32: ?*std.Build.Module,

    debug: bool,
};

pub fn buildModule(
    target_build: *std.Build,
    aio_build: *std.Build,
    dependencies: Dependencies,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) !*std.Build.Module {
    _ = target_build;
    var aio_opts = aio_build.addOptions();
    {
        aio_opts.addOption(bool, "debug", dependencies.debug);

        const PosixMode = enum { auto, force, disable };
        aio_opts.addOption(PosixMode, "posix", PosixMode.auto);

        const WasiMode = enum { wasi, wasix };
        aio_opts.addOption(WasiMode, "wasi", WasiMode.wasi);
    }

    const minilib = aio_build.addModule("minilib", .{
        .root_source_file = aio_build.path("src/minilib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aio = aio_build.addModule("aio", .{
        .root_source_file = aio_build.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.query.os_tag orelse builtin.os.tag) {
            .windows => true,
            .freebsd, .openbsd, .dragonfly, .netbsd => true,
            else => false,
        },
    });
    aio.addImport("minilib", minilib);
    aio.addImport("build_options", aio_opts.createModule());

    if (dependencies.zigwin32) |zw| {
        aio.addImport("win32", zw);
    }

    return aio;
}
