const std = @import("std");

const Kind = @import("object.zig").Kind;
const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;
const eql = @import("object.zig").eql;
const debugPrint = @import("object.zig").debugPrint;

const OBJECTS_PER_LEVEL = 4; // NOTE increase once implementation is finished
const SHIFT = 2; // log2(objects per level)

pub const ObjectAmt = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,
    level: u32, // how many levels beneath this (0 == leaf)
    len: u32, // number of children in this node

    pub fn size(_len: usize) usize {
        return std.mem.alignForwardLog2(@sizeOf(ObjectAmt) + @sizeOf(usize) * _len, 4);
    }

    pub fn hash(amt: *ObjectAmt, level: u64) u64 {
        var h: u64 = 16918459230259101617;
        for (0..2 * amt.len) |i| {
            h ^= Object.hash(amt.data()[i], level);
            h *%= 13015751150583452993;
        }
        return h;
    }

    pub fn data(amt: *ObjectAmt) [*]?*Object {
        return @ptrFromInt(@intFromPtr(&amt.len) + 4);
    }
};

pub fn assoc(gca: *GCAllocator, objamt: ?*Object, index: usize, objval: ?*Object) *Object {
    _ = gca;
    _ = objamt;
    _ = index;
    _ = objval;
}

pub fn get(objamt: ?*Object, index: usize) ?*Object {
    _ = objamt;
    _ = index;
}

pub fn append(gca: *GCAllocator, objamt: ?*Object, objval: ?*Object) *Object {
    if (objamt == null) return gca.newAmt(); // could also be error?
    const amt = objamt.?.as(.amt);

    if (amt.len == OBJECTS_PER_LEVEL and
        (amt.level == 0 or amt.data()[amt.len - 1].?.as(.amt).len == OBJECTS_PER_LEVEL))
    {
        // special case when the root is full
        const new = gca.new(.amt, 0);
        new.level = amt.level;
        new.len = 0;
        const parent = gca.new(.amt, 2);
        parent.level = amt.level + 1;
        parent.len = 2;
        parent.data()[0] = objamt;
        parent.data()[1] = append(gca, @alignCast(@ptrCast(new)), objval);
        return @alignCast(@ptrCast(parent));
    }

    if (amt.level == 0) {
        // found leaf (with space), can insert right here
        std.debug.assert(amt.len < OBJECTS_PER_LEVEL);
        const new = gca.new(.amt, amt.len + 1);
        new.level = 0;
        new.len = amt.len + 1;
        @memcpy(new.data(), amt.data()[0..amt.len]);
        new.data()[amt.len] = objval;
        return @alignCast(@ptrCast(new));
    }

    if (amt.len > 0 and amt.data()[amt.len - 1].?.as(.amt).len < OBJECTS_PER_LEVEL) {
        // child nodes with space exist, insert into them
        const new = gca.new(.amt, amt.len);
        new.level = amt.level;
        new.len = amt.len;
        @memcpy(new.data(), amt.data()[0..amt.len]);
        new.data()[amt.len - 1] = append(gca, amt.data()[amt.len - 1], objval);
        return @alignCast(@ptrCast(new));
    }

    // no child node with space, create it
    const sub = gca.new(.amt, 0);
    sub.level = amt.level - 1;
    sub.len = 0;
    const new = gca.new(.amt, amt.len + 1);
    new.level = amt.level;
    new.len = amt.len + 1;
    @memcpy(new.data(), amt.data()[0..amt.len]);
    new.data()[amt.len] = append(gca, @alignCast(@ptrCast(sub)), objval);
    return @alignCast(@ptrCast(new));
}

pub fn count(objamt: ?*Object) usize {
    if (objamt == null) return 0;
    const amt = objamt.?.as(.amt);

    if (amt.len == 0) return 0;
    if (amt.level == 0) return amt.len;

    const len_left = std.math.powi(usize, OBJECTS_PER_LEVEL, amt.level) catch
        @panic("Overflow in vector length");
    const len_right = count(amt.data()[amt.len - 1]);
    std.debug.print("level {} : {} {}\n", .{ amt.level, len_left * (amt.len - 1), len_right });
    return len_left * (amt.len - 1) + len_right;
}

test "scratch" {
    const gc = GC.create(std.testing.allocator);
    defer gc.destroy();
    const gca = &gc.allocator;

    var v = gca.newAmt();
    debugPrint(v);
    for (0..100) |i| {
        v = append(gca, v, gca.newReal(@floatFromInt(i)));
        std.debug.print("{}\t", .{count(v)});
        debugPrint(v);
        std.debug.assert(count(v) == i + 1);
    }
}
