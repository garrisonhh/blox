const impl = @import("impl.zig");

comptime {
    @import("std").testing.refAllDecls(impl);
}

pub const Error = impl.Error;
pub const Div = impl.Div;
pub const Mason = impl.Mason;
