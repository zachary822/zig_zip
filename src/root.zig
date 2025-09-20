const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("zlib.h");
    @cInclude("bzlib.h");
    @cInclude("lzma.h");
});
const testing = std.testing;
const assert = std.debug.assert;

pub const std_options: std.Options = .{};

pub const ZipFileError = error{
    ZipFileFinished,
    UnsupportedCompressionMethod,
    DeflateCompressionFailed,
    Bzip2CompressionFailed,
    ZstdCompressionFailed,
    LZMACompressionFailed,
};

const CHUNK = 16384;

pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
    bzip2 = 12,
    lzma = 14,
    xz = 95,
    _,
};

const GeneralPurposeFlags = packed struct(u16) {
    encrypted: bool,
    _: u15,
};

pub const LocalFileHeader = extern struct {
    signature: [4]u8 align(1),
    version_needed_to_extract: u16 align(1),
    flags: GeneralPurposeFlags align(1),
    compression_method: CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
};

pub const CentralDirectoryFileHeader = extern struct {
    signature: [4]u8 align(1),
    version_made_by: u16 align(1),
    version_needed_to_extract: u16 align(1),
    flags: GeneralPurposeFlags align(1),
    compression_method: CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
    comment_len: u16 align(1),
    disk_number: u16 align(1),
    internal_file_attributes: u16 align(1),
    external_file_attributes: u32 align(1),
    local_file_header_offset: u32 align(1),
};

