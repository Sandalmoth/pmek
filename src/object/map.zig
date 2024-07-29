const std = @import("std");
const Object = @import("../object.zig").Object;
const GC = @import("../gc.zig").GC;

// implements a compressed hash-array mapped prefix-tree (CHAMP)

pub const ObjectMap = extern struct {
    head: Object,
    datamask: u64,
    nodemask: u64,
    datalen: u32,
    nodelen: u32,

    pub fn hash(map: *ObjectMap, seed: u64) u64 {
        // entries in data have two pointers, a key and a value
        // and entries in in nodes have just one
        // however, the hash is simply the xor of all of the kv in the map
        // and since xor is commutative, we can simply xor everything together
        var h: u64 = 0;
        const children = map.data();
        for (0..2 * map.datalen + map.nodelen) |i| {
            // while the nodes cannot be null, the data could be
            h ^= Object.hash(children[i].load(.acquire), seed);
        }
        return h;
    }

    pub fn data(map: *ObjectMap) [*]std.atomic.Value(?*Object) {
        return @ptrFromInt(@intFromPtr(&map.nodemask) + 16);
    }

    pub fn nodes(map: *ObjectMap) [*]std.atomic.Value(*Object) {
        return @ptrFromInt(@intFromPtr(&map.nodemask) + 16 + 16 * map.datalen);
    }

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(
            @sizeOf(ObjectMap) + @sizeOf(usize) * _len,
            4,
        );
    }

    pub fn contains(map: *ObjectMap, objkey: ?*Object) bool {
        _ = map;
        _ = objkey;
        return undefined;
    }

    pub fn get(map: *ObjectMap, objkey: ?*Object) ?*Object {
        _ = map;
        _ = objkey;
        return undefined;
    }

    pub fn assoc(map: *ObjectMap, gc: *GC, objkey: ?*Object, objval: ?*Object) *Object {
        _ = map;
        _ = gc;
        _ = objkey;
        _ = objval;
        return undefined;
    }

    pub fn dissoc(map: *ObjectMap, gc: *GC, objkey: ?*Object) *Object {
        _ = map;
        _ = gc;
        _ = objkey;
        return undefined;
    }
};
