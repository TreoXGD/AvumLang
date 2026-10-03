const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

const GC = @import("gc.zig").GC;

const EvalError = @import("./errors.zig").EvalError;

const v = @import("./value.zig");
const Value = v.Value;

const GcObject = v.GcObject;
const GcObjectValue = v.GcObjectValue;

pub const Frame = Aligned(Value, null);

const max_recursion_depth = 1000;

pub const Interpreter = struct {
    allocator: Allocator,
    writer: *std.Io.Writer,
    recursion_depth: u32 = 0,
    block_level: u32 = 0,
    block_contents: Aligned(Token, null) = .empty,
    // a stack of frames for regular operations and array creation
    frame_stack: Aligned(Frame, null) = .empty,
    var_dict: std.array_hash_map.String(Value) = .empty,
    gc: GC,

    pub fn init(allocator: Allocator, writer: *std.Io.Writer) EvalError!Interpreter {
        var interpreter: Interpreter = .{
            .allocator = allocator,
            .writer = writer,
            .gc = GC.init(allocator),
        };

        // initialize global stack frame
        try interpreter.beginFrame();

        return interpreter;
    }

    pub fn deinit(self: *Interpreter) void {
        // deallocate the frame stack
        for (self.frame_stack.items) |*stack| {
            stack.deinit(self.allocator);
        }
        self.frame_stack.deinit(self.allocator);

        // deallocate the variable dictionary
        self.var_dict.deinit(self.allocator);

        // deallocate any in-progress blocks
        self.block_contents.deinit(self.allocator);

        self.gc.deinit();
    }

    fn evalBlock(self: *Interpreter, token: Token) EvalError!void {
        switch (token) {
            .op => |op| {
                if (op == .left_brace) self.block_level += 1;
                if (op == .right_brace) self.block_level -= 1;
            },
            else => {},
        }

        if (self.block_level == 0) {
            const block = try self.block_contents.toOwnedSlice(self.allocator);

            const gc_value: GcObjectValue = .{ .block = block };
            const gc_object = try self.gc.allocObject(gc_value);

            try self.pushActive(.{ .object = gc_object });
        } else {
            try self.block_contents.append(self.allocator, try self.preserveToken(token));
        }
    }

    fn preserveToken(self: *Interpreter, token: Token) EvalError!Token {
        return switch (token) {
            .string => |s| .{ .string = try self.getGCText(s) },
            .set_var => |s| .{ .set_var = try self.getGCText(s) },
            .get_var => |s| .{ .get_var = try self.getGCText(s) },
            else => token,
        };
    }

    fn getGCText(self: *Interpreter, text: []const u8) EvalError![]const u8 {
        return (try self.gc.getOrCreateString(text)).value.string;
    }

    pub fn eval(self: *Interpreter, token: Token) EvalError!void {
        if (self.block_level != 0) {
            try self.evalBlock(token);
            return;
        }

        switch (token) {
            .int => |i| try self.pushActive(.{ .int = i }),
            .float => |f| try self.pushActive(.{ .float = f }),
            .bool => |b| try self.pushActive(.{ .bool = b }),
            .string => |s| {
                const gc_object = try self.gc.getOrCreateString(s);

                try self.pushActive(.{ .object = gc_object });
            },
            .set_var => |ident| {
                const value = try self.popOrError();
                try self.var_dict.put(self.allocator, try self.getGCText(ident), value);
            },
            .get_var => |ident| {
                if (self.var_dict.get(ident)) |value| {
                    try self.pushActive(value);
                } else return EvalError.UndefinedVariable;
            },
            .op => |op| {
                switch (op) {
                    // tertiary
                    .rot => {
                        const top = try self.popOrError();
                        const middle = try self.popOrError();
                        const bottom = try self.popOrError();

                        try self.pushActive(middle);
                        try self.pushActive(top);
                        try self.pushActive(bottom);
                    },
                    .ifelse => {
                        const else_branch = try (try self.popOrError()).isBlock();
                        const then_branch = try (try self.popOrError()).isBlock();
                        const cond = try (try self.popOrError()).isBool();

                        if (cond) {
                            try self.callBlock(then_branch);
                        } else {
                            try self.callBlock(else_branch);
                        }
                    },
                    .set => {
                        const value = try self.popOrError();
                        const index = try (try self.popOrError()).isInteger();
                        const array = try (try self.popOrError()).isArray();

                        if (index < 0 or index >= array.len) return EvalError.AccessOutsideArrayBounds;
                        array[@intCast(index)] = value;
                    },
                    .reduce => {
                        const block = try (try self.popOrError()).isBlock();
                        const init_value = try self.popOrError();
                        const array = try (try self.popOrError()).isArray();

                        try self.beginFrame();
                        errdefer self.discardFrame();

                        try self.pushActive(init_value);
                        for (array) |value| {
                            try self.pushActive(value);
                            try self.callBlock(block);

                            const frame = self.frame_stack.getLast();
                            if (frame.items.len != 1) return EvalError.BlockLeftWrongElementCount;
                        }

                        var frame = self.frame_stack.pop().?;
                        defer frame.deinit(self.allocator);

                        const result = frame.pop() orelse return EvalError.StackUnderflow;
                        try self.pushActive(result);
                    },
                    // binary
                    .plus, .minus, .star, .slash, .percent, .min, .max, .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => {
                        const rhs = try (try self.popOrError()).isNumber();
                        const lhs = try (try self.popOrError()).isNumber();

                        const result = try computeBin(op, lhs, rhs);

                        try self.pushActive(result);
                    },
                    .amp, .bar => {
                        const rhs = try (try self.popOrError()).isInteger();
                        const lhs = try (try self.popOrError()).isInteger();

                        const result: Value = switch (op) {
                            .amp => .{ .int = lhs & rhs },
                            .bar => .{ .int = lhs | rhs },
                            else => unreachable,
                        };

                        try self.pushActive(result);
                    },
                    .amp_amp, .bar_bar => {
                        const rhs = try (try self.popOrError()).isBool();
                        const lhs = try (try self.popOrError()).isBool();

                        const result: Value = switch (op) {
                            .amp_amp => .{ .bool = lhs and rhs },
                            .bar_bar => .{ .bool = lhs or rhs },
                            else => unreachable,
                        };

                        try self.pushActive(result);
                    },
                    .swap => {
                        const rhs = try self.popOrError();
                        const lhs = try self.popOrError();

                        try self.pushActive(rhs);
                        try self.pushActive(lhs);
                    },
                    .over => {
                        // second from top
                        const second = try self.peekAtOrError(1);
                        try self.pushActive(second);
                    },
                    .@"if" => {
                        const then_branch = try (try self.popOrError()).isBlock();
                        const cond = try (try self.popOrError()).isBool();

                        if (cond) try self.callBlock(then_branch);
                    },
                    .@"while" => {
                        const body = try (try self.popOrError()).isBlock();
                        const cond = try (try self.popOrError()).isBlock();

                        while (true) {
                            try self.callBlock(cond);

                            const result = try (try self.popOrError()).isBool();
                            if (!result) break;

                            try self.callBlock(body);
                        }
                    },
                    .get => {
                        const index = try (try self.popOrError()).isInteger();
                        const array = try (try self.popOrError()).isArray();

                        if (index < 0 or index >= array.len) return EvalError.AccessOutsideArrayBounds;
                        try self.pushActive(array[@intCast(index)]);
                    },
                    .array => {
                        const value = try self.popOrError();
                        const elem_count = try (try self.popOrError()).isInteger();

                        if (elem_count < 0) return EvalError.NegativeArraySize;

                        const count: usize = @intCast(elem_count);

                        const array: GcObjectValue = .{ .array = try self.allocator.alloc(Value, count) };
                        @memset(array.array, value);

                        const obj = try self.gc.allocObject(array);

                        try self.pushActive(.{ .object = obj });
                    },
                    .map => {
                        const block = try (try self.popOrError()).isBlock();
                        const array = try (try self.popOrError()).isArray();

                        try self.beginFrame();
                        errdefer self.discardFrame();

                        for (array, 1..) |value, i| {
                            try self.pushActive(value);
                            try self.callBlock(block);

                            const frame = self.frame_stack.getLast();
                            if (frame.items.len != i) return EvalError.BlockLeftWrongElementCount;
                        }

                        try self.closeFrame();
                    },
                    .filter => {
                        const block = try (try self.popOrError()).isBlock();
                        const array = try (try self.popOrError()).isArray();

                        try self.beginFrame();
                        errdefer self.discardFrame();

                        var leftover_elements_count: usize = 0;
                        for (array) |value| {
                            try self.pushActive(value);
                            try self.callBlock(block);

                            const frame = self.frame_stack.getLast();
                            if (frame.items.len != leftover_elements_count + 1) return EvalError.BlockLeftWrongElementCount;

                            const boolean = try (try self.popOrError()).isBool();
                            if (boolean) {
                                try self.pushActive(value);
                                leftover_elements_count += 1;
                            }
                        }

                        try self.closeFrame();
                    },
                    .each => {
                        const block = try (try self.popOrError()).isBlock();
                        const array = try (try self.popOrError()).isArray();

                        try self.beginFrame();
                        defer self.discardFrame();

                        for (array) |value| {
                            try self.pushActive(value);
                            try self.callBlock(block);

                            const frame = self.frame_stack.getLast();
                            if (frame.items.len != 0) return EvalError.BlockLeftWrongElementCount;
                        }
                    },
                    // unary
                    .neg, .abs => {
                        const num = try (try self.popOrError()).isNumber();

                        const result = try computeUnary(op, num);

                        try self.pushActive(result);
                    },
                    .not => {
                        const val = try (try self.popOrError()).isBool();

                        try self.pushActive(.{ .bool = !val });
                    },
                    .dup => {
                        const num = try self.popOrError();

                        try self.pushActive(num);
                        try self.pushActive(num);
                    },
                    .call => {
                        const block = try (try self.popOrError()).isBlock();

                        try self.callBlock(block);
                    },
                    .len => {
                        const array = try (try self.popOrError()).isArray();

                        try self.pushActive(.{ .int = @intCast(array.len) });
                    },
                    .drop => _ = try self.popOrError(),
                    .debug => try self.writer.print("> {f}\n", .{try self.popOrError()}),
                    .print => {
                        const value = try self.popOrError();
                        if (value.isString() catch null) |s| {
                            try self.writer.print("{s}", .{s});
                        } else {
                            try self.writer.print("{f}", .{value});
                        }
                    },
                    .peek => try self.writer.print("| {f}\n", .{try self.peekAtOrError(0)}),
                    // no argument
                    .left_brace => self.block_level += 1,
                    .right_brace => return EvalError.UnmatchedRightBrace,
                    .left_bracket => try self.beginFrame(),
                    .right_bracket => if (self.frame_stack.items.len > 1) try self.closeFrame() else return EvalError.UnmatchedRightBracket,
                    .clear => self.getActive().clearRetainingCapacity(),
                    .stack => {
                        if (self.getActive().items.len == 0) {
                            try self.writer.writeAll("|\n");
                        } else {
                            var i = self.getActive().items.len;
                            while (i > 0) : (i -= 1) try self.writer.print("| {f}\n", .{self.getActive().items[i - 1]});
                        }
                    },
                    .depth => try self.pushActive(.{ .int = @intCast(self.getActive().items.len) }),
                    .vars => {
                        if (self.var_dict.count() == 0) {
                            try self.writer.writeAll("||\n");
                        } else {
                            var iter = self.var_dict.iterator();
                            while (iter.next()) |entry| {
                                try self.writer.print("|| {s} = {f}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                            }
                        }
                    },
                    .varclear => {
                        self.var_dict.clearRetainingCapacity();
                    },
                    .nl => try self.writer.print("\n", .{}),
                    .quit => return EvalError.Quit,
                    .help => {
                        const help_commands =
                            \\(ident) -> [A-Za-z][A-Za-z0-9]*
                            \\
                            \\+ - pops 2, pushes their sum
                            \\- - pops 2, pushes their second-from-top minus top
                            \\* - pops 2, pushes their product
                            \\/ - pops 2, pushes their second-from-top over top and errors if top is 0
                            \\% - pops 2, pushes remainder of second-from-top over top and errors if top is 0
                            \\< - pops 2, pushes boolean showing if second-from-top is less than top
                            \\<= - pops 2, pushes boolean showing if second-from-top is less or equal than top
                            \\> - pops 2, pushes boolean showing if second-from-top is greater than top
                            \\>= - pops 2, pushes boolean showing if second-from-top is greater or equal than top
                            \\== - pops 2, pushes boolean showing if second-from-top is equal than top
                            \\!= - pops 2, pushes boolean showing if second-from-top is not equal than top
                            \\! - pops 1, pushes opposite boolean value
                            \\& - pops 2, pushes their bitwise and
                            \\&& - pops 2, pushes their boolean and
                            \\| - pops 2, pushes their bitwise or
                            \\|| - pops 2, pushes their boolean or
                            \\{ - starts a new block
                            \\} - ends the innermost block
                            \\[ - starts a new array
                            \\] - ends the innermost array
                            \\set - pops 3, sets the array's (third-from-top) element to value (top) at index (second-from-top)
                            \\get - pops 2, pushes the arrays's (second-from-top) element at index (top)
                            \\len - pops 1, pushes length of array
                            \\array - pops 2, pushes new array of length second-from-top value with same top value (shallow copy)
                            \\depth - pushes the number of values in active stack
                            \\map - pops 2, pushes new array of block (top) applied to every element of array (second-from-top)
                            \\filter - pops 2, pushes new array keeping elements of array (second-from-top) where block (top) leaves true
                            \\reduce - pops 3, folds block (top) over every element of array (third-from-top) starting from init (second-from-top), pushes the result
                            \\each - pops 2, runs block (top) once per element of array (second-from-top) for side effects only, pushes nothing
                            \\$(ident) - pops 1, defines a variable with popped value and (ident) name
                            \\@(ident) - pushes value of defined (ident) variable onto the stack
                            \\:(ident) - pushes block value of defined (ident) variable onto the stack and executes it
                            \\neg - pops 1, pushes its negations
                            \\abs - pops 1, pushes its absolute value
                            \\min - pops 2, pushes smaller value
                            \\max - pops 2, pushes bigger value
                            \\call - pops 1, executes the value only if it is a block and errors otherwise
                            \\if - pops 2, executes the top block only if second-from-top bool is true
                            \\ifelse - pops 3, executes the second-from-top stack block only if third-from-top bool is true, top block otherwise
                            \\while - pops 2, continues to execute the top block only if second-from-top block continues to return true boolean
                            \\dup - pushes a copy of the top
                            \\swap - swaps the 2 top values
                            \\drop - pops the top
                            \\over - pushes copy of second-from-top value to top
                            \\rot - moves third-from-top to top
                            \\clear - empties the stack
                            \\print - pops and prints the top
                            \\peek - prints the top without popping
                            \\stack - prints the entire stack top to bottom without popping
                            \\vars - prints the entire list of defined variables
                            \\varclear - empties the list of defined variables
                            \\quit - exit the program
                            \\help - shows this message
                        ;

                        try self.writer.writeAll(help_commands ++ "\n");
                    },
                }
            },
        }
    }

    fn callBlock(self: *Interpreter, block: []Token) EvalError!void {
        if (self.recursion_depth > max_recursion_depth) return EvalError.CallStackOverflow;

        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        for (block) |token| {
            try self.eval(token);
        }
    }

    // checks the types of both lhs and rhs. calls numOp afterwards
    fn computeBin(op: OpType, lhs: Value, rhs: Value) EvalError!Value {
        // comparison operators
        if (isCompOp(op)) {
            if (lhs == .int and rhs == .int) return .{ .bool = numCompOp(i32, op, lhs.int, rhs.int) };

            const lf: f64 = if (lhs == .int) @floatFromInt(lhs.int) else lhs.float;
            const rf: f64 = if (rhs == .int) @floatFromInt(rhs.int) else rhs.float;

            return .{ .bool = numCompOp(f64, op, lf, rf) };
        }

        // arithmetic operators
        if (lhs == .int and rhs == .int) return .{ .int = try numArithOp(i32, op, lhs.int, rhs.int) };

        const lf: f64 = if (lhs == .int) @floatFromInt(lhs.int) else lhs.float;
        const rf: f64 = if (rhs == .int) @floatFromInt(rhs.int) else rhs.float;

        const res = try numArithOp(f64, op, lf, rf);
        if (std.math.isInf(res) or std.math.isNan(res)) return EvalError.InvalidFloat;
        return .{ .float = res };
    }

    fn computeUnary(op: OpType, rhs: Value) EvalError!Value {
        // does not need a separate function because only one argument needs to have type checked
        return blk: switch (op) {
            .neg => if (rhs == .int) {
                const res = @subWithOverflow(0, rhs.int);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk .{ .int = res[0] };
            } else .{ .float = -rhs.float },
            .abs => if (rhs == .int) {
                if (rhs.int == std.math.minInt(i32)) return EvalError.OverflowOnCommand;
                break :blk .{ .int = if (rhs.int < 0) -rhs.int else rhs.int };
            } else .{ .float = @abs(rhs.float) },
            else => unreachable,
        };
    }

    // finds the result of 'lhs op rhs' expression and returns it with same type as the arguments
    fn numArithOp(T: type, op: OpType, lhs: T, rhs: T) EvalError!T {
        return blk: switch (op) {
            .plus => if (T == i32) {
                const res = @addWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs + rhs,
            .minus => if (T == i32) {
                const res = @subWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs - rhs,
            .star => if (T == i32) {
                const res = @mulWithOverflow(lhs, rhs);
                if (res[1] != 0) return EvalError.OverflowOnCommand;
                break :blk res[0];
            } else lhs * rhs,
            .slash => {
                if (rhs == 0) return EvalError.DivisionByZero;
                break :blk if (T == i32) @divTrunc(lhs, rhs) else lhs / rhs;
            },
            .percent => {
                if (rhs == 0) return EvalError.DivisionByZero;
                break :blk @rem(lhs, rhs);
            },
            .min => @min(lhs, rhs),
            .max => @max(lhs, rhs),
            else => unreachable,
        };
    }

    fn numCompOp(T: type, op: OpType, lhs: T, rhs: T) bool {
        return switch (op) {
            .less => lhs < rhs,
            .less_equal => lhs <= rhs,
            .greater => lhs > rhs,
            .greater_equal => lhs >= rhs,
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            else => unreachable,
        };
    }

    fn isCompOp(op: OpType) bool {
        return switch (op) {
            .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => true,
            else => false,
        };
    }

    pub fn gcTryCollect(self: *Interpreter) void {
        // mark stack objects
        for (self.frame_stack.items) |frame| {
            for (frame.items) |val| {
                self.gc.markValue(val);
            }
        }

        // marks variable objects
        for (self.var_dict.keys()) |name| self.gc.markText(name);
        for (self.var_dict.values()) |val| self.gc.markValue(val);

        // marks current block
        for (self.block_contents.items) |token| self.gc.markToken(token);

        self.gc.sweepObjects();
    }

    pub fn gcMaybeCollect(self: *Interpreter) void {
        if (self.gc.obj_list.items.len > self.gc.obj_threshold) {
            self.gcTryCollect();

            self.gc.obj_threshold = self.gc.obj_list.items.len * 2;

            if (self.gc.obj_threshold < 128) self.gc.obj_threshold = 128;
        }
    }

    fn beginFrame(self: *Interpreter) EvalError!void {
        try self.frame_stack.append(self.allocator, .empty);
    }

    fn closeFrame(self: *Interpreter) EvalError!void {
        var contents = self.frame_stack.pop().?;

        const array: GcObjectValue = .{ .array = try contents.toOwnedSlice(self.allocator) };

        const obj = try self.gc.allocObject(array);

        try self.pushActive(.{ .object = obj });
    }

    fn discardFrame(self: *Interpreter) void {
        var frame = self.frame_stack.pop().?;
        frame.deinit(self.allocator);
    }

    fn pushActive(self: *Interpreter, value: Value) EvalError!void {
        try self.getActive().append(self.allocator, value);
    }

    fn getActive(self: *Interpreter) *Frame {
        return &self.frame_stack.items[self.frame_stack.items.len - 1];
    }

    fn peekAtOrError(self: *Interpreter, depth: usize) EvalError!Value {
        if (depth >= self.getActive().items.len) return EvalError.StackUnderflow;
        return self.getActive().items[self.getActive().items.len - 1 - depth];
    }

    fn popOrError(self: *Interpreter) EvalError!Value {
        return self.getActive().pop() orelse return EvalError.StackUnderflow;
    }
};

// for testing purposes only
fn pushBlock(interp: *Interpreter, tokens: []const Token) !void {
    const copy = try interp.allocator.alloc(Token, tokens.len);
    for (tokens, copy) |t, *slot| slot.* = try interp.preserveToken(t);
    const obj = try interp.gc.allocObject(.{ .block = copy });
    try interp.pushActive(.{ .object = obj });
}

test "rot operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .rot });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 1 } }, interp.getActive().items);
}

test "add operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .plus });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.getActive().items);
}

test "sub operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 10 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .minus });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 7 }}, interp.getActive().items);
}

test "mul operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .star });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 20 }}, interp.getActive().items);
}

