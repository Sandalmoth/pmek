const std = @import("std");
const builtin = @import("builtin");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const ObjectType = @import("object.zig").ObjectType;
const rng = @import("shared_rng.zig");

const Page = struct {
    next: ?*Page,
    offset: usize,
    mark: bool, // should this page be evacuated?
    data: [std.mem.page_size - 32]u8 align(std.mem.page_size),

    fn init() Page {
        return .{
            .offset = 0,
            .next = null,
            .mark = false,
            .data = undefined,
        };
    }

    /// for types that aren't varsized, len must be 0
    /// for .map it must be the number of children (i.e. 2 * datalen + nodelen)
    /// for .string it must be the number of bytes required to store it
    fn alloc(page: *Page, comptime kind: Kind, len: usize) ?*ObjectType(kind) {
        // to alloc an object on a page, simplpy make sure there is room and then bump-allocate
        switch (kind) {
            .real, .cons => std.debug.assert(len == 0),
            .map => std.debug.assert(len <= 128),
            .string => {},
        }

        const addr = page.offset;
        var offset = page.offset;
        offset += ObjectType(kind).size(len);
        std.debug.assert(std.mem.isAlignedLog2(offset, 4)); // size() must always multiple of 16

        if (offset <= page.data.len) {
            const obj: *ObjectType(kind) = @alignCast(@ptrCast(&page.data[addr]));
            obj.head.fwd.store(@ptrCast(obj), .unordered);
            obj.head.kind = kind;
            obj.head.finished = false;
            obj.head.using_backup_allocator = false;
            page.offset = offset;
            return obj;
        } else {
            return null;
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(Page) <= std.mem.page_size);
}

const DummyMutex = struct {
    fn lock(_: *DummyMutex) void {}
    fn unlock(_: *DummyMutex) void {}
    fn tryLock(_: *DummyMutex) bool {
        return true;
    }
};

// a single one of these exists (for each vm instantiation)
// and it handles collecting garbage
pub const GC = struct {
    const multithreaded = !builtin.single_threaded;

    backing_allocator: std.mem.Allocator = std.heap.page_allocator,
    free: ?*Page = null,
    n_free: usize = 0,
    mutex_free: if (multithreaded) std.Thread.Mutex else DummyMutex,

    eden: ?*Page = null,
    from: ?*Page = null,
    survivor: ?*Page = null,
    discard: ?*Page = null,

    roots: std.ArrayListUnmanaged(*Object),

    p_compact: f64 = 0.5,
    n_compact_allocs: usize = 0,

    collector_thread: std.Thread,
    waiting_for_roots: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    collector_should_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    collect_timer: std.time.Timer,
    collect_interval: u64 = 200_000_000,

    pub inline fn init() !GC {
        const gc = GC{
            .collector_thread = undefined,
            .mutex_free = if (multithreaded) std.Thread.Mutex{} else DummyMutex{},
            .roots = std.ArrayListUnmanaged(*Object){},
            .collect_timer = try std.time.Timer.start(),
        };
        return gc;
    }

    pub fn startCollector(gc: *GC) !void {
        if (!multithreaded) return;
        gc.collector_thread = try std.Thread.spawn(.{}, GC.collector, .{gc});
    }

    pub fn deinit(gc: *GC) void {
        gc.collector_should_run.store(false, .unordered);
        if (multithreaded) gc.collector_thread.join();
        if (gc.mutex_free.tryLock()) {
            gc.mutex_free.unlock();
        } else {
            // indicates some kind of unexpected use, shoudn't really happen
            std.log.err("GC.mutex_free was locked during call to GC.deinit", .{});
        }
        var walk: ?*Page = gc.free;
        while (walk) |p| {
            walk = p.next;
            gc.backing_allocator.destroy(p);
            gc.n_free -= 1;
        }
        std.debug.assert(gc.n_free == 0);
        walk = gc.eden;
        while (walk) |p| {
            walk = p.next;
            gc.backing_allocator.destroy(p);
        }
        walk = gc.from;
        while (walk) |p| {
            walk = p.next;
            gc.backing_allocator.destroy(p);
        }
        walk = gc.survivor;
        while (walk) |p| {
            walk = p.next;
            gc.backing_allocator.destroy(p);
        }
        walk = gc.discard;
        while (walk) |p| {
            walk = p.next;
            gc.backing_allocator.destroy(p);
        }
        gc.roots.deinit(gc.backing_allocator);
        gc.* = undefined;
    }

    /// performs the allocation, but doesn't compute the hash
    /// marks the object as unfinished
    /// do not allow the alloced object to escape before calling commit
    /// but, updates are allowed before commit
    /// for types that aren't varsized, len should be 0
    /// for .map it should be the number of children (i.e. 2 * datalen + nodelen)
    /// for .string it should be the number of bytes required to store it
    pub fn alloc(gc: *GC, comptime kind: Kind, len: usize) !*ObjectType(kind) {
        if (gc.eden == null) try gc.newEdenPage();
        var result = gc.eden.?.alloc(kind, len);
        if (result) |r| return r;
        try gc.newEdenPage(); // page couldn't fit our object, make a new one
        result = gc.eden.?.alloc(kind, len);
        if (result) |r| {
            return r;
        } else {
            result = @alignCast(@ptrCast(
                try gc.backing_allocator.alignedAlloc(u8, 16, ObjectType(kind).size(len)),
            ));
            std.debug.assert(result != null);
            result.?.head.fwd.store(@ptrCast(result), .unordered);
            result.?.head.kind = kind;
            result.?.head.finished = false;
            result.?.head.using_backup_allocator = true;
            return result.?;
        }
    }

    /// marks the object as usable
    pub fn commit(gc: *GC, comptime kind: Kind, obj: *ObjectType(kind)) *Object {
        // without memoizing the hash of all objects, this isn't really needed
        // but I'll keep it around just for the safety of the finished marker
        std.debug.assert(!obj.head.finished);
        std.debug.assert(obj.head.kind == kind);
        obj.head.finished = true;

        if (!multithreaded and gc.collect_timer.read() > gc.collect_interval) {
            gc.collect_timer.reset();
            gc.waiting_for_roots.store(true, .unordered);
        }

        return @ptrCast(obj);
    }

    pub fn shouldTrace(gc: *GC) bool {
        return gc.waiting_for_roots.load(.acquire);
    }

    pub fn traceRoot(gc: *GC, root: **Object) !void {
        // STOP THE WORLD
        // update the given roots if they point to forwarded objects
        // add root to the root dataset so we can trace it later
        root.* = root.*.fwd.load(.unordered);
        try gc.roots.append(gc.backing_allocator, root.*);
    }

    pub fn releaseEden(gc: *GC) !void {
        // STOP THE WORLD
        // NO UNREACHABLE YET NEEDED VALUE MAY EXIST WHEN THIS IS CALLED
        // (which could happen during e.g. path-copying insert operations)
        // move from-space to discard-space
        // move eden-space to from-space
        gc.discard = gc.from;
        gc.from = gc.eden;
        gc.eden = null;

        gc.waiting_for_roots.store(false, .release);
        if (!multithreaded) try gc.collect();
    }

    fn collector(gc: *GC) !void {
        while (gc.collector_should_run.load(.unordered)) {
            while (gc.waiting_for_roots.load(.unordered)) {
                if (!gc.collector_should_run.load(.unordered)) return;
                std.time.sleep(1_000_000);
            }
            try gc.collect();

            while (gc.collect_timer.read() < gc.collect_interval) std.time.sleep(1_000_000);
            gc.collect_timer.reset();
            gc.waiting_for_roots.store(true, .unordered);
        }
    }

    fn collect(gc: *GC) !void {
        std.debug.print("######## ran collect {}\n", .{multithreaded});

        // CONCURRENT
        // move some of survivor-space to from-space (dynamic probability?)
        // mark all pages in from-space
        // trace root dataset
        // - if forwarded, update the reference
        // - if on from-space page, replicate in to-space
        // clear root dataset
        // destroy discard-space

        var n_survivors_compacted: usize = 0;
        var parent: *?*Page = &gc.survivor;
        var walk = gc.survivor;
        while (walk) |p| {
            if (rng.float(f64) < gc.p_compact) {
                parent.* = p.next;
                walk = p.next;
                p.next = gc.from;
                gc.from = p;
            } else {
                parent = &p.next;
                walk = p.next;
            }
            n_survivors_compacted += 1;
        }

        var n_from: usize = 0;
        walk = gc.from;
        while (walk) |p| {
            p.mark = true;
            walk = p.next;
            n_from += 1;
        }

        gc.n_compact_allocs = 0;
        for (gc.roots.items) |root| try gc.trace(root);
        gc.roots.clearRetainingCapacity();
        walk = gc.discard;
        while (walk) |p| {
            walk = p.next;
            gc.destroyPage(p); // lots of mutex locking/unlocking
        }
        gc.discard = null;

        // the fewer pages we needed to allocate to fit the freed data
        // the more survivor pages we should try to compact next time
        // as the survivor space contained a lot of garbage
        // and vice versa

        // assume that the odds of surviving is the same in eden and survivor space (tunable?)
        const ratio = @as(f64, @floatFromInt(gc.n_compact_allocs)) /
            @as(f64, @floatFromInt(n_from));
        gc.p_compact = 1.0 - ratio;

        gc.waiting_for_roots.store(true, .release);
    }

    fn pageOf(obj: *Object) *Page {
        std.debug.assert(obj.finished);
        const mask = ~@as(usize, std.mem.page_size - 1);
        return @ptrFromInt(@intFromPtr(obj) & mask);
    }

    fn trace(gc: *GC, ptr: ?*Object) !void {
        std.debug.print("so am i, still tracing, for this world to stop tracing\n", .{});
        const obj = ptr orelse return;
        switch (obj.kind) {
            .real, .string => {},
            .cons => {
                const cons = obj.as(.cons);
                if (cons.car.load(.acquire)) |car| {
                    cons.car.store(car.fwd.load(.acquire), .release);
                }
                if (cons.cdr.load(.acquire)) |cdr| {
                    cons.cdr.store(cdr.fwd.load(.acquire), .release);
                }
            },
            .map => {
                const map = obj.as(.map);
                for (0..2 * map.datalen + map.nodelen) |i| {
                    const child = map.data()[i].load(.acquire) orelse continue;
                    map.data()[i].store(child.fwd.load(.acquire), .release);
                }
            },
        }
        // now, replicate if we are on a marked page
        // and we haven't already been replicated
        if (obj == obj.fwd.load(.unordered) and pageOf(obj).mark) {
            const r = switch (obj.kind) {
                .real => try gc.dup(.real, obj),
                .cons => try gc.dup(.cons, obj),
                .map => try gc.dup(.map, obj),
                .string => try gc.dup(.string, obj),
            };
            obj.fwd.store(r, .release);
        }

        // finally, keep tracing
        switch (obj.kind) {
            .real, .string => {},
            .cons => {
                const cons = obj.as(.cons);
                // note, trace cdr first s.t. linked lists are sequential
                try gc.trace(cons.cdr.load(.acquire));
                try gc.trace(cons.car.load(.acquire));
            },
            .map => {
                const map = obj.as(.map);
                // i think this tracing-order is marginally better
                // but would need careful benchmarking, it's not a huge difference
                for (0..map.nodelen) |i| try gc.trace(map.nodes()[i].load(.acquire));
                for (0..map.datalen) |i| try gc.trace(map.data()[2 * i].load(.acquire));
                for (0..map.datalen) |i| try gc.trace(map.data()[2 * i + 1].load(.acquire));
            },
        }
    }

    fn allocSurvivor(gc: *GC, comptime kind: Kind, len: usize) !*ObjectType(kind) {
        if (gc.survivor == null) try gc.newSurvivorPage();
        var result = gc.survivor.?.alloc(kind, len);
        if (result) |r| return r;
        try gc.newSurvivorPage(); // page couldn't fit our object, make a new one
        result = gc.survivor.?.alloc(kind, len);
        if (result) |r| {
            return r;
        } else {
            // large objects are individually allocated during alloc
            // we never replicate them in the first place
            // so we cannot fail to replicate them on a survivor page
            unreachable;
        }
    }

    fn dup(gc: *GC, comptime kind: Kind, _old: *Object) !*Object {
        std.debug.assert(_old.finished); // disallow functions on unfinished allocations
        if (_old.using_backup_allocator) return _old;
        const old = _old.as(kind);
        const new = switch (kind) {
            .real, .cons => try gc.allocSurvivor(kind, 0),
            .map => try gc.allocSurvivor(kind, 2 * old.datalen + old.nodelen),
            .string => try gc.allocSurvivor(kind, old.len),
        };
        switch (kind) {
            .real => new.data = old.data,
            .cons => {
                new.car = old.car;
                new.cdr = old.cdr;
            },
            .map => {
                new.datamask = old.datamask;
                new.nodemask = old.nodemask;
                new.datalen = old.datalen;
                new.nodelen = old.nodelen;
                @memcpy(new.data(), old.data()[0 .. 2 * old.datalen + old.nodelen]);
            },
            .string => {
                new.len = old.len;
                @memcpy(new.data(), old.data()[0..old.len]);
            },
        }
        new.head.kind = kind;
        new.head.using_backup_allocator = false;
        std.debug.assert(@intFromPtr(new.head.fwd.load(.unordered)) == @intFromPtr(new));
        return gc.commit(kind, new);
    }

    fn newEdenPage(gc: *GC) !void {
        gc.mutex_free.lock();
        defer gc.mutex_free.unlock();
        var new: *Page = undefined;
        if (gc.n_free > 0) {
            std.debug.assert(gc.free != null);
            new = gc.free.?;
            gc.free = new.next;
            gc.n_free -= 1;
        } else {
            std.debug.assert(gc.free == null);
            new = try gc.backing_allocator.create(Page);
        }
        new.* = Page.init();
        new.next = gc.eden;
        gc.eden = new;
    }

    fn newSurvivorPage(gc: *GC) !void {
        gc.mutex_free.lock();
        defer gc.mutex_free.unlock();
        var new: *Page = undefined;
        if (gc.n_free > 0) {
            std.debug.assert(gc.free != null);
            new = gc.free.?;
            gc.free = new.next;
            gc.n_free -= 1;
        } else {
            std.debug.assert(gc.free == null);
            new = try gc.backing_allocator.create(Page);
        }
        new.* = Page.init();
        new.next = gc.survivor;
        gc.survivor = new;
        gc.n_compact_allocs += 1;
    }

    fn destroyPage(gc: *GC, page: *Page) void {
        gc.mutex_free.lock();
        defer gc.mutex_free.unlock();
        page.next = gc.free;
        gc.free = page;
        gc.n_free += 1;
        // TODO add heuristic to really destroy some pages if n_free is too large
    }
};

test "basic functionality" {
    var gc = try GC.init();
    try gc.startCollector();
    defer gc.deinit();

    const _a = try gc.alloc(.real, 0);
    _a.data = 1.0;
    var a = gc.commit(.real, _a);

    try gc.traceRoot(&a);
    try gc.releaseEden();

    std.time.sleep(500_000_000);
}

fn debugPrint(obj: ?*Object) void {
    if (obj == null) {
        std.debug.print("nil", .{});
        return;
    }
    const cons = obj.?.as(.cons);
    std.debug.print("(", .{});
    debugPrint(cons.car.load(.unordered));
    std.debug.print(" . ", .{});
    debugPrint(cons.cdr.load(.unordered));
    std.debug.print(")", .{});
}

test "conses all the way down" {
    var gc = try GC.init();
    try gc.startCollector();
    defer gc.deinit();

    var prng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    const rand = prng.random();

    var roots: [256]*Object = undefined;
    for (0..roots.len) |i| {
        const cons = try gc.alloc(.cons, 0);
        cons.car.store(null, .unordered);
        cons.cdr.store(null, .unordered);
        roots[i] = gc.commit(.cons, cons);
    }

    for (0..100000) |k| {
        std.debug.print("{}\n", .{k});
        if (gc.shouldTrace()) {
            for (0..256) |i| {
                try gc.traceRoot(&roots[i]);
            }
            try gc.releaseEden();
        }

        const x = rand.int(u8);
        const y = rand.int(u8);
        const z = rand.int(u8);
        const cons = try gc.alloc(.cons, 0);
        cons.car.store(roots[x], .unordered);
        cons.cdr.store(roots[y], .unordered);
        roots[z] = gc.commit(.cons, cons);
        // debugPrint(roots[z]);
    }
}
