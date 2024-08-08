const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const eql = @import("object.zig").eql;
const debugPrint = @import("object.zig").debugPrint;

pub const ObjectChamp = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    datamask: u64,
    nodemask: u64,
    datalen: u32,
    nodelen: u32,

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectChamp) + @sizeOf(usize) * _len, 4);
    }

    pub fn hash(objchamp: *ObjectChamp, level: u64) u64 {
        var h: u64 = 13015751150583452993;
        for (0..2 * objchamp.datalen + objchamp.nodelen) |i| {
            h ^= Object.hash(objchamp.data()[i], level);
            h *%= 16918459230259101617;
        }
        return h;
    }

    pub fn data(champ: *ObjectChamp) [*]?*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16);
    }

    pub fn nodes(champ: *ObjectChamp) [*]*Object {
        return @ptrFromInt(@intFromPtr(&champ.nodemask) + 16 + 16 * champ.datalen);
    }
};

const ChampKeyContext = struct {
    objkey: ?*Object,
    keyhash: u64,
    depth: usize,

    // though it wastes some bits in the hash
    // the improved performance on divide and modulo seems to be worth it
    const LEVELS_PER_HASH = 8;

    fn init(objkey: ?*Object) ChampKeyContext {
        return .{
            .objkey = objkey,
            .keyhash = Object.hash(objkey, 0),
            .depth = 0,
        };
    }

    fn initDepth(objkey: ?*Object, depth: usize) ChampKeyContext {
        return .{
            .objkey = objkey,
            .keyhash = Object.hash(objkey, depth / LEVELS_PER_HASH),
            .depth = depth,
        };
    }

    fn next(old: ChampKeyContext) ChampKeyContext {
        var new = ChampKeyContext{
            .objkey = old.objkey,
            .keyhash = old.keyhash,
            .depth = old.depth + 1,
        };
        if (old.depth / LEVELS_PER_HASH < new.depth / LEVELS_PER_HASH) {
            new.keyhash = Object.hash(new.objkey, new.depth / LEVELS_PER_HASH);
        }
        return new;
    }

    fn slot(ctx: ChampKeyContext) usize {
        return (ctx.keyhash >> @intCast((ctx.depth % LEVELS_PER_HASH) * 6)) & 0b11_1111;
    }
};

pub fn assoc(gca: *GCAllocator, objchamp: ?*Object, objkey: ?*Object, objval: ?*Object) *Object {
    // inserting into nil just creates a new map
    const obj = objchamp orelse gca.newChamp();
    return assocImpl(gca, obj, ChampKeyContext.init(objkey), objval);
}
fn assocImpl(
    gca: *GCAllocator,
    objchamp: *Object,
    keyctx: ChampKeyContext,
    objval: ?*Object,
) *Object {
    const champ = objchamp.as(.champ);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = champ.datamask & slotmask > 0;
    const is_node = champ.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (is_node) {
        // traverse and insert further down
        const packed_index = @popCount(champ.nodemask & (slotmask - 1));
        const new = gca.new(.champ, 2 * champ.datalen + champ.nodelen);
        new.datamask = champ.datamask;
        new.nodemask = champ.nodemask;
        new.datalen = champ.datalen;
        new.nodelen = champ.nodelen;
        @memcpy(new.data()[0..], champ.data()[0 .. 2 * champ.datalen + champ.nodelen]);
        new.nodes()[packed_index] = assocImpl(
            gca,
            champ.nodes()[packed_index],
            keyctx.next(),
            objval,
        );
        return @alignCast(@ptrCast(new));
    }

    if (!is_data) {
        // empty slot, insert here
        const packed_index = @popCount(champ.datamask & (slotmask - 1));
        const new = gca.new(.champ, 2 * (champ.datalen + 1) + champ.nodelen);
        new.datamask = champ.datamask | slotmask;
        new.nodemask = champ.nodemask;
        new.datalen = champ.datalen + 1;
        new.nodelen = champ.nodelen;
        const newdata = new.data();
        const olddata = champ.data();
        @memcpy(newdata[0..], olddata[0 .. 2 * packed_index]);
        newdata[2 * packed_index] = keyctx.objkey;
        newdata[2 * packed_index + 1] = objval;
        @memcpy(
            newdata[2 * packed_index + 2 ..],
            olddata[2 * packed_index .. 2 * champ.datalen + champ.nodelen],
        );
        return @alignCast(@ptrCast(new));
    }

    const packed_index = @popCount(champ.datamask & (slotmask - 1));
    if (eql(champ.data()[2 * packed_index], keyctx.objkey)) {
        // key already present, just update
        const new = gca.new(.champ, 2 * champ.datalen + champ.nodelen);
        new.datamask = champ.datamask;
        new.nodemask = champ.nodemask;
        new.datalen = champ.datalen;
        new.nodelen = champ.nodelen;
        @memcpy(new.data()[0..], champ.data()[0 .. 2 * champ.datalen + champ.nodelen]);
        new.data()[2 * packed_index + 1] = objval;
        return @alignCast(@ptrCast(new));
    }

    // add new sublevel with displaced child
    const packed_data_index = @popCount(champ.datamask & (slotmask - 1));
    const packed_node_index = @popCount(champ.nodemask & (slotmask - 1));
    const subkey = champ.data()[2 * packed_data_index];
    const subval = champ.data()[2 * packed_data_index + 1];
    const subctx = ChampKeyContext.initDepth(subkey, keyctx.depth + 1);
    const subslot = subctx.slot();
    const sub = gca.new(.champ, 2);
    sub.datamask = @as(u64, 1) << @intCast(subslot);
    sub.nodemask = 0;
    sub.datalen = 1;
    sub.nodelen = 0;
    const subdata = sub.data();
    subdata[0] = subkey;
    subdata[1] = subval;

    // then insert into that sublevel
    const new = gca.new(.champ, 2 * (champ.datalen - 1) + champ.nodelen + 1);
    new.datamask = champ.datamask & ~slotmask;
    new.nodemask = champ.nodemask | slotmask;
    new.datalen = champ.datalen - 1;
    new.nodelen = champ.nodelen + 1;
    const newdata = new.data();
    const olddata = champ.data();
    @memcpy(newdata[0..], olddata[0 .. 2 * packed_data_index]);
    @memcpy(
        newdata[2 * packed_data_index ..],
        olddata[2 * packed_data_index + 2 .. 2 * champ.datalen],
    );
    const newnodes = new.nodes();
    const oldnodes = champ.nodes();
    @memcpy(newnodes[0..], oldnodes[0..packed_node_index]);
    newnodes[packed_node_index] = assocImpl(
        gca,
        @alignCast(@ptrCast(sub)),
        keyctx.next(),
        objval,
    );
    @memcpy(newnodes[packed_node_index + 1 ..], oldnodes[packed_node_index..champ.nodelen]);

    return @alignCast(@ptrCast(new));
}

