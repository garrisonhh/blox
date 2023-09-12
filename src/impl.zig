const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("common");
const utf8 = com.utf8;
const Codepoint = utf8.Codepoint;
const char = @import("char.zig");
const Char = char.Char;
const Color = char.Color;

const ref_bits = 32;
const BloxRef = com.Ref(.blox_block, ref_bits);
const BloxMap = com.RefMap(BloxRef, Region);

pub const Error = Allocator.Error || Codepoint.ParseError;

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

    pub fn getSize(self: *const Self, div: Div) UVec2 {
        return self.get(div).getDims();
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
        opts: TextOptions,
    ) Allocator.Error!Div {
        return try self.put(Region.newSpacer(width, height, opts));
    }

    /// create a preformatted div
    pub fn newPre(self: *Self, text: []const u8, opts: TextOptions) Error!Div {
        return try self.put(try Region.newPre(self.ally, text, opts));
    }

    /// create a container
    pub fn newBox(self: *Self, divs: []const Div, opts: BoxOptions) Error!Div {
        return try self.put(try Region.newBox(self, divs, opts));
    }

    // TODO should I make this a part of init() rather than write()?
    pub const WriteOptions = struct {
        enable_colors: bool = true,
        print_final_newline: bool = true,
    };

    /// write a div to a writer
    pub fn write(
        self: *const Self,
        div: Div,
        writer: anytype,
        comptime opts: WriteOptions,
    ) (Allocator.Error || @TypeOf(writer).Error)!void {
        const Writer = @TypeOf(writer);

        // configuration
        const printch = comptime switch (opts.enable_colors) {
            true => struct {
                fn f(ch: Char, w: Writer) Writer.Error!void {
                    // print the Char
                    try w.print("{}", .{ch});
                }
            }.f,
            false => struct {
                fn f(ch: Char, w: Writer) Writer.Error!void {
                    // print the Codepoint directly
                    try w.print("{}", .{ch.c});
                }
            }.f,
        };

        // bake and iterate over lines to print
        const baked = try self.get(div).bake(self);
        defer baked.deinit(self.ally);

        var lines = baked.lines();
        var first = true;
        while (lines.next()) |line| : (first = false) {
            if (!first) try printch(Char.newline, writer);
            for (line) |ch| try printch(ch, writer);
        }

        if (opts.print_final_newline) {
            try printch(Char.newline, writer);
        }
    }

    /// allows you to seamlessly mix blox and std.fmt code
    pub fn fmt(
        self: *const Self,
        div: Div,
        comptime opts: WriteOptions,
    ) FormattableDiv(opts) {
        return .{ .mason = self, .div = div };
    }

    fn FormattableDiv(comptime opts: WriteOptions) type {
        return struct {
            mason: *const Mason,
            div: Div,

            pub fn format(
                self: @This(),
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) @TypeOf(writer).Error!void {
                self.mason.write(self.div, writer, opts) catch |e| {
                    // check if this error can propagate
                    const name = @errorName(e);
                    const E = @TypeOf(writer).Error;
                    const errors: []const std.builtin.Type.Error =
                        @typeInfo(E).ErrorSet orelse &.{};

                    inline for (errors) |err| {
                        if (std.mem.eql(u8, err.name, name)) {
                            return @as(E, @errSetCast(e));
                        }
                    }

                    // the error can't propagate
                    std.debug.panic(
                        "error in FormattableDiv.format: {s}",
                        .{name}
                    );
                };
            }
        };
    }
};

/// a reference to a block of text
pub const Div = packed struct(std.meta.Int(.unsigned, ref_bits)) {
    const Self = @This();

    ref: BloxRef,

    pub const format = @compileError("write() a div to print it");
};

/// different types of divs
pub const Kind = enum {
    /// spacing
    spacer,
    /// preformatted text
    pre,
    /// a container of smaller boxes
    box,

    // TODO formattable text? with wrapping etc
};

