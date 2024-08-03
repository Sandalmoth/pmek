const std = @import("std");
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const ObjectReal = @import("object.zig").ObjectReal;
const eql = @import("object.zig").eql;

pub const ObjectMap = extern struct {
    head: Object,
    datamask: u64,
    nodemask: u64,
    datalen: u32,
    nodelen: u32,

    pub fn create(gc: *GC) *Object {
        const obj = gc.alloc(.map, 0) catch @panic("GC allocation failure");
        obj.datamask = 0;
        obj.nodemask = 0;
        obj.datalen = 0;
        obj.nodelen = 0;
        return gc.commit(.map, obj);
    }

    pub fn hash(map: *ObjectMap, seed: u64) u64 {
        // entries in data have two pointers, a key and a value
        // and entries in in nodes have just one
        // however, the hash is simply the xor of all of the kv in the map
        // and since xor is commutative, we can simply xor everything together
        var h: u64 = 0;
        const children = map.data();
        for (0..2 * map.datalen + map.nodelen) |i| {
            // while the nodes cannot be null, the data could be
            h ^= Object.hash(children[i].load(.acquire), seed);
        }
        return h;
    }

    pub fn data(map: *ObjectMap) [*]std.atomic.Value(?*Object) {
        return @ptrFromInt(@intFromPtr(&map.nodemask) + 16);
    }

    pub fn nodes(map: *ObjectMap) [*]std.atomic.Value(*Object) {
        return @ptrFromInt(@intFromPtr(&map.nodemask) + 16 + 16 * map.datalen);
    }

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(
            @sizeOf(ObjectMap) + @sizeOf(usize) * _len,
            4,
        );
    }
};

pub fn contains(objmap: ?*Object, objkey: ?*Object) bool {
    const obj = objmap orelse return false;
    return _getImpl(obj, MapKeyContext.init(objkey)) != null;
}

pub fn get(objmap: ?*Object, objkey: ?*Object) ?*Object {
    const obj = objmap orelse return null;
    return _getImpl(obj, MapKeyContext.init(objkey));
}
fn _getImpl(objmap: *Object, keyctx: MapKeyContext) ?*Object {
    const map = objmap.as(.map);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = map.datamask & slotmask > 0;
    const is_node = map.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (!(is_node or is_data)) return null;
    if (is_node) {
        const packed_index = @popCount(map.nodemask & (slotmask - 1));
        return _getImpl(map.nodes()[packed_index].load(.acquire), keyctx.next());
    }
    const packed_index = @popCount(map.datamask & (slotmask - 1));
    if (eql(map.data()[2 * packed_index].load(.acquire), keyctx.objkey)) {
        return map.data()[2 * packed_index + 1].load(.acquire);
    }
    return null;
}

