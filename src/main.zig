const std = @import("std");
const testing = std.testing;
const opcode = @import("opcode.zig");
const gas = @import("gas.zig");
const int = std.math.big.int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ac = gpa.allocator();
    defer _ = gpa.deinit();

    // bytecode = try std.fmt.hexToBytes(bytecode, "6003800160061400");
    var bytecode = [_]u8{
        opcode.PUSH1,
        0x02,
        opcode.PUSH1,
        0x03,
        opcode.EXP,
        opcode.DUP1,
        opcode.SUB,
        opcode.ISZERO,
        opcode.STOP,
    };
    std.debug.print("input bytecode 0x{x}\n", .{
        std.fmt.fmtSliceHexLower(&bytecode),
    });
    var interpreter = try Interpreter.init(ac, &bytecode);
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
            const item = self.get(len - idx);
            try self.push(item.*);
            return Status.Continue;
        }
        fn print(self: This) void {
            std.debug.print("{any}\n", .{self.inner.items});
        }
    };
}

pub const Interpreter = struct {
    const This = @This();
    ac: std.mem.Allocator,
    inst: [*]u8,
    gas_tracker: gas.Tracker,
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
            .gas_tracker = gas.Tracker.init(100),
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
                b.deinit();
            },
            opcode.SIGNEXTEND => {},
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
            opcode.AND => {},
            opcode.OR => {},
            opcode.XOR => {},
            opcode.NOT => {},
            opcode.BYTE => {},
            opcode.SHL => {},
            opcode.SHR => {},
            opcode.SAR => {},
            opcode.SHA3 => {},
            opcode.ADDRESS => {},
            opcode.BALANCE => {},
            opcode.ORIGIN => {},
            opcode.CALLER => {},
            opcode.CALLVALUE => {},
            opcode.CALLDATALOAD => {},
            opcode.CALLDATASIZE => {},
            opcode.CALLDATACOPY => {},
            opcode.CODESIZE => {},
            opcode.GASPRICE => {},
            opcode.EXTCODESIZE => {},
            opcode.EXTCODECOPY => {},
            opcode.RETURNDATASIZE => {},
            opcode.RETURNDATACOPY => {},
            opcode.EXTCODEHASH => {},
            opcode.BLOCKHASH => {},
            opcode.COINBASE => {},
            opcode.TIMESTAMP => {},
            opcode.NUMBER => {},
            opcode.PREVRANDAO => {},
            opcode.GASLIMIT => {},
            opcode.CHAINID => {},
            opcode.SELFBALANCE => {},
            opcode.BASEFEE => {},
            opcode.POP => {
                self.subGas(gas.VERYLOW);
                var x = self.stack.pop();
                x.deinit();
            },
            opcode.MLOAD => {},
            opcode.MSTORE => {},
            opcode.MSTORE8 => {},
            opcode.SLOAD => {},
            opcode.SSTORE => {},
            opcode.JUMP => {},
            opcode.JUMPI => {},
            opcode.PC => {},
            opcode.MSIZE => {},
            opcode.GAS => {},
            opcode.JUMPDEST => {},
            // Pushes.
            opcode.PUSH1 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            opcode.PUSH2 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH3 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH4 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH5 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH6 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH7 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH8 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH9 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH10 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH11 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH12 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH13 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH14 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH15 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH16 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH17 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH18 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH19 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH20 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH21 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH22 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH23 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH24 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH25 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH26 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH27 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH28 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH29 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH30 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH31 => {
                const start = @ptrCast(*u8, self.inst + 1);
                var x = try int.Managed.initSet(self.ac, start.*);
                try self.stack.push(x);
                self.inst += 1;
            },
            // Pushes.
            opcode.PUSH32 => {
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
            opcode.SWAP1 => {},
            opcode.SWAP2 => {},
            opcode.SWAP3 => {},
            opcode.SWAP4 => {},
            opcode.SWAP5 => {},
            opcode.SWAP6 => {},
            opcode.SWAP7 => {},
            opcode.SWAP8 => {},
            opcode.SWAP9 => {},
            opcode.SWAP10 => {},
            opcode.SWAP11 => {},
            opcode.SWAP12 => {},
            opcode.SWAP13 => {},
            opcode.SWAP14 => {},
            opcode.SWAP15 => {},
            opcode.SWAP16 => {},
            opcode.LOG0 => {

            },
            opcode.LOG1 => {

            },
            opcode.LOG2 => {

            },
            opcode.LOG3 => {

            },
            opcode.CREATE => {},
            opcode.CALL => {},
            opcode.CALLCODE => {},
            opcode.RETURN => {},
            opcode.DELEGATECALL => {},
            opcode.CREATE2 => {},
            opcode.STATICCALL => {},
            opcode.REVERT => {},
            opcode.INVALID => {},
            opcode.SELFDESTRUCT => {},
            else => {
                std.debug.print("Unhandled opcode 0x{x}\n", .{op});
                self.inst_result = Status.Break;
            },
        }
    }
};