test "div operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 20 });
    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .op = .slash });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.getActive().items);
}

test "div operation with division by zero" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 0 });

    try std.testing.expectError(EvalError.DivisionByZero, interp.eval(.{ .op = .slash }));
}

test "mod operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = -7 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .percent });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = -1 }}, interp.getActive().items);
}

test "mod operation with division by zero" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 0 });

    try std.testing.expectError(EvalError.DivisionByZero, interp.eval(.{ .op = .percent }));
}

test "neg operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .neg });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = -5 }}, interp.getActive().items);
}

test "abs operation on negative" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = -5 });
    try interp.eval(.{ .op = .abs });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.getActive().items);
}

test "abs operation on positive" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .abs });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 7 }}, interp.getActive().items);
}

test "min operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .min });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 2 }}, interp.getActive().items);
}

test "max operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .int = 9 });
    try interp.eval(.{ .op = .max });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 9 }}, interp.getActive().items);
}

test "dup operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .dup });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 7 }, .{ .int = 7 } }, interp.getActive().items);
}

test "swap operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .swap });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 2 }, .{ .int = 1 } }, interp.getActive().items);
}

test "over operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .over });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 1 } }, interp.getActive().items);
}

test "drop operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .drop });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 1 }}, interp.getActive().items);
}

