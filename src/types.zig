pub const InterpreterStatus = enum {
    Break,
    Continue,
    OutOfGas,
    StackUnderflow,
    StackOverflow,
};
