const std = @import("std");
const Status = @import("main.zig").Status;

pub const StackErr = error{ Underflow, Overflow };

// TODO: Impl safe stack.
pub fn Stack(comptime T: type) type {
    const STACK_LIMIT: usize = 1024;
    return struct {
        const This = @This();
        inner: std.ArrayList(T),
        ac: std.mem.Allocator,
        pub fn init(ac: std.mem.Allocator) !This {
            var inner = try std.ArrayList(T).initCapacity(ac, STACK_LIMIT);
            return .{
                .ac = ac,
                .inner = inner,
            };
        }
        pub fn deinit(self: *This) !void {
            self.inner.deinit();
        }
        pub fn get(self: This, idx: usize) *T {
            return &self.inner.items[idx];
        }
        pub fn push(self: *This, x: T) !void {
            return try self.inner.append(x);
        }
        pub fn pop(self: *This) T {
            return self.inner.pop();
        }
        pub fn swap(self: *This, idx: usize) !void {
            const removed = self.inner.swapRemove(idx - 1);
            return try self.inner.append(removed);
        }
        pub fn dup(self: *This, idx: usize) !Status {
            const len = self.inner.items.len;
            if (len < idx) {
                return Status.StackUnderflow;
            } else if (len + 1 > STACK_LIMIT) {
                return Status.StackOverflow;
            }
            const item = self.get(len - idx);
            try self.push(item.*);
            return Status.Continue;
        }
        pub fn print(self: This) void {
            std.debug.print("{any}\n", .{self.inner.items});
        }
    };
}
