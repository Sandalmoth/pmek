const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const ObjectCons = @import("object_cons.zig").ObjectCons;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const eql = @import("object.zig").eql;
const debugPrint = @import("object.zig").debugPrint;

pub const ObjectPrimitive = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    ptr: *const anyopaque,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectPrimitive), 4);
    }

    pub fn hash(objprim: *ObjectPrimitive, level: u64) u64 {
        const seed = 11400714819323198393 *% (level + 1);
        return std.hash.XxHash3.hash(seed, std.mem.asBytes(&objprim.ptr));
    }

    pub fn call(objprim: *ObjectPrimitive, gca: *GCAllocator, objargs: ?*Object) ?*Object {
        const f: *const fn (*GCAllocator, ?*Object) ?*Object = @alignCast(@ptrCast(objprim.ptr));
        return f(gca, objargs);
    }
};

pub fn add(gca: *GCAllocator, objargs: ?*Object) ?*Object {
    var acc: f64 = 0;
    var args = objargs;
    while (args) |arg| {
        if (arg.kind != .cons) return gca.newErr("add: malformed argument list");
        const cons = arg.as(.cons);
        if (cons.car == null) return gca.newErr("add: cannot add null");
        if (cons.car.?.kind != .real) {
            return gca.newErr("add: arguments must be numbers");
        }
        acc += cons.car.?.as(.real).val;
        args = cons.cdr;
    }
    return gca.newReal(acc);
}

test "simple calls" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    const args1 = gca.newCons(gca.newReal(1.0), gca.newCons(gca.newReal(2.0), null));
    const prim_add = gca.newPrim(&add);
    const sum1 = prim_add.as(.primitive).call(gca, args1);
    debugPrint(args1);
    debugPrint(sum1);
}
