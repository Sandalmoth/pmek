const std = @import("std");

const Kind = @import("object.zig").Kind;

pub const ObjectString = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    len: usize,

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectString) + _len, 4);
    }

    pub fn hash(objstring: *ObjectString, level: u64) u64 {
        const seed = 11400714819323198393 *% (level + 1);
        return std.hash.XxHash3.hash(seed, objstring.slice());
    }

    pub fn data(objstring: *ObjectString) [*]u8 {
        return @ptrFromInt(@intFromPtr(&objstring.len) + @sizeOf(usize));
    }

    pub fn slice(objstring: *ObjectString) []const u8 {
        return objstring.data()[0..objstring.len];
    }
};
