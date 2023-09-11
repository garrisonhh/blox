const std = @import("std");
const com = @import("common");
const Codepoint = com.utf8.Codepoint;

/// represents a terminal color code
pub const Color = packed struct(u5) {
    const Self = @This();

    pub const Brightness = enum(u1) {
        normal,
        bright,
    };

    pub const Basic = enum(u4) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
        default = 9,
    };

    brightness: Brightness,
    color: Basic,

    pub fn init(brightness: Brightness, color: Basic) Self {
        return Self{
            .brightness = brightness,
            .color = color,
        };
    }

    pub const Layer = enum {
        foreground,
        background,
    };

    pub fn ansiCode(self: Self, layer: Layer) u7 {
        const layer_offset: u7 = switch (layer) {
            .foreground => 30,
            .background => 40,
        };
        const brightness_offset: u7 = switch (self.brightness) {
            .normal => 0,
            .bright => 60,
        };

        return @intFromEnum(self.color) + layer_offset + brightness_offset;
    }

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (self.brightness) {
            .normal => {},
            .bright => try writer.writeAll("bright "),
        }

        try writer.print("{s}", .{@tagName(self.color)});
    }
};

const char_bits = @bitSizeOf(Codepoint) + 2 * @bitSizeOf(Color);

comptime {
    std.debug.assert(char_bits <= 32);
}

pub const Char = packed struct(std.meta.Int(.unsigned, char_bits)) {
    const Self = @This();

    pub const empty = Self{ .c = Codepoint.ct(" ") };
    pub const newline = Self{ .c = Codepoint.ct("\n") };

    fg: Color = Color.init(.normal, .default),
    bg: Color = Color.init(.normal, .default),
    c: Codepoint,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        try writer.print(
            "\x1b[{};{}m{}",
            .{
                self.fg.ansiCode(.foreground),
                self.bg.ansiCode(.background),
                self.c,
            },
        );
    }
};
