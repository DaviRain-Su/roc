const std = @import("std");
const math = std.math;
const RocList = @import("list.zig").RocList;
const RocStr = @import("str.zig").RocStr;
const utils = @import("utils.zig");
const WithOverflow = utils.WithOverflow;
const Ordering = utils.Ordering;
const roc_panic = @import("panic.zig").panic_help;

pub fn NumParseResult(comptime T: type) type {
    // on the roc side we sort by alignment; putting the errorcode last
    // always works out (no number with smaller alignment than 1)
    return extern struct {
        value: T,
        errorcode: u8, // 0 indicates success
    };
}

pub const F32Parts = extern struct {
    fraction: u32,
    exponent: u8,
    sign: bool,
};

pub const F64Parts = extern struct {
    fraction: u64,
    exponent: u16,
    sign: bool,
};

pub const U256 = struct {
    hi: u128,
    lo: u128,
};

pub fn mul_u128(a: u128, b: u128) U256 {
    var hi: u128 = undefined;
    var lo: u128 = undefined;

    const bits_in_dword_2: u32 = 64;
    const lower_mask: u128 = math.maxInt(u128) >> bits_in_dword_2;

    lo = (a & lower_mask) * (b & lower_mask);

    var t = lo >> bits_in_dword_2;

    lo &= lower_mask;

    t += (a >> bits_in_dword_2) * (b & lower_mask);

    lo += (t & lower_mask) << bits_in_dword_2;

    hi = t >> bits_in_dword_2;

    t = lo >> bits_in_dword_2;

    lo &= lower_mask;

    t += (b >> bits_in_dword_2) * (a & lower_mask);

    lo += (t & lower_mask) << bits_in_dword_2;

    hi += t >> bits_in_dword_2;

    hi += (a >> bits_in_dword_2) * (b >> bits_in_dword_2);

    return .{ .hi = hi, .lo = lo };
}

// Only define exportParseInt for non-SBF targets to avoid pulling in std.fmt
// which contains Writer code with variable-size inline intrinsics
pub const exportParseInt = if (utils.is_solana)
    struct {
        pub fn placeholder(comptime T: type, comptime name: []const u8) void {
            _ = T;
            _ = name;
            @compileError("exportParseInt should not be called for SBF");
        }
    }.placeholder
else
    struct {
        pub fn func(comptime T: type, comptime name: []const u8) void {
            const f = struct {
                fn func(buf: RocStr) callconv(utils.cc) NumParseResult(T) {
                    // a radix of 0 will make zig determine the radix from the frefix:
                    //  * A prefix of "0b" implies radix=2,
                    //  * A prefix of "0o" implies radix=8,
                    //  * A prefix of "0x" implies radix=16,
                    //  * Otherwise radix=10 is assumed.
                    const radix = 0;
                    if (std.fmt.parseInt(T, buf.asSlice(), radix)) |success| {
                        return .{ .errorcode = 0, .value = success };
                    } else |_| {
                        return .{ .errorcode = 1, .value = 0 };
                    }
                }
            }.func;
            @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
        }
    }.func;

// Only define exportParseFloat for non-SBF targets
pub const exportParseFloat = if (utils.is_solana)
    struct {
        pub fn placeholder(comptime T: type, comptime name: []const u8) void {
            _ = T;
            _ = name;
            @compileError("exportParseFloat should not be called for SBF");
        }
    }.placeholder
else
    struct {
        pub fn func(comptime T: type, comptime name: []const u8) void {
            const f = struct {
                fn func(buf: RocStr) callconv(utils.cc) NumParseResult(T) {
                    if (std.fmt.parseFloat(T, buf.asSlice())) |success| {
                        return .{ .errorcode = 0, .value = success };
                    } else |_| {
                        return .{ .errorcode = 1, .value = 0 };
                    }
                }
            }.func;
            @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
        }
    }.func;

