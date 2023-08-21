const std = @import("std");
const com = @import("common");
const Codepoint = com.utf8.Codepoint;

/// represents a terminal color code
pub const Color = packed struct(u4) {
    const Self = @This();

    pub const Brightness = enum(u1) {
        normal,
        bright,
    };

    pub const Basic = enum(u3) {
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
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
};

const char_bits = @bitSizeOf(Codepoint) + 2 * @bitSizeOf(Color);

comptime {
    std.debug.assert(char_bits <= 32);
}

pub const Char = packed struct(std.meta.Int(.unsigned, char_bits)) {
    const Self = @This();

    pub const default_fg = Color.init(.normal, .white);
    pub const default_bg = Color.init(.normal, .black);

    pub const empty = Self{
        .fg = default_fg,
        .bg = default_bg,
        .c = Codepoint.ct(" "),
    };
    pub const newline = Self{
        .fg = default_fg,
        .bg = default_bg,
        .c = Codepoint.ct("\n"),
    };

    fg: Color,
    bg: Color,
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