pub const ZipFile = struct {
    allocator: std.mem.Allocator,
    last_modification_time: u16,
    last_modification_date: u16,
    output_buff: std.array_list.Managed(u8),
    cd_buff: std.array_list.Managed(u8),
    file_count: usize = 0,
    finished: bool = false,

    const Self = @This();

    const Options = struct {
        compression_method: CompressionMethod = .deflate,
        mode: std.fs.File.Mode = 0o644 | std.c.S.IFREG,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        const now = c.time(null);
        var local: c.tm = undefined;
        _ = c.localtime_r(&now, &local);

        return .{
            .allocator = allocator,
            .last_modification_time = @intCast((local.tm_hour << 11) | (local.tm_min << 5) | @divFloor(local.tm_sec, 2)),
            .last_modification_date = @intCast((local.tm_year - 80 << 9) | (local.tm_mon + 1 << 5) | local.tm_mday),
            .output_buff = std.array_list.Managed(u8).init(allocator),
            .cd_buff = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.output_buff.deinit();
        self.cd_buff.deinit();
    }

    pub fn addFile(self: *Self, name: []const u8, content: []const u8, options: Options) !void {
        if (self.finished) {
            return ZipFileError.ZipFileFinished;
        }

        const local_file_header_offset: u32 = @intCast(self.output_buff.items.len);

        var local_header = LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = options.compression_method,
            .last_modification_time = self.last_modification_time,
            .last_modification_date = self.last_modification_date,
            .crc32 = std.hash.Crc32.hash(content),
            .compressed_size = 0,
            .uncompressed_size = @intCast(content.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
        };

        const writer = self.output_buff.writer();

        switch (options.compression_method) {
            .store => {
                local_header.compressed_size = @intCast(content.len);
                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(content);
            },
            .deflate => {
                var compress_buffer = std.array_list.Managed(u8).init(self.allocator);
                defer compress_buffer.deinit();

                var strm: c.z_stream = undefined;
                strm.zalloc = @ptrFromInt(c.Z_NULL);
                strm.zfree = @ptrFromInt(c.Z_NULL);
                strm.@"opaque" = @ptrFromInt(c.Z_NULL);

                var out: [CHUNK]u8 = undefined;
                var ret: c_int = 0;

                ret = c.deflateInit2(&strm, c.Z_DEFAULT_COMPRESSION, c.Z_DEFLATED, -c.MAX_WBITS, 8, c.Z_DEFAULT_STRATEGY);
                defer _ = c.deflateEnd(&strm);

                if (ret != c.Z_OK) {
                    std.log.err("zlib error code: {}", .{ret});
                    return ZipFileError.DeflateCompressionFailed;
                }

                strm.avail_in = @intCast(content.len);
                strm.next_in = @constCast(content.ptr);

                while (true) {
                    strm.avail_out = CHUNK;
                    strm.next_out = &out;
                    ret = c.deflate(&strm, c.Z_FINISH);
                    assert(ret != c.Z_STREAM_ERROR);
                    const have = CHUNK - strm.avail_out;

                    try compress_buffer.appendSlice(out[0..have]);

                    if (strm.avail_out == 0) {
                        continue;
                    }

                    break;
                }
                assert(ret == c.Z_STREAM_END);

                local_header.compressed_size = @intCast(compress_buffer.items.len);

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(compress_buffer.items);
            },
            .bzip2 => {
                var compress_buffer = std.array_list.Managed(u8).init(self.allocator);
                defer compress_buffer.deinit();

                var strm: c.bz_stream = undefined;
                strm.bzalloc = null;
                strm.bzfree = null;
                strm.@"opaque" = null;

                var out: [CHUNK]u8 = undefined;
                var ret: c_int = 0;
                ret = c.BZ2_bzCompressInit(&strm, 9, 0, 30);
                defer _ = c.BZ2_bzCompressEnd(&strm);

                if (ret != c.BZ_OK) {
                    return ZipFileError.Bzip2CompressionFailed;
                }

                strm.avail_in = @intCast(content.len);
                strm.next_in = @constCast(content.ptr);

                while (true) {
                    strm.avail_out = CHUNK;
                    strm.next_out = &out;
                    ret = c.BZ2_bzCompress(&strm, c.BZ_FINISH);
                    assert(ret != c.BZ_SEQUENCE_ERROR);

                    const have = CHUNK - strm.avail_out;

                    try compress_buffer.appendSlice(out[0..have]);

                    if (ret != c.BZ_STREAM_END) {
                        continue;
                    }

                    break;
                }

                local_header.compressed_size = @intCast(compress_buffer.items.len);

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(compress_buffer.items);
            },
            .lzma => {
                var compress_buffer = std.array_list.Managed(u8).init(self.allocator);
                defer compress_buffer.deinit();

                var options_lzma: c.lzma_options_lzma = undefined;
                if (c.lzma_lzma_preset(&options_lzma, c.LZMA_PRESET_DEFAULT) != 0) {
                    return ZipFileError.LZMACompressionFailed;
                }

                var strm: c.lzma_stream = .{};
                const filters = [_]c.lzma_filter{
                    .{ .id = c.LZMA_FILTER_LZMA1, .options = &options_lzma },
                    .{ .id = c.LZMA_VLI_UNKNOWN, .options = null },
                };

                var out: [CHUNK]u8 = undefined;
                var ret: c.lzma_ret = c.lzma_raw_encoder(&strm, &filters);
                defer _ = c.lzma_end(&strm);

                if (ret != c.LZMA_OK) {
                    return ZipFileError.LZMACompressionFailed;
                }

                strm.avail_in = content.len;
                strm.next_in = content.ptr;

                while (true) {
                    strm.next_out = &out;
                    strm.avail_out = CHUNK;

                    ret = c.lzma_code(&strm, c.LZMA_FINISH);

                    const have = CHUNK - strm.avail_out;

                    try compress_buffer.appendSlice(out[0..have]);

                    if (ret != c.LZMA_STREAM_END) {
                        continue;
                    }

                    break;
                }

                var propery_size: u32 = undefined;
                ret = c.lzma_properties_size(&propery_size, &filters);
                if (ret != c.LZMA_OK) {
                    return ZipFileError.LZMACompressionFailed;
                }
                const lzma_props = try self.allocator.alloc(u8, propery_size);
                defer self.allocator.free(lzma_props);
                ret = c.lzma_properties_encode(&filters, lzma_props.ptr);
                if (ret != c.LZMA_OK) {
                    return ZipFileError.LZMACompressionFailed;
                }

                local_header.compressed_size = @as(u32, @intCast(compress_buffer.items.len)) + 4 + propery_size;

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeByte(@intCast(c.LZMA_VERSION_MAJOR));
                try writer.writeByte(@intCast(c.LZMA_VERSION_MINOR));
                try writer.writeInt(u16, @intCast(propery_size), .little);
                try writer.writeAll(lzma_props);
                try writer.writeAll(compress_buffer.items);
            },
            .xz => {
                var compress_buffer = std.array_list.Managed(u8).init(self.allocator);
                defer compress_buffer.deinit();

                var strm: c.lzma_stream = .{};
                var out: [CHUNK]u8 = undefined;
                var ret: c.lzma_ret = c.lzma_easy_encoder(&strm, c.LZMA_PRESET_DEFAULT, c.LZMA_CHECK_CRC64);
                defer _ = c.lzma_end(&strm);
                if (ret != c.LZMA_OK) {
                    return ZipFileError.LZMACompressionFailed;
                }

                strm.avail_in = content.len;
                strm.next_in = content.ptr;

                while (true) {
                    strm.next_out = &out;
                    strm.avail_out = CHUNK;

                    ret = c.lzma_code(&strm, c.LZMA_FINISH);

                    const have = CHUNK - strm.avail_out;

                    try compress_buffer.appendSlice(out[0..have]);

                    if (ret != c.LZMA_STREAM_END) {
                        continue;
                    }

                    break;
                }

                local_header.compressed_size = @intCast(compress_buffer.items.len);

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(compress_buffer.items);
            },
            else => {
                return ZipFileError.UnsupportedCompressionMethod;
            },
        }

        const cd_header = CentralDirectoryFileHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 0x0314,
            .version_needed_to_extract = local_header.version_needed_to_extract,
            .flags = local_header.flags,
            .compression_method = local_header.compression_method,
            .last_modification_time = local_header.last_modification_time,
            .last_modification_date = local_header.last_modification_date,
            .crc32 = local_header.crc32,
            .compressed_size = local_header.compressed_size,
            .uncompressed_size = local_header.uncompressed_size,
            .filename_len = local_header.filename_len,
            .extra_len = local_header.extra_len,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = @as(u32, @intCast(options.mode)) << 16,
            .local_file_header_offset = local_file_header_offset,
        };

        const cd_writer = self.cd_buff.writer();

        try cd_writer.writeStructEndian(cd_header, .little);
        try cd_writer.writeAll(name);
        self.file_count += 1;
    }

    pub fn finish(self: *Self) !void {
        if (self.finished) {
            return;
        }

        const writer = self.output_buff.writer();

        const cdh_offset = self.output_buff.items.len;

        try writer.writeAll(self.cd_buff.items);

        const eocd = std.zip.EndRecord{
            .signature = std.zip.end_record_sig,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = @intCast(self.file_count),
            .record_count_total = @intCast(self.file_count),
            .central_directory_size = @intCast(self.cd_buff.items.len),
            .central_directory_offset = @intCast(cdh_offset),
            .comment_len = 0,
        };

        try writer.writeStructEndian(eocd, .little);
        self.finished = true;
    }
};

test "can init/deinit" {
    var f = ZipFile.init(std.testing.allocator);
    defer f.deinit();

    try f.addFile("test1.txt", "deflate content\n", .{ .compression_method = .deflate });
    try f.addFile("test2.txt", "store content\n", .{ .compression_method = .store });
    try f.addFile("test3.txt", "bzip2 content\n", .{ .compression_method = .bzip2 });
    try f.addFile("test4.txt", "lzma content\n", .{ .compression_method = .lzma });
    try f.addFile("test5.txt", "xz content\n", .{ .compression_method = .xz });
    try f.finish();

    var file = try std.fs.cwd().createFile("test.zip", .{});
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var buffered = file.writer(&buffer);
    const writer = &buffered.interface;
    try writer.writeAll(f.output_buff.items);
    try writer.flush();
}

test "cannot add file to finished zip archive" {
    var f = ZipFile.init(std.testing.allocator);
    defer f.deinit();

    try f.finish();

    try testing.expectError(ZipFileError.ZipFileFinished, f.addFile("bad.txt", "bad file", .{}));
}
