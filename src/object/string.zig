const std = @import("std");
const Object = @import("../object.zig").Object;

pub const ObjectString = extern struct {
    head: Object,
    len: usize,

    pub fn hash(string: *ObjectString, seed: u64) u64 {
        return std.hash.XxHash3.hash(seed, string.data()[0..string.len]);
    }

    pub fn data(string: *ObjectString) [*]u8 {
        return @ptrFromInt(@intFromPtr(&string.len) + 8);
    }

    pub fn size(len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectString) + @sizeOf(u8) * len, 4);
    }
};
