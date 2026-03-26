const std = @import("std");
const fb2 = @import("fb2.zig");

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: fb2indexer <file.fb2> [file2.fb2 ...]\n", .{});
        std.process.exit(1);
    }

    for (args[1..]) |path| {
        const meta = fb2.parse(allocator, path) catch |err| {
            print("Error parsing {s}: {}\n", .{ path, err });
            continue;
        };
        defer meta.deinit(allocator);

        print("File: {s}\n", .{path});
        print("  Title:  {s}\n", .{meta.title orelse "(none)"});
        if (meta.author_first) |v| print("  First:  {s}\n", .{v});
        if (meta.author_middle) |v| print("  Middle: {s}\n", .{v});
        if (meta.author_last) |v| print("  Last:   {s}\n", .{v});
        if (meta.series_name) |v| {
            print("  Series: {s}", .{v});
            if (meta.series_number) |n| print(" #{s}", .{n});
            print("\n", .{});
        }
        if (meta.annotation) |v| print("  Annot:  {s}\n", .{v});
        if (meta.cover_id) |v| print("  Cover:  binary id=\"{s}\" ({d} bytes)\n", .{ v, meta.cover_data.len });
        print("\n", .{});
    }
}
