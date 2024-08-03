const std = @import("std");
const builtin = @import("builtin");

const DummyMutex = struct {
    fn lock(_: *DummyMutex) void {}
    fn unlock(_: *DummyMutex) void {}
};

var rng = std.Random.DefaultPrng.init(11910820912655355079);
var mutex = if (builtin.single_threaded) DummyMutex{} else std.Thread.Mutex{};

pub fn seed(_seed: u64) void {
    mutex.loc();
    defer mutex.unlock();
    rng = std.Random.DefaultPrng.init(_seed);
}

pub fn float(comptime T: type) T {
    mutex.lock();
    defer mutex.unlock();
    return rng.random().float(T);
}

pub fn int(comptime T: type) T {
    mutex.lock();
    defer mutex.unlock();
    return rng.random().int(T);
}