test "clear operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .int = 3 });
    try interp.eval(.{ .op = .clear });

    try std.testing.expectEqual(0, interp.getActive().items.len);
}

test "print operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .print });

    try std.testing.expectEqualStrings("5", w.buffer[0..w.end]);
    try std.testing.expectEqual(0, interp.getActive().items.len);
}

test "peek operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .peek });

    try std.testing.expectEqualStrings("| 5\n", w.buffer[0..w.end]);
    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.getActive().items);
}

test "stack operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .stack });

    try std.testing.expectEqualStrings("| 2\n| 1\n", w.buffer[0..w.end]);
    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 1 }, .{ .int = 2 } }, interp.getActive().items);
}

test "quit operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try std.testing.expectError(EvalError.Quit, interp.eval(.{ .op = .quit }));
}

test "less than operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 4 });
    try interp.eval(.{ .op = .less });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = false }}, interp.getActive().items);
}

test "less than or equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .less_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.getActive().items);
}

test "greater than operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .float = 5.1 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .greater });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.getActive().items);
}

test "greater than or equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .greater_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.getActive().items);
}

test "equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = true }}, interp.getActive().items);
}

test "not equal operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .op = .not_equal });

    try std.testing.expectEqualSlices(Value, &.{.{ .bool = false }}, interp.getActive().items);
}

