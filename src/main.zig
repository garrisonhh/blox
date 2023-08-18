const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("common");
const regions = @import("regions.zig");
const Region = regions.Region;

const ref_bits = 32;
const BloxRef = com.Ref(.blox_block, ref_bits);
const BloxMap = com.RefMap(BloxRef, regions.Region);

pub const Error = Region.Error;

/// a reference to a block of text
pub const Div = packed struct(std.meta.Int(.unsigned, ref_bits)) {
    const Self = @This();

    ref: BloxRef,

    pub const format = @compileError("bake() a div to print it");
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

    fn put(self: *Self, region: Region) Allocator.Error!Div {
        const ref = try self.blox.put(self.ally, region);
        return Div{ .ref = ref };
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

    /// create a spacer
    pub fn newSpacer(
        self: *Self,
        width: usize,
        height: usize,
    ) Allocator.Error!Div {
        return try self.put(try Region.newSpacer(width, height));
    }

    /// create a preformatted div
    pub fn newPre(self: *Self, text: []const u8) Error!Div {
        return try self.put(try Region.newPre(self.ally, text));
    }

    /// write a div to a writer
    pub fn write(
        self: *const Self,
        div: Div,
        writer: anytype,
    ) (Error || @TypeOf(writer).Error)!void {
        const baked = try self.get(div).bake(self.ally);
        defer baked.deinit(self.ally);

        try writer.print("{}", .{baked});
    }
};

// tests =======================================================================

fn expectDiv(mason: *Mason, expected: []const u8, div: Div) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try mason.write(div, buf.writer());
    try std.testing.expectEqualStrings(expected, buf.items);
}

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
    try expectDiv(&mason, text, div);

    // ensure attrs
    const region = mason.get(div);
    try std.testing.expect(region.* == .pre);
    try std.testing.expectEqual(@as(usize, 7), region.pre.dims.width);
    try std.testing.expectEqual(@as(usize, 4), region.pre.dims.height);
}
