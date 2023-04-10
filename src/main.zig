const std = @import("std");
const testing = std.testing;
const opcode = @import("opcode.zig");
const gas = @import("gas.zig");
const host = @import("host.zig");
const int = std.math.big.int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ac = gpa.allocator();
    defer _ = gpa.deinit();

    // TODO: Allocate a fixed buffer for the stack!
    var bytecode = [_]u8{
        opcode.PUSH1,
        0x02,
        opcode.PUSH1,
        0x03,
        opcode.EXP,
        opcode.DUP1,
        opcode.SUB,
        opcode.ISZERO,
        opcode.ADDRESS,
        opcode.STOP,
    };
    std.debug.print("input bytecode 0x{x}\n", .{
        std.fmt.fmtSliceHexLower(&bytecode),
    });
    var mock_host = host.Mock.init();
    var interpreter = try Interpreter.init(ac, mock_host, &bytecode);
    defer interpreter.deinit() catch std.debug.print("failed", .{});

    const start = try std.time.Instant.now();
    try interpreter.runLoop();
    const end = try std.time.Instant.now();
    std.debug.print("Elapsed={}, Result={}\n", .{ std.fmt.fmtDuration(end.since(start)), interpreter.inst_result });
}

test "Arithmetic opcodes" {}
test "Bitwise manipulation opcodes" {}
test "Stack manipulation opcodes" {}
test "Control flow opcodes" {}
test "Host opcodes" {}

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
        fn swap(self: *This, idx: usize) !Status {
            _ = idx;
            _ = self;
            return Status.Continue;
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
    eth_host: host.Mock,
    stack: Stack(int.Managed),
    inst_result: Status,
    // TODO: Validate inputs.
    fn init(
        alloc: std.mem.Allocator,
        eth_host: host.Mock,
        bytecode: []u8,
    ) !This {
        return .{
            .ac = alloc,
            .eth_host = eth_host,
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
    fn pushN(self: *This, comptime n: u8) !void {
        self.subGas(gas.VERYLOW);
        const start = @ptrCast(*u8, self.inst + n);
        var x = try int.Managed.initSet(self.ac, start.*);
        try self.stack.push(x);
        self.inst += n;
    }
    fn dupN(self: *This, comptime n: u8) !void {
        self.subGas(gas.VERYLOW);
        self.inst_result = try self.stack.dup(n);
    }
    fn swapN(self: *This, comptime n: u8) !void {
        self.subGas(gas.VERYLOW);
        self.inst_result = try self.stack.swap(n);
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
            opcode.AND => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var r = try int.Managed.init(self.ac);
                try r.bitAnd(&a, &b);
                try self.stack.push(r);
                a.deinit();
                b.deinit();
            },
            opcode.OR => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var r = try int.Managed.init(self.ac);
                try r.bitOr(&a, &b);
                try self.stack.push(r);
                a.deinit();
                b.deinit();
            },
            opcode.XOR => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var r = try int.Managed.init(self.ac);
                try r.bitXor(&a, &b);
                try self.stack.push(r);
                a.deinit();
                b.deinit();
            },
            opcode.NOT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var r = try int.Managed.init(self.ac);
                try r.bitNotWrap(&a, .unsigned, 256);
                try self.stack.push(r);
                a.deinit();
            },
            opcode.BYTE => {},
            opcode.SHL => {},
            opcode.SHR => {},
            opcode.SAR => {},
            opcode.SHA3 => {},
            opcode.ADDRESS => {
                // self.subGas(gas.HIGH);
                // const addr = try self.eth_host.address();
                // var addr_bytes = std.fmt.bytesToHex(addr, .lower);
                // var r = try int.Managed.init(self.ac);
                // try r.setString(10, &addr_bytes);
                // try self.stack.push(r);
            },
            opcode.BALANCE => {
                // self.subGas(gas.HIGH);
                // const balance = try self.eth_host.balance();
                // var balance_bytes = std.fmt.bytesToHex(balance, .lower);
                // var r = try int.Managed.init(self.ac);
                // try r.setString(10, &balance_bytes);
                // try self.stack.push(r);
            },
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
            opcode.GAS => {
                var r = try int.Managed.initSet(self.ac, self.gas_tracker.total_used);
                try self.stack.push(r);
            },
            opcode.JUMPDEST => {},
            // Pushes.
            opcode.PUSH1 => try self.pushN(1),
            opcode.PUSH2 => try self.pushN(2),
            opcode.PUSH3 => try self.pushN(3),
            opcode.PUSH4 => try self.pushN(4),
            opcode.PUSH5 => try self.pushN(5),
            opcode.PUSH6 => try self.pushN(6),
            opcode.PUSH7 => try self.pushN(7),
            opcode.PUSH8 => try self.pushN(8),
            opcode.PUSH9 => try self.pushN(9),
            opcode.PUSH10 => try self.pushN(10),
            opcode.PUSH11 => try self.pushN(11),
            opcode.PUSH12 => try self.pushN(12),
            opcode.PUSH13 => try self.pushN(13),
            opcode.PUSH14 => try self.pushN(14),
            opcode.PUSH15 => try self.pushN(15),
            opcode.PUSH16 => try self.pushN(16),
            opcode.PUSH17 => try self.pushN(17),
            opcode.PUSH18 => try self.pushN(18),
            opcode.PUSH19 => try self.pushN(19),
            opcode.PUSH20 => try self.pushN(20),
            opcode.PUSH21 => try self.pushN(21),
            opcode.PUSH22 => try self.pushN(22),
            opcode.PUSH23 => try self.pushN(23),
            opcode.PUSH24 => try self.pushN(24),
            opcode.PUSH25 => try self.pushN(25),
            opcode.PUSH26 => try self.pushN(26),
            opcode.PUSH27 => try self.pushN(27),
            opcode.PUSH28 => try self.pushN(28),
            opcode.PUSH29 => try self.pushN(29),
            opcode.PUSH30 => try self.pushN(30),
            opcode.PUSH31 => try self.pushN(31),
            opcode.PUSH32 => try self.pushN(32),
            // Dups.
            opcode.DUP1 => try self.dupN(1),
            opcode.DUP2 => try self.dupN(2),
            opcode.DUP3 => try self.dupN(3),
            opcode.DUP4 => try self.dupN(4),
            opcode.DUP5 => try self.dupN(5),
            opcode.DUP6 => try self.dupN(6),
            opcode.DUP7 => try self.dupN(7),
            opcode.DUP8 => try self.dupN(8),
            opcode.DUP9 => try self.dupN(9),
            opcode.DUP10 => try self.dupN(10),
            opcode.DUP11 => try self.dupN(11),
            opcode.DUP12 => try self.dupN(12),
            opcode.DUP13 => try self.dupN(13),
            opcode.DUP14 => try self.dupN(14),
            opcode.DUP15 => try self.dupN(15),
            opcode.DUP16 => try self.dupN(16),
            // Swaps.
            opcode.SWAP1 => try self.swapN(1),
            opcode.SWAP2 => try self.swapN(2),
            opcode.SWAP3 => try self.swapN(3),
            opcode.SWAP4 => try self.swapN(4),
            opcode.SWAP5 => try self.swapN(5),
            opcode.SWAP6 => try self.swapN(6),
            opcode.SWAP7 => try self.swapN(7),
            opcode.SWAP8 => try self.swapN(8),
            opcode.SWAP9 => try self.swapN(9),
            opcode.SWAP10 => try self.swapN(10),
            opcode.SWAP11 => try self.swapN(11),
            opcode.SWAP12 => try self.swapN(12),
            opcode.SWAP13 => try self.swapN(13),
            opcode.SWAP14 => try self.swapN(14),
            opcode.SWAP15 => try self.swapN(15),
            opcode.SWAP16 => try self.swapN(16),
            opcode.LOG0 => {},
            opcode.LOG1 => {},
            opcode.LOG2 => {},
            opcode.LOG3 => {},
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

// Insanely fast arena allocator for a single type using a memory pool.
fn TurboPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const List = std.TailQueue(T);
        arena: std.heap.ArenaAllocator,
        free: List = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
        pub fn new(self: *Self) !*T {
            const obj = if (self.free.popFirst()) |item|
                item
            else
                try self.arena.allocator().create(List.Node);
            return &obj.data;
        }
        pub fn delete(self: *Self, obj: *T) void {
            const node = @fieldParentPtr(List.Node, "data", obj);
            self.free.append(node);
        }
    };
}
