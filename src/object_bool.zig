const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;

pub const ObjectTrue = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectTrue), 4);
    }

    pub fn hash(objtrue: *ObjectTrue, level: u64) u64 {
        _ = objtrue;
        const seed = 11400714819323198393 *% (level + 1);
        return seed ^ 13530035797109074601;
    }
};

pub const ObjectFalse = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectFalse), 4);
    }

    pub fn hash(objfalse: *ObjectFalse, level: u64) u64 {
        _ = objfalse;
        const seed = 11400714819323198393 *% (level + 1);
        return seed ^ 16725121391229870607;
    }
};
