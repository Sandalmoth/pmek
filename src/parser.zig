const std = @import("std");

const Object = @import("object.zig").Object;
const GC = @import("gc.zig").GC;
const GCAllocator = @import("gc.zig").GCAllocator;

const TokenType = enum {
    nil,
    lpar,
    rpar,
    number,
    string,
    symbol,
    invalid,
};
const Token = union(TokenType) {
    nil: void,
    lpar: void,
    rpar: void,
    number: []const u8,
    string: []const u8,
    symbol: []const u8,
    invalid: void,
};

pub fn parse(gc: *GC, src: []const u8) ?*Object {
    var arena = std.heap.ArenaAllocator.init(gc.backup_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const tokens = lex(aa, src);

    for (tokens.items) |t| {
        std.debug.print("{} ", .{t});
    }
    std.debug.print("\n", .{});

    if (tokens.items.len == 0) return gc.allocator.newErr("parse: found no tokens");
    return parseImpl(&gc.allocator, tokens, 0);
}

fn parseImpl(gca: *GCAllocator, tokens: std.ArrayList(Token), cursor: usize) ?*Object {
    switch (tokens.items[cursor]) {
        .nil => return null,
        .lpar => {
            var i: usize = 1;
            var list: ?*Object = null;
            while (cursor + i < tokens.items.len and tokens.items[cursor + i] != .rpar) : (i += 1) {
                list = gca.newCons(
                    parseImpl(gca, tokens, cursor + i),
                    list,
                );
            }
            if (cursor + i == tokens.items.len or tokens.items[cursor + i] != .rpar) {
                return gca.newErr("parseImpl: missing ')'");
            }
            i += 1;
            if (cursor + i < tokens.items.len) return gca.newErr("parseImpl: tokens after expr");
            // reversing lists after making them is stupid, how does a good lisp deal with this?
            var reversed: ?*Object = null;
            var walk = list;
            while (walk != null) {
                const cons = walk.?.as(.cons);
                reversed = gca.newCons(cons.car, reversed);
                walk = cons.cdr;
            }
            return reversed;
        },
        .rpar => return gca.newErr("parseImpl: unexpected ')'"),
        .number => |s| {
            const x = std.fmt.parseFloat(f64, s) catch
                return gca.newErr("parseImpl: failed to parse float");
            return gca.newReal(x);
        },
        .string => |s| return gca.newString(s),
        .symbol => |s| return gca.newSymbol(s),
        .invalid => return gca.newErr("parseImpl: invalid character"),
    }
}

// pub fn parseSexpr()

fn isSymbolChar(c: u8) bool {
    return switch (c) {
        '.', '+', '*', '-', '/', '<'...'?', 'a'...'z', 'A'...'Z' => true,
        else => false,
    };
}

fn isNumberChar(c: u8) bool {
    return switch (c) {
        '.', '0'...'9' => true,
        else => false,
    };
}

fn lex(aa: std.mem.Allocator, src: []const u8) std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).initCapacity(aa, src.len) catch @panic("Allocation falure");
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            ' ' => {},
            '(' => tokens.appendAssumeCapacity(.{ .lpar = {} }),
            ')' => tokens.appendAssumeCapacity(.{ .rpar = {} }),
            '0'...'9' => {
                var end = i + 1;
                while (end < src.len and isNumberChar(src[end])) : (end += 1) {}
                tokens.appendAssumeCapacity(.{ .number = src[i..end] });
                i = end - 1;
            },
            '+', '*', '-', '/', '<'...'?', 'a'...'z', 'A'...'Z' => {
                var end = i + 1;
                while (end < src.len and isSymbolChar(src[end])) : (end += 1) {}
                if (std.mem.eql(u8, "nil", src[i..end])) {
                    tokens.appendAssumeCapacity(.{ .nil = {} });
                } else {
                    tokens.appendAssumeCapacity(.{ .symbol = src[i..end] });
                }
                i = end - 1;
            },
            '"' => {
                var end = i + 1;
                while (end < src.len and src[end] != '"') : (end += 1) {}
                if (end == src.len) {
                    tokens.appendAssumeCapacity(.{ .invalid = {} });
                    continue;
                }
                tokens.appendAssumeCapacity(.{ .string = src[i + 1 .. end] });
                i = end;
            },
            else => tokens.appendAssumeCapacity(.{ .invalid = {} }),
        }
    }
    return tokens;
}
