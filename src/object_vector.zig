const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const eql = @import("object.zig").eql;
const debugPrint = @import("object.zig").debugPrint;

const OBJECTS_PER_LEVEL = 4; // NOTE increase once implementation is finished
const SHIFT = 2; // log2(objects per level)

pub const ObjectVector = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    level: u32, // how many levels beneath this (0 == leaf)
    len: u32, // number of children in this node

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectVector) + @sizeOf(usize) * _len, 4);
    }

    pub fn hash(objvector: *ObjectVector, level: u64) u64 {
        var h: u64 = 16918459230259101617;
        for (0..2 * objvector.len) |i| {
            h ^= Object.hash(objvector.data()[i], level);
            h *%= 13015751150583452993;
        }
        return h;
    }

    pub fn data(vector: *ObjectVector) [*]?*Object {
        return @ptrFromInt(@intFromPtr(&vector.len) + 4);
    }
};

pub fn assoc(gca: *GCAllocator, objvec: ?*Object, index: usize, objval: ?*Object) *Object {
    _ = gca;
    _ = objvec;
    _ = index;
    _ = objval;
}

pub fn get(objvec: ?*Object, index: usize) ?*Object {
    _ = objvec;
    _ = index;
}

pub fn contains(objvec: ?*Object, index: usize) bool {
    _ = objvec;
    _ = index;
}

pub fn append(gca: *GCAllocator, objvec: ?*Object, objval: ?*Object) *Object {
    if (objvec == null) return gca.newVector(); // could also be error?
    const vec = objvec.?.as(.vector);

    if (vec.len == OBJECTS_PER_LEVEL and
        (vec.level == 0 or vec.data()[vec.len - 1].?.as(.vector).len == OBJECTS_PER_LEVEL))
    {
        // special case when the root is full
        const new = gca.new(.vector, 0);
        new.level = vec.level;
        new.len = 0;
        const parent = gca.new(.vector, 2);
        parent.level = vec.level + 1;
        parent.len = 2;
        parent.data()[0] = objvec;
        parent.data()[1] = append(gca, @alignCast(@ptrCast(new)), objval);
        return @alignCast(@ptrCast(parent));
    }

    if (vec.level == 0) {
        // found leaf (with space), can insert right here
        std.debug.assert(vec.len < OBJECTS_PER_LEVEL);
        const new = gca.new(.vector, vec.len + 1);
        new.level = 0;
        new.len = vec.len + 1;
        @memcpy(new.data(), vec.data()[0..vec.len]);
        new.data()[vec.len] = objval;
        return @alignCast(@ptrCast(new));
    }

    if (vec.len > 0 and vec.data()[vec.len - 1].?.as(.vector).len < OBJECTS_PER_LEVEL) {
        // child nodes with space exist, insert into them
        const new = gca.new(.vector, vec.len);
        new.level = vec.level;
        new.len = vec.len;
        @memcpy(new.data(), vec.data()[0..vec.len]);
        new.data()[vec.len - 1] = append(gca, vec.data()[vec.len - 1], objval);
        return @alignCast(@ptrCast(new));
    }

    // no child node with space, create it
    const sub = gca.new(.vector, 0);
    sub.level = vec.level - 1;
    sub.len = 0;
    const new = gca.new(.vector, vec.len + 1);
    new.level = vec.level;
    new.len = vec.len + 1;
    @memcpy(new.data(), vec.data()[0..vec.len]);
    new.data()[vec.len] = append(gca, @alignCast(@ptrCast(sub)), objval);
    return @alignCast(@ptrCast(new));
}

pub fn count(objvec: ?*Object) usize {
    _ = objvec;
}

test "scratch" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    var v = gca.newVector();
    debugPrint(v);
    for (0..100) |i| {
        v = append(gca, v, gca.newReal(@floatFromInt(i)));
        debugPrint(v);
    }
}
