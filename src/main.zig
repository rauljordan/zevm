const std = @import("std");
const testing = std.testing;
const opcode = @import("opcode.zig");
const gas = @import("gas.zig");
const host = @import("host.zig");
const BigInt = std.math.big.int.Managed;

const MAX_CODE_SIZE: usize = 0x6000;

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // var ac = gpa.allocator();
    // defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ac = arena.allocator();
    defer _ = arena.deinit();

    // TODO: Allocate a fixed buffer for the stack!
    var bytecode = [_]u8{
        opcode.PUSH1,
        0x02,
        opcode.PUSH1,
        0x03,
        opcode.EXP,
        opcode.DUP1,
        opcode.ADD,
        opcode.DUP1,
        opcode.EXP,
        opcode.STOP,
    };
    std.debug.print("input bytecode 0x{x}\n", .{
        std.fmt.fmtSliceHexLower(&bytecode),
    });
    var mock = host.Mock.init();
    var interpreter = try Interpreter.init(ac, mock.host, &bytecode);
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

pub const StackErr = error{ Underflow, Overflow };

pub const Status = enum {
    Break,
    Continue,
    OutOfGas,
    StackUnderflow,
    StackOverflow,
};

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

pub const InterpreterError = error{
    DisallowedHostCall,
};

pub const Interpreter = struct {
    const This = @This();
    ac: std.mem.Allocator,
    inst: [*]u8,
    gas_tracker: gas.Tracker,
    bytecode: []u8,
    eth_host: host.Host,
    stack: Stack(u256),
    inst_result: Status,
    // TODO: Validate inputs.
    fn init(
        alloc: std.mem.Allocator,
        eth_host: host.Host,
        bytecode: []u8,
    ) !This {
        return .{
            .ac = alloc,
            .eth_host = eth_host,
            .inst = bytecode.ptr,
            .bytecode = bytecode,
            .stack = try Stack(u256).init(alloc),
            .gas_tracker = gas.Tracker.init(100),
            .inst_result = Status.Continue,
        };
    }
    fn deinit(self: *This) !void {
        try self.stack.deinit();
    }
    fn programCounter(self: This) usize {
        // Subtraction of pointers is safe here
        const inst = @ptrCast(*u8, self.inst);
        return @ptrToInt(self.bytecode.ptr - inst.*);
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
        var x = @as(u256, start.*);
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
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                var r = try BigInt.init(self.ac);
                defer r.deinit();
                _ = try r.addWrap(&x, &y, .unsigned, 256);
                const result = try r.to(u256);
                try self.stack.push(result);
            },
            opcode.MUL => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                var r = try BigInt.init(self.ac);
                defer r.deinit();
                _ = try r.mulWrap(&x, &y, .unsigned, 256);
                const result = try r.to(u256);
                try self.stack.push(result);
            },
            opcode.SUB => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                var r = try BigInt.init(self.ac);
                defer r.deinit();
                _ = try r.subWrap(&x, &y, .unsigned, 256);
                const result = try r.to(u256);
                try self.stack.push(result);
            },
            opcode.DIV => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                var quotient = try BigInt.init(self.ac);
                defer quotient.deinit();
                var remainder = try BigInt.init(self.ac);
                defer remainder.deinit();
                _ = try quotient.divFloor(&remainder, &x, &y);
                const result = try quotient.to(u256);
                try self.stack.push(result);
            },
            opcode.SDIV => {},
            opcode.MOD => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                try self.stack.push(@mod(a, b));
            },
            opcode.SMOD => {},
            opcode.ADDMOD => {},
            opcode.MULMOD => {},
            opcode.EXP => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                const exponent = try y.to(u32);
                _ = try x.pow(&x, exponent);
                const result = try x.to(u256);
                try self.stack.push(result);
            },
            opcode.SIGNEXTEND => {},
            // Comparisons.
            opcode.LT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                if (a < b) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.GT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                if (a > b) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.SLT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                if (x.order(y) == .lt) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.SGT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                var x = try BigInt.initSet(self.ac, a);
                defer x.deinit();
                var y = try BigInt.initSet(self.ac, b);
                defer y.deinit();
                if (x.order(y) == .gt) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.EQ => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                if (a == b) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.ISZERO => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                if (a == 0) {
                    try self.stack.push(1);
                } else {
                    try self.stack.push(0);
                }
            },
            opcode.AND => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                try self.stack.push(a & b);
            },
            opcode.OR => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                try self.stack.push(a | b);
            },
            opcode.XOR => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                try self.stack.push(a ^ b);
            },
            opcode.NOT => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                try self.stack.push(~a);
            },
            opcode.BYTE => {},
            opcode.SHL => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                const rhs = @truncate(u8, b);
                try self.stack.push(a << rhs);
            },
            opcode.SHR => {
                self.subGas(gas.LOW);
                var a = self.stack.pop();
                var b = self.stack.pop();
                const rhs = @truncate(u8, b);
                try self.stack.push(a >> rhs);
            },
            opcode.SAR => {},
            opcode.SHA3 => {},
            opcode.ADDRESS => {
                self.subGas(gas.HIGH);
                const env = try self.eth_host.env();
                const addr = switch (env.tx.purpose) {
                    .Call => |address| address,
                    else => return InterpreterError.DisallowedHostCall,
                };
                try self.stack.push(@as(u256, addr));
            },
            opcode.BALANCE => {
                self.subGas(gas.HIGH);
                var a = self.stack.pop();
                const addr = @truncate(u160, a);
                const result = try self.eth_host.balance(addr);
                const balance = if (result) |r|
                    r.data
                else
                    0;
                try self.stack.push(balance);
            },
            opcode.ORIGIN => {},
            opcode.CALLER => {
                self.subGas(gas.HIGH);
                const env = try self.eth_host.env();
                try self.stack.push(@as(u256, env.tx.caller));
            },
            opcode.CALLVALUE => {
                self.subGas(gas.HIGH);
                const env = try self.eth_host.env();
                try self.stack.push(env.tx.value);
            },
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
                _ = self.stack.pop();
            },
            opcode.MLOAD => {},
            opcode.MSTORE => {},
            opcode.MSTORE8 => {},
            opcode.SLOAD => {},
            opcode.SSTORE => {},
            opcode.JUMP => {},
            opcode.JUMPI => {},
            opcode.PC => {
                try self.stack.push(@as(u256, self.programCounter()));
            },
            opcode.MSIZE => {},
            opcode.GAS => {
                try self.stack.push(@as(u256, self.gas_tracker.total_used));
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