pub fn get(objchamp: ?*Object, objkey: ?*Object) ?*Object {
    const obj = objchamp orelse return null;
    return getImpl(obj, ChampKeyContext.init(objkey));
}
fn getImpl(objchamp: *Object, keyctx: ChampKeyContext) ?*Object {
    const champ = objchamp.as(.champ);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = champ.datamask & slotmask > 0;
    const is_node = champ.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (!(is_node or is_data)) return null;
    if (is_node) {
        const packed_index = @popCount(champ.nodemask & (slotmask - 1));
        return getImpl(champ.nodes()[packed_index], keyctx.next());
    }
    const packed_index = @popCount(champ.datamask & (slotmask - 1));
    if (eql(champ.data()[2 * packed_index], keyctx.objkey)) {
        return champ.data()[2 * packed_index + 1];
    }
    return null;
}

pub fn contains(objchamp: ?*Object, objkey: ?*Object) bool {
    const obj = objchamp orelse return false;
    return getImpl(obj, ChampKeyContext.init(objkey)) != null;
}

pub fn dissoc(gca: *GCAllocator, objchamp: ?*Object, objkey: ?*Object) ?*Object {
    const obj = objchamp orelse return null;
    return dissocImpl(gca, obj, ChampKeyContext.init(objkey));
}
fn dissocImpl(gca: *GCAllocator, objchamp: *Object, keyctx: ChampKeyContext) *Object {
    const champ = objchamp.as(.champ);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = champ.datamask & slotmask > 0;
    const is_node = champ.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (!(is_data or is_node)) return objchamp;

    if (is_data) {
        const packed_index = @popCount(champ.datamask & (slotmask - 1));
        if (!eql(champ.data()[2 * packed_index], keyctx.objkey)) return objchamp;
        if (champ.datalen + champ.nodelen == 1) return gca.newChamp();
        const new = gca.new(.champ, 2 * (champ.datalen - 1) + champ.nodelen);
        new.datamask = champ.datamask & ~slotmask;
        new.nodemask = champ.nodemask;
        new.datalen = champ.datalen - 1;
        new.nodelen = champ.nodelen;
        const newdata = new.data();
        const olddata = champ.data();
        @memcpy(newdata[0..], olddata[0 .. 2 * packed_index]);
        @memcpy(
            newdata[2 * packed_index ..],
            olddata[2 * packed_index + 2 .. 2 * champ.datalen + champ.nodelen],
        );
        return @alignCast(@ptrCast(new));
    }

    const packed_index = @popCount(champ.nodemask & (slotmask - 1));
    const objresult = dissocImpl(gca, champ.nodes()[packed_index], keyctx.next());
    if (eql(champ.nodes()[packed_index], objresult)) return objchamp;

    const result = objresult.as(.champ);
    if (result.nodelen == 0 and result.datalen == 1) {
        if (champ.datalen + champ.nodelen == 1) {
            // this node has only one child
            // and that child is just a kv after the deletion
            // so we can just keep that kv and get rid of this node
            return objresult;
        } else {
            // a node child of this node is now just a kv
            // so store that kv directly here instead
            // (node without subnode) with key
            const packed_data_index = @popCount(champ.datamask & (slotmask - 1));
            const packed_node_index = @popCount(champ.nodemask & (slotmask - 1));
            const new = gca.new(.champ, 2 * (champ.datalen + 1) + champ.nodelen - 1);
            new.datamask = champ.datamask | slotmask;
            new.nodemask = champ.nodemask & ~slotmask;
            new.datalen = champ.datalen + 1;
            new.nodelen = champ.nodelen - 1;
            const newdata = new.data();
            const olddata = champ.data();
            @memcpy(newdata[0..], olddata[0 .. 2 * packed_data_index]);
            newdata[2 * packed_data_index] = result.data()[0];
            newdata[2 * packed_data_index + 1] = result.data()[1];
            @memcpy(
                newdata[2 * packed_data_index + 2 ..],
                olddata[2 * packed_data_index .. 2 * champ.datalen],
            );
            const newnodes = new.nodes();
            const oldnodes = champ.nodes();
            @memcpy(newnodes[0..], oldnodes[0..packed_node_index]);
            @memcpy(
                newnodes[packed_node_index..],
                oldnodes[packed_node_index + 1 .. champ.nodelen],
            );
            return @alignCast(@ptrCast(new));
        }
    }
    // node updated with result
    // the node child of this node has been altered but is still a node
    // so just replace that node-child with the result
    std.debug.assert(result.datalen + result.nodelen > 0);
    const new = gca.new(.champ, 2 * champ.datalen + champ.nodelen);
    new.datamask = champ.datamask;
    new.nodemask = champ.nodemask;
    new.datalen = champ.datalen;
    new.nodelen = champ.nodelen;
    const newdata = new.data();
    const olddata = champ.data();
    @memcpy(newdata[0..], olddata[0 .. 2 * champ.datalen + champ.nodelen]);
    new.nodes()[packed_index] = objresult;
    return @alignCast(@ptrCast(new));
}