test "mul operation with float overflow" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .float = std.math.floatMax(f64) });
    try interp.eval(.{ .float = 2.0 });

    try std.testing.expectError(EvalError.InvalidFloat, interp.eval(.{ .op = .star }));
}

test "Value.format" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    try w.print("{f} {f} {f}", .{ Value{ .int = 5 }, Value{ .float = 2.5 }, Value{ .float = 5.0 } });

    try std.testing.expectEqualStrings("5 2.5 5.0", w.buffer[0..w.end]);
}

test "arithmetic errors on non-numeric value" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.pushActive(.{ .bool = true });
    try interp.pushActive(.{ .int = 1 });

    try std.testing.expectError(EvalError.NotANumber, interp.eval(.{ .op = .plus }));
}

test "set var and get var operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var interp = try Interpreter.init(arena.allocator(), &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .get_var = "x" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 5 }}, interp.getActive().items);
}

test "get var errors on undefined variable" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try std.testing.expectError(EvalError.UndefinedVariable, interp.eval(.{ .get_var = "x" }));
}

test "set var overwrites an existing variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(arena.allocator(), &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .set_var = "x" });
    try interp.eval(.{ .get_var = "x" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 2 }}, interp.getActive().items);
}

test "variable name matching a keyword doesn't collide with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(arena.allocator(), &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 99 });
    try interp.eval(.{ .set_var = "dup" });
    try interp.eval(.{ .int = 7 });
    try interp.eval(.{ .op = .dup });
    try interp.eval(.{ .get_var = "dup" });

    try std.testing.expectEqualSlices(Value, &.{ .{ .int = 7 }, .{ .int = 7 }, .{ .int = 99 } }, interp.getActive().items);
}

