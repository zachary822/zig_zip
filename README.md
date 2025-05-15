# zig_zip

Basic library for creating zip archives

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var f = ZipFile.init(std.testing.allocator);
    defer f.deinit();

    try f.addFile("test1.txt", "test1 content", .{ .compression_method = .deflate });
    try f.addFile("test2.txt", "test2 content", .{ .compression_method = .store });
    try f.finish();

    var file = try std.fs.cwd().createFile("test.zip", .{});
    defer file.close();

    var buffered = std.io.bufferedWriter(file.writer());
    var writer = buffered.writer();
    try writer.writeAll(f.output_buff.items);
    try buffered.flush();
}
```