test "champ fuzz" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp() *% 89));
    const rand = rng.random();

    const ns = [_]u32{ 32, 512, 8192, 131072, 2097152 };
    const m = 100_000;

    for (ns) |n| {
        var h = gca.newChamp();

        var s = std.AutoHashMap(u32, u32).init(std.testing.allocator);
        defer s.deinit();

        for (0..m) |_| {
            const x = rand.intRangeLessThan(u32, 0, n);
            const y = rand.intRangeLessThan(u32, 0, n);
            const a = gca.newReal(@floatFromInt(x));
            const b = gca.newReal(@floatFromInt(y));

            // std.debug.print("{} {}\n", .{ x, y });
            // debugPrint(h);
            // std.debug.print("{} {}\n", .{ contains(h, a), s.contains(x) });
            std.debug.assert(contains(h, a) == s.contains(x));
            if (contains(h, a)) {
                std.debug.assert(
                    @as(u32, @intFromFloat(get(h, a).?.as(.real).val)) == s.get(x).?,
                );
                const h2 = dissoc(gca, h, a);
                h = h2.?;
                _ = s.remove(x);
            } else {
                const h2 = assoc(gca, h, a, b);
                h = h2;
                try s.put(x, y);
            }

            const u = rand.intRangeLessThan(u32, 0, n);
            const v = rand.intRangeLessThan(u32, 0, n);
            const c = gca.newReal(@floatFromInt(u));
            const d = gca.newReal(@floatFromInt(v));
            if (rand.boolean()) {
                const h2 = dissoc(gca, h, c);
                h = h2.?;
                _ = s.remove(u);
            } else {
                const h2 = assoc(gca, h, c, d);
                h = h2;
                try s.put(u, v);
            }

            if (gca.shouldTrace()) {
                gca.traceRoot(h);
                gca.endTrace();
            }
        }
    }
}
