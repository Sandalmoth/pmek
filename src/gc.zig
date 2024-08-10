const std = @import("std");

const Kind = @import("object.zig").Kind;
pub const Object = @import("object.zig").Object;
const ObjectType = @import("object.zig").ObjectType;

pub const Page = struct {
    const LINE_SIZE = 256;

    // spend one line on metadata, and one mark byte per line, how many lines can fit?
    // (p - l) / (l + n) = n
    // n**2 + n*l + l - p = 0
    // n = (sqrt(l**2 - 4l + 4p) - l) / 2
    // (we can ignore the negative solution)
    const N_LINES = (std.math.sqrt(
        LINE_SIZE * LINE_SIZE - 4 * LINE_SIZE + 4 * std.mem.page_size,
    ) - LINE_SIZE) / 2;

    next: ?*Page,
    start: usize,
    end: usize,
    marks: [N_LINES]u8 align(LINE_SIZE),
    data: [N_LINES * LINE_SIZE]u8 align(std.mem.page_size),

    // init from undefined memory
    pub fn init(page: *Page) void {
        page.next = null;
        page.start = undefined;
        page.end = undefined;
        page.marks = [_]u8{0} ** N_LINES;
        page.data = undefined;
    }

    // initialize start/end (from either init or recycle)
    pub fn nextRegion(page: *Page, comptime first: bool) void {
        var i: usize = if (first) 0 else page.end / LINE_SIZE;
        while (i < N_LINES and page.marks[i] != 0) : (i += 1) {}
        page.start = i * LINE_SIZE;
        while (i < N_LINES and page.marks[i] == 0) : (i += 1) {}
        page.end = i * LINE_SIZE;
    }

    pub fn useBackupAllocator(comptime kind: Kind, len: usize) bool {
        const sz = ObjectType(kind).size(len);
        return sz > (N_LINES / 2) * LINE_SIZE;
    }

    pub fn canFit(page: *Page, comptime kind: Kind, len: usize) bool {
        const sz = ObjectType(kind).size(len);
        return page.start + sz <= page.end;
    }

    pub fn isFull(page: *Page) bool {
        std.debug.assert(page.start <= page.data.len);
        return page.start >= page.data.len;
    }

    pub fn isFree(page: *Page) bool {
        var acc: usize = 0;
        for (page.marks) |mark| acc += mark;
        return acc == 0;
    }

    pub fn alloc(page: *Page, comptime kind: Kind, len: usize) *ObjectType(kind) {
        std.debug.assert(page.canFit(kind, len));
        const sz = ObjectType(kind).size(len);
        const obj: *ObjectType(kind) = @alignCast(@ptrCast(&page.data[page.start]));
        obj.kind = kind;
        page.start += sz;
        std.debug.assert(page.start <= page.end);
        if (page.start >= page.end) page.nextRegion(false);
        return obj;
    }

    pub fn unmark(page: *Page) void {
        page.marks = [_]u8{0} ** N_LINES;
    }

    pub fn markRange(page: *Page, _start: usize, _end: usize) void {
        for (_start / LINE_SIZE..((_end - 1) / LINE_SIZE) + 1) |i| page.marks[i] +|= 1;
    }

    pub fn markObject(page: *Page, obj: *Object, comptime kind: Kind, len: usize) void {
        std.debug.assert(page == obj.page());
        std.debug.assert(obj.kind == kind);
        const sz = ObjectType(kind).size(len);
        const of = @intFromPtr(obj) - @intFromPtr(&page.data[0]);
        page.markRange(of, of + sz);
    }
};

comptime {
    std.debug.assert(@sizeOf(Page) == std.mem.page_size);
    std.debug.assert(@alignOf(Page) == std.mem.page_size);
}

