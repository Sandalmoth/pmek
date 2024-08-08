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

    pub fn hash(objmap: *ObjectMap, level: u64) u64 {
        var h: u64 = 14568007547523660521;
        h ^= Object.hash(objmap.root, level);
        h ^= Object.hash(objmap.meta, level);
        return h;
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

    pub fn hash(objchamp: *ObjectChamp, level: u64) u64 {
        var h: u64 = 13015751150583452993;
        for (0..2 * objchamp.datalen + objchamp.nodelen) |i| {
            h ^= Object.hash(objchamp.data()[i], level);
            h *%= 16918459230259101617;
        }
        return h;
    }

    pub fn data(champ: *ObjectChamp) [*]?*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16);
    }

    pub fn nodes(champ: *ObjectChamp) [*]*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16 + 16 * champ.datalen);
    }
};
