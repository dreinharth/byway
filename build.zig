const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("byway", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludeDir("protocol");
    exe.addIncludeDir(".");

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("wlroots");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("pixman-1");
    exe.install();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    const protocols_dir = "$(pkg-config --variable=pkgdatadir wayland-protocols)";
    const wayland_scanner = "$(pkg-config --variable=wayland_scanner wayland-scanner)";
    const server_header = "server-header";
    const fmt_str = "{s} {s} {s}{s} {s}";

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const xdg_proto = try std.fmt.allocPrint(alloc, fmt_str, .{
        wayland_scanner,
        server_header,
        protocols_dir,
        "/stable/xdg-shell/xdg-shell.xml",
        "xdg-shell-protocol.h",
    });
    defer alloc.free(xdg_proto);

    const wlr_proto = try std.fmt.allocPrint(alloc, fmt_str, .{
        wayland_scanner,
        server_header,
        "protocol",
        "/wlr-layer-shell-unstable-v1.xml",
        "wlr-layer-shell-unstable-v1-protocol.h",
    });
    defer alloc.free(wlr_proto);

    exe.step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", xdg_proto }).step);
    exe.step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", wlr_proto }).step);

    const run_step = b.step("run", "Run Byway");
    run_step.dependOn(&run_cmd.step);
}