pub fn assoc(objmap: ?*Object, gc: *GC, objkey: ?*Object, objval: ?*Object) *Object {
    const obj = objmap orelse ObjectMap.create(gc);
    return _assocImpl(gc, obj, MapKeyContext.init(objkey), objval);
}
fn _assocImpl(
    gc: *GC,
    objmap: *Object,
    keyctx: MapKeyContext,
    objval: ?*Object,
) *Object {
    const map = objmap.as(.map);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = map.datamask & slotmask > 0;
    const is_node = map.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (is_node) {
        // traverse and insert further down
        const packed_index = @popCount(map.nodemask & (slotmask - 1));
        const new = gc.alloc(.map, 2 * map.datalen + map.nodelen) catch
            @panic("GC allocation failure");
        new.datamask = map.datamask;
        new.nodemask = map.nodemask;
        new.datalen = map.datalen;
        new.nodelen = map.nodelen;
        @memcpy(new.data()[0..], map.data()[0 .. 2 * map.datalen + map.nodelen]);
        new.nodes()[packed_index].store(_assocImpl(
            gc,
            map.nodes()[packed_index].load(.acquire),
            keyctx.next(),
            objval,
        ), .release);
        return gc.commit(.map, new);
    }

    if (!is_data) {
        // empty slot, insert here
        const packed_index = @popCount(map.datamask & (slotmask - 1));
        const new = gc.alloc(.map, 2 * (map.datalen + 1) + map.nodelen) catch
            @panic("GC allocation failure");
        new.datamask = map.datamask | slotmask;
        new.nodemask = map.nodemask;
        new.datalen = map.datalen + 1;
        new.nodelen = map.nodelen;
        const newdata = new.data();
        const olddata = map.data();
        @memcpy(newdata[0..], olddata[0 .. 2 * packed_index]);
        newdata[2 * packed_index].store(keyctx.objkey, .unordered);
        newdata[2 * packed_index + 1].store(objval, .unordered);
        @memcpy(
            newdata[2 * packed_index + 2 ..],
            olddata[2 * packed_index .. 2 * map.datalen + map.nodelen],
        );
        return gc.commit(.map, new);
    }

    const packed_index = @popCount(map.datamask & (slotmask - 1));
    if (eql(map.data()[2 * packed_index].load(.acquire), keyctx.objkey)) {
        // key already present, just update
        const new = gc.alloc(.map, 2 * map.datalen + map.nodelen) catch
            @panic("GC allocation failure");
        new.datamask = map.datamask;
        new.nodemask = map.nodemask;
        new.datalen = map.datalen;
        new.nodelen = map.nodelen;
        @memcpy(new.data()[0..], map.data()[0 .. 2 * map.datalen + map.nodelen]);
        new.data()[2 * packed_index + 1].store(objval, .unordered);
        return gc.commit(.map, new);
    }

    // add new sublevel with displaced child
    const packed_data_index = @popCount(map.datamask & (slotmask - 1));
    const packed_node_index = @popCount(map.nodemask & (slotmask - 1));
    const subkey = map.data()[2 * packed_data_index];
    const subval = map.data()[2 * packed_data_index + 1];
    const subctx = MapKeyContext.initDepth(subkey.load(.acquire), keyctx.depth + 1);
    const subslot = subctx.slot();
    const sub = gc.alloc(.map, 2) catch @panic("GC allocation failure");
    sub.datamask = @as(u64, 1) << @intCast(subslot);
    sub.nodemask = 0;
    sub.datalen = 1;
    sub.nodelen = 0;
    const subdata = sub.data();
    subdata[0] = subkey;
    subdata[1] = subval;

    // then insert into that sublevel
    const new = gc.alloc(.map, 2 * (map.datalen - 1) + map.nodelen + 1) catch
        @panic("GC allocation failure");
    new.datamask = map.datamask & ~slotmask;
    new.nodemask = map.nodemask | slotmask;
    new.datalen = map.datalen - 1;
    new.nodelen = map.nodelen + 1;
    const newdata = new.data();
    const olddata = map.data();
    @memcpy(newdata[0..], olddata[0 .. 2 * packed_data_index]);
    @memcpy(
        newdata[2 * packed_data_index ..],
        olddata[2 * packed_data_index + 2 .. 2 * map.datalen],
    );
    const newnodes = new.nodes();
    const oldnodes = map.nodes();
    @memcpy(newnodes[0..], oldnodes[0..packed_node_index]);
    newnodes[packed_node_index].store(_assocImpl(
        gc,
        gc.commit(.map, sub),
        keyctx.next(),
        objval,
    ), .release);
    @memcpy(newnodes[packed_node_index + 1 ..], oldnodes[packed_node_index..map.nodelen]);

    return gc.commit(.map, new);
}

pub fn dissoc(objmap: ?*Object, gc: *GC, objkey: ?*Object) ?*Object {
    const obj = objmap orelse return null;
    return _dissocImpl(gc, obj, MapKeyContext.init(objkey));
}
fn _dissocImpl(gc: *GC, objmap: *Object, keyctx: MapKeyContext) *Object {
    const map = objmap.as(.map);
    const slot = keyctx.slot();
    const slotmask = @as(u64, 1) << @intCast(slot);
    const is_data = map.datamask & slotmask > 0;
    const is_node = map.nodemask & slotmask > 0;
    std.debug.assert(!(is_data and is_node));

    if (!(is_data or is_node)) return objmap;

    if (is_data) {
        const packed_index = @popCount(map.datamask & (slotmask - 1));
        if (!eql(map.data()[2 * packed_index].load(.acquire), keyctx.objkey)) return objmap;
        if (map.datalen + map.nodelen == 1) return ObjectMap.create(gc);
        const new = gc.alloc(.map, 2 * (map.datalen - 1) + map.nodelen) catch
            @panic("GC allocation failure");
        new.datamask = map.datamask & ~slotmask;
        new.nodemask = map.nodemask;
        new.datalen = map.datalen - 1;
        new.nodelen = map.nodelen;
        const newdata = new.data();
        const olddata = map.data();
        @memcpy(newdata[0..], olddata[0 .. 2 * packed_index]);
        @memcpy(
            newdata[2 * packed_index ..],
            olddata[2 * packed_index + 2 .. 2 * map.datalen + map.nodelen],
        );
        return gc.commit(.map, new);
    }

    const packed_index = @popCount(map.nodemask & (slotmask - 1));
    const objresult = _dissocImpl(gc, map.nodes()[packed_index].load(.acquire), keyctx.next());
    if (eql(map.nodes()[packed_index].load(.acquire), objresult)) return objmap;

    const result = objresult.as(.map);
    if (result.nodelen == 0 and result.datalen == 1) {
        if (map.datalen + map.nodelen == 1) {
            // this node has only one child
            // and that child is just a kv after the deletion
            // so we can just keep that kv and get rid of this node
            return objresult;
        } else {
            // a node child of this node is now just a kv
            // so store that kv directly here instead
            // (node without subnode) with key
            const packed_data_index = @popCount(map.datamask & (slotmask - 1));
            const packed_node_index = @popCount(map.nodemask & (slotmask - 1));
            const new = gc.alloc(.map, 2 * (map.datalen + 1) + map.nodelen - 1) catch
                @panic("GC allocation failure");
            new.datamask = map.datamask | slotmask;
            new.nodemask = map.nodemask & ~slotmask;
            new.datalen = map.datalen + 1;
            new.nodelen = map.nodelen - 1;
            const newdata = new.data();
            const olddata = map.data();
            @memcpy(newdata[0..], olddata[0 .. 2 * packed_data_index]);
            newdata[2 * packed_data_index] = result.data()[0];
            newdata[2 * packed_data_index + 1] = result.data()[1];
            @memcpy(
                newdata[2 * packed_data_index + 2 ..],
                olddata[2 * packed_data_index .. 2 * map.datalen],
            );
            const newnodes = new.nodes();
            const oldnodes = map.nodes();
            @memcpy(newnodes[0..], oldnodes[0..packed_node_index]);
            @memcpy(
                newnodes[packed_node_index..],
                oldnodes[packed_node_index + 1 .. map.nodelen],
            );
            return gc.commit(.map, new);
        }
    }
    // node updated with result
    // the node child of this node has been altered but is still a node
    // so just replace that node-child with the result
    std.debug.assert(result.datalen + result.nodelen > 0);
    const new = gc.alloc(.map, 2 * map.datalen + map.nodelen) catch
        @panic("GC allocation failure");
    new.datamask = map.datamask;
    new.nodemask = map.nodemask;
    new.datalen = map.datalen;
    new.nodelen = map.nodelen;
    const newdata = new.data();
    const olddata = map.data();
    @memcpy(newdata[0..], olddata[0 .. 2 * map.datalen + map.nodelen]);
    new.nodes()[packed_index].store(objresult, .unordered);
    return gc.commit(.map, new);
}

