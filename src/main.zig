const std = @import("std");
const GC = @import("gc.zig").GC;
const Object = @import("gc.zig").Object;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gc = GC.create(gpa.allocator());
    defer gc.destroy();
    const gca = &gc.allocator;

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp() *% 89));
    const rand = rng.random();

    const n = 16;
    var roots: [n]?*Object = [_]?*Object{null} ** n;

    for (0..1_000_000) |i| {
        if (rand.boolean()) {
            const x = rand.int(u32) % n;
            const y = blk: {
                var y = rand.int(u32) % n;
                while (y == x) y = rand.int(u32) % n;
                break :blk y;
            };
            const z = blk: {
                var z = rand.int(u32) % n;
                while (z == x or z == y) z = rand.int(u32) % n;
                break :blk z;
            };
            roots[x] = gca.newCons(roots[y], roots[z]);
        } else {
            const x = rand.int(u32) % n;
            roots[x] = gca.newReal(@floatFromInt(i));
        }

        if (gca.shouldTrace()) {
            for (roots) |root| {
                gca.traceRoot(root);
            }
            gca.endTrace();
        }
        if (i % 10_000 == 0) std.debug.print("{}\t{}\n", .{ i, gc.n_pages });
    }
}
