const std = @import("std");
const testing = std.testing;
const opcode = @import("opcode.zig");
const gas = @import("gas.zig");
const int = std.math.big.int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ac = gpa.allocator();
    defer _ = gpa.deinit();

    var bytecode = try ac.alloc(u8, 8);
    defer ac.free(bytecode);

    //bytecode = try std.fmt.hexToBytes(bytecode, "60038001600114");
    bytecode = try std.fmt.hexToBytes(bytecode, "6003800160061400");
    std.debug.print("input bytecode 0x{x}\n", .{
        std.fmt.fmtSliceHexLower(bytecode),
    });
    var interpreter = try Interpreter.init(ac, bytecode);
    defer interpreter.deinit() catch std.debug.print("failed", .{});
    try interpreter.runLoop();
    std.debug.print("Finished, result {}\n", .{interpreter.inst_result});
}

pub const Status = enum {
    Break,
    Continue,
    OutOfGas,
    StackUnderflow,
    StackOverflow,
};

pub const StackErr = error{ Underflow, Overflow };

// TODO: Impl safe stack.
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
        fn deinit(self: *This) !void {
            for (self.inner.items) |*item| {
                item.deinit();
            }
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
        fn dup(self: *This, idx: usize) !Status {
            const len = self.inner.items.len;
            if (len < idx) {
                return Status.StackUnderflow;
            } else if (len + 1 > STACK_LIMIT) {
                return Status.StackOverflow;
            }
            // Validation of item.
            const item = self.get(len - idx);
            try self.push(item.*);
            return Status.Continue;
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
    stack: Stack(int.Managed),
    inst_result: Status,
    // TODO: Validate inputs.
    fn init(
        alloc: std.mem.Allocator,
        bytecode: []u8,
    ) !This {
        return .{
            .ac = alloc,
            .inst = bytecode.ptr,
            .bytecode = bytecode,
            .stack = try Stack(int.Managed).init(alloc),
            .gas_tracker = GasTracker.init(100),
            .inst_result = Status.Continue,
        };
    }
    fn deinit(self: *This) !void {
        try self.stack.deinit();
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
            self.stack.print();
            self.inst = self.inst + 1;
        }
    }
    fn subGas(self: *This, cost: u64) void {
        if (!self.gas_tracker.recordGasCost(cost)) {
            self.inst_result = Status.OutOfGas;
        }
    }
    fn eval(self: *This, op: u8) !void {
        switch (op) {
            // Control.
            opcode.STOP => {
                self.inst_result = Status.Break;
            },
            // Arithmetic.
            opcode.ADD => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                _ = try a.addWrap(&a, &b, .unsigned, 256);
                try self.stack.push(a);
            },
            opcode.MUL => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                _ = try a.mulWrap(&a, &b, .unsigned, 256);
                try self.stack.push(a);
            },
            opcode.SUB => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                _ = try a.subWrap(&a, &b, .unsigned, 256);
                try self.stack.push(a);
            },
            opcode.DIV => {
                // self.subGas(gas.LOW);
                // var a = self.stack.pop();
                // var b = self.stack.pop();
                // _ = try a.divFloor(&a, &b, .unsigned, 256);
                // try self.stack.push(a);
            },
            opcode.SDIV => {},
            opcode.MOD => {},
            opcode.SMOD => {},
            opcode.ADDMOD => {},
            opcode.MULMOD => {},
            opcode.EXP => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                const exponent = try b.to(u32);
                _ = try a.pow(&a, exponent);
                try self.stack.push(a);
            },
            // Comparisons.
            opcode.LT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.orderAbs(b) == .lt) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
                b.deinit();
            },
            opcode.GT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.orderAbs(b) == .gt) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
                b.deinit();
            },
            opcode.SLT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.order(b) == .lt) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
                b.deinit();
            },
            opcode.SGT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.order(b) == .gt) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
                b.deinit();
            },
            opcode.EQ => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.eq(b)) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
                b.deinit();
            },
            opcode.ISZERO => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var x = try int.Managed.initSet(self.ac, 0);
                if (a.eq(x)) {
                    try x.set(1);
                }
                try self.stack.push(x);
                a.deinit();
            },
            // Pushes.
            opcode.PUSH1 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Dups.
            opcode.DUP1 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(1);
            },
            opcode.DUP2 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(2);
            },
            opcode.DUP3 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(3);
            },
            opcode.DUP4 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(4);
            },
            opcode.DUP5 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(5);
            },
            opcode.DUP6 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(6);
            },
            opcode.DUP7 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(7);
            },
            opcode.DUP8 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(8);
            },
            opcode.DUP9 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(9);
            },
            opcode.DUP10 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(10);
            },
            opcode.DUP11 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(11);
            },
            opcode.DUP12 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(12);
            },
            opcode.DUP13 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(13);
            },
            opcode.DUP14 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(14);
            },
            opcode.DUP15 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(15);
            },
            opcode.DUP16 => {
                self.subGas(gas.VERYLOW);
                self.inst_result = try self.stack.dup(16);
            },
            opcode.POP => {
                self.subGas(gas.VERYLOW);
                var x = self.stack.pop();
                x.deinit();
            },
            else => {
                std.debug.print("Unhandled opcode 0x{x}\n", .{op});
                self.inst_result = Status.Break;
            },
        }
    }
};
