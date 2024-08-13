const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const RT = @import("rt.zig").RT;

const champ = @import("object_champ.zig");

pub const Form = enum(u8) {
    _if,
    def,
};

pub const ObjectSpecial = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    form: Form,

    pub fn size(len: usize) usize {
        _ = len;
        return std.mem.alignForwardLog2(@sizeOf(ObjectSpecial), 4);
    }

    pub fn hash(objspecial: *ObjectSpecial, level: u64) u64 {
        const seed = 11400714819323198393 *% (level + 1);
        return std.hash.XxHash3.hash(seed, std.mem.asBytes(&@intFromEnum(objspecial.form)));
    }

    pub fn call(objspecial: *ObjectSpecial, rt: *RT, objargs: ?*Object) ?*Object {
        return switch (objspecial.form) {
            ._if => _if(rt, objargs),
            .def => def(rt, objargs),
        };
    }
};

fn truthy(objcond: ?*Object) bool {
    if (objcond == null) return false;
    if (objcond.?.kind == ._false) return false;
    return true;
}

fn _if(rt: *RT, objargs: ?*Object) ?*Object {
    if (objargs == null) return rt.gca.newErr("_if: not enough arguments 0");
    if (objargs.?.kind != .cons) return rt.gca.newErr("_if: malformed argument list 0");
    const cons = objargs.?.as(.cons);
    if (cons.cdr == null) return rt.gca.newErr("_if: not enough arguments 1");
    if (cons.cdr.?.kind != .cons) return rt.gca.newErr("_if: malformed argument list 1");
    const cond = rt.eval(cons.car);
    const actions0 = cons.cdr.?.as(.cons);
    if (truthy(cond)) {
        return rt.eval(actions0.car);
    } else {
        if (actions0.cdr == null) return null;
        if (actions0.cdr.?.kind != .cons) return rt.gca.newErr("_if: malformed argument list 2");
        const actions1 = actions0.cdr.?.as(.cons);
        if (actions1.cdr != null) return rt.gca.newErr("_if: too many arguments");
        return rt.eval(actions1.car);
    }
}

fn def(rt: *RT, objargs: ?*Object) ?*Object {
    if (objargs == null) return rt.gca.newErr("def: not enough arguments 0");
    if (objargs.?.kind != .cons) return rt.gca.newErr("def: malformed argument list 0");
    const cons = objargs.?.as(.cons);
    if (cons.cdr == null) return rt.gca.newErr("def: not enough arguments 1");
    if (cons.cdr.?.kind != .cons) return rt.gca.newErr("def: malformed argument list 1");
    const cons2 = cons.cdr.?.as(.cons);
    if (cons2.cdr != null) return rt.gca.newErr("def: too many arguments");
    if (cons.car == null or cons.car.?.kind != .symbol)
        return rt.gca.newErr("def: first argument must be a symbol");
    const value = rt.eval(cons2.car);
    rt.env = champ.assoc(rt.gca, rt.env, cons.car, value);
    return value;
}
