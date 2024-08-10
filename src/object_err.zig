const std = @import("std");

const Kind = @import("object.zig").Kind;

pub const ObjectErr = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    len: usize,

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectErr) + _len, 4);
    }

    pub fn hash(objerr: *ObjectErr, level: u64) u64 {
        const seed = 11400714819323198393 *% (level + 1);
        return std.hash.XxHash3.hash(seed ^ 15882555672276140117, objerr.slice());
    }

    pub fn data(objerr: *ObjectErr) [*]u8 {
        return @ptrFromInt(@intFromPtr(&objerr.len) + @sizeOf(usize));
    }

    pub fn slice(objerr: *ObjectErr) []const u8 {
        return objerr.data()[0..objerr.len];
    }
};
