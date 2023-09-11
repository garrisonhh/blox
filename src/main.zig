comptime {
    @import("std").testing.refAllDecls(@This());
}

pub usingnamespace @import("impl.zig");
pub usingnamespace @import("char.zig");
