const std = @import("std");

const Page = @import("gc.zig").Page;
pub const ObjectInt = @import("object/int.zig").ObjectInt;
pub const ObjectCons = @import("object/cons.zig").ObjectCons;

pub const Kind = enum(u8) {
    int,
    cons,
};

pub fn ObjectType(comptime kind: Kind) type {
    return switch (kind) {
        .int => ObjectInt,
        .cons => ObjectCons,
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
