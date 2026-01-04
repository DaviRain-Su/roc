const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const LazyPath = Build.LazyPath;

// Check if this Zig build supports SBF target (solana-zig)
const has_sbf_support = @hasField(std.Target.Cpu.Arch, "sbf");

pub fn build(b: *Build) void {
    const mode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const main_path = b.path("src/main.zig");

    // Targets
    const host_target = b.resolveTargetQuery(.{
        .cpu_model = .baseline,
        .os_tag = builtin.os.tag,
    });

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = main_path,
        .target = host_target,
    });
    test_module.linkSystemLibrary("c", .{});
    const main_tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
    const linux32_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .linux,
        .abi = .none,
    });
    const linux_x64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .none,
    });
    const linux_aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .none,
    });
    const windows64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .none,
    });
    const wasm32_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // LLVM IR
    generateLlvmIrFile(b, mode, host_target, main_path, "ir", "builtins-host");
    generateLlvmIrFile(b, mode, linux32_target, main_path, "ir-x86", "builtins-x86");
    generateLlvmIrFile(b, mode, linux_x64_target, main_path, "ir-x86_64", "builtins-x86_64");
    generateLlvmIrFile(b, mode, linux_aarch64_target, main_path, "ir-aarch64", "builtins-aarch64");
    generateLlvmIrFile(b, mode, windows64_target, main_path, "ir-windows-x86_64", "builtins-windows-x86_64");
    generateLlvmIrFile(b, mode, wasm32_target, main_path, "ir-wasm32", "builtins-wasm32");

    // Generate Object Files
    generateObjectFile(b, mode, host_target, main_path, "object", "builtins-host");
    generateObjectFile(b, mode, windows64_target, main_path, "windows-x86_64-object", "builtins-windows-x86_64");
    generateObjectFile(b, mode, wasm32_target, main_path, "wasm32-object", "builtins-wasm32");

    // SBF target (only available with solana-zig)
    // Note: SBF builtins must be built separately using solana-zig
    // Use: ./solana-zig/zig build ir-sbf
    if (has_sbf_support) {
        generateSbfBuiltins(b, mode);
    }
}

fn generateSbfBuiltins(b: *Build, mode: std.builtin.OptimizeMode) void {
    if (!has_sbf_support) return;

    const sbf_target = b.resolveTargetQuery(.{
        .cpu_arch = .sbf,
        .os_tag = .solana,
        .abi = .none,
    });
    // Using full main.zig with conditional compilation for SBF
    // sort.zig is excluded via conditional import in list.zig (Solana has 4KB stack limit)
    const sbf_main_path = b.path("src/main.zig");
    generateLlvmIrFileSbf(b, mode, sbf_target, sbf_main_path, "ir-sbf", "builtins-sbf");
    generateObjectFileSbf(b, mode, sbf_target, sbf_main_path, "sbf-object", "builtins-sbf");
}

fn generateLlvmIrFile(
    b: *Build,
    mode: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    main_path: LazyPath,
    step_name: []const u8,
    object_name: []const u8,
) void {
    const is_wasm = target.result.cpu.arch == .wasm32;

    const obj_module = b.createModule(.{
        .root_source_file = main_path,
        .optimize = mode,
        .target = target,
        .pic = if (is_wasm) null else true,
        .strip = true,
        .stack_check = false,
    });

    const obj = b.addObject(.{
        .name = object_name,
        .root_module = obj_module,
        .use_llvm = true,
    });

    if (!is_wasm)
        obj.bundle_compiler_rt = true;

    _ = obj.getEmittedBin();
    const ir_file = obj.getEmittedLlvmIr();
    const bc_file = obj.getEmittedLlvmBc();
    const install_ir = b.addInstallFile(ir_file, b.fmt("{s}.ll", .{object_name}));
    const install_bc = b.addInstallFile(bc_file, b.fmt("{s}.bc", .{object_name}));

    const ir = b.step(step_name, "Build LLVM ir");
    ir.dependOn(&install_ir.step);
    ir.dependOn(&install_bc.step);
    b.getInstallStep().dependOn(ir);
}

fn generateObjectFile(
    b: *Build,
    mode: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    main_path: LazyPath,
    step_name: []const u8,
    object_name: []const u8,
) void {
    const is_wasm = target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64;

    const obj_module = b.createModule(.{
        .root_source_file = main_path,
        .optimize = mode,
        .target = target,
        .pic = if (is_wasm) null else true,
        .strip = true,
        .stack_check = false,
    });

    const obj = b.addObject(.{
        .name = object_name,
        .root_module = obj_module,
        .use_llvm = true,
    });

    obj.link_function_sections = true;

    if (!is_wasm)
        obj.bundle_compiler_rt = true;

    const obj_file = obj.getEmittedBin();

    const suffix = if (target.result.os.tag == .windows) "obj" else "o";
    const install = b.addInstallFile(obj_file, b.fmt("{s}.{s}", .{ object_name, suffix }));

    const obj_step = b.step(step_name, "Build object file for linking");
    obj_step.dependOn(&obj.step);
    obj_step.dependOn(&install.step);
    b.getInstallStep().dependOn(obj_step);
}

// SBF-specific versions that are only compiled when SBF is supported
fn generateLlvmIrFileSbf(
    b: *Build,
    mode: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    main_path: LazyPath,
    step_name: []const u8,
    object_name: []const u8,
) void {
    if (!has_sbf_support) return;

    const obj_module = b.createModule(.{
        .root_source_file = main_path,
        .optimize = mode,
        .target = target,
        .pic = null, // SBF doesn't use PIC
        .strip = true,
        .stack_check = false,
    });

    const obj = b.addObject(.{
        .name = object_name,
        .root_module = obj_module,
        .use_llvm = true,
    });

    // No compiler_rt for SBF

    _ = obj.getEmittedBin();
    const ir_file = obj.getEmittedLlvmIr();
    const bc_file = obj.getEmittedLlvmBc();
    const install_ir = b.addInstallFile(ir_file, b.fmt("{s}.ll", .{object_name}));
    const install_bc = b.addInstallFile(bc_file, b.fmt("{s}.bc", .{object_name}));

    const ir = b.step(step_name, "Build LLVM ir");
    ir.dependOn(&install_ir.step);
    ir.dependOn(&install_bc.step);
    b.getInstallStep().dependOn(ir);
}

fn generateObjectFileSbf(
    b: *Build,
    mode: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    main_path: LazyPath,
    step_name: []const u8,
    object_name: []const u8,
) void {
    if (!has_sbf_support) return;

    const obj_module = b.createModule(.{
        .root_source_file = main_path,
        .optimize = mode,
        .target = target,
        .pic = null, // SBF doesn't use PIC
        .strip = true,
        .stack_check = false,
    });

    const obj = b.addObject(.{
        .name = object_name,
        .root_module = obj_module,
        .use_llvm = true,
    });

    obj.link_function_sections = true;
    // No compiler_rt for SBF

    const obj_file = obj.getEmittedBin();

    const install = b.addInstallFile(obj_file, b.fmt("{s}.o", .{object_name}));

    const obj_step = b.step(step_name, "Build object file for linking");
    obj_step.dependOn(&obj.step);
    obj_step.dependOn(&install.step);
    b.getInstallStep().dependOn(obj_step);
}