pub const GC = struct {
    backup_allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    free: ?*Page,
    recycled: ?*Page,
    n_pages: usize,

    allocator: GCAllocator,
    collector: GCCollector,
    waiting_for_roots: std.atomic.Value(bool),

    pub fn create(backup_allocator: std.mem.Allocator) *GC {
        const gc = backup_allocator.create(GC) catch @panic("Allocation failure");
        gc.* = .{
            .backup_allocator = backup_allocator,
            .mutex = std.Thread.Mutex{},
            .free = null,
            .recycled = null,
            .n_pages = 0,
            .allocator = undefined,
            .collector = undefined,
            .waiting_for_roots = undefined,
        };
        gc.waiting_for_roots.store(false, .unordered);
        gc.allocator = .{
            .gc = gc,
            .free = gc.getFree(),
            .recycled = gc.getRecycled(),
            .used = null,
            .roots = std.ArrayList(*Object).init(backup_allocator),
        };
        gc.allocator.free.nextRegion(true);
        gc.allocator.recycled.nextRegion(true);
        gc.collector = .{
            .gc = gc,
            .used = null,
            .worker = undefined, // set by start
            .should_run = undefined, // set by start
        };
        GCCollector.start(&gc.collector);
        return gc;
    }

    fn destroyPageList(root: ?*Page) void {
        var walk = root;
        while (walk) |p| {
            walk = p.next;
            std.heap.page_allocator.destroy(p);
        }
    }

    pub fn destroy(gc: *GC) void {
        GCCollector.shutdown(&gc.collector);
        gc.allocator.roots.deinit();
        // TODO if we have large allocs, how do we free them?
        destroyPageList(gc.free);
        destroyPageList(gc.recycled);
        destroyPageList(gc.allocator.free);
        destroyPageList(gc.allocator.recycled);
        destroyPageList(gc.allocator.used);
        destroyPageList(gc.collector.used);
        gc.backup_allocator.destroy(gc);
    }

    pub fn getFree(gc: *GC) *Page {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        if (gc.free == null) {
            const page = std.heap.page_allocator.create(Page) catch @panic("Allocationn failure");
            page.init();
            gc.n_pages += 1;
            return page;
        } else {
            const page = gc.free.?;
            gc.free = page.next;
            page.next = null;
            return page;
        }
    }

    pub fn getRecycled(gc: *GC) *Page {
        gc.mutex.lock();
        if (gc.recycled != null) {
            const page = gc.recycled.?;
            gc.recycled = page.next;
            page.next = null;
            gc.mutex.unlock();
            return page;
        } else {
            gc.mutex.unlock();
            return gc.getFree();
        }
    }

    pub fn putFree(gc: *GC, page: *Page) void {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        page.next = gc.free;
        gc.free = page;
    }

    pub fn putRecycled(gc: *GC, page: *Page) void {
        gc.mutex.lock();
        defer gc.mutex.unlock();
        page.next = gc.recycled;
        gc.recycled = page;
    }
};

pub const GCAllocator = struct {
    gc: *GC,
    free: *Page, // not a linked list
    recycled: *Page, // not a linked list
    used: ?*Page,
    roots: std.ArrayList(*Object),

    pub fn new(gca: *GCAllocator, comptime kind: Kind, len: usize) *ObjectType(kind) {
        if (Page.useBackupAllocator(kind, len)) {
            @panic("TODO");
        }
        if (gca.recycled.canFit(kind, len)) {
            const obj = gca.recycled.alloc(kind, len);
            if (gca.recycled.isFull()) gca.newRecycled();
            return obj;
        }
        if (!gca.free.canFit(kind, len)) gca.newFree();
        std.debug.assert(gca.free.canFit(kind, len));
        const obj = gca.free.alloc(kind, len);
        if (gca.free.isFull()) gca.newFree();
        return obj;
    }

    pub fn newReal(gca: *GCAllocator, val: f64) *Object {
        const obj = gca.new(.real, 0);
        obj.val = val;
        return @alignCast(@ptrCast(obj));
    }

    pub fn newCons(gca: *GCAllocator, car: ?*Object, cdr: ?*Object) *Object {
        const obj = gca.new(.cons, 0);
        obj.car = car;
        obj.cdr = cdr;
        return @alignCast(@ptrCast(obj));
    }

    pub fn newString(gca: *GCAllocator, val: []const u8) *Object {
        const obj = gca.new(.string, val.len);
        obj.len = val.len;
        @memcpy(obj.data(), val);
        return @alignCast(@ptrCast(obj));
    }

    pub fn newChamp(gca: *GCAllocator) *Object {
        const obj = gca.new(.champ, 0);
        obj.datamask = 0;
        obj.nodemask = 0;
        obj.datalen = 0;
        obj.nodelen = 0;
        return @alignCast(@ptrCast(obj));
    }

    pub fn newAmt(gca: *GCAllocator) *Object {
        const obj = gca.new(.amt, 0);
        obj.level = 0;
        obj.len = 0;
        return @alignCast(@ptrCast(obj));
    }

    fn newFree(gca: *GCAllocator) void {
        gca.free.next = gca.used;
        gca.used = gca.free;
        gca.free = gca.gc.getFree();
        gca.free.nextRegion(true);
    }

    fn newRecycled(gca: *GCAllocator) void {
        gca.recycled.next = gca.used;
        gca.used = gca.recycled;
        gca.recycled = gca.gc.getRecycled();
        gca.recycled.nextRegion(true);
        if (gca.recycled.isFull()) gca.newRecycled();
    }

    pub fn shouldTrace(gca: *GCAllocator) bool {
        return gca.gc.waiting_for_roots.load(.unordered);
    }

    pub fn traceRoot(gca: *GCAllocator, root: ?*Object) void {
        if (root == null) return;
        gca.roots.append(root.?) catch @panic("Allocation failure");
    }

    // relinquish all the used pages to the collector thread
    pub fn endTrace(gca: *GCAllocator) void {
        std.debug.assert(gca.gc.collector.used == null);
        gca.gc.collector.used = gca.used;
        gca.used = null;
        gca.gc.waiting_for_roots.store(false, .unordered);
    }
};

