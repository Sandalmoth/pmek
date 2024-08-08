const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;

pub const ObjectMap = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    len: usize, // number of kv-pairs in map
    root: *ObjectChamp,
    meta: ?*ObjectMap,

    pub fn size(_len: usize) usize {
        std.debug.assert(_len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectMap), 4);
    }
};

pub const ObjectChamp = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    datamask: u64,
    nodemask: u64,
    datalen: u32,
    nodelen: u32,

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectChamp) + @sizeOf(usize) * _len, 4);
    }

    pub fn data(champ: *ObjectChamp) [*]?*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16);
    }

    pub fn nodes(champ: *ObjectChamp) [*]*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16 + 16 * champ.datalen);
    }
};
