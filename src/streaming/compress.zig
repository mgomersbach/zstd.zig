const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const compress_mod = @import("../compress/compress.zig");
const header_mod = @import("../frame/header.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_mod = @import("../compress/block.zig");

pub const EndDirective = enum { cont, flush, end };

pub const StreamingCompressor = struct {
    allocator: std.mem.Allocator,
    options: compress_mod.CompressionOptions,
    buffer: std.ArrayList(u8),
    checksum_state: checksum_mod.ChecksumState,
    finished: bool,
    header_written: bool,
    level: i32,
    /// Raw-content dictionary, as in `compress.compressWithDict`: each block
    /// is seeded with it independently.
    dict: []const u8 = &[_]u8{},

    pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor {
        return StreamingCompressor{
            .allocator = allocator,
            .options = compress_mod.getCompressionParameters(level, 0, 0),
            .buffer = .empty,
            .checksum_state = checksum_mod.ChecksumState.init(),
            .finished = false,
            .header_written = false,
            .level = level,
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: compress_mod.CompressionOptions) StreamingCompressor {
        return StreamingCompressor{
            .allocator = allocator,
            .options = options,
            .buffer = .empty,
            .checksum_state = checksum_mod.ChecksumState.init(),
            .finished = false,
            .header_written = false,
            .level = options.level,
        };
    }

    pub fn initWithDict(allocator: std.mem.Allocator, level: i32, dict: []const u8) !StreamingCompressor {
        var self = try init(allocator, level);
        self.dict = dict;
        return self;
    }

    pub fn deinit(self: *StreamingCompressor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn setPledgedSrcSize(self: *StreamingCompressor, size: ?u64) void {
        self.options.content_size = size;
    }

    pub fn setChecksumFlag(self: *StreamingCompressor, flag: bool) void {
        self.options.checksum = flag;
    }

    /// Must be called before the first `compressStream` (i.e. before any
    /// data or the header has been written); there is no per-block
    /// dictionary swap mid-stream.
    pub fn setDict(self: *StreamingCompressor, dict: []const u8) void {
        self.dict = dict;
    }

    pub fn compressStream(self: *StreamingCompressor, out: []u8, in_data: []const u8, directive: EndDirective) errors.ZstdError!struct { in_consumed: usize, out_produced: usize, remaining: usize } {
        if (self.finished and directive != .end) return error.StageWrong;
        var out_pos: usize = 0;
        if (!self.header_written) {
            const window_size: u64 = if (self.options.window_log != 0) @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(self.options.window_log)) else @as(u64, 1) << 17;
            const single_segment = self.options.content_size != null and self.options.content_size.? < 256 * 1024 and window_size >= (self.options.content_size orelse 0);
            const header_size = header_mod.writeFrameHeader(out[out_pos..], self.options.content_size, window_size, self.options.dict_id, self.options.checksum, single_segment);
            out_pos += header_size;
            self.header_written = true;
        }
        if (in_data.len > 0) {
            try self.buffer.appendSlice(self.allocator, in_data);
            self.checksum_state.update(in_data);
        }
        const in_consumed = in_data.len;
        if (directive == .flush or directive == .end) {
            const to_compress = self.buffer.items;
            if (to_compress.len > 0) {
                var remaining = to_compress.len;
                var src_pos: usize = 0;
                while (remaining > 0) {
                    const chunk = @min(remaining, constants.block_size_max);
                    const is_last = directive == .end and src_pos + chunk >= to_compress.len;
                    const block_buf = out[out_pos..];
                    if (block_buf.len < chunk + 3) return error.DstSizeTooSmall;
                    const written = try block_mod.compressBlock(block_buf, to_compress[src_pos .. src_pos + chunk], self.dict, is_last);
                    out_pos += written;
                    src_pos += chunk;
                    remaining -= chunk;
                    if (out_pos + 128 > out.len and remaining > 0) break;
                }
                if (directive == .end) {
                    self.buffer.clearRetainingCapacity();
                } else {
                    if (src_pos > 0) {
                        const left = to_compress.len - src_pos;
                        if (left > 0) std.mem.copyForwards(u8, self.buffer.items[0..left], to_compress[src_pos..]);
                        self.buffer.shrinkRetainingCapacity(left);
                    }
                }
            } else if (directive == .end) {
                if (out.len < out_pos + 3) return error.DstSizeTooSmall;
                const written = try block_mod.compressBlock(out[out_pos..], &[_]u8{}, self.dict, true);
                out_pos += written;
            }
        }
        if (directive == .end) {
            if (self.options.checksum) {
                if (out.len < out_pos + 4) return error.DstSizeTooSmall;
                const chk = self.checksum_state.final();
                checksum_mod.writeChecksum(out[out_pos..], chk);
                out_pos += 4;
            }
            self.finished = true;
            return .{ .in_consumed = in_consumed, .out_produced = out_pos, .remaining = 0 };
        }
        return .{ .in_consumed = in_consumed, .out_produced = out_pos, .remaining = self.buffer.items.len };
    }

    pub fn reset(self: *StreamingCompressor) void {
        self.buffer.clearRetainingCapacity();
        self.checksum_state = checksum_mod.ChecksumState.init();
        self.finished = false;
        self.header_written = false;
    }
};

pub const CStream = StreamingCompressor;

const testing = std.testing;

test "StreamingCompressor init and deinit" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
}

test "StreamingCompressor initWithOptions" {
    const opts = compress_mod.CompressionOptions{ .level = 5 };
    var sc = StreamingCompressor.initWithOptions(testing.allocator, opts);
    defer sc.deinit();
}

test "StreamingCompressor cont then end" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r1 = try sc.compressStream(&buf, "hello ", .cont);
    try testing.expect(r1.in_consumed == 6 or r1.remaining > 0);
    const r2 = try sc.compressStream(&buf, "world", .end);
    try testing.expect(r2.out_produced > 0);
}

