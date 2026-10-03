const std = @import("std");
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;
const StringHashMap = std.hash_map.StringHashMap;

const Token = @import("./token.zig").Token;

const Value = @import("./value.zig").Value;
const GcObject = @import("./value.zig").GcObject;
const GcObjectValue = @import("./value.zig").GcObjectValue;

const EvalError = @import("./errors.zig").EvalError;

// standard mark and sweep garbage collector
pub const GC = struct {
    allocator: Allocator,
    // contains references of text (string and identifier) objects
    text_pool: StringHashMap(*GcObject),
    // contains all object references used for marking and sweeping
    obj_list: Aligned(*GcObject, null) = .empty,
    obj_threshold: usize = 128,

    pub fn init(allocator: Allocator) GC {
        return .{
            .allocator = allocator,
            .text_pool = StringHashMap(*GcObject).init(allocator),
        };
    }

    pub fn deinit(self: *GC) void {
        for (self.obj_list.items) |obj| {
            obj.deinit(self.allocator);
        }
        self.obj_list.deinit(self.allocator);
        self.text_pool.deinit();
    }

    pub fn getOrCreateString(self: *GC, str: []const u8) !*GcObject {
        if (self.text_pool.get(str)) |obj| return obj;

        const str_copy = try self.allocator.dupe(u8, str);
        const gc_object = try self.allocObject(.{ .string = str_copy });
        try self.text_pool.put(str_copy, gc_object);
        return gc_object;
    }

    pub fn allocObject(self: *GC, gc_value: GcObjectValue) EvalError!*GcObject {
        errdefer gc_value.deinit(self.allocator);

        const gc_object = try self.allocator.create(GcObject);
        errdefer gc_object.deinit(self.allocator);

        gc_object.* = .{
            .value = gc_value,
            .is_marked = false,
        };

        try self.obj_list.append(self.allocator, gc_object);

        return gc_object;
    }

    pub fn markValue(self: *GC, value: Value) void {
        switch (value) {
            .object => self.markObject(value.object),
            else => return,
        }
    }

    pub fn markObject(self: *GC, gc_object: *GcObject) void {
        // stop when a cycle is detected
        if (gc_object.is_marked) return;

        gc_object.is_marked = true;

        switch (gc_object.value) {
            .array => |a| for (a) |item| self.markValue(item),
            .block => |b| for (b) |tok| self.markToken(tok),
            .string => {},
        }
    }

    pub fn markToken(self: *GC, token: Token) void {
        const text = switch (token) {
            .string, .set_var, .get_var => |s| s,
            else => return,
        };

        self.markText(text);
    }

    pub fn markText(self: *GC, text: []const u8) void {
        if (self.text_pool.get(text)) |o| self.markObject(o);
    }

    pub fn sweepObjects(self: *GC) void {
        var i = self.obj_list.items.len;

        while (i > 0) {
            i -= 1;

            const obj = self.obj_list.items[i];
            const is_marked = obj.is_marked;

            if (is_marked) {
                obj.is_marked = false;
            } else {
                if (obj.value == .string) _ = self.text_pool.remove(obj.value.string);

                obj.deinit(self.allocator);
                _ = self.obj_list.swapRemove(i);
            }
        }
    }
};
