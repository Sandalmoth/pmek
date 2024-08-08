const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;

pub const ObjectCons = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    car: ?*Object,
    cdr: ?*Object,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectCons), 4);
    }
};
