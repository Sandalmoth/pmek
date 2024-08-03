const std = @import("std");
const Object = @import("../object.zig").Object;

pub const ObjectCons = extern struct {
    head: Object,
    car: std.atomic.Value(?*Object),
    cdr: std.atomic.Value(?*Object),

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectCons), 4);
    }
};
