//! Minimal SBF builtins for Roc on Solana
//!
//! These are stripped-down builtins that don't use any std lib features
//! that are unavailable on Solana (threads, posix, file I/O, etc.)
//!
//! Most actual functionality is provided by the Zig host.

const builtin = @import("builtin");

// Verify we're compiling for SBF
comptime {
    if (builtin.cpu.arch != .sbf) {
        @compileError("This file should only be compiled for SBF target");
    }
}

// Use BPF calling convention for SBF
const cc: std.builtin.CallingConvention = .{ .bpf_std = .{} };

// ============================================================================
// Memory operations - these are provided by the host, we just declare them
// ============================================================================

// Note: On Solana, memory allocation is handled by the host through
// roc_alloc, roc_realloc, roc_dealloc which are provided by the Zig host.

// ============================================================================
// Basic numeric operations
// ============================================================================

export fn @"roc_builtins.num.add_i64"(a: i64, b: i64) callconv(cc) i64 {
    return a +% b;
}

export fn @"roc_builtins.num.sub_i64"(a: i64, b: i64) callconv(cc) i64 {
    return a -% b;
}

export fn @"roc_builtins.num.mul_i64"(a: i64, b: i64) callconv(cc) i64 {
    return a *% b;
}

export fn @"roc_builtins.num.add_u64"(a: u64, b: u64) callconv(cc) u64 {
    return a +% b;
}

export fn @"roc_builtins.num.sub_u64"(a: u64, b: u64) callconv(cc) u64 {
    return a -% b;
}

export fn @"roc_builtins.num.mul_u64"(a: u64, b: u64) callconv(cc) u64 {
    return a *% b;
}

// ============================================================================
// Memory copy/set operations (inline implementations)
// ============================================================================

export fn @"roc_builtins.utils.memcpy"(dest: [*]u8, src: [*]const u8, len: usize) callconv(cc) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

export fn @"roc_builtins.utils.memset"(dest: [*]u8, value: u8, len: usize) callconv(cc) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = value;
    }
    return dest;
}

// ============================================================================
// Placeholder stubs for string/list operations
// These will be replaced or provided by the host
// ============================================================================

export fn @"roc_builtins.str.init"() callconv(cc) void {}
export fn @"roc_builtins.list.init"() callconv(cc) void {}

// Need std for CallingConvention type
const std = @import("std");
