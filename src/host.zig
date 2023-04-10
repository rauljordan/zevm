const std = @import("std");

// TODO: Build the host structs here!
const Host = struct {
    getFn: *const fn (ptr: *Host) void,
    numInputsFn: *const fn (ptr: *Host) void,
    pub fn get(self: *Host) void {
        self.getFn(self);
    }
    pub fn numInputs(self: *Host) void {
        self.numInputsFn(self);
    }
};

// TODO: Build a real host via the Rust FFI boundary.
const Mock = struct {
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
    pub fn get(self: *Host) void {
        _ = self;
        std.debug.print("get", .{});
    }
    pub fn numInputs(self: *Host) void {
        _ = self;
        std.debug.print("numInputs", .{});
    }
};
