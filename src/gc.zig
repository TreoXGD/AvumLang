const std = @import("std");
const Allocator = std.mem.Allocator;
const Aligned = std.array_list.Aligned;
const StringHashMap = std.hash_map.StringHashMap;

const Value = @import("./value.zig").Value;
const GcObject = @import("./value.zig").GcObject;
const GcObjectValue = @import("./value.zig").GcObjectValue;

const EvalError = @import("./errors.zig").EvalError;

// standard mark and sweep garbage collector
pub const GC = struct {
    allocator: Allocator,
    // contains references of string objects
    string_pool: StringHashMap(*GcObject),
    // contains all object references used for marking and sweeping
    obj_list: Aligned(*GcObject, null) = .empty,
    obj_count: usize = 0,
    obj_threshold: usize = 128,

    pub fn init(allocator: Allocator) GC {
        return .{
            .allocator = allocator,
            .string_pool = StringHashMap(*GcObject).init(allocator),
        };
    }

    pub fn deinit(self: *GC) void {
        for (self.obj_list.items) |obj| {
            obj.deinit(self.allocator);
        }
        self.obj_list.deinit(self.allocator);
        self.string_pool.deinit();
    }

    pub fn getOrCreateString(self: *GC, str: []const u8) !*GcObject {
        const get_result = try self.string_pool.getOrPut(str);
        if (get_result.found_existing) {
            return get_result.value_ptr.*;
        }

        const gc_object = try self.allocObject(.{ .string = str });
        get_result.value_ptr.* = gc_object;
        return gc_object;
    }

    pub fn allocObject(self: *GC, gc_value: GcObjectValue) EvalError!*GcObject {
        const gc_object = try self.allocator.create(GcObject);
        errdefer gc_object.deinit(self.allocator);

        gc_object.* = .{
            .value = gc_value,
            .is_marked = false,
        };

        try self.obj_list.append(self.allocator, gc_object);

        self.obj_count += 1;

        return gc_object;
    }

    pub fn markValue(value: Value) void {
        // check if the value is an object
        const gc_object = switch (value) {
            .object => value.object,
            else => return,
        };

        // stop when a cycle is detected
        if (gc_object.is_marked) return;

        gc_object.is_marked = true;

        switch (gc_object.value) {
            .array => |a| {
                for (a) |item| markValue(item);
            },
            .block => {},
            .string => {},
        }
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
                if (obj.value == .string) _ = self.string_pool.remove(obj.value.string);

                obj.deinit(self.allocator);
                _ = self.obj_list.swapRemove(i);
            }
        }
    }
};
