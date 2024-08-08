const std = @import("std");

const Kind = @import("object.zig").Kind;

const RNG = struct {
    prng: std.Random.DefaultPrng = undefined,
    initialized: bool = false,
    mutex: std.Thread.Mutex = std.Thread.Mutex{},

    fn bits(r: *RNG) u64 {
        r.mutex.lock();
        defer r.mutex.unlock();
        if (!r.initialized) {
            r.prng = std.Random.DefaultPrng.init(
                @as(u64, @bitCast(std.time.microTimestamp())) *% 11400714819323198393,
            );
            r.initialized = true;
        }
        return r.prng.random().int(u64);
    }
};
var rng = RNG{};

pub const ObjectReal = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    val: f64,

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectReal), 4);
    }

    pub fn hash(objreal: *ObjectReal, level: u64) u64 {
        // go-like hash rules, i.e.
        // +/- 0 is treated as the same
        // NaN produces random hashes, to avoid performance degradation in maps for many nans
        const seed = 11400714819323198393 *% (level + 1);
        if (objreal.val == 0) return (seed ^ 16465025849920122817) *% 11583958599168417197;
        if (objreal.val != objreal.val) return rng.bits();
        return std.hash.XxHash3.hash(seed, std.mem.asBytes(&objreal.val));
    }
};
