const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const debugPrint = @import("object.zig").debugPrint;

const champ = @import("object_champ.zig");
const primitive = @import("object_primitive.zig");

const RT = struct {
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

        rt.env = champ.assoc(rt.gca, rt.env, rt.gca.newSymbol("+"), rt.gca.newPrim(primitive.add));

        return rt;
    }

    pub fn destroy(rt: *RT) void {
        rt.gc.destroy();
        rt.alloc.destroy(rt);
    }

    pub fn read(rt: *RT, src: []const u8) ?*Object {
        _ = rt;
        _ = src;
    }

    pub fn eval(rt: *RT, ast: ?*Object) ?*Object {
        _ = rt;
        _ = ast;
        return null;
    }

    pub fn print(rt: *RT, ast: ?*Object, writer: anytype) void {
        _ = rt;
        _ = ast;
        _ = writer;
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
}