pub const Direction = enum {
    left,
    right,
    up,
    down,
};

pub const Alignment = enum {
    inner,
    center,
    outer,
};

pub const BoxOptions = struct {
    direction: Direction = .down,
    alignment: Alignment = .inner,
};

pub const TextOptions = struct {
    fg: Color = Color.init(.normal, .default),
    bg: Color = Color.init(.normal, .default),
};

const UVec2 = @Vector(2, usize);
const IVec2 = @Vector(2, isize);

/// the underlying implementation of a div. intermediary between raw text and
/// baked FormattedText.
const Region = union(Kind) {
    const Self = @This();

    spacer: Spacer,
    pre: FormattedText,
    box: Box,

    pub fn deinit(self: *Self, ally: Allocator) void {
        switch (self.*) {
            .spacer => {},
            .pre => |ft| ft.deinit(ally),
            .box => |*box| box.deinit(ally),
        }
    }

    fn getDims(self: Self) UVec2 {
        return switch (self) {
            inline else => |x| x.dims,
        };
    }

    /// convert this div to an owned formatted text object
    /// (this also allows regions to be printed)
    fn bake(
        self: *const Self,
        mason: *const Mason,
    ) Allocator.Error!FormattedText {
        return switch (self.*) {
            .spacer => |s| try FormattedText.initSpacer(mason.ally, s),
            .pre => |ft| try ft.clone(mason.ally),
            .box => |box| try box.bake(mason),
        };
    }

    fn newSpacer(
        width: usize,
        height: usize,
        opts: TextOptions,
    ) Self {
        return Self{
            .spacer = Spacer{
                .opts = opts,
                .dims = .{ width, height },
            },
        };
    }

    fn newPre(
        ally: Allocator,
        text: []const u8,
        opts: TextOptions,
    ) Error!Self {
        return Self{
            .pre = try FormattedText.initPreformatted(ally, text, opts),
        };
    }

    fn newBox(
        mason: *const Mason,
        divs: []const Div,
        opts: BoxOptions,
    ) Allocator.Error!Self {
        return Self{ .box = try Box.init(mason, divs, opts) };
    }
};

/// used to structure divs
const Spacer = struct {
    opts: TextOptions,
    dims: UVec2,
};

/// a container of other divs
const Box = struct {
    const Self = @This();

    divs: std.ArrayListUnmanaged(Div),
    opts: BoxOptions,
    dims: UVec2,

    fn init(
        mason: *const Mason,
        initial_divs: []const Div,
        opts: BoxOptions,
    ) Allocator.Error!Self {
        var divs = std.ArrayListUnmanaged(Div){};
        try divs.appendSlice(mason.ally, initial_divs);

        return Self{
            .divs = divs,
            .opts = opts,
            .dims = calcDims(mason, opts.direction, divs.items),
        };
    }

    fn deinit(self: *Self, ally: Allocator) void {
        self.divs.deinit(ally);
    }

    fn calcDims(
        mason: *const Mason,
        dir: Direction,
        divs: []const Div,
    ) UVec2 {
        // figure out strategy
        const max_axis: u1 = switch (dir) {
            .up, .down => 0,
            .left, .right => 1,
        };
        const sum_axis: u1 = switch (max_axis) {
            0 => 1,
            1 => 0,
        };

        // compute total
        var final = UVec2{ 0, 0 };
        for (divs) |div| {
            const dims = mason.get(div).getDims();

            final[max_axis] = @max(final[max_axis], dims[max_axis]);
            final[sum_axis] += dims[sum_axis];
        }

        return final;
    }

    fn bake(self: Self, mason: *const Mason) Allocator.Error!FormattedText {
        const canvas = try FormattedText.initEmpty(mason.ally, self.dims);

        switch (self.opts.direction) {
            inline else => |dir| {
                const Sign = enum { negative, positive };

                // metadata about baking
                const grow_axis: u1 = comptime switch (dir) {
                    .up, .down => 1,
                    .left, .right => 0,
                };
                const grow_sign: Sign = comptime switch (dir) {
                    .up, .left => .negative,
                    .down, .right => .positive,
                };
                const align_axis: u1 = comptime switch (grow_axis) {
                    0 => 1,
                    1 => 0,
                };

                // write to canvas
                const i_span: isize = @intCast(self.dims[align_axis]);

                var grow_pos: isize = 0;
                for (self.divs.items) |div| {
                    const baked = try mason.get(div).bake(mason);
                    defer baked.deinit(mason.ally);

                    const align_pos: isize = switch (self.opts.alignment) {
                        .inner => 0,
                        .outer => outer: {
                            const i_div_span: isize =
                                @intCast(baked.dims[align_axis]);
                            break :outer i_span - i_div_span;
                        },
                        .center => center: {
                            const i_div_span: isize =
                                @intCast(baked.dims[align_axis]);
                            break :center @divTrunc(i_span - i_div_span, 2);
                        },
                    };

                    if (comptime grow_sign == .negative) {
                        grow_pos -= @intCast(baked.dims[grow_axis]);
                    }

                    var offset: IVec2 = undefined;
                    offset[grow_axis] = grow_pos;
                    offset[align_axis] = align_pos;
                    canvas.blit(baked, offset);

                    if (comptime grow_sign == .positive) {
                        grow_pos += @intCast(baked.dims[grow_axis]);
                    }
                }
            },
        }

        return canvas;
    }
};