const MapKeyContext = struct {
    objkey: ?*Object,
    keyhash: u64,
    depth: usize,

    // though it wastes some bits in the hash
    // the improved performance on divide and modulo seems to be worth it
    const LEVELS_PER_HASH = 8;

    fn init(objkey: ?*Object) MapKeyContext {
        return .{
            .objkey = objkey,
            .keyhash = Object.hash(objkey, 0),
            .depth = 0,
        };
    }

    fn initDepth(objkey: ?*Object, depth: usize) MapKeyContext {
        return .{
            .objkey = objkey,
            .keyhash = Object.hash(objkey, depth / LEVELS_PER_HASH),
            .depth = depth,
        };
    }

    fn next(old: MapKeyContext) MapKeyContext {
        var new = MapKeyContext{
            .objkey = old.objkey,
            .keyhash = old.keyhash,
            .depth = old.depth + 1,
        };
        if (old.depth / LEVELS_PER_HASH < new.depth / LEVELS_PER_HASH) {
            new.keyhash = Object.hash(new.objkey, new.depth / LEVELS_PER_HASH);
        }
        return new;
    }

    fn slot(ctx: MapKeyContext) usize {
        return (ctx.keyhash >> @intCast((ctx.depth % LEVELS_PER_HASH) * 6)) & 0b11_1111;
    }
};

test "fuzz" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    const rand = rng.random();

    const ns = [_]u32{ 32, 128, 512, 2048, 8192, 32768, 131072, 524288 };
    const m = 100000;

    for (ns) |n| {
        var gc = try GC.init();
        try gc.startCollector();
        defer gc.deinit();

        var h = ObjectMap.create(&gc);

        var s = std.AutoHashMap(u32, u32).init(alloc);
        defer s.deinit();

        for (0..m) |_| {
            const x = rand.intRangeLessThan(u32, 0, n);
            const y = rand.intRangeLessThan(u32, 0, n);
            const a = ObjectReal.create(&gc, @floatFromInt(x));
            const b = ObjectReal.create(&gc, @floatFromInt(y));

            std.debug.assert(contains(h, a) == s.contains(x));
            if (contains(h, a)) {
                std.debug.assert(
                    @as(u32, @intFromFloat(get(h, a).?.as(.real).data)) == s.get(x).?,
                );
                const h2 = dissoc(h, &gc, a);
                h = h2.?;
                _ = s.remove(x);
            } else {
                const h2 = assoc(h, &gc, a, b);
                h = h2;
                try s.put(x, y);
            }

            const u = rand.intRangeLessThan(u32, 0, n);
            const v = rand.intRangeLessThan(u32, 0, n);
            const c = ObjectReal.create(&gc, @floatFromInt(u));
            const d = ObjectReal.create(&gc, @floatFromInt(v));
            if (rand.boolean()) {
                const h2 = dissoc(h, &gc, c);
                h = h2.?;
                _ = s.remove(u);
            } else {
                const h2 = assoc(h, &gc, c, d);
                h = h2;
                try s.put(u, v);
            }

            if (gc.shouldTrace()) {
                try gc.traceRoot(&h);
                try gc.releaseEden();
            }
        }
    }
}
