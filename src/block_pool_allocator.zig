const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    block_size: comptime_int = std.mem.page_size,
    reservoir: comptime_int = 1024,
    preheat: comptime_int = 1024,
    thread_safe: bool = !builtin.single_threaded,
};

// neat design from std.GeneralPurposeAllocator
const DummyMutex = struct {
    fn lock(_: *DummyMutex) void {}
    fn unlock(_: *DummyMutex) void {}
};

pub fn BlockPoolAllocator(comptime config: Config) type {
    std.debug.assert(config.preheat <= config.preheat);
    std.debug.assert(std.math.isPowerOfTwo(config.block_size));

    const Block = struct {
        bytes: [config.block_size]u8 align(config.block_size),
    };

    return struct {
        const Pool = @This();
        pub const BLOCK_SIZE = config.block_size;

        alloc: std.mem.Allocator,
        mutex: if (config.thread_safe) std.Thread.Mutex else DummyMutex,
        free: []*Block,
        n_free: usize align(64),

        // stats
        n_total: usize,
        n_allocs: usize, // if this grows much bigger than n_total, try increasing reservoir

        pub fn init(_alloc: std.mem.Allocator) !Pool {
            var pool = Pool{
                .alloc = _alloc,
                .mutex = if (config.thread_safe) std.Thread.Mutex{} else DummyMutex{},
                .free = undefined,
                .n_free = 0,
                .n_total = 0,
                .n_allocs = 0,
            };
            pool.free = try pool.alloc.alloc(*Block, config.reservoir);
            while (pool.n_free < config.preheat) {
                pool.free[pool.n_free] = try pool.alloc.create(Block);
                errdefer pool.deinit();
                pool.n_free += 1;
                pool.n_total += 1;
                pool.n_allocs += 1;
            }
            return pool;
        }

        pub fn deinit(pool: *Pool) void {
            for (0..pool.n_free) |i| pool.alloc.destroy(pool.free[i]);
            pool.alloc.free(pool.free);
            pool.* = undefined;
        }

        pub fn allocator(pool: *Pool) std.mem.Allocator {
            return .{ .ptr = pool, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            } };
        }

        pub fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret: usize) ?[*]u8 {
            const pool: *Pool = @alignCast(@ptrCast(ctx));
            _ = ret;
            if (len > config.block_size) return null;
            if (config.block_size == std.mem.page_size) {
                // the zig allocator interface already comptime asserts
                // that the alignment is less than the page size
                // so we only need to check this if the block size is smaller than the page size
                if (@as(usize, 1) << log2_align > config.block_size) return null;
            }
            return @ptrCast(@alignCast(pool.getBlock() catch return null));
        }

        pub fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret: usize) bool {
            _ = ctx;
            _ = buf;
            _ = log2_align;
            _ = ret;
            return new_len <= config.block_size;
        }

        pub fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret: usize) void {
            const pool: *Pool = @alignCast(@ptrCast(ctx));
            _ = log2_align;
            _ = ret;
            pool.returnBlock(buf.ptr);
        }

        fn getBlock(pool: *Pool) !*anyopaque {
            pool.mutex.lock();
            defer pool.mutex.unlock();
            if (pool.n_free == 0) {
                // we have no free blocks, just allocate a new one
                const new_block = try pool.alloc.create(Block);
                pool.n_total += 1;
                pool.n_allocs += 1;
                return new_block;
            } else {
                pool.n_free -= 1;
                return pool.free[pool.n_free];
            }
        }

        fn returnBlock(pool: *Pool, ptr: *anyopaque) void {
            pool.mutex.lock();
            defer pool.mutex.unlock();
            const block: *Block = @alignCast(@ptrCast(ptr));
            if (pool.n_free == config.reservoir) {
                // we have too many free blocks, destroy this one
                pool.n_total -= 1;
                pool.alloc.destroy(block);
            } else {
                pool.free[pool.n_free] = block;
                pool.n_free += 1;
            }
        }
    };
}

comptime {
    const BP = BlockPoolAllocator(.{});
    std.debug.assert(@alignOf(BP) == 64);
    std.debug.assert(@sizeOf(BP) <= 64);
}

test "basic functionality" {
    var bpa = try BlockPoolAllocator(.{ .block_size = 16 }).init(std.testing.allocator);
    defer bpa.deinit();
    const alloc = bpa.allocator();

    const p1 = try alloc.create(u32);
    const p2 = try alloc.create(u32);
    const p3 = try alloc.create(u32);

    // uniqueness
    try std.testing.expect(p1 != p2);
    try std.testing.expect(p1 != p3);
    try std.testing.expect(p2 != p3);

    alloc.destroy(p2);
    const p4 = try alloc.create(u32);

    // memory reuse
    try std.testing.expect(p2 == p4);

    alloc.destroy(p1);
    alloc.destroy(p3);
    alloc.destroy(p4);

    // protection against impossible allocations
    try std.testing.expectError(error.OutOfMemory, alloc.create([std.mem.page_size + 1]u8));
    try std.testing.expectError(
        error.OutOfMemory,
        alloc.create(struct { a: u32 align(32) }),
    );
}