/// essentially the target final form of text in blox. all the ways you
/// manipulate divs and regions result in producing a FormattedText object which
/// you can use for whatever purposes.
const FormattedText = struct {
    const Self = @This();

    mem: []Char,
    /// indices into mem where each line starts, excluding line 0 (which always
    /// starts at 0)
    starts: []const usize,
    dims: UVec2,

    fn deinit(self: Self, ally: Allocator) void {
        ally.free(self.mem);
        ally.free(self.starts);
    }

    fn clone(self: Self, ally: Allocator) Allocator.Error!Self {
        return Self{
            .mem = try ally.dupe(Char, self.mem),
            .starts = try ally.dupe(usize, self.starts),
            .dims = self.dims,
        };
    }

    fn initFill(ally: Allocator, dims: UVec2, ch: Char) Allocator.Error!Self {
        const mem = try ally.alloc(Char, dims[0] * dims[1]);
        @memset(mem, ch);

        const starts: []const usize = if (dims[1] == 0) &.{} else b: {
            const starts = try ally.alloc(usize, dims[1] - 1);
            for (starts, 1..dims[1]) |*slot, count| {
                slot.* = count * dims[0];
            }

            break :b starts;
        };

        return Self{
            .mem = mem,
            .starts = starts,
            .dims = dims,
        };
    }

    /// makes an empty rectangle
    fn initEmpty(ally: Allocator, dims: UVec2) Allocator.Error!Self {
        return initFill(ally, dims, Char.empty);
    }

    /// make a spacer
    fn initSpacer(ally: Allocator, spacer: Spacer) Allocator.Error!Self {
        return initFill(ally, spacer.dims, Char{
            .fg = spacer.opts.fg,
            .bg = spacer.opts.bg,
            .c = Char.empty.c,
        });
    }

    /// directly translates string into FormattedText
    fn initPreformatted(
        ally: Allocator,
        text: []const u8,
        opts: TextOptions,
    ) (Allocator.Error || Codepoint.ParseError)!Self {
        // collect lines
        var mem = std.ArrayListUnmanaged(Char){};
        defer mem.deinit(ally);
        var starts = std.ArrayListUnmanaged(usize){};
        defer starts.deinit(ally);

        var codepoint_iter = Codepoint.parse(text);
        while (try codepoint_iter.next()) |c| {
            if (c.eql(Codepoint.ct("\n"))) {
                try starts.append(ally, mem.items.len);
            } else {
                try mem.append(ally, Char{
                    .fg = opts.fg,
                    .bg = opts.bg,
                    .c = c,
                });
            }
        }

        // format into proper structure
        const frozen_mem = try mem.toOwnedSlice(ally);
        const frozen_starts = try starts.toOwnedSlice(ally);

        return Self{
            .mem = frozen_mem,
            .starts = frozen_starts,
            .dims = calcDims(frozen_mem, frozen_starts),
        };
    }

    /// helper for init functions
    fn calcDims(mem: []Char, starts: []const usize) UVec2 {
        var max_width: usize = 0;
        var line_iter = LineIterator.init(mem, starts);
        while (line_iter.next()) |line| {
            var line_width: usize = 0;
            for (line) |ch| {
                line_width += ch.c.printedWidth();
            }

            max_width = @max(max_width, line_width);
        }

        return UVec2{ max_width, starts.len + 1 };
    }

    const BlitCrop = struct {
        inner: UVec2,
        outer: UVec2,
    };

    fn calcBlitCrop(dst_dims: UVec2, src_dims: UVec2, offset: IVec2) BlitCrop {
        const i_dst_dims: IVec2 = @intCast(dst_dims);
        const i_src_dims: IVec2 = @intCast(src_dims);
        const bound = offset + i_src_dims;

        const raw_inner: UVec2 = @intCast(-@min(IVec2{ 0, 0 }, offset));
        const inner_crop = @min(raw_inner, src_dims);

        const raw_outer: UVec2 = @intCast(i_src_dims + (i_dst_dims - bound));
        const outer_crop = @min(raw_outer, src_dims);

        return BlitCrop{
            .inner = inner_crop,
            .outer = outer_crop,
        };
    }

    fn blit(dst: Self, src: Self, offset: IVec2) void {
        const crop = calcBlitCrop(dst.dims, src.dims, offset);
        const dst_offset: UVec2 = @intCast(
            offset + @as(IVec2, @intCast(crop.inner)),
        );

        for (crop.inner[1]..crop.outer[1]) |row| {
            // get src
            const src_line = src.getLine(row);
            const src_start = crop.inner[0];
            const src_stop = @min(src_line.len, crop.outer[0]);
            const src_slice = src_line[src_start..src_stop];

            // get dst
            const dst_line = dst.getLine(dst_offset[1] + row);
            const dst_start = dst_offset[0];
            const dst_crop = dst_offset[0] + (crop.outer[0] - crop.inner[0]);
            const dst_stop = @min(dst_line.len, dst_crop);
            const dst_slice = dst_line[dst_start..dst_stop];

            // write
            if (src_slice.len == dst_slice.len) {
                @memcpy(dst_slice, src_slice);
            } else if (src_slice.len < dst_slice.len) {
                @memcpy(dst_slice[0..src_slice.len], src_slice);
                @memset(dst_slice[src_slice.len..], Char.empty);
            } else {
                std.debug.assert(false);
            }
        }
    }

    fn getLineImpl(
        mem: []Char,
        starts: []const usize,
        index: usize,
    ) []Char {
        std.debug.assert(index <= starts.len);

        if (index == 0) {
            // first line
            if (starts.len == 0) {
                return mem;
            } else {
                return mem[0..starts[0]];
            }
        } else if (index == starts.len) {
            // last line
            return mem[starts[starts.len - 1]..];
        } else {
            // middle line
            const start_cp = starts[index - 1];
            const stop_cp = starts[index];
            return mem[start_cp..stop_cp];
        }
    }

    fn getLine(self: Self, index: usize) []Char {
        return getLineImpl(self.mem, self.starts, index);
    }

    /// iterate over the lines of text
    fn lines(self: Self) LineIterator {
        return LineIterator.init(self.mem, self.starts);
    }

    const LineIterator = struct {
        mem: []Char,
        starts: []const usize,
        index: usize = 0,

        fn init(mem: []Char, starts: []const usize) LineIterator {
            return LineIterator{
                .mem = mem,
                .starts = starts,
            };
        }

        fn next(self: *LineIterator) ?[]const Char {
            if (self.index > self.starts.len) {
                return null;
            }

            defer self.index += 1;
            return getLineImpl(self.mem, self.starts, self.index);
        }
    };
};

