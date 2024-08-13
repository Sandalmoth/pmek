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

pub fn sub(gca: *GCAllocator, objargs: ?*Object) ?*Object {
    var acc: f64 = 0;
    var args = objargs;
    var first = true;
    while (args) |arg| {
        if (arg.kind != .cons) return gca.newErr("sub: malformed argument list");
        const cons = arg.as(.cons);
        if (cons.car == null) return gca.newErr("sub: cannot sub null");
        if (cons.car.?.kind != .real) {
            return gca.newErr("sub: arguments must be numbers");
        }
        if (first) {
            acc = cons.car.?.as(.real).val;
            first = false;
        } else {
            acc -= cons.car.?.as(.real).val;
        }
        args = cons.cdr;
    }
    if (first) return gca.newErr("sub: not enough arguments");
    return gca.newReal(acc);
}

pub fn mul(gca: *GCAllocator, objargs: ?*Object) ?*Object {
    var acc: f64 = 1;
    var args = objargs;
    while (args) |arg| {
        if (arg.kind != .cons) return gca.newErr("mul: malformed argument list");
        const cons = arg.as(.cons);
        if (cons.car == null) return gca.newErr("mul: cannot mul null");
        if (cons.car.?.kind != .real) {
            return gca.newErr("mul: arguments must be numbers");
        }
        acc *= cons.car.?.as(.real).val;
        args = cons.cdr;
    }
    return gca.newReal(acc);
}

pub fn div(gca: *GCAllocator, objargs: ?*Object) ?*Object {
    var acc: f64 = 1;
    var args = objargs;
    var first = true;
    while (args) |arg| {
        if (arg.kind != .cons) return gca.newErr("div: malformed argument list");
        const cons = arg.as(.cons);
        if (cons.car == null) return gca.newErr("div: cannot div null");
        if (cons.car.?.kind != .real) {
            return gca.newErr("div: arguments must be numbers");
        }
        if (first) {
            acc = cons.car.?.as(.real).val;
            first = false;
        } else {
            acc /= cons.car.?.as(.real).val;
        }
        args = cons.cdr;
    }
    if (first) return gca.newErr("div: not enough arguments");
    return gca.newReal(acc);
}

pub fn _eql(gca: *GCAllocator, objargs: ?*Object) ?*Object {
    var acc: ?*Object = null;
    var args = objargs;
    var first = true;
    while (args) |arg| {
        if (arg.kind != .cons) return gca.newErr("eql: malformed argument list");
        const cons = arg.as(.cons);
        if (first) {
            acc = cons.car;
            first = false;
        } else {
            if (!eql(acc, cons.car)) return gca.newFalse();
        }
        args = cons.cdr;
    }
    if (first) return gca.newErr("eql: not enough arguments");
    return gca.newTrue();
}

test "simple calls" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    const prim_add = gca.newPrim(&add);

    var acc: f64 = 0;

    var args: ?*Object = null;
    for (0..10) |i| {
        const sum = prim_add.as(.primitive).call(gca, args);
        try std.testing.expect(sum.?.as(.real).val == acc);
        // debugPrint(args);
        // debugPrint(sum);
        args = gca.newCons(gca.newReal(@floatFromInt(i + 1)), args);
        acc += @floatFromInt(i + 1);
    }
}
