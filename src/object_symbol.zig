const std = @import("std");

const Kind = @import("object.zig").Kind;

// symbols should probably be interned in any proper language implementation...

pub const ObjectSymbol = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    len: usize,

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectSymbol) + _len, 4);
    }

    pub fn hash(objsym: *ObjectSymbol, level: u64) u64 {
        const seed = 11400714819323198393 *% (level + 1);
        return std.hash.XxHash3.hash(seed ^ 10241052866237812727, objsym.slice());
    }

    pub fn data(objsym: *ObjectSymbol) [*]u8 {
        return @ptrFromInt(@intFromPtr(&objsym.len) + @sizeOf(usize));
    }

    pub fn slice(objsym: *ObjectSymbol) []const u8 {
        return objsym.data()[0..objsym.len];
    }
};
