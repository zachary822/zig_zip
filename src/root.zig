const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const testing = std.testing;

pub const ZipFile = struct {
    allocator: std.mem.Allocator,
    last_modification_time: u16,
    last_modification_date: u16,
    output_buff: std.ArrayList(u8),
    cd_list: std.ArrayList(std.zip.CentralDirectoryFileHeader),
    filenames: std.ArrayList([]const u8),

    const Self = @This();

    const Options = struct {
        compression_method: std.zip.CompressionMethod = .deflate,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        const now = c.time(null);
        const local = c.localtime(&now);

        return .{
            .allocator = allocator,
            .last_modification_time = @intCast((local.*.tm_hour << 11) | (local.*.tm_min << 5) | @divFloor(local.*.tm_sec, 2)),
            .last_modification_date = @intCast((local.*.tm_year - 80 << 9) | (local.*.tm_mon << 5) | local.*.tm_mday),
            .output_buff = std.ArrayList(u8).init(allocator),
            .cd_list = std.ArrayList(std.zip.CentralDirectoryFileHeader).init(allocator),
            .filenames = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.output_buff.deinit();
        self.cd_list.deinit();

        for (self.filenames.items) |name| {
            self.allocator.free(name);
        }
        self.filenames.deinit();
    }

    pub fn addFile(self: *Self, name: []const u8, content: []const u8, options: Options) !void {
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

        try self.filenames.append(try self.allocator.dupe(u8, name));

        const writer = self.output_buff.writer();

        switch (options.compression_method) {
            .store => {
                local_header.compressed_size = @intCast(content.len);
                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(content);
            },
            .deflate => {
                var compress_buffer = std.ArrayList(u8).init(self.allocator);
                defer compress_buffer.deinit();

                var content_stream = std.io.fixedBufferStream(content);
                try std.compress.flate.compress(content_stream.reader(), compress_buffer.writer(), .{});

                local_header.compressed_size = @intCast(compress_buffer.items.len);

                try writer.writeStructEndian(local_header, .little);
                try writer.writeAll(name);
                try writer.writeAll(compress_buffer.items);
            },
            else => {
                return error.UnsupportedCompressionMethod;
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
            .external_file_attributes = 0,
            .local_file_header_offset = local_file_header_offset,
        };

        try self.cd_list.append(cd_header);
    }

    pub fn finish(self: *Self) !void {
        const writer = self.output_buff.writer();

        const cdh_offset = self.output_buff.items.len;

        for (self.cd_list.items, self.filenames.items) |cd, name| {
            try writer.writeStructEndian(cd, .little);
            try writer.writeAll(name);
        }

        const cdh_size = self.output_buff.items.len - cdh_offset;

        const eocd = std.zip.EndRecord{
            .signature = std.zip.end_record_sig,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = @intCast(self.filenames.items.len),
            .record_count_total = @intCast(self.filenames.items.len),
            .central_directory_size = @intCast(cdh_size),
            .central_directory_offset = @intCast(cdh_offset),
            .comment_len = 0,
        };

        try writer.writeStructEndian(eocd, .little);
    }
};

test "can init/deinit" {
    var f = ZipFile.init(std.testing.allocator);
    defer f.deinit();

    try f.addFile("yay.txt", "hmm", .{ .compression_method = .deflate });
    try f.finish();

    var file = try std.fs.cwd().createFile("test.zip", .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    var writer = buffered.writer();
    try writer.writeAll(f.output_buff.items);
    try buffered.flush();
}
