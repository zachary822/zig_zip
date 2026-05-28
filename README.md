# zig_zip

Basic library for creating zip archives

```zig
const std = @import("std");
const ZipFile = @import("zig_zip").ZipFile;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var f = ZipFile.init(gpa);
    defer f.deinit();

    try f.addFile("test1.txt", "test1 content", .{ .compression_method = .deflate });
    try f.addFile("test2.txt", "test2 content", .{ .compression_method = .store });
    try f.finish();

    var file = try std.Io.Dir.cwd().createFile(io, "test.zip", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, f.output_buff.items);
}
```
