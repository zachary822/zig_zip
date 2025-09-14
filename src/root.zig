const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("zlib.h");
});
const testing = std.testing;

pub const std_options: std.Options = .{};

pub const ZipFileError = error{
    ZipFileFinished,
    UnsupportedCompressionMethod,
    DeflateCompressionFailed,
};

const CHUNK = 16384;

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
        compression_method: std.zip.CompressionMethod = .deflate,
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

        var local_header = std.zip.LocalFileHeader{
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
                    std.debug.assert(ret != c.Z_STREAM_ERROR);
                    const have = CHUNK - strm.avail_out;
                    std.debug.print("have {} {x}\n", .{ have, out[0..have] });

                    try compress_buffer.appendSlice(out[0..have]);

                    if (strm.avail_out == 0) {
                        continue;
                    }

                    break;
                }
                std.debug.assert(ret == c.Z_STREAM_END);

                local_header.compressed_size = @intCast(compress_buffer.items.len);

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(compress_buffer.items);
            },
            else => {
                return ZipFileError.UnsupportedCompressionMethod;
            },
        }

        const cd_header = std.zip.CentralDirectoryFileHeader{
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

    try f.addFile("test1.txt", "test1 content\n", .{ .compression_method = .deflate });
    try f.addFile("test2.txt", "test2 content\n", .{ .compression_method = .store });
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