// tests =======================================================================

const BlitCropCase = struct {
    const Self = @This();
    const FT = FormattedText;

    src_dims: UVec2,
    dst_dims: UVec2,
    offset: IVec2,
    expects: FT.BlitCrop,

    fn init(src_dims: UVec2, dst_dims: UVec2, offset: IVec2, expects: FT.BlitCrop) Self {
        return Self{
            .src_dims = src_dims,
            .dst_dims = dst_dims,
            .offset = offset,
            .expects = expects,
        };
    }

    fn doTest(self: Self) !void {
        const stderr = std.io.getStdErr().writer();

        const crop = FT.calcBlitCrop(self.src_dims, self.dst_dims, self.offset);
        if (!std.meta.eql(crop, self.expects)) {
            try stderr.print(
                \\in blit crop case:
                \\  src_dims = {}
                \\  dst_dims = {}
                \\  offset   = {}
                \\expected:
                \\  {}
                \\actually calculated:
                \\  {}
                \\
            ,
                .{
                    self.src_dims,
                    self.dst_dims,
                    self.offset,
                    self.expects,
                    crop,
                },
            );

            return error.TestUnexpectedResult;
        }
    }
};

test "blit-cropping" {
    const bcc = BlitCropCase.init;
    const cases = [_]BlitCropCase{
        bcc(
            .{ 10, 10 },
            .{ 10, 10 },
            .{ 0, 0 },
            .{ .inner = .{ 0, 0 }, .outer = .{ 10, 10 } },
        ),
        bcc(
            .{ 10, 10 },
            .{ 10, 10 },
            .{ -1, -2 },
            .{ .inner = .{ 1, 2 }, .outer = .{ 10, 10 } },
        ),
        bcc(
            .{ 10, 10 },
            .{ 10, 10 },
            .{ 4, 5 },
            .{ .inner = .{ 0, 0 }, .outer = .{ 6, 5 } },
        ),
    };

    for (cases) |case| {
        try case.doTest();
    }
}

