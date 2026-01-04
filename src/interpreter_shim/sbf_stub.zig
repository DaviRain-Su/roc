//! Minimal stub for SBF/Solana target
//!
//! Solana programs run compiled code, not interpreted.
//! This file provides the minimal exports needed to satisfy the linker
//! when building Roc applications for Solana.
//!
//! The platform shim calls roc_entrypoint which dispatches to the compiled Roc functions.

const std = @import("std");

// RocStr ABI - must match what the Roc compiler generates
const RocStr = extern struct {
    bytes: ?[*]const u8,
    length: u32,
    capacity: u32,

    pub fn asSlice(self: *const RocStr) []const u8 {
        if (self.bytes) |ptr| {
            return ptr[0..@as(usize, self.length)];
        }
        return &[_]u8{};
    }
};

// STUB: For now, provide a hardcoded implementation
// TODO: Once Roc supports native SBF code generation, this should be:
// extern fn roc__main_for_host_1_exposed_generic(output: *RocStr) callconv(.c) void;
//
// Currently Roc generates serialized IR for interpretation, not native code.
// This stub allows testing the Solana pipeline while native codegen is being developed.
//
// NOTE: The message below is intentionally different from app.roc to distinguish
// stub output from actual Roc-compiled code. When you see this message, it means
// the stub is being used, not the actual Roc application code.
const stub_message = "[STUB] Roc SBF pipeline works - awaiting native codegen";

export fn roc__main_for_host_1_exposed_generic(output: *RocStr) callconv(.c) void {
    output.* = RocStr{
        .bytes = stub_message.ptr,
        .length = @intCast(stub_message.len),
        .capacity = @intCast(stub_message.len),
    };
}

// External: Solana log syscall (provided by Solana runtime)
extern fn sol_log_(message: [*]const u8, len: u64) callconv(.c) void;

/// roc_entrypoint - Called by the platform shim to execute the Roc program
/// This is the bridge between the platform shim and the compiled Roc code.
///
/// For Solana, we:
/// 1. Call the Roc main function to get the string
/// 2. Log it to the Solana program log
export fn roc_entrypoint(
    entry_idx: i32,
    ops: ?*anyopaque,
    ret_ptr: ?*anyopaque,
    arg_ptr: ?*anyopaque,
) callconv(.c) void {
    // Ignore unused parameters (interpreter-style ABI)
    _ = entry_idx;
    _ = ops;
    _ = ret_ptr;
    _ = arg_ptr;

    // Call the Roc main function
    var result: RocStr = .{ .bytes = null, .length = 0, .capacity = 0 };
    roc__main_for_host_1_exposed_generic(&result);

    // Log the result to Solana
    const slice = result.asSlice();
    sol_log_(slice.ptr, slice.len);
}

// Minimal exports for SBF target - Solana programs don't use the interpreter
export fn roc__mainForHost() void {
    // Stub - actual main is provided by the compiled Roc application
}

// Roc memory functions - these will be provided by the platform host
pub extern fn roc_alloc(size: usize, alignment: u32) ?[*]u8;
pub extern fn roc_realloc(ptr: [*]u8, new_size: usize, old_size: usize, alignment: u32) ?[*]u8;
pub extern fn roc_dealloc(ptr: [*]u8, alignment: u32) void;
pub extern fn roc_panic(msg: [*]const u8, tag_id: u32) noreturn;

// Minimal compiler-rt support is bundled via the build system