test "StreamingCompressor flush" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "data", .flush);
    try testing.expect(!sc.finished);
}

test "StreamingCompressor end writes empty block" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "", .end);
    try testing.expect(r.out_produced > 0);
    try testing.expect(sc.finished);
}

test "StreamingCompressor setChecksumFlag" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try testing.expect(r.out_produced > 0);
}

test "StreamingCompressor setPledgedSrcSize" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setPledgedSrcSize(100);
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "pledged", .end);
}

test "StreamingCompressor reset" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "first", .end);
    sc.reset();
    try testing.expect(!sc.finished);
    try testing.expect(!sc.header_written);
}

test "StreamingCompressor initWithDict shrinks output versus no dictionary" {
    const alloc = testing.allocator;
    const decompress_mod = @import("../decompress/decompress.zig");
    const dict = repeatString("The quick brown fox jumps over the lazy dog. ", 20);
    const src = repeatString("The quick brown fox jumps over the lazy dog. ", 4);

    var with_dict = try StreamingCompressor.initWithDict(alloc, 3, dict);
    defer with_dict.deinit();
    var buf1: [4096]u8 = undefined;
    const r1 = try with_dict.compressStream(&buf1, src, .end);

    var without_dict = try StreamingCompressor.init(alloc, 3);
    defer without_dict.deinit();
    var buf2: [4096]u8 = undefined;
    const r2 = try without_dict.compressStream(&buf2, src, .end);

    try testing.expect(r1.out_produced < r2.out_produced);

    const decoded = try decompress_mod.decompressAllocWithDict(alloc, buf1[0..r1.out_produced], dict);
    defer alloc.free(decoded);
    try testing.expectEqualStrings(src, decoded);
}

test "StreamingCompressor setDict matches initWithDict" {
    const alloc = testing.allocator;
    const dict = "shared streaming dictionary content";

    var a = try StreamingCompressor.initWithDict(alloc, 3, dict);
    defer a.deinit();
    var buf_a: [4096]u8 = undefined;
    const ra = try a.compressStream(&buf_a, "payload", .end);

    var b = try StreamingCompressor.init(alloc, 3);
    defer b.deinit();
    b.setDict(dict);
    var buf_b: [4096]u8 = undefined;
    const rb = try b.compressStream(&buf_b, "payload", .end);

    try testing.expectEqualSlices(u8, buf_a[0..ra.out_produced], buf_b[0..rb.out_produced]);
}

/// `s` repeated `n` times, as `"s" ** n` used to produce before Zig 0.17
/// removed array multiplication. Test-fixture data only.
fn repeatString(comptime s: []const u8, comptime n: usize) []const u8 {
    const buf: [s.len * n]u8 = comptime blk: {
        var b: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(b[i * s.len ..][0..s.len], s);
        break :blk b;
    };
    return &buf;
}