fn expectDiv(mason: *Mason, expected: []const u8, div: Div) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const writer = buf.writer();
    try mason.write(div, writer, .{
        .enable_colors = false,
        .print_final_newline = false,
    });

    try std.testing.expectEqualStrings(expected, buf.items);
}

test "preformatted" {
    var mason = Mason.init(std.testing.allocator);
    defer mason.deinit();

    // make div
    const text =
        \\hello
        \\  blox
        \\    !!!
        \\
    ;
    const div = try mason.newPre(text, .{});
    try expectDiv(&mason, text, div);

    // ensure attrs
    const region = mason.get(div);
    try std.testing.expect(region.* == .pre);
    try std.testing.expectEqual(@as(usize, 7), region.pre.dims[0]);
    try std.testing.expectEqual(@as(usize, 4), region.pre.dims[1]);
}

test "box" {
    var mason = Mason.init(std.testing.allocator);
    defer mason.deinit();

    // make div
    const text0 = "hello";
    const text1 = ", ";
    const text2 = "world!";
    const expected = "hello, world!";

    const div0 = try mason.newPre(text0, .{});
    const div1 = try mason.newPre(text1, .{});
    const div2 = try mason.newPre(text2, .{});
    const box = try mason.newBox(&.{ div0, div1, div2 }, .{
        .direction = .right,
    });

    try expectDiv(&mason, expected, box);

    // ensure attrs
    const region = mason.get(box);
    try std.testing.expect(region.* == .box);
    try std.testing.expectEqual(@as(usize, 13), region.box.dims[0]);
    try std.testing.expectEqual(@as(usize, 1), region.box.dims[1]);
}
