const std = @import("std");
const GC = @import("gc.zig").GC;
const Object = @import("object.zig").Object;

pub const ObjectCons = extern struct {
    head: Object,
    car: std.atomic.Value(?*Object),
    cdr: std.atomic.Value(?*Object),

    pub fn create(gc: *GC, car: ?*Object, cdr: ?*Object) *Object {
        const obj = gc.alloc(.cons, 0) catch @panic("GC allocation failure");
        obj.car.store(car, .unordered);
        obj.cdr.store(cdr, .unordered);
        return gc.commit(.cons, obj);
    }

    pub fn hash(cons: *ObjectCons, seed: u64) u64 {
        var h: u64 = 0;
        h ^= Object.hash(cons.car.load(.acquire), seed);
        h ^= Object.hash(cons.cdr.load(.acquire), seed);
        return h;
    }

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectCons), 4);
    }
};
