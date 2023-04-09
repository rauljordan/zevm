pub const Mock = struct {
    pub fn init() Mock {
        return .{};
    }
    pub fn address(self: Mock) ![20]u8 {
        _ = self;
        return [20]u8{
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
        };
    }
    pub fn balance(self: Mock) ![4]u8 {
        _ = self;
        return [4]u8{ 1, 2, 3, 4 };
    }
    pub fn gasLimit(self: Mock) !u64 {
        _ = self;
        return 1;
    }
};
