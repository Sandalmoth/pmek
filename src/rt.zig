const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const debugPrint = @import("object.zig").debugPrint;
const printAST = @import("object.zig").print;
const parse = @import("parser.zig").parse;

const champ = @import("object_champ.zig");
const primitive = @import("object_primitive.zig");

pub const RT = struct {
    alloc: std.mem.Allocator,
    gc: *GC,
    gca: *GCAllocator,

    env: ?*Object,

    pub fn create(alloc: std.mem.Allocator) *RT {
        const rt = alloc.create(RT) catch @panic("Allocation failure");
        rt.* = .{
            .alloc = alloc,
            .gc = GC.create(alloc),
            .gca = undefined,
            .env = null,
        };
        rt.gca = &rt.gc.allocator;
        rt.env = rt.gca.newChamp();

        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("if"), rt.gca.newSpecial(._if));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("def"), rt.gca.newSpecial(.def));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("true"), rt.gca.newTrue());
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("false"), rt.gca.newFalse());
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("+"), rt.gca.newPrim(primitive.add));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("-"), rt.gca.newPrim(primitive.sub));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("*"), rt.gca.newPrim(primitive.mul));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("/"), rt.gca.newPrim(primitive.div));
        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("="), rt.gca.newPrim(primitive._eql));

        return rt;
    }

    pub fn destroy(rt: *RT) void {
        rt.gc.destroy();
        rt.alloc.destroy(rt);
    }

    pub fn read(rt: *RT, src: []const u8) ?*Object {
        const result = parse(rt.gc, src);
        debugPrint(result);
        return result;
    }

    pub fn eval(rt: *RT, ast: ?*Object) ?*Object {
        if (ast == null) return null;

        switch (ast.?.kind) {
            .real, .string, .champ, .primitive, .err, .special, ._true, ._false => return ast,
            .symbol => {
                const result = champ.get(rt.env, ast);
                if (result == null) return rt.gca.newErr("eval: unbound symbol");
                return result;
            },
            .cons => {},
        }

        const cons = (ast orelse return null).as(.cons);
        if (cons.car == null) return rt.gca.newErr("eval: cannot call nil");
        if (cons.car.?.kind != .symbol) return rt.gca.newErr("eval: cannot call non-symbol");
        const f = champ.get(rt.env, cons.car);
        debugPrint(f);
        if (f == null) return rt.gca.newErr("eval: cannot call nil");
        switch (f.?.kind) {
            .primitive => {
                const args = rt.evlis(cons.cdr);
                debugPrint(args);
                return f.?.as(.primitive).call(rt.gca, args);
            },
            .special => {
                return f.?.as(.special).call(rt, cons.cdr);
            },
            else => return rt.gca.newErr("eval: can only call primitive"),
        }

        return null;
    }

    fn evlis(rt: *RT, ast: ?*Object) ?*Object {
        var evaluated: ?*Object = null;
        var walk = ast;
        while (walk != null) {
            if (walk.?.kind != .cons) return rt.gca.newErr("evlis: malformed argument list");
            const cons = walk.?.as(.cons);
            evaluated = rt.gca.newCons(
                rt.eval(cons.car),
                evaluated,
            );
            walk = cons.cdr;
        }
        // the evaluation reverses the order, so we need to unreverseit
        // this seems like a lot of unneccessary gc-pressure...
        var reversed: ?*Object = null;
        walk = evaluated;
        while (walk != null) {
            const cons = walk.?.as(.cons);
            reversed = rt.gca.newCons(cons.car, reversed);
            walk = cons.cdr;
        }
        return reversed;
    }

    pub fn print(rt: *RT, ast: ?*Object, writer: anytype) void {
        _ = rt;
        _ = ast;
        _ = writer;
    }

    pub fn rep(rt: *RT, src: []const u8, writer: anytype) !void {
        const ast = rt.read(src);
        const result = rt.eval(ast);
        try printAST(result, writer);
    }
};

test "scratch" {
    const rt = RT.create(std.testing.allocator);
    defer rt.destroy();

    const expr = rt.gca.newCons(
        rt.gca.newSymbol("+"),
        rt.gca.newCons(
            rt.gca.newReal(1.0),
            rt.gca.newCons(
                rt.gca.newReal(2.0),
                null,
            ),
        ),
    );
    debugPrint(expr);
    debugPrint(rt.eval(expr));

    const ifexpr = rt.gca.newCons(
        rt.gca.newSymbol("if"),
        rt.gca.newCons(
            // rt.gca.newTrue(),
            // rt.gca.newFalse(),
            rt.gca.newSymbol("true"),
            // rt.gca.newSymbol("false"),
            // null,
            rt.gca.newCons(
                rt.gca.newReal(1.0),
                rt.gca.newCons(
                    rt.gca.newReal(2.0),
                    null,
                ),
            ),
        ),
    );
    debugPrint(ifexpr);
    debugPrint(rt.eval(ifexpr));

    const src = "(+ 1 2)";
    const rexpr = rt.read(src);
    debugPrint(rexpr);
    debugPrint(rt.eval(rexpr));

    _ = rt.read("hello");
    _ = rt.read("hello   ");
    _ = rt.read("\"hello\"");
    _ = rt.read("\"hello\"   ");

    const stdout = std.io.getStdOut().writer();
    try rt.rep("(+ 1 2)", stdout);
    try rt.rep("(if true (+ 1 2) (+ 3 4))", stdout);
    try rt.rep("(if false (+ 1 2) (+ 3 4))", stdout);
    try rt.rep("(+ 1.5 2.5)", stdout);
    try rt.rep("(+ 1.5 \"hello\")", stdout);
    try rt.rep("a", stdout);
    try rt.rep("(def a (+ 2 3))", stdout);
    try rt.rep("a", stdout);
}