const GCCollector = struct {
    gc: *GC,
    used: ?*Page,

    worker: std.Thread,
    should_run: std.atomic.Value(bool),

    fn start(gcc: *GCCollector) void {
        gcc.should_run.store(true, .unordered);
        gcc.worker = std.Thread.spawn(.{}, collect, .{gcc}) catch @panic("Failed to spawn thread");
    }

    fn shutdown(gcc: *GCCollector) void {
        gcc.should_run.store(false, .unordered);
        gcc.worker.join();
    }

    fn collect(gcc: *GCCollector) void {
        loop: while (gcc.should_run.load(.unordered)) {
            gcc.gc.waiting_for_roots.store(true, .unordered);
            while (gcc.gc.waiting_for_roots.load(.unordered)) {
                if (!gcc.should_run.load(.unordered)) break :loop;
                std.time.sleep(1_000_000);
            }
            if (gcc.used == null) {
                std.time.sleep(1_000_000);
                continue :loop;
            }

            var walk = gcc.used;
            while (walk) |p| {
                p.unmark();
                walk = p.next;
            }

            for (gcc.gc.allocator.roots.items) |root| {
                gcc.trace(root);
            }
            gcc.gc.allocator.roots.clearRetainingCapacity();

            walk = gcc.used;
            while (walk) |p| {
                walk = p.next;
                if (p.isFree()) {
                    gcc.gc.putFree(p);
                } else {
                    gcc.gc.putRecycled(p);
                }
            }
            gcc.used = null;
        }
    }

    fn trace(gcc: *GCCollector, root: ?*Object) void {
        const obj = root orelse return;
        switch (obj.kind) {
            .real => obj.page().markObject(obj, .real, 0),
            .cons => {
                obj.page().markObject(obj, .cons, 0);
                const cons = obj.as(.cons);
                gcc.trace(cons.car);
                gcc.trace(cons.cdr);
            },
            .string => obj.page().markObject(obj, .string, obj.as(.string).len),
            .champ => {
                const champ = obj.as(.champ);
                obj.page().markObject(obj, .champ, 2 * champ.datalen + champ.nodelen);
                const data = champ.data();
                for (0..2 * champ.datalen + champ.nodelen) |i| gcc.trace(data[i]);
            },
            .amt => {
                const amt = obj.as(.amt);
                obj.page().markObject(obj, .amt, amt.len);
                const data = amt.data();
                for (0..amt.len) |i| gcc.trace(data[i]);
            },
        }
    }
};

test "cons-mania" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp() *% 89));
    const rand = rng.random();

    const n = 16;
    var roots: [n]?*Object = [_]?*Object{null} ** n;

    for (0..1_000_000) |i| {
        // std.time.sleep(1);
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
        // if (i % 10_000 == 0) std.debug.print("{}\t{}\n", .{ i, gc.n_pages });
    }
}
