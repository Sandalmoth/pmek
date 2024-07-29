const std = @import("std");

const Page = @import("gc.zig").Page;
pub const ObjectReal = @import("object/real.zig").ObjectReal;
pub const ObjectString = @import("object/string.zig").ObjectString;
pub const ObjectCons = @import("object/cons.zig").ObjectCons;
pub const ObjectMap = @import("object/map.zig").ObjectMap;

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
