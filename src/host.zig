const std = @import("std");
const Status = @import("main.zig").Status;
const GasTracker = @import("gas.zig").Tracker;
const BigInt = std.math.big.int.Managed;
const Hash = [32]u8;
const Address = [20]u8;

/// Environment data for the host, such as block, transaction, and chain
/// configuration values at the time of the execution.
pub const Env = struct {
    chain: ChainEnv,
    block: BlockEnv,
    tx: TxEnv,
};

/// The current hard fork the chain environment is on.
pub const Fork = enum {
    Frontier,
    FrontierThawing,
    Homestead,
    Dao,
    Tangerine,
    SpuriousDragon,
    Byzantium,
    Constantinople,
    Petersburg,
    Istambul,
    MuirGlacier,
    Berlin,
    London,
    ArrowGlacier,
    GrayGlacier,
    Merge,
    Shanghai,
};

pub const ChainEnv = struct {
    chain_id: BigInt,
    memory_limit: u64,
    fork: Fork,
};

pub const BlockEnv = struct {
    number: BigInt,
    coinbase: Address,
    timestamp: u64,
    difficulty: BigInt,
    prev_randao: ?Hash,
    basefee: BigInt,
    gas_limit: u64,
};

pub const TxEnv = struct {
    caller: Address,
    gas_limit: u64,
    gas_price: u64,
    gas_priority_fee: ?BigInt,
    value: BigInt,
    data: []u8,
    chain_id: ?u64,
    nonce: ?u64,
    // TODO: Add access list?
    purpose: union(enum) {
        Call: Address,
        Create: CreateScheme,
    },
};

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

pub const HostError = error{ Internal, Unimplemented };

/// Host defines an interface for an Ethereum node host that can perform actions required by EVM opcodes
/// such as retrieving environment values, interacting with accounts, and performing
/// expensive operations such as sstore, create, and create2. Cross-contract calls
/// are also performed via the host.
pub const Host = struct {
    envFn: *const fn (ptr: *Host) HostError!Env,
    loadAccountFn: *const fn (ptr: *Host, address: Address) HostError!?AccountLoadResult,
    blockHashFn: *const fn (ptr: *Host, number: BigInt) HostError!?Hash,
    balanceFn: *const fn (ptr: *Host, address: Address) HostError!?HostResult(BigInt),
    codeFn: *const fn (ptr: *Host) HostError!?HostResult([]u8),
    codeHashFn: *const fn (ptr: *Host) HostError!?HostResult(Hash),
    sloadFn: *const fn (ptr: *Host, address: Address, index: BigInt) HostError!?HostResult(BigInt),
    sstoreFn: *const fn (ptr: *Host, address: Address, index: BigInt, value: BigInt) HostError!?SStoreResult,
    logFn: *const fn (ptr: *Host, address: Address, topics: []Hash, data: []u8) HostError!void,
    selfDestructFn: *const fn (ptr: *Host, address: Address, target: Address) HostError!?SelfDestructResult,
    createFn: *const fn (self: *Host, inputs: CreateInputs) HostError!?CreateResult,
    callFn: *const fn (self: *Host, inputs: CallInputs) HostError!?CallResult,
    pub fn env(self: *Host) !Env {
        return self.envFn(self);
    }
    pub fn loadAccount(self: *Host, address: Address) !?AccountLoadResult {
        return self.loadAccountFn(self, address);
    }
    pub fn blockHash(self: *Host, number: BigInt) !?Hash {
        return self.blockHashFn(self, number);
    }
    pub fn balance(self: *Host, address: Address) !?HostResult(BigInt) {
        return self.balanceFn(self, address);
    }
    pub fn code(self: *Host) !?HostResult([]u8) {
        return self.codeFn(self);
    }
    pub fn codeHash(self: *Host) !?HostResult(Hash) {
        return self.codeHashFn(self);
    }
    pub fn sload(self: *Host, address: Address, index: BigInt) !?HostResult(BigInt) {
        return self.sloadFn(self, address, index);
    }
    pub fn sstore(
        self: *Host,
        address: Address,
        index: BigInt,
        value: BigInt,
    ) !?SStoreResult {
        return self.sstoreFn(self, address, index, value);
    }
    pub fn log(
        self: *Host,
        address: Address,
        topics: []Hash,
        data: []u8,
    ) !void {
        return self.logFn(self, address, topics, data);
    }
    pub fn selfDestruct(
        self: *Host,
        address: Address,
        target: Address,
    ) !?SelfDestructResult {
        return self.selfDestructFn(self, address, target);
    }
    pub fn create(self: *Host, inputs: CreateInputs) !?CreateResult {
        return self.createFn(self, inputs);
    }
    pub fn call(self: *Host, inputs: CallInputs) !?CallResult {
        return self.callFn(self, inputs);
    }
};