// Simple parseInt implementation for SBF that avoids std.fmt (which pulls in Writer with inline intrinsics)
pub fn exportParseIntSbf(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(buf: RocStr) callconv(utils.cc) NumParseResult(T) {
            const slice = buf.asSlice();
            if (slice.len == 0) {
                return .{ .errorcode = 1, .value = 0 };
            }

            var idx: usize = 0;
            var negative = false;
            var radix: u8 = 10;

            // Handle sign
            if (slice[idx] == '-') {
                negative = true;
                idx += 1;
            } else if (slice[idx] == '+') {
                idx += 1;
            }

            if (idx >= slice.len) {
                return .{ .errorcode = 1, .value = 0 };
            }

            // Detect radix prefix
            if (slice.len > idx + 1 and slice[idx] == '0') {
                switch (slice[idx + 1]) {
                    'b', 'B' => {
                        radix = 2;
                        idx += 2;
                    },
                    'o', 'O' => {
                        radix = 8;
                        idx += 2;
                    },
                    'x', 'X' => {
                        radix = 16;
                        idx += 2;
                    },
                    else => {},
                }
            }

            if (idx >= slice.len) {
                return .{ .errorcode = 1, .value = 0 };
            }

            const is_signed = @typeInfo(T).int.signedness == .signed;
            var result: T = 0;

            while (idx < slice.len) : (idx += 1) {
                const c = slice[idx];
                const digit: u8 = if (c >= '0' and c <= '9')
                    c - '0'
                else if (c >= 'a' and c <= 'f')
                    c - 'a' + 10
                else if (c >= 'A' and c <= 'F')
                    c - 'A' + 10
                else
                    return .{ .errorcode = 1, .value = 0 };

                if (digit >= radix) {
                    return .{ .errorcode = 1, .value = 0 };
                }

                // Check for overflow - use intCast which will fail at comptime if radix > max(T)
                // but radix is always 2, 8, 10, or 16 which fits in any integer type we support
                const mul_result = @mulWithOverflow(result, @as(T, @intCast(radix)));
                if (mul_result[1] == 1) {
                    return .{ .errorcode = 1, .value = 0 };
                }
                const add_result = @addWithOverflow(mul_result[0], @as(T, @intCast(digit)));
                if (add_result[1] == 1) {
                    return .{ .errorcode = 1, .value = 0 };
                }
                result = add_result[0];
            }

            if (negative) {
                if (is_signed) {
                    const neg_result = @subWithOverflow(@as(T, 0), result);
                    if (neg_result[1] == 1) {
                        return .{ .errorcode = 1, .value = 0 };
                    }
                    return .{ .errorcode = 0, .value = neg_result[0] };
                } else {
                    return .{ .errorcode = 1, .value = 0 };
                }
            }

            return .{ .errorcode = 0, .value = result };
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

// Simple parseFloat implementation for SBF that avoids std.fmt
// This is a very basic implementation - for Solana programs, float parsing is rarely needed
pub fn exportParseFloatSbf(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(buf: RocStr) callconv(utils.cc) NumParseResult(T) {
            const slice = buf.asSlice();
            if (slice.len == 0) {
                return .{ .errorcode = 1, .value = 0 };
            }

            var idx: usize = 0;
            var negative = false;

            // Handle sign
            if (slice[idx] == '-') {
                negative = true;
                idx += 1;
            } else if (slice[idx] == '+') {
                idx += 1;
            }

            if (idx >= slice.len) {
                return .{ .errorcode = 1, .value = 0 };
            }

            var integer_part: i64 = 0;
            var fraction_part: i64 = 0;
            var fraction_digits: u32 = 0;
            var in_fraction = false;

            while (idx < slice.len) : (idx += 1) {
                const c = slice[idx];
                if (c == '.') {
                    if (in_fraction) {
                        return .{ .errorcode = 1, .value = 0 };
                    }
                    in_fraction = true;
                    continue;
                }
                if (c == 'e' or c == 'E') {
                    // Exponent not supported in simple implementation
                    return .{ .errorcode = 1, .value = 0 };
                }
                if (c < '0' or c > '9') {
                    return .{ .errorcode = 1, .value = 0 };
                }
                const digit: i64 = c - '0';
                if (in_fraction) {
                    if (fraction_digits < 18) { // Limit precision
                        fraction_part = fraction_part * 10 + digit;
                        fraction_digits += 1;
                    }
                } else {
                    integer_part = integer_part * 10 + digit;
                }
            }

            var result: T = @floatFromInt(integer_part);

            if (fraction_digits > 0) {
                var divisor: T = 1.0;
                var i: u32 = 0;
                while (i < fraction_digits) : (i += 1) {
                    divisor *= 10.0;
                }
                result += @as(T, @floatFromInt(fraction_part)) / divisor;
            }

            if (negative) {
                result = -result;
            }

            return .{ .errorcode = 0, .value = result };
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportNumToFloatCast(comptime T: type, comptime F: type, comptime name: []const u8) void {
    const f = struct {
        fn func(x: T) callconv(utils.cc) F {
            return @floatFromInt(x);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportPow(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(base: T, exp: T) callconv(utils.cc) T {
            switch (@typeInfo(T)) {
                // std.math.pow can handle ints via powi, but it turns any errors to unreachable
                // we want to catch overflow and report a proper error to the user
                .int => {
                    if (std.math.powi(T, base, exp)) |value| {
                        return value;
                    } else |err| switch (err) {
                        error.Overflow => roc_panic("Integer raised to power overflowed!", 0),
                        error.Underflow => return 0,
                    }
                },
                else => {
                    return std.math.pow(T, base, exp);
                },
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportIsNan(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) bool {
            return std.math.isNan(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportIsInfinite(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) bool {
            return std.math.isInf(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportIsFinite(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) bool {
            return std.math.isFinite(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAsin(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return std.math.asin(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAcos(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return std.math.acos(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAtan(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return std.math.atan(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportSin(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return math.sin(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportCos(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return math.cos(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportTan(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return math.tan(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportLog(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return @log(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportFAbs(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return @abs(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportSqrt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: T) callconv(utils.cc) T {
            return math.sqrt(input);
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportRound(comptime F: type, comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: F) callconv(utils.cc) T {
            return @as(T, @intFromFloat((math.round(input))));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportFloor(comptime F: type, comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: F) callconv(utils.cc) T {
            return @as(T, @intFromFloat((math.floor(input))));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportCeiling(comptime F: type, comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: F) callconv(utils.cc) T {
            return @as(T, @intFromFloat((math.ceil(input))));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportDivCeil(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(a: T, b: T) callconv(utils.cc) T {
            return math.divCeil(T, a, b) catch {
                roc_panic("Integer division by 0!", 0);
            };
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn ToIntCheckedResult(comptime T: type) type {
    // On the Roc side we sort by alignment; putting the errorcode last
    // always works out (no number with smaller alignment than 1).
    return extern struct {
        value: T,
        out_of_bounds: bool,
    };
}

pub fn exportToIntCheckingMax(comptime From: type, comptime To: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: From) callconv(utils.cc) ToIntCheckedResult(To) {
            if (input > std.math.maxInt(To)) {
                return .{ .out_of_bounds = true, .value = 0 };
            }
            return .{ .out_of_bounds = false, .value = @as(To, @intCast(input)) };
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(From), .linkage = .strong });
}

pub fn exportToIntCheckingMaxAndMin(comptime From: type, comptime To: type, comptime name: []const u8) void {
    const f = struct {
        fn func(input: From) callconv(utils.cc) ToIntCheckedResult(To) {
            if (input > std.math.maxInt(To) or input < std.math.minInt(To)) {
                return .{ .out_of_bounds = true, .value = 0 };
            }
            return .{ .out_of_bounds = false, .value = @as(To, @intCast(input)) };
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(From), .linkage = .strong });
}

fn isMultipleOf(comptime T: type, lhs: T, rhs: T) bool {
    if (rhs == 0 or rhs == -1) {
        // lhs is a multiple of rhs iff
        //
        // - rhs == -1
        // - both rhs and lhs are 0
        //
        // the -1 case is important for overflow reasons `isize::MIN % -1` crashes in rust
        return (rhs == -1) or (lhs == 0);
    } else {
        const rem = @mod(lhs, rhs);
        return rem == 0;
    }
}

pub fn exportIsMultipleOf(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) bool {
            return @call(.always_inline, isMultipleOf, .{ T, self, other });
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

fn addWithOverflow(comptime T: type, self: T, other: T) WithOverflow(T) {
    switch (@typeInfo(T)) {
        .int => {
            const answer = @addWithOverflow(self, other);
            return .{ .value = answer[0], .has_overflowed = answer[1] == 1 };
        },
        else => {
            const answer = self + other;
            const overflowed = !std.math.isFinite(answer);
            return .{ .value = answer, .has_overflowed = overflowed };
        },
    }
}

pub fn exportAddWithOverflow(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) WithOverflow(T) {
            return @call(.always_inline, addWithOverflow, .{ T, self, other });
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAddSaturatedInt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = addWithOverflow(T, self, other);
            if (result.has_overflowed) {
                // We can unambiguously tell which way it wrapped, because we have N+1 bits including the overflow bit
                if (result.value >= 0 and @typeInfo(T).int.signedness == .signed) {
                    return std.math.minInt(T);
                } else {
                    return std.math.maxInt(T);
                }
            } else {
                return result.value;
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAddWrappedInt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            return self +% other;
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportAddOrPanic(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = addWithOverflow(T, self, other);
            if (result.has_overflowed) {
                roc_panic("Integer addition overflowed!", 0);
            } else {
                return result.value;
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

fn subWithOverflow(comptime T: type, self: T, other: T) WithOverflow(T) {
    switch (@typeInfo(T)) {
        .int => {
            const answer = @subWithOverflow(self, other);
            return .{ .value = answer[0], .has_overflowed = answer[1] == 1 };
        },
        else => {
            const answer = self - other;
            const overflowed = !std.math.isFinite(answer);
            return .{ .value = answer, .has_overflowed = overflowed };
        },
    }
}

pub fn exportSubWithOverflow(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) WithOverflow(T) {
            return @call(.always_inline, subWithOverflow, .{ T, self, other });
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportSubSaturatedInt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = subWithOverflow(T, self, other);
            if (result.has_overflowed) {
                if (@typeInfo(T).int.signedness == .unsigned) {
                    return 0;
                } else if (self < 0) {
                    return std.math.minInt(T);
                } else {
                    return std.math.maxInt(T);
                }
            } else {
                return result.value;
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportSubWrappedInt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            return self -% other;
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportSubOrPanic(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = subWithOverflow(T, self, other);
            if (result.has_overflowed) {
                roc_panic("Integer subtraction overflowed!", 0);
            } else {
                return result.value;
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

fn mulWithOverflow(comptime T: type, comptime W: type, self: T, other: T) WithOverflow(T) {
    switch (@typeInfo(T)) {
        .int => {
            if (T == i128) {
                const is_answer_negative = (self < 0) != (other < 0);
                const max = std.math.maxInt(i128);
                const min = std.math.minInt(i128);

                const self_u128 = @abs(self);
                if (self_u128 > @as(u128, @intCast(std.math.maxInt(i128)))) {
                    if (other == 0) {
                        return .{ .value = 0, .has_overflowed = false };
                    } else if (other == 1) {
                        return .{ .value = self, .has_overflowed = false };
                    } else if (is_answer_negative) {
                        return .{ .value = min, .has_overflowed = true };
                    } else {
                        return .{ .value = max, .has_overflowed = true };
                    }
                }

                const other_u128 = @abs(other);
                if (other_u128 > @as(u128, @intCast(std.math.maxInt(i128)))) {
                    if (self == 0) {
                        return .{ .value = 0, .has_overflowed = false };
                    } else if (self == 1) {
                        return .{ .value = other, .has_overflowed = false };
                    } else if (is_answer_negative) {
                        return .{ .value = min, .has_overflowed = true };
                    } else {
                        return .{ .value = max, .has_overflowed = true };
                    }
                }

                const answer256: U256 = mul_u128(self_u128, other_u128);

                if (is_answer_negative) {
                    if (answer256.hi != 0 or answer256.lo > (1 << 127)) {
                        return .{ .value = min, .has_overflowed = true };
                    } else if (answer256.lo == (1 << 127)) {
                        return .{ .value = min, .has_overflowed = false };
                    } else {
                        return .{ .value = -@as(i128, @intCast(answer256.lo)), .has_overflowed = false };
                    }
                } else {
                    if (answer256.hi != 0 or answer256.lo > @as(u128, @intCast(max))) {
                        return .{ .value = max, .has_overflowed = true };
                    } else {
                        return .{ .value = @as(i128, @intCast(answer256.lo)), .has_overflowed = false };
                    }
                }
            } else {
                const self_wide: W = self;
                const other_wide: W = other;
                const answer: W = self_wide * other_wide;

                const max: W = std.math.maxInt(T);
                const min: W = std.math.minInt(T);

                if (answer > max) {
                    return .{ .value = max, .has_overflowed = true };
                } else if (answer < min) {
                    return .{ .value = min, .has_overflowed = true };
                } else {
                    return .{ .value = @as(T, @intCast(answer)), .has_overflowed = false };
                }
            }
        },
        else => {
            const answer = self * other;
            const overflowed = !std.math.isFinite(answer);
            return .{ .value = answer, .has_overflowed = overflowed };
        },
    }
}

pub fn exportMulWithOverflow(comptime T: type, comptime W: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) WithOverflow(T) {
            return @call(.always_inline, mulWithOverflow, .{ T, W, self, other });
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportMulSaturatedInt(comptime T: type, comptime W: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = @call(.always_inline, mulWithOverflow, .{ T, W, self, other });
            return result.value;
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportMulWrappedInt(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            return self *% other;
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn shiftRightZeroFillI128(self: i128, other: u8) callconv(utils.cc) i128 {
    if (other & 0b1000_0000 > 0) {
        return 0;
    } else {
        return self >> @as(u7, @intCast(other));
    }
}

pub fn shiftRightZeroFillU128(self: u128, other: u8) callconv(utils.cc) u128 {
    if (other & 0b1000_0000 > 0) {
        return 0;
    } else {
        return self >> @as(u7, @intCast(other));
    }
}

pub fn compareI128(self: i128, other: i128) callconv(utils.cc) Ordering {
    if (self == other) {
        return Ordering.EQ;
    } else if (self < other) {
        return Ordering.LT;
    } else {
        return Ordering.GT;
    }
}

pub fn compareU128(self: u128, other: u128) callconv(utils.cc) Ordering {
    if (self == other) {
        return Ordering.EQ;
    } else if (self < other) {
        return Ordering.LT;
    } else {
        return Ordering.GT;
    }
}

pub fn lessThanI128(self: i128, other: i128) callconv(utils.cc) bool {
    return self < other;
}

pub fn lessThanOrEqualI128(self: i128, other: i128) callconv(utils.cc) bool {
    return self <= other;
}

pub fn greaterThanI128(self: i128, other: i128) callconv(utils.cc) bool {
    return self > other;
}

pub fn greaterThanOrEqualI128(self: i128, other: i128) callconv(utils.cc) bool {
    return self >= other;
}

pub fn lessThanU128(self: u128, other: u128) callconv(utils.cc) bool {
    return self < other;
}

pub fn lessThanOrEqualU128(self: u128, other: u128) callconv(utils.cc) bool {
    return self <= other;
}

pub fn greaterThanU128(self: u128, other: u128) callconv(utils.cc) bool {
    return self > other;
}

pub fn greaterThanOrEqualU128(self: u128, other: u128) callconv(utils.cc) bool {
    return self >= other;
}

pub fn exportMulOrPanic(comptime T: type, comptime W: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T, other: T) callconv(utils.cc) T {
            const result = @call(.always_inline, mulWithOverflow, .{ T, W, self, other });
            if (result.has_overflowed) {
                roc_panic("Integer multiplication overflowed!", 0);
            } else {
                return result.value;
            }
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportCountLeadingZeroBits(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T) callconv(utils.cc) u8 {
            return @as(u8, @clz(self));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportCountTrailingZeroBits(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T) callconv(utils.cc) u8 {
            return @as(u8, @ctz(self));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn exportCountOneBits(comptime T: type, comptime name: []const u8) void {
    const f = struct {
        fn func(self: T) callconv(utils.cc) u8 {
            return @as(u8, @popCount(self));
        }
    }.func;
    @export(&f, .{ .name = name ++ @typeName(T), .linkage = .strong });
}

pub fn f32ToParts(self: f32) callconv(utils.cc) F32Parts {
    const u32Value = @as(u32, @bitCast(self));
    return F32Parts{
        .fraction = u32Value & 0x7fffff,
        .exponent = @truncate(u32Value >> 23 & 0xff),
        .sign = u32Value >> 31 & 1 == 1,
    };
}

pub fn f64ToParts(self: f64) callconv(utils.cc) F64Parts {
    const u64Value = @as(u64, @bitCast(self));
    return F64Parts{
        .fraction = u64Value & 0xfffffffffffff,
        .exponent = @truncate(u64Value >> 52 & 0x7ff),
        .sign = u64Value >> 63 & 1 == 1,
    };
}

pub fn f32FromParts(parts: F32Parts) callconv(utils.cc) f32 {
    return @as(f32, @bitCast(parts.fraction & 0x7fffff | (@as(u32, parts.exponent) << 23) | (@as(u32, @intFromBool(parts.sign)) << 31)));
}

pub fn f64FromParts(parts: F64Parts) callconv(utils.cc) f64 {
    return @as(f64, @bitCast(parts.fraction & 0xfffffffffffff | (@as(u64, parts.exponent & 0x7ff) << 52) | (@as(u64, @intFromBool(parts.sign)) << 63)));
}

pub fn f32ToBits(self: f32) callconv(utils.cc) u32 {
    return @as(u32, @bitCast(self));
}

pub fn f64ToBits(self: f64) callconv(utils.cc) u64 {
    return @as(u64, @bitCast(self));
}

pub fn i128ToBits(self: i128) callconv(utils.cc) u128 {
    return @as(u128, @bitCast(self));
}

pub fn f32FromBits(bits: u32) callconv(utils.cc) f32 {
    return @as(f32, @bitCast(bits));
}

pub fn f64FromBits(bits: u64) callconv(utils.cc) f64 {
    return @as(f64, @bitCast(bits));
}

pub fn i128FromBits(bits: u128) callconv(utils.cc) i128 {
    return @as(i128, @bitCast(bits));
}
