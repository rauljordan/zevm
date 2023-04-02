const std = @import("std");
const testing = std.testing;
const opcode = @import("opcode.zig");
const gas = @import("gas.zig");

pub const Status = enum { Break, Continue, OutOfGas };

pub const StackErr = error{Overflow};

fn Stack(comptime T: type) type {
    const STACK_LIMIT: usize = 1024;
    return struct {
        const This = @This();
        inner: std.ArrayList(T),
        ac: std.mem.Allocator,
        fn init(ac: std.mem.Allocator) !This {
            var inner = try std.ArrayList(T).initCapacity(ac, STACK_LIMIT);
            return .{
                .ac = ac,
                .inner = inner,
            };
        }
        fn deinit(self: *This) void {
            self.inner.deinit();
        }
        fn get(self: This, idx: usize) *T {
            return &self.inner.items[idx];
        }
        fn push(self: *This, x: T) !void {
            return try self.inner.append(x);
        }
        fn pop(self: *This) T {
            return self.inner.pop();
        }
        fn dup(self: *This, idx: usize) void {
            const item = self.inner.items[idx];
            _ = item;
            return;
        }
        fn print(self: This) void {
            std.debug.print("{any}\n", .{self.inner.items});
        }
    };
}

pub const GasTracker = struct {
    limit: u64,
    total_used: u64,
    no_mem_used: u64,
    mem_used: u64,
    refunded: i64,
    pub fn init(gas_limit: u64) GasTracker {
        return .{
            .limit = gas_limit,
            .total_used = 0,
            .no_mem_used = 0,
            .mem_used = 0,
            .refunded = 0,
        };
    }
    inline fn recordGasCost(self: *GasTracker, cost: u64) bool {
        // Check if we overflow.
        const max_u64 = (1 << 64) - 1;
        if (self.total_used >= max_u64 - cost) {
            return false;
        }
        const all_used = self.total_used + cost;
        if (all_used >= self.limit) {
            return false;
        }
        self.no_mem_used += cost;
        self.total_used = all_used;
        return true;
    }
};

pub const Interpreter = struct {
    const This = @This();
    ac: std.mem.Allocator,
    inst: [*]u8,
    gas_tracker: GasTracker,
    bytecode: []u8,
    stack: Stack(u8),
    inst_result: Status,
    fn eval(self: *This, op: u8) !void {
        switch (op) {
            opcode.ADD => {
                if (!self.gas_tracker.recordGasCost(gas.VERYLOW)) {
                    self.inst_result = Status.OutOfGas;
                }
                const a = self.stack.pop();
                const b = self.stack.pop();
                // TODO: Modulo add.
                try self.stack.push(a + b);
                self.stack.print();
                self.inst_result = Status.Break;
            },
            opcode.PUSH1 => {
                const start = @ptrCast(*u8, self.inst + 1);
                try self.stack.push(start.*);
                std.debug.print("push1 = {x}\n", .{start.*});
                self.inst += 1;
            },
            opcode.DUP1 => {
                if (!self.gas_tracker.recordGasCost(gas.LOW)) {
                    self.inst_result = Status.OutOfGas;
                }
                const item = self.stack.get(0);
                try self.stack.push(item.*);
                self.stack.print();
            },
            else => {
                std.debug.print("Unhandled opcode 0x{x}\n", .{op});
                self.inst_result = Status.Break;
            },
        }
    }
    fn init(
        alloc: std.mem.Allocator,
        bytecode: []u8,
    ) !This {
        return .{
            .ac = alloc,
            .inst = bytecode.ptr,
            .bytecode = bytecode,
            .stack = try Stack(u8).init(alloc),
            .gas_tracker = GasTracker.init(100),
            .inst_result = Status.Continue,
        };
    }
    fn deinit(self: *This) void {
        self.stack.deinit();
    }
    fn programCounter(self: This) usize {
        // Subtraction of pointers is safe here
        return @ptrToInt(self.bytecode.ptr - self.inst);
    }
    fn runLoop(self: *This) !void {
        while (self.inst_result == Status.Continue) {
            const op = @ptrCast(*u8, self.inst);
            std.debug.print("Running 0x{x}\n", .{op.*});
            try self.eval(op.*);
            self.inst = self.inst + 1;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ac = gpa.allocator();
    defer _ = gpa.deinit();

    var bytecode = try ac.alloc(u8, 4);
    defer ac.free(bytecode);

    bytecode = try std.fmt.hexToBytes(bytecode, "60038001");
    std.debug.print("input bytecode 0x{x}\n", .{
        std.fmt.fmtSliceHexLower(bytecode),
    });
    var interpreter = try Interpreter.init(ac, bytecode);
    defer interpreter.deinit();
    try interpreter.runLoop();
    std.debug.print("Finished, result {}\n", .{interpreter.inst_result});
}
