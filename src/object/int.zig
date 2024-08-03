const std = @import("std");
const Object = @import("../object.zig").Object;

pub const ObjectInt = extern struct {
    head: Object,
    data: i64,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectInt), 4);
    }
};