test "not operator errors on non-boolean" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 5 });

    try std.testing.expectError(EvalError.NotABoolean, interp.eval(.{ .op = .not }));
}

test "comparison errors on a boolean operand" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .less });
    try interp.eval(.{ .int = 1 });
    try interp.eval(.{ .int = 2 });
    try interp.eval(.{ .op = .less });

    try std.testing.expectError(EvalError.NotANumber, interp.eval(.{ .op = .equal }));
}

test "call operation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try pushBlock(&interp, &.{ .{ .int = 5 }, .{ .int = 3 }, .{ .op = .plus } });
    try interp.eval(.{ .op = .call });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 8 }}, interp.getActive().items);
}

test "if operation runs the block when true" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.pushActive(.{ .bool = true });
    try pushBlock(&interp, &.{.{ .int = 42 }});
    try interp.eval(.{ .op = .@"if" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 42 }}, interp.getActive().items);
}

test "ifelse operation runs the else block when false" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(std.testing.allocator, &w);
    defer interp.deinit();

    try interp.pushActive(.{ .bool = false });
    try pushBlock(&interp, &.{.{ .int = 1 }});
    try pushBlock(&interp, &.{.{ .int = 2 }});
    try interp.eval(.{ .op = .ifelse });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 2 }}, interp.getActive().items);
}

test "while operation loops until condition is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var interp = try Interpreter.init(arena.allocator(), &w);
    defer interp.deinit();

    try interp.eval(.{ .int = 0 });
    try interp.eval(.{ .set_var = "i" });

    try pushBlock(&interp, &.{ .{ .get_var = "i" }, .{ .int = 3 }, .{ .op = .less } });
    try pushBlock(&interp, &.{ .{ .get_var = "i" }, .{ .int = 1 }, .{ .op = .plus }, .{ .set_var = "i" } });
    try interp.eval(.{ .op = .@"while" });
    try interp.eval(.{ .get_var = "i" });

    try std.testing.expectEqualSlices(Value, &.{.{ .int = 3 }}, interp.getActive().items);
}
