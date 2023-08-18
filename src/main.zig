const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("common");
const regions = @import("regions.zig");
const Region = regions.Region;

const ref_bits = 32;
const BloxRef = com.Ref(.blox_block, ref_bits);
const BloxMap = com.RefMap(BloxRef, regions.Region);

pub const Error = Allocator.Error || com.utf8.Codepoint.ParseError;

/// a reference to a block of text
pub const Div = packed struct(std.meta.Int(.unsigned, ref_bits)) {
    const Self = @This();

    ref: BloxRef,

    pub const format = @compileError("to print a div, use fmt()");

    /// make div compatible with zig std.fmt
    pub fn fmt(self: Self, mason: *const Mason) Formattable {
        return Formattable{ .region = mason.get(self) };
    }

    pub const Formattable = struct {
        region: *const Region,

        pub fn format(
            self: @This(),
            comptime fmt_str: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            try self.region.format(fmt_str, options, writer);
        }
    };
};

/// masons are the memory context for blox.
pub const Mason = struct {
    const Self = @This();

    ally: Allocator,
    blox: BloxMap = .{},

    pub fn init(ally: Allocator) Self {
        return Self{ .ally = ally };
    }

    pub fn deinit(self: *Self) void {
        var region_iter = self.blox.iterator();
        while (region_iter.next()) |region| region.deinit(self.ally);

        self.blox.deinit(self.ally);
    }

    fn get(self: *const Self, div: Div) *Region {
        return self.blox.get(div.ref);
    }

    /// delete a div. unless you're really making a crapload of text objects or
    /// reusing the same mason repeatedly (why?), this is really an unnecessary
    /// thing to do
    pub fn del(self: *Self, div: Div) void {
        self.get(div).deinit(self.ally);
        self.blox.del(div.ref);
    }

    /// create a preformatted div
    pub fn newPre(self: *Self, text: []const u8) Error!Div {
        const region = try Region.newPre(self.ally, text);
        const ref = try self.blox.put(self.ally, region);
        return Div{ .ref = ref };
    }
};

// tests =======================================================================

test "basic-preformatted" {
    var mason = Mason.init(std.testing.allocator);
    defer mason.deinit();

    // make div
    const text =
        \\hello
        \\  blox
        \\    !!!
        \\
    ;
    const div = try mason.newPre(text);

    try std.testing.expectFmt(text, "{}", .{div.fmt(&mason)});

    // ensure attrs
    const region = mason.get(div);
    try std.testing.expect(region.* == .pre);
    try std.testing.expectEqual(@as(usize, 7), region.pre.dims.width);
    try std.testing.expectEqual(@as(usize, 4), region.pre.dims.height);
}