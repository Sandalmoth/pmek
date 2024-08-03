const std = @import("std");
const GC = @import("gc.zig").GC;
const Object = @import("object.zig").Object;

pub const ObjectString = extern struct {
    head: Object,
    len: usize,

    pub fn create(gc: *GC, val: []const u8) *Object {
        const obj = gc.alloc(.string, val.len) catch @panic("GC allocation failure");
        obj.len = val.len;
        @memcpy(obj.data(), val);
        return gc.commit(.string, obj);
    }

    pub fn hash(string: *ObjectString, seed: u64) u64 {
        return std.hash.XxHash3.hash(seed, string.data()[0..string.len]);
    }

    pub fn data(string: *ObjectString) [*]u8 {
        return @ptrFromInt(@intFromPtr(&string.len) + 8);
    }

    pub fn size(len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectString) + @sizeOf(u8) * len, 4);
    }
};
