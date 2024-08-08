const std = @import("std");

const Kind = @import("object.zig").Kind;

pub const ObjectReal = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    val: f64,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectReal), 4);
    }
};
