const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

const LexError = @import("./errors.zig").LexError;

pub const TokenList = Aligned(Token, null);

pub const Lexer = struct {
    index: usize = 0,
    text: []const u8 = "",

    const LexState = enum {
        start,
        num,
        ident_op,
        op,
        end,
    };

    pub fn lex(self: *Lexer, text: []const u8, arena: Allocator) LexError!TokenList {
        var token_list: TokenList = .empty;
        self.index = 0;
        self.text = text;

        state: switch (LexState.start) {
            .start => {
                if (self.isAtEnd()) continue :state .end;
                switch (self.advance()) {
                    '0'...'9' => {
                        continue :state .num;
                    },
                    '+', '*', '/', '%', '<', '>', '=', '!', '&', '|', '{', '}', '[', ']' => continue :state .op,
                    '-' => {
                        if (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) continue :state .num;

                        continue :state .op;
                    },
                    ';' => {
                        while (!self.isAtEnd() and self.peekAt(0) != '\n') self.index += 1;
                        continue :state .start;
                    },
                    ':' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.peekAt(0))) return LexError.CallVarWithoutValidVar;

                        const start_index = self.index;
                        while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.peekAt(0))) self.index += 1;

                        const ident = self.text[start_index..self.index];

                        // syntactic sugar: :(ident) => @(ident) call
                        try token_list.append(arena, .{ .get_var = ident });
                        try token_list.append(arena, .{ .op = .call });
                        continue :state .start;
                    },
                    '@' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.peekAt(0))) return LexError.GetVarWithoutValidVar;

                        const start_index = self.index;
                        while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.peekAt(0))) self.index += 1;

                        const ident = self.text[start_index..self.index];

                        try token_list.append(arena, .{ .get_var = ident });

                        continue :state .start;
                    },
                    '$' => {
                        if (self.isAtEnd() or !std.ascii.isAlphabetic(self.peekAt(0))) return LexError.SetVarWithoutValidVar;

                        const start_index = self.index;
                        while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.peekAt(0))) self.index += 1;

                        const ident = self.text[start_index..self.index];

                        try token_list.append(arena, .{ .set_var = ident });

                        continue :state .start;
                    },
                    '\"' => {
                        if (self.isAtEnd()) return LexError.UnclosedString;

                        const start_index = self.index;
                        while (!self.isAtEnd() and self.peekAt(0) != '\"') {
                            if (self.peekAt(0) == '\n') return LexError.UnclosedString;
                            self.index += 1;
                        }

                        if (self.isAtEnd()) return LexError.UnclosedString;

                        const string = self.text[start_index..self.index];

                        // closing string
                        self.index += 1;

                        try token_list.append(arena, .{ .string = string });
                        continue :state .start;
                    },
                    ' ', '\t', '\r', '\n' => continue :state .start,
                    'a'...'z' => continue :state .ident_op,
                    else => return LexError.UnsupportedCharacter,
                }
            },
            .op => {
                const op: OpType = switch (self.text[self.index - 1]) {
                    '+' => .plus,
                    '-' => .minus,
                    '*' => .star,
                    '/' => .slash,
                    '%' => .percent,
                    '{' => .left_brace,
                    '}' => .right_brace,
                    '[' => .left_bracket,
                    ']' => .right_bracket,
                    '<' => if (!self.isAtEnd() and self.matchAdvance('=')) .less_equal else .less,
                    '>' => if (!self.isAtEnd() and self.matchAdvance('=')) .greater_equal else .greater,
                    '=' => if (!self.isAtEnd() and self.matchAdvance('=')) .equal else return LexError.EqualWithoutSecondEqual,
                    '!' => if (!self.isAtEnd() and self.matchAdvance('=')) .not_equal else .not,
                    '&' => if (!self.isAtEnd() and self.matchAdvance('&')) .amp_amp else .amp,
                    '|' => if (!self.isAtEnd() and self.matchAdvance('|')) .bar_bar else .bar,
                    else => unreachable,
                };

                try token_list.append(arena, .{ .op = op });

                continue :state .start;
            },
            .num => {
                // start_index is index - 1 in order to include the '-' sign for parsing and bound checking
                const start_index = self.index - 1;
                while (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) {
                    self.index += 1;
                }

                // floats
                if (!self.isAtEnd() and self.peekAt(0) == '.') {
                    self.index += 1;
                    if (self.isAtEnd() or !std.ascii.isDigit(self.peekAt(0))) return LexError.DecimalPointWithoutNumber;

                    while (!self.isAtEnd() and std.ascii.isDigit(self.peekAt(0))) {
                        self.index += 1;
                    }
                    const num = std.fmt.parseFloat(f64, text[start_index..self.index]) catch unreachable;

                    try token_list.append(arena, .{ .float = num });
                } else {
                    const num = std.fmt.parseInt(i32, text[start_index..self.index], 10) catch |err| switch (err) {
                        error.InvalidCharacter => unreachable,
                        error.Overflow => return LexError.Overflow,
                    };

                    try token_list.append(arena, .{ .int = num });
                }

                continue :state .start;
            },
            .ident_op => {
                const start_index = self.index - 1;
                while (!self.isAtEnd() and std.ascii.isAlphabetic(self.peekAt(0))) {
                    self.index += 1;
                }

                // no support for non-keyword identifiers for now
                const keyword = try strToKeyword(text[start_index..self.index]);

                try token_list.append(arena, keyword);

                continue :state .start;
            },
            .end => {},
        }

        return token_list;
    }

    fn strToKeyword(str: []const u8) LexError!Token {
        const op = std.meta.stringToEnum(OpType, str) orelse return LexError.NotKeyword;
        // check so something like `not` does not get registered as `!`
        if (op.isOpSymbol()) return LexError.NotKeyword;
        return .{ .op = op };
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.index >= self.text.len;
    }

    fn advance(self: *Lexer) u8 {
        self.index += 1;
        return self.text[self.index - 1];
    }

    fn previous(self: *Lexer) u8 {
        return self.text[self.index - 1];
    }

    fn peekAt(self: *Lexer, ahead: usize) u8 {
        return self.text[self.index + ahead];
    }

    fn matchAdvance(self: *Lexer, expected: u8) bool {
        if (self.peekAt(0) == expected) {
            self.index += 1;
            return true;
        } else return false;
    }
};

