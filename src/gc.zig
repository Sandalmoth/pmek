const std = @import("std");
const builtin = @import("builtin");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const ObjectType = @import("object.zig").ObjectType;

const Page = struct {
    next: ?*Page,
    offset: usize,
    mark: bool, // should this page be evacuated?
    discarded: bool, // mark pages that will be destroyed soon (debug help)
    destroyed: bool,
    data: [std.mem.page_size - 32]u8 align(std.mem.page_size),

    fn init() Page {
        return .{
            .offset = 0,
            .next = null,
            .mark = false,
            .discarded = false,
            .destroyed = false,
            .data = undefined,
        };
    }

    /// for types that aren't varsized, len must be 0
    fn alloc(page: *Page, comptime kind: Kind, len: usize) ?*ObjectType(kind) {
        std.debug.assert(!page.discarded);
        std.debug.assert(!page.destroyed);
        // to alloc an object on a page, simplpy make sure there is room and then bump-allocate
        switch (kind) {
            .int, .cons => std.debug.assert(len == 0),
        }

        const addr = page.offset;
        var offset = page.offset;
        offset += ObjectType(kind).size(len);
        std.debug.assert(std.mem.isAlignedLog2(offset, 4)); // size() must always multiple of 16

        if (offset <= page.data.len) {
            const obj: *ObjectType(kind) = @alignCast(@ptrCast(&page.data[addr]));
            obj.head.fwd.store(@ptrCast(obj), .release);
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

pub const GC = struct {
    mutex: std.Thread.Mutex,

    backing_allocator: std.mem.Allocator,
    free: ?*Page,
    n_free: usize,

    eden: ?*Page,
    from: ?*Page,
    survivor: ?*Page,
    discard: ?*Page,

    roots: std.ArrayListUnmanaged(*Object),

    collector_thread: std.Thread,
    waiting_for_roots: std.atomic.Value(bool),
    collector_should_run: std.atomic.Value(bool),

    collect_timer: std.time.Timer,
    collect_interval: u64,

    pub fn init(gc: *GC) !void {
        gc.mutex = std.Thread.Mutex{};
        gc.backing_allocator = std.heap.page_allocator;
        gc.free = null;
        gc.n_free = 0;
        gc.eden = null;
        gc.from = null;
        gc.survivor = null;
        gc.discard = null;
        gc.collect_interval = 100_000_000;
        gc.waiting_for_roots = std.atomic.Value(bool).init(false);
        gc.collector_should_run = std.atomic.Value(bool).init(true);
        gc.collect_timer = try std.time.Timer.start();
        gc.collector_thread = try std.Thread.spawn(.{}, GC.collector, .{gc});
        gc.roots = try std.ArrayListUnmanaged(*Object).initCapacity(
            gc.backing_allocator,
            std.mem.page_size / @sizeOf(*Object),
        );
    }

    pub fn deinit(gc: *GC) void {
        gc.collector_should_run.store(false, .unordered);
        gc.collector_thread.join();
        if (gc.mutex.tryLock()) {
            gc.mutex.unlock();
        } else {
            // indicates some kind of unexpected use, shoudn't really happen
            std.log.err("GC.mutex was locked during call to GC.deinit", .{});
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
            result.?.head.fwd.store(@ptrCast(result), .release);
            result.?.head.kind = kind;
            result.?.head.finished = false;
            result.?.head.using_backup_allocator = true;
            return result.?;
        }
    }

    /// marks the object as usable
    pub fn commit(gc: *GC, comptime kind: Kind, obj: *ObjectType(kind)) *Object {
        _ = gc;
        std.debug.assert(!obj.head.finished);
        std.debug.assert(obj.head.kind == kind);
        obj.head.finished = true;
        return @ptrCast(obj);
    }

    pub fn newInt(gc: *GC, val: i64) !*Object {
        const obj = try gc.alloc(.int, 0);
        obj.data = val;
        return gc.commit(.int, obj);
    }

    pub fn newCons(gc: *GC, car: ?*Object, cdr: ?*Object) !*Object {
        const obj = try gc.alloc(.cons, 0);
        obj.car.store(car, .unordered);
        obj.cdr.store(cdr, .unordered);
        return gc.commit(.cons, obj);
    }

    pub fn shouldTrace(gc: *GC) bool {
        return gc.waiting_for_roots.load(.acquire);
    }

    pub fn traceRoot(gc: *GC, root: **Object) !void {
        // STOP THE WORLD
        // update the given roots if they point to forwarded objects
        // add root to the root dataset so we can trace it later
        std.debug.print("updating root {*} -> {*}\n", .{ root.*, root.*.fwd.load(.unordered) });
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

        var walk = gc.discard;
        while (walk) |p| {
            p.discarded = true;
            walk = p.next;
        }

        gc.from = gc.eden;
        gc.eden = null;

        gc.waiting_for_roots.store(false, .release);
    }

    fn collector(gc: *GC) !void {
        loop: while (true) {
            gc.collect_timer.reset();
            while (gc.collect_timer.read() < gc.collect_interval) {
                if (!gc.collector_should_run.load(.acquire)) break :loop;
                std.time.sleep(1_000_000);
            }
            gc.waiting_for_roots.store(true, .release);

            while (gc.waiting_for_roots.load(.acquire)) {
                if (!gc.collector_should_run.load(.acquire)) break :loop;
                std.time.sleep(1_000_000);
            }
            try gc.collect();
        }
        std.debug.print("####################################\n", .{});
        std.debug.print("######## SHUTDOWN COLLECTOR ########\n", .{});
        std.debug.print("####################################\n", .{});
    }

    fn collect(gc: *GC) !void {
        std.debug.print("######## ran collect\n", .{});

        // CONCURRENT
        // move some of survivor-space to from-space (dynamic probability?)
        // mark all pages in from-space
        // trace root dataset
        // - if forwarded, update the reference
        // - if on from-space page, replicate in to-space
        // clear root dataset
        // destroy discard-space

        var parent: *?*Page = &gc.survivor;
        var walk = gc.survivor;
        while (walk) |p| {
            if (true) {
                parent.* = p.next;
                walk = p.next;
                p.next = gc.from;
                gc.from = p;
            } else {
                parent = &p.next;
                walk = p.next;
            }
        }

        var n_from: usize = 0;
        walk = gc.from;
        while (walk) |p| {
            p.mark = true;
            walk = p.next;
            n_from += 1;
        }
        std.debug.print("FROM SPAEC SIZE IS {}\n", .{n_from});

        for (gc.roots.items) |root| try gc.traceForward(root);
        for (gc.roots.items) |root| try gc.traceMove(root);
        gc.roots.clearRetainingCapacity();
        walk = gc.discard;
        while (walk) |p| {
            walk = p.next;
            gc.destroyPage(p); // lots of mutex locking/unlocking
        }
        gc.discard = null;
    }

    fn pageOf(obj: *Object) *Page {
        std.debug.assert(obj.finished);
        const mask = ~@as(usize, std.mem.page_size - 1);
        return @ptrFromInt(@intFromPtr(obj) & mask);
    }

    fn traceForward(gc: *GC, ptr: ?*Object) !void {
        if (ptr) |p| {
            // std.debug.assert(!pageOf(p).discarded);
            std.debug.assert(!pageOf(p).destroyed);
        }
        std.debug.print("tracing (forward)\n", .{});
        const obj = ptr orelse return;
        switch (obj.kind) {
            .int => {},
            .cons => {
                const cons = obj.as(.cons);
                if (cons.car.load(.acquire)) |car| {
                    cons.car.store(car.fwd.load(.acquire), .release);
                }
                if (cons.cdr.load(.acquire)) |cdr| {
                    cons.cdr.store(cdr.fwd.load(.acquire), .release);
                }
            },
        }

        // keep tracing
        switch (obj.kind) {
            .int => {
                std.debug.print("INT-TAIL\n", .{});
            },
            .cons => {
                const cons = obj.as(.cons);
                try gc.traceForward(cons.cdr.load(.acquire));
                try gc.traceForward(cons.car.load(.acquire));
            },
        }
    }

    fn traceMove(gc: *GC, ptr: ?*Object) !void {
        if (ptr) |p| {
            std.debug.assert(!pageOf(p).discarded);
            std.debug.assert(!pageOf(p).destroyed);
        }
        std.debug.print("tracing (move)\n", .{});
        const obj = ptr orelse return;
        if (obj != obj.fwd.load(.acquire)) {
            // we must have moved this object in this round already
            // hence we must also have moved it's children
            // so we can short circuit
            return;
        }
        // now, replicate if we are on a marked page
        // and we haven't already been replicated
        if (pageOf(obj).mark) {
            const r = switch (obj.kind) {
                .int => try gc.dup(.int, obj),
                .cons => try gc.dup(.cons, obj),
            };
            obj.fwd.store(r, .release);
        }

        // keep tracing
        switch (obj.kind) {
            .int => {},
            .cons => {
                const cons = obj.as(.cons);
                // note, trace cdr first s.t. linked lists are sequential
                try gc.traceMove(cons.cdr.load(.acquire));
                try gc.traceMove(cons.car.load(.acquire));
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
        std.debug.print("called dup on a {}\n", .{kind});
        std.debug.assert(_old.finished); // disallow functions on unfinished allocations
        if (_old.using_backup_allocator) return _old;
        const old = _old.as(kind);
        const new = switch (kind) {
            .int, .cons => try gc.allocSurvivor(kind, 0),
        };
        switch (kind) {
            .int => new.data = old.data,
            .cons => {
                new.car = old.car;
                new.cdr = old.cdr;
            },
        }
        new.head.kind = kind;
        new.head.using_backup_allocator = false;
        std.debug.assert(@intFromPtr(new.head.fwd.load(.acquire)) == @intFromPtr(new));
        return gc.commit(kind, new);
    }

    fn newEdenPage(gc: *GC) !void {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        var new: *Page = undefined;
        if (false) {
            // if (gc.n_free > 0) {
            std.debug.assert(gc.free != null);
            new = gc.free.?;
            gc.free = new.next;
            gc.n_free -= 1;
        } else {
            // std.debug.assert(gc.free == null);
            new = try gc.backing_allocator.create(Page);
        }
        new.* = Page.init();
        new.next = gc.eden;
        gc.eden = new;
    }

    fn newSurvivorPage(gc: *GC) !void {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        var new: *Page = undefined;
        if (false) {
            // if (gc.n_free > 0) {
            std.debug.assert(gc.free != null);
            new = gc.free.?;
            gc.free = new.next;
            gc.n_free -= 1;
        } else {
            // std.debug.assert(gc.free == null);
            new = try gc.backing_allocator.create(Page);
        }
        new.* = Page.init();
        new.next = gc.survivor;
        gc.survivor = new;
    }

    fn destroyPage(gc: *GC, page: *Page) void {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        std.debug.assert(!page.destroyed);
        page.destroyed = true;
        page.next = gc.free;
        gc.free = page;
        gc.n_free += 1;
        // TODO add heuristic to really destroy some pages if n_free is too large
    }
};

test "basic functionality" {
    var gc: GC = undefined;
    try gc.init();
    defer gc.deinit();

    var a = try gc.newInt(1);

    std.debug.print("{*} {*}\n", .{ a, a.fwd.load(.unordered) });
    debugPrint(a);

    while (!gc.shouldTrace()) std.time.sleep(1_000_000);
    try gc.traceRoot(&a);
    try gc.releaseEden();
    std.time.sleep(500_000_000);

    var b = try gc.newCons(a, null);

    std.debug.print("{*} {*}\n", .{ a, a.fwd.load(.unordered) });
    debugPrint(a);
    std.debug.print("{*} {*}\n", .{ b, b.fwd.load(.unordered) });
    debugPrint(b);

    while (!gc.shouldTrace()) std.time.sleep(1_000_000);
    try gc.traceRoot(&b);
    try gc.releaseEden();
    std.time.sleep(500_000_000);

    std.debug.print("{*} {*}\n", .{ b, b.fwd.load(.unordered) });
    debugPrint(b);

    var c = try gc.newCons(b, null);

    std.debug.print("{*} {*}\n", .{ c, c.fwd.load(.unordered) });
    debugPrint(c);

    while (!gc.shouldTrace()) std.time.sleep(1_000_000);
    try gc.traceRoot(&c);
    try gc.releaseEden();
    std.time.sleep(500_000_000);

    std.debug.print("{*} {*}\n", .{ c, c.fwd.load(.unordered) });
    debugPrint(c);
}

fn debugPrint(obj: ?*Object) void {
    _debugPrint(obj);
    std.debug.print("\n", .{});
}

fn _debugPrint(obj: ?*Object) void {
    if (obj == null) {
        std.debug.print("nil", .{});
        return;
    }
    std.debug.assert(!GC.pageOf(obj.?).destroyed);
    if (obj.?.kind == .int) {
        std.debug.print("{}", .{obj.?.as(.int).data});
        return;
    }
    const cons = obj.?.as(.cons);
    std.debug.print("(", .{});
    _debugPrint(cons.car.load(.acquire));
    std.debug.print(" . ", .{});
    _debugPrint(cons.cdr.load(.acquire));
    std.debug.print(")", .{});
}

test "conses all the way down" {
    var gc: GC = undefined;
    try gc.init();
    defer gc.deinit();

    var prng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    const rand = prng.random();

    const n = 256;

    var roots: [n]*Object = undefined;
    for (0..roots.len) |i| {
        const int = try gc.alloc(.int, 0);
        int.data = @intCast(i);
        roots[i] = gc.commit(.int, int);
    }

    for (0..1000) |k| {
        std.debug.print("{}\n", .{k});
        std.time.sleep(20_000_000);
        if (gc.shouldTrace()) {
            for (0..n) |i| {
                try gc.traceRoot(&roots[i]);
                debugPrint(roots[i]);
            }
            try gc.releaseEden();
        }

        const x = rand.int(u32) % n;
        if (true) {
            // if (rand.boolean()) {
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
            roots[z] = try gc.newCons(roots[x], roots[y]);
        } else {
            roots[x] = try gc.newInt(@intCast(k));
        }
    }
}
