const std = @import("std");

const Page = @import("gc.zig").Page;

const ObjectReal = @import("object_real.zig").ObjectReal;
const ObjectCons = @import("object_cons.zig").ObjectCons;
const ObjectString = @import("object_string.zig").ObjectString;
const ObjectChamp = @import("object_champ.zig").ObjectChamp;
const ObjectAmt = @import("object_amt.zig").ObjectAmt;

pub const Kind = enum(u8) {
    real,
    cons,
    string,
    champ,
    amt,
};

pub fn ObjectType(comptime kind: Kind) type {
    return switch (kind) {
        .real => ObjectReal,
        .cons => ObjectCons,
        .string => ObjectString,
        .champ => ObjectChamp,
        .amt => ObjectAmt,
    };
}

pub const Object = extern struct {
    kind: Kind align(16),
    _pad: [7]u8,

    pub fn as(obj: *Object, comptime kind: Kind) *ObjectType(kind) {
        std.debug.assert(obj.kind == kind);
        return @alignCast(@ptrCast(obj));
    }

    pub fn page(obj: *Object) *Page {
        const mask: usize = ~(@as(usize, std.mem.page_size) - 1);
        return @ptrFromInt(@intFromPtr(obj) & mask);
    }

    pub fn hash(obj: ?*Object, level: usize) u64 {
        if (obj == null) {
            const seed = 11400714819323198393 *% (level + 1);
            return seed *% 12542518518317951677 +% 14939819388667570391;
        }
        return switch (obj.?.kind) {
            .real => obj.?.as(.real).hash(level),
            .cons => obj.?.as(.cons).hash(level),
            .string => obj.?.as(.string).hash(level),
            .champ => obj.?.as(.champ).hash(level),
            .amt => obj.?.as(.amt).hash(level),
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Object) <= 16);
    std.debug.assert(@alignOf(Object) == 16);
}

pub fn eql(obj1: ?*Object, obj2: ?*Object) bool {
    if (obj1 == obj2) return true;
    if (obj1 == null or obj2 == null) return false;
    if (obj1.?.kind != obj2.?.kind) return false;
    return switch (obj1.?.kind) {
        .real => obj1.?.as(.real).val == obj2.?.as(.real).val,
        .cons => blk: {
            const cons1 = obj1.?.as(.cons);
            const cons2 = obj2.?.as(.cons);
            break :blk eql(cons1.car, cons2.car) and eql(cons1.cdr, cons2.cdr);
        },
        .string => blk: {
            const string1 = obj1.?.as(.string);
            const string2 = obj2.?.as(.string);
            if (string1.len != string2.len) break :blk false;
            break :blk std.mem.eql(
                u8,
                string1.data()[0..string1.len],
                string2.data()[0..string2.len],
            );
        },
        .champ => blk: {
            const champ1 = obj1.?.as(.champ);
            const champ2 = obj2.?.as(.champ);
            if (champ1.datamask != champ2.datamask or
                champ1.nodemask != champ2.nodemask) break :blk false;
            std.debug.assert(champ1.datalen == champ2.datalen);
            std.debug.assert(champ1.nodelen == champ2.nodelen);
            const data1 = champ1.data();
            const data2 = champ2.data();
            for (0..2 * champ1.datalen + champ1.nodelen) |i| {
                if (!eql(data1[i], data2[i])) break :blk false;
            }
            break :blk true;
        },
        .amt => blk: {
            const amt1 = obj1.?.as(.amt);
            const amt2 = obj2.?.as(.amt);
            if (amt1.len != amt2.len or amt1.level != amt2.level) break :blk false;
            const data1 = amt1.data();
            const data2 = amt2.data();
            for (0..amt1.len) |i| {
                if (!eql(data1[i], data2[i])) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn print(obj: ?*Object, writer: anytype) anyerror!void {
    try _printImpl(obj, writer);
    try writer.print("\n", .{});
}

pub fn debugPrint(obj: ?*Object) void {
    const stderr = std.io.getStdErr().writer();
    print(obj, stderr) catch {};
}

fn _printImpl(_obj: ?*Object, writer: anytype) anyerror!void {
    const obj = _obj orelse return writer.print("nil", .{});
    switch (obj.kind) {
        .real => try writer.print("{d}", .{obj.as(.real).val}),
        .cons => {
            var cons = obj.as(.cons);
            try writer.print("(", .{});
            while (true) {
                try _printImpl(cons.car, writer);
                if (cons.cdr == null) {
                    break;
                } else if (cons.cdr.?.kind != .cons) {
                    try writer.print(" . ", .{});
                    try _printImpl(cons.cdr, writer);
                    break;
                }
                try writer.print(" ", .{});
                cons = cons.cdr.?.as(.cons);
            }
            try writer.print(")", .{});
        },
        .string => {
            const str = obj.as(.string);
            try writer.print("\"{s}\"", .{str.data()[0..str.len]});
        },
        .champ => {
            try writer.print("{{", .{});
            try _printChamp(obj, true, writer);
            try writer.print("}}", .{});
        },
        .amt => {
            try writer.print("[", .{});
            try _printAmt(obj, true, writer);
            try writer.print("]", .{});
        },
    }
}

fn _printChamp(obj: *Object, first: bool, writer: anytype) anyerror!void {
    const champ = obj.as(.champ);
    var not_first = false;
    for (0..champ.datalen) |i| {
        if (!first or i > 0) try writer.print(", ", .{});
        const key = champ.data()[2 * i];
        const val = champ.data()[2 * i + 1];
        try _printImpl(key, writer);
        try writer.print(" ", .{});
        try _printImpl(val, writer);
        not_first = true;
    }
    for (0..champ.nodelen) |i| {
        const child = champ.nodes()[i];
        try _printChamp(child, first and i == 0 and !not_first, writer);
    }
}

fn _printAmt(obj: *Object, first: bool, writer: anytype) anyerror!void {
    const amt = obj.as(.amt);
    for (0..amt.len) |i| {
        const val = amt.data()[i];
        if (amt.level == 0) {
            if (!first or i > 0) try writer.print(" ", .{});
            try _printImpl(val, writer);
        } else {
            std.debug.assert(val != null);
            try _printAmt(val.?, first and i == 0, writer);
        }
    }
}