test "numbers and plus operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("3 4 +", arena.allocator());

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 3 }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .int = 4 }, token_list.items[1]);
    try std.testing.expectEqual(Token{ .op = .plus }, token_list.items[2]);
}

test "comment with no trailing newline doesn't run off the buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("-5 ; rest is ignored", arena.allocator());

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = -5 }, token_list.items[0]);
}

test "errors on bad input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    try std.testing.expectError(LexError.UnsupportedCharacter, lexer.lex("?", arena.allocator()));
    try std.testing.expectError(LexError.NotKeyword, lexer.lex("foo", arena.allocator()));
    try std.testing.expectError(LexError.EqualWithoutSecondEqual, lexer.lex("=", arena.allocator()));
}

test "float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("2.5", arena.allocator());

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .float = 2.5 }, token_list.items[0]);
}

test "negative float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("-2.5", arena.allocator());

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .float = -2.5 }, token_list.items[0]);
}

test "mixed int and float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("3 4.5 +", arena.allocator());

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 3 }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .float = 4.5 }, token_list.items[1]);
    try std.testing.expectEqual(Token{ .op = .plus }, token_list.items[2]);
}

test "error on decimal point without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    try std.testing.expectError(LexError.DecimalPointWithoutNumber, lexer.lex("3.", arena.allocator()));
}

test "error on set variable without proper identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    try std.testing.expectError(LexError.SetVarWithoutValidVar, lexer.lex("$", arena.allocator()));
    try std.testing.expectError(LexError.SetVarWithoutValidVar, lexer.lex("$-", arena.allocator()));
}

test "error on get variable without proper identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    try std.testing.expectError(LexError.GetVarWithoutValidVar, lexer.lex("@", arena.allocator()));
    try std.testing.expectError(LexError.GetVarWithoutValidVar, lexer.lex("@+", arena.allocator()));
}

test "set var and get var operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("5 $x @x", arena.allocator());

    try std.testing.expectEqual(3, token_list.items.len);
    try std.testing.expectEqual(Token{ .int = 5 }, token_list.items[0]);

    try std.testing.expect(token_list.items[1] == .set_var);
    try std.testing.expectEqualStrings("x", token_list.items[1].set_var);

    try std.testing.expect(token_list.items[2] == .get_var);
    try std.testing.expectEqualStrings("x", token_list.items[2].get_var);
}

test "less than and less than or equal operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};

    const token_list = try lexer.lex("< <=", arena.allocator());

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .less }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .less_equal }, token_list.items[1]);
}

test "greater than and greater than or equal operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};
    const token_list = try lexer.lex("> >=", arena.allocator());

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .greater }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .greater_equal }, token_list.items[1]);
}

test "equal and not equal operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};
    const token_list = try lexer.lex("== !=", arena.allocator());

    try std.testing.expectEqual(2, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .equal }, token_list.items[0]);
    try std.testing.expectEqual(Token{ .op = .not_equal }, token_list.items[1]);
}

test "not equal operator without =" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer{};
    const token_list = try lexer.lex("!", arena.allocator());

    try std.testing.expectEqual(1, token_list.items.len);
    try std.testing.expectEqual(Token{ .op = .not }, token_list.items[0]);
}
