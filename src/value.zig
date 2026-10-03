const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;

const tok = @import("./token.zig");
const Token = tok.Token;
const OpType = tok.OpType;

const EvalError = @import("./errors.zig").EvalError;

pub const Value = union(enum) {
    int: i32,
    float: f64,
    bool: bool,
    object: *GcObject,

    pub fn isNumber(self: Value) EvalError!Value {
        return switch (self) {
            .int, .float => self,
            else => EvalError.NotANumber,
        };
    }

    pub fn isInteger(self: Value) EvalError!i32 {
        return switch (self) {
            .int => |i| i,
            else => EvalError.NotAnInteger,
        };
    }

    pub fn isFloat(self: Value) EvalError!f64 {
        return switch (self) {
            .float => |f| f,
            else => EvalError.NotAFloat,
        };
    }

    pub fn isBool(self: Value) EvalError!bool {
        return switch (self) {
            .bool => |b| b,
            else => EvalError.NotABoolean,
        };
    }

    pub fn isBlock(self: Value) EvalError![]Token {
        return switch (self) {
            .object => |o| o.isBlock(),
            else => EvalError.NotABlock,
        };
    }

    pub fn isArray(self: Value) EvalError![]Value {
        return switch (self) {
            .object => |o| o.isArray(),
            else => EvalError.NotAnArray,
        };
    }

    pub fn isString(self: Value) EvalError![]const u8 {
        return switch (self) {
            .object => |o| o.isString(),
            else => EvalError.NotAString,
        };
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| if (f == @floor(f)) try writer.print("{d:.1}", .{f}) else try writer.print("{d}", .{f}),
            .bool => |b| try writer.print("{}", .{b}),
            .object => |o| {
                try writer.print("{f}", .{o});
            },
        }
    }
};

pub const GcObject = struct {
    value: GcObjectValue,
    is_marked: bool,

    pub fn deinit(self: *GcObject, allocator: Allocator) void {
        self.value.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn isArray(self: GcObject) EvalError![]Value {
        return switch (self.value) {
            .array => |a| a,
            else => EvalError.NotAnArray,
        };
    }

    pub fn isString(self: GcObject) EvalError![]const u8 {
        return switch (self.value) {
            .string => |s| s,
            else => EvalError.NotAString,
        };
    }

    pub fn isBlock(self: GcObject) EvalError![]Token {
        return switch (self.value) {
            .block => |b| b,
            else => EvalError.NotABlock,
        };
    }

    pub fn format(self: GcObject, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.value) {
            .array => |a| {
                try writer.writeAll("[ ");
                for (a, 0..) |val, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try writer.print("{f}", .{val});
                }
                try writer.writeAll(" ]");
            },
            .string => |s| {
                try writer.writeAll("\"");
                try writer.print("{s}", .{s});
                try writer.writeAll("\"");
            },
            .block => |b| {
                try writer.writeAll("{ ");
                for (b, 0..) |token, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try writer.print("{f}", .{token});
                }
                try writer.writeAll(" }");
            },
        }
    }
};

pub const GcObjectValue = union(enum) {
    array: []Value,
    string: []const u8,
    block: []Token,

    pub fn deinit(self: GcObjectValue, allocator: Allocator) void {
        // does not need to have child elements freed since the GC frees them either way
        switch (self) {
            .array => |a| allocator.free(a),
            .string => |s| allocator.free(s),
            .block => |b| allocator.free(b),
        }
    }
};
