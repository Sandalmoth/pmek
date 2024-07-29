const std = @import("std");
const Object = @import("../object.zig").Object;
const rng = @import("../shared_rng.zig");

pub const ObjectReal = extern struct {
    head: Object,
    data: f64,

    pub fn hash(real: *ObjectReal, seed: u64) u64 {
        // make +0 and -0 hash to the same value, since they compare equal
        // i just picked these primes at random, might not be the best
        if (real.data == 0) return (seed ^ 15345951513627307427) *% 11490803873075654471;
        // make NaN random, since it compares unequal
        // avoids performance degradation when inserting many NaN keys (not recommended though)
        if (real.data != real.data) return rng.int(64);
        return std.hash.XxHash3.hash(seed, std.mem.asBytes(&real.data));
    }

    pub fn size(len: usize) usize {
        std.debug.assert(len == 0);
        return std.mem.alignForwardLog2(@sizeOf(ObjectReal), 4);
    }
};
