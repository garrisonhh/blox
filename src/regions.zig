const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("common");
const utf8 = com.utf8;
const Codepoint = utf8.Codepoint;

/// different types of divs
pub const Kind = enum {
    /// spacing
    spacer,
    /// preformatted text
    pre,

    // TODO some kind of container
    // TODO formattable text? with wrapping etc
};

const Dimensions = struct {
    width: usize,
    height: usize,
};

/// the underlying implementation of a div. intermediary between raw text and
/// baked FormattedText.
pub const Region = union(Kind) {
    const Self = @This();

    pub const Error = Allocator.Error || Codepoint.ParseError;

    spacer: Dimensions,
    pre: FormattedText,

    pub fn deinit(self: Self, ally: Allocator) void {
        switch (self) {
            .spacer => {},
            .pre => |ft| ft.deinit(ally),
        }
    }

    /// convert this div to an owned formatted text object
    /// (this also allows regions to be printed)
    pub fn bake(
        self: *const Self,
        ally: Allocator,
    ) Error!FormattedText {
        return switch (self.*) {
            .spacer => |dims| try FormattedText.fromSpacer(ally, dims),
            .pre => |ft| try ft.clone(ally),
        };
    }

    pub fn newSpacer(width: usize, height: usize) Self {
        return Self{ .spacer = .{ .width = width, .height = height } };
    }

    pub fn newPre(ally: Allocator, text: []const u8) Error!Self {
        return Self{ .pre = try FormattedText.fromPreformatted(ally, text) };
    }
};

/// essentially the target final form of text in blox. all the ways you
/// manipulate divs and regions result in producing a FormattedText object which
/// you can use for whatever purposes.
pub const FormattedText = struct {
    const Self = @This();

    mem: []const Codepoint,
    /// indices into mem where each line starts, excluding line 0 (which always
    /// starts at 0)
    starts: []const usize,
    dims: Dimensions,

    pub fn deinit(self: Self, ally: Allocator) void {
        ally.free(self.mem);
        ally.free(self.starts);
    }

    pub fn clone(self: Self, ally: Allocator) Allocator.Error!Self {
        return Self{
            .mem = try ally.dupe(Codepoint, self.mem),
            .starts = try ally.dupe(usize, self.starts),
            .dims = self.dims,
        };
    }

    /// bake a spacer
    fn fromSpacer(ally: Allocator, dims: Dimensions) Allocator.Error!Self {
        const mem = try ally.alloc(Codepoint, 0);
        const starts = try ally.alloc(usize, dims.height - 1);
        @memset(starts, 0);

        return Self{
            .mem = mem,
            .starts = starts,
            .dims = dims,
        };
    }

    /// directly translates string into FormattedText
    fn fromPreformatted(
        ally: Allocator,
        text: []const u8,
    ) (Allocator.Error || Codepoint.ParseError)!Self {
        // collect lines
        var mem = std.ArrayListUnmanaged(Codepoint){};
        defer mem.deinit(ally);
        var starts = std.ArrayListUnmanaged(usize){};
        defer starts.deinit(ally);

        var codepoint_iter = Codepoint.parse(text);
        while (try codepoint_iter.next()) |c| {
            if (c.eql(Codepoint.ct("\n"))) {
                try starts.append(ally, mem.items.len);
            } else {
                try mem.append(ally, c);
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

    fn calcDims(mem: []const Codepoint, starts: []const usize) Dimensions {
        var max_width: usize = 0;
        var line_iter = LineIterator.init(mem, starts);
        while (line_iter.next()) |line| {
            var line_width: usize = 0;
            for (line) |c| {
                line_width += c.printedWidth();
            }

            max_width = @max(max_width, line_width);
        }

        return Dimensions{
            .width = max_width,
            .height = starts.len + 1,
        };
    }

    /// iterate over the lines of text
    fn lines(self: Self) LineIterator {
        return LineIterator.init(self.mem, self.starts);
    }

    const LineIterator = struct {
        mem: []const Codepoint,
        starts: []const usize,
        index: usize = 0,

        fn init(mem: []const Codepoint, starts: []const usize) LineIterator {
            return LineIterator{
                .mem = mem,
                .starts = starts,
            };
        }

        fn next(self: *LineIterator) ?[]const Codepoint {
            if (self.index > self.starts.len) {
                return null;
            }

            defer self.index += 1;
            if (self.index == 0) {
                // first line
                if (self.starts.len == 0) {
                    return self.mem;
                } else {
                    return self.mem[0..self.starts[0]];
                }
            } else if (self.index == self.starts.len) {
                // last line
                return self.mem[self.starts[self.starts.len - 1]..];
            } else {
                // middle line
                const start_cp = self.starts[self.index - 1];
                const stop_cp = self.starts[self.index];
                return self.mem[start_cp..stop_cp];
            }
        }
    };

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        var line_iter = self.lines();
        var first = true;
        while (line_iter.next()) |line| : (first = false) {
            if (!first) try writer.writeByte('\n');
            for (line) |c| try c.format("", .{}, writer);
        }
    }
};
