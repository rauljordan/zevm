const std = @import("std");
const Status = @import("main.zig").Status;
const GasTracker = @import("gas.zig").Tracker;
const BigInt = std.math.big.int.Managed;
const Hash = [32]u8;
const Address = [20]u8;

/// Returns a result from a host call, which will include
/// data and a boolean indicating whether the data was cold loaded.
fn HostResult(comptime T: type) type {
    return struct {
        data: T,
        is_cold_loaded: bool,
    };
}

pub const AccountLoadResult = struct {
    is_cold: bool,
    is_new_account: bool,
};

pub const SStoreResult = struct {
    original: BigInt,
    present: BigInt,
    new: BigInt,
    is_cold: bool,
};

pub const SelfDestructResult = struct {
    had_value: bool,
    target_exists: bool,
    is_cold: bool,
    previously_destroyed: bool,
};

pub const CreateScheme = enum {
    Create,
    Create2,
};

pub const CreateInputs = struct {
    caller: Address,
    scheme: CreateScheme,
    salt: ?BigInt,
    value: BigInt,
    init_code: []u8,
    gas_limit: u64,
};

pub const CreateResult = struct {
    status: Status,
    address: ?Address,
    gas_tracker: GasTracker,
    data: []u8,
};

pub const Transfer = struct {
    source: Address,
    target: Address,
    value: BigInt,
};

pub const CallScheme = enum {
    Call,
    CallCode,
    DelegateCall,
    StaticCall,
};

/// CallContext of the runtime.
pub const CallContext = struct {
    /// Execution address.
    address: Address,
    /// Caller of the EVM.
    caller: Address,
    /// The address the contract code was loaded from, if any.
    code_address: ?Address,
    /// Apparent value of the EVM.
    apparent_value: BigInt,
    /// The scheme used for the call.
    scheme: CallScheme,
};

pub const CallInputs = struct {
    target: Address,
    transfer: ?Transfer,
    input: []u8,
    gas_limit: u64,
    /// The context of the call.
    context: CallContext,
    is_static: bool,
};

pub const CallResult = struct {
    status: Status,
    gas_tracker: GasTracker,
    data: []u8,
};

// TODO: Build the host structs here!
pub const Host = struct {
    getFn: *const fn (ptr: *Host) void,
    numInputsFn: *const fn (ptr: *Host) void,
    pub fn get(self: *Host) void {
        self.getFn(self);
    }
    pub fn numInputs(self: *Host) void {
        self.numInputsFn(self);
    }
    pub fn loadAccount(self: *Host, address: Address) !?AccountLoadResult {
        _ = address;
        _ = self;
        return null;
    }
    pub fn blockHash(self: *Host, number: BigInt) !?Hash {
        _ = number;
        _ = self;
        return null;
    }
    pub fn balance(self: *Host, address: Address) !?HostResult(BigInt) {
        _ = address;
        _ = self;
        return null;
    }
    pub fn code(self: *Host) !?HostResult([]u8) {
        _ = self;
        return null;
    }
    pub fn codeHash(self: *Host) !?HostResult(Hash) {
        _ = self;
        return null;
    }
    pub fn sload(self: *Host) !?HostResult(Hash) {
        _ = self;
        return null;
    }
    pub fn sstore(
        self: *Host,
        address: Address,
        index: BigInt,
        value: BigInt,
    ) !?SStoreResult {
        _ = value;
        _ = index;
        _ = address;
        _ = self;
        return null;
    }
    pub fn log(
        self: *Host,
        address: Address,
        topics: []Hash,
        data: []u8,
    ) !void {
        _ = data;
        _ = topics;
        _ = address;
        _ = self;
    }
    pub fn selfdestruct(
        self: *Host,
        address: Address,
        target: Address,
    ) !?SelfDestructResult {
        _ = target;
        _ = address;
        _ = self;
    }
    pub fn create(self: *Host, inputs: CreateInputs) !?CreateResult {
        _ = inputs;
        _ = self;
    }
    pub fn call(self: *Host, inputs: CallInputs) !?CallResult {
        _ = inputs;
        _ = self;
    }
};

// TODO: Build a real host via the Rust FFI boundary.
pub const Mock = struct {
    db: Host,
    pub fn init() Mock {
        const impl = struct {
            pub fn get(ptr: *Host) void {
                const self = @fieldParentPtr(Mock, "db", ptr);
                self.get();
            }
            pub fn numInputs(ptr: *Host) void {
                const self = @fieldParentPtr(Mock, "db", ptr);
                self.numInputs();
            }
        };
        return .{
            .db = .{ .getFn = impl.get, .numInputsFn = impl.numInputs },
        };
    }
    pub fn get(self: *Mock) void {
        _ = self;
        std.debug.print("get", .{});
    }
    pub fn numInputs(self: *Mock) void {
        _ = self;
        std.debug.print("numInputs", .{});
    }
};
