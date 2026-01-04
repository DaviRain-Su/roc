const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const RocStr = @import("str.zig").RocStr;

// An optional debug impl to be called during `roc test`
pub fn dbg_impl(loc: *const RocStr, msg: *const RocStr, src: *const RocStr) callconv(utils.cc) void {
    // On wasm32 and Solana, std.debug.print is not available
    if (builtin.target.cpu.arch != .wasm32 and !utils.is_solana) {
        // Use std.debug.print for Zig 0.15 compatibility
        std.debug.print("[{s}] {s} = {s}\n", .{ loc.asSlice(), src.asSlice(), msg.asSlice() });
    }
}
