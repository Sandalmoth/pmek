const std = @import("std");

const Page = @import("gc.zig").Page;

const ObjectReal = @import("object_real.zig").ObjectReal;
const ObjectCons = @import("object_cons.zig").ObjectCons;
const ObjectString = @import("object_string.zig").ObjectString;
const ObjectMap = @import("object_map.zig").ObjectMap;
const ObjectChamp = @import("object_map.zig").ObjectChamp;

pub const Kind = enum(u8) {
    real,
    cons,
    string,
    map, // head of map
    champ, // internal node in map
};

pub fn ObjectType(comptime kind: Kind) type {
    return switch (kind) {
        .real => ObjectReal,
        .cons => ObjectCons,
        .string => ObjectString,
        .map => ObjectMap,
        .champ => ObjectChamp,
    };
}

pub const Object = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,

    pub fn as(obj: *Object, comptime kind: Kind) *ObjectType(kind) {
        std.debug.assert(obj.kind == kind);
        return @alignCast(@ptrCast(obj));
    }

    pub fn page(obj: *Object) *Page {
        const mask: usize = ~(@as(usize, std.mem.page_size) - 1);
        return @ptrFromInt(@intFromPtr(obj) & mask);
    }
};

comptime {
    std.debug.assert(@sizeOf(Object) <= 16);
    std.debug.assert(@alignOf(Object) == 16);
}
