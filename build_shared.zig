const std = @import("std");

/// All shared (platform-independent) modules, passed into platform build functions.
pub const SharedModules = struct {
    build_options: *std.Build.Module,
    input_protocol: *std.Build.Module,
    osc_parser: *std.Build.Module,
    viewer_state: *std.Build.Module,
    ivf: *std.Build.Module,
    session: *std.Build.Module,
    session_recorder: *std.Build.Module,
    encoder: *std.Build.Module,
    codec: *std.Build.Module,
    terminal_share: *std.Build.Module,
    debounce: *std.Build.Module,
    clock: *std.Build.Module,
    control: *std.Build.Module,
    yuv: *std.Build.Module,
    svt_backend: *std.Build.Module,
};

/// Platform-specific modules returned by platform build functions.
pub const PlatformModules = struct {
    app_share: *std.Build.Module,
    gpu_detect: ?*std.Build.Module = null,
    compositor: ?*std.Build.Module = null,
};

/// Link libdatachannel and its static dependencies into an artifact.
/// Shared across the main binary and all test artifacts that transitively
/// depend on session.zig (which uses the libdatachannel C API).
pub fn linkDatachannel(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addObjectFile(b.path(".zig-cache/cmake/libdatachannel.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/libjuice/libjuice.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/libsrtp/libsrtp2.a"));
    artifact.addObjectFile(b.path(".zig-cache/cmake/deps/usrsctp/usrsctplib/libusrsctp.a"));
    artifact.linkSystemLibrary("ssl");
    artifact.linkSystemLibrary("crypto");
    artifact.linkLibCpp();
}

/// Configure cmake to build libdatachannel as a static lib via the project's
/// zig-cc shim. Produces .zig-cache/cmake/libdatachannel.a + dep archives.
pub fn buildLibdatachannelStep(b: *std.Build) *std.Build.Step {
    const cmake_build_dir = ".zig-cache/cmake";
    const zig_cc_path = b.pathJoin(&.{ b.build_root.path orelse ".", ".zig-cache/bin/zig-cc" });
    const zig_cxx_path = b.pathJoin(&.{ b.build_root.path orelse ".", ".zig-cache/bin/zig-c++" });

    const configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "packages/libdatachannel",
        "-B",
        cmake_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DNO_EXAMPLES=ON",
        "-DNO_TESTS=ON",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    });
    configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s}", .{zig_cc_path}));
    configure.addArg(b.fmt("-DCMAKE_CXX_COMPILER={s}", .{zig_cxx_path}));

    const compile = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "--parallel",
    });
    compile.step.dependOn(&configure.step);
    return &compile.step;
}

/// Configure cmake to build SVT-AV1 (pure-C, no NASM) as a static lib via
/// zig-cc. Produces packages/svt-av1/Bin/Release/libSvtAv1Enc.a.
pub fn buildSvtAv1Step(b: *std.Build) *std.Build.Step {
    const svt_build_dir = ".zig-cache/cmake-svt";
    const zig_cc_path = b.pathJoin(&.{ b.build_root.path orelse ".", ".zig-cache/bin/zig-cc" });

    const configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "packages/svt-av1",
        "-B",
        svt_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_APPS=OFF",
        "-DBUILD_ENC=OFF",
        "-DBUILD_DEC=OFF",
        "-DBUILD_TESTING=OFF",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        // Pure-C build (no NASM/yasm assembler required). Slower than the
        // optimized asm path but portable and adequate for a software-fallback
        // encoder primarily used for GPU-free tests.
        "-DCOMPILE_C_ONLY=ON",
        // Zig cc treats -Wdate-time as an error by default; SVT-AV1's
        // enc_handle.c uses __DATE__/__TIME__. Suppress to compile clean.
        "-DCMAKE_C_FLAGS=-Wno-date-time",
    });
    configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s}", .{zig_cc_path}));

    const compile = b.addSystemCommand(&.{
        "cmake",
        "--build",
        svt_build_dir,
        "--config",
        "Release",
        "--target",
        "SvtAv1Enc",
        "--parallel",
    });
    compile.step.dependOn(&configure.step);
    return &compile.step;
}