// TODO: Build a real host via the Rust FFI boundary.

/// Defines a mock host for testing purposes.
pub const Mock = struct {
    host: Host,
    pub fn init() Mock {
        const impl = struct {
            pub fn env(ptr: *Host) HostError!Env {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.env();
            }
            pub fn loadAccount(ptr: *Host, address: Address) HostError!?AccountLoadResult {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.loadAccount(address);
            }
            pub fn blockHash(ptr: *Host, number: BigInt) HostError!?Hash {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.blockHash(number);
            }
            pub fn balance(ptr: *Host, address: Address) HostError!?HostResult(BigInt) {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.balance(address);
            }
            pub fn code(ptr: *Host) HostError!?HostResult([]u8) {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.code();
            }
            pub fn codeHash(ptr: *Host) HostError!?HostResult(Hash) {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.codeHash();
            }
            pub fn sload(ptr: *Host, address: Address, index: BigInt) HostError!?HostResult(BigInt) {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.sload(address, index);
            }
            pub fn sstore(ptr: *Host, address: Address, index: BigInt, value: BigInt) HostError!?SStoreResult {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.sstore(address, index, value);
            }
            pub fn log(ptr: *Host, address: Address, topics: []Hash, data: []u8) HostError!void {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.log(address, topics, data);
            }
            pub fn selfDestruct(ptr: *Host, address: Address, target: Address) HostError!?SelfDestructResult {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.selfDestruct(address, target);
            }
            pub fn create(ptr: *Host, inputs: CreateInputs) HostError!?CreateResult {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.create(inputs);
            }
            pub fn call(ptr: *Host, inputs: CallInputs) HostError!?CallResult {
                const self = @fieldParentPtr(Mock, "host", ptr);
                return self.call(inputs);
            }
        };
        return .{
            .host = .{
                .envFn = impl.env,
                .loadAccountFn = impl.loadAccount,
                .blockHashFn = impl.blockHash,
                .balanceFn = impl.balance,
                .codeFn = impl.code,
                .codeHashFn = impl.codeHash,
                .sloadFn = impl.sload,
                .sstoreFn = impl.sstore,
                .logFn = impl.log,
                .selfDestructFn = impl.selfDestruct,
                .createFn = impl.create,
                .callFn = impl.call,
            },
        };
    }
    pub fn env(self: *Mock) !Env {
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn loadAccount(self: *Mock, address: Address) !?AccountLoadResult {
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn blockHash(self: *Mock, number: BigInt) !?Hash {
        _ = number;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn balance(self: *Mock, address: Address) !?HostResult(BigInt) {
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn code(self: *Mock) !?HostResult([]u8) {
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn codeHash(self: *Mock) !?HostResult(Hash) {
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn sload(self: *Mock, address: Address, index: BigInt) !?HostResult(BigInt) {
        _ = index;
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn sstore(
        self: *Mock,
        address: Address,
        index: BigInt,
        value: BigInt,
    ) !?SStoreResult {
        _ = value;
        _ = index;
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn log(
        self: *Mock,
        address: Address,
        topics: []Hash,
        data: []u8,
    ) !void {
        _ = data;
        _ = topics;
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn selfDestruct(
        self: *Mock,
        address: Address,
        target: Address,
    ) !?SelfDestructResult {
        _ = target;
        _ = address;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn create(self: *Mock, inputs: CreateInputs) !?CreateResult {
        _ = inputs;
        _ = self;
        return HostError.Unimplemented;
    }
    pub fn call(self: *Mock, inputs: CallInputs) !?CallResult {
        _ = inputs;
        _ = self;
        return HostError.Unimplemented;
    }
};
