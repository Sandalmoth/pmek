const std = @import("std");

pub const ObjectReal = @import("real.zig").ObjectReal;
pub const ObjectString = @import("string.zig").ObjectString;
pub const ObjectCons = @import("cons.zig").ObjectCons;
pub const ObjectMap = @import("map.zig").ObjectMap;

pub const Kind = enum(u8) {
    real,
    string,
    cons,
    map,
};

pub fn ObjectType(comptime kind: Kind) type {
    return switch (kind) {
        .real => ObjectReal,
        .string => ObjectString,
        .cons => ObjectCons,
        .map => ObjectMap,
    };
}

pub const Object = extern struct {
    fwd: std.atomic.Value(*Object) align(16),
    kind: Kind,
    finished: bool, // just a nice check to make sure we always call gc.commit
    using_backup_allocator: bool,

    // what should we do with all our spare bits here?
    // - external types?
    // - offset to next object in page so we could walk the pages?
    // alternatively, we could pack the kind into the pointer
    // assuming that pointers won't become truly 64-bit in the near future

    pub fn hash(obj: ?*Object, level: u64) u64 {
        // I dont' want to support hash collisions
        // so instead, we'll just support an infinite series hash-bits
        if (obj == null) {
            // this is the prime closest to 2^64/phi
            // so the weyl sequence will visit all 2^64 numbers
            // and the bits will be maximally different from the previous level
            const seed: u64 = 11400714819323198393 *% level;
            return (seed ^ 14939819388667570391) *% 12542518518317951677;
        }
        std.debug.assert(obj.?.finished);
        return switch (obj.?.kind) {
            .real => obj.?.as(.real).hash(level),
            .string => obj.?.as(.string).hash(level),
            .cons => obj.?.as(.cons).hash(level),
            .map => obj.?.as(.map).hash(level),
        };
    }

    pub fn as(obj: *Object, comptime kind: Kind) *ObjectType(kind) {
        std.debug.assert(obj.finished);
        std.debug.assert(obj.kind == kind);
        return @alignCast(@ptrCast(obj));
    }
};

comptime {
    std.debug.assert(@alignOf(Object) == 16);
    std.debug.assert(@sizeOf(Object) == 16);
}

pub fn eql(obj1: ?*Object, obj2: ?*Object) bool {
    if (obj1 == obj2) return true;
    if (obj1 == null or obj2 == null) return false;
    if (obj1.?.kind != obj2.?.kind) return false;
    return switch (obj1.?.kind) {
        .real => obj1.?.as(.real).data == obj2.?.as(.real).data,
        .cons => blk: {
            const cons1 = obj1.?.as(.cons);
            const cons2 = obj2.?.as(.cons);
            break :blk eql(cons1.car.load(.acquire), cons2.car.load(.acquire)) and
                eql(cons1.cdr.load(.acquire), cons2.cdr.load(.acquire));
        },
        .map => blk: {
            const map1 = obj1.?.as(.map);
            const map2 = obj2.?.as(.map);
            if (map1.datamask != map2.datamask or
                map1.nodemask != map2.nodemask) break :blk false;
            std.debug.assert(map1.datalen == map2.datalen);
            std.debug.assert(map1.nodelen == map2.nodelen);
            const data1 = map1.data();
            const data2 = map2.data();
            for (0..2 * map1.datalen + map1.nodelen) |i| {
                if (!eql(data1[i].load(.acquire), data2[i].load(.acquire))) break :blk false;
            }
            break :blk true;
        },
        .string => blk: {
            const string1 = obj1.?.as(.string);
            const string2 = obj2.?.as(.string);
            if (string1.len != string2.len) break :blk false;
            break :blk std.mem.eql(
                u8,
                string1.data()[0..string1.len],
                string2.data()[0..string2.len],
            );
        },
    };
}
