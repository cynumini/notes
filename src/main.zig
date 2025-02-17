const std = @import("std");

const Entry = struct {
    name: []const u8,
    path: []const u8,

    fn sortByName(_: void, lhs: Entry, rhs: Entry) bool {
        return std.mem.order(u8, lhs.name, rhs.name) == .lt;
    }

    fn sortByPathLen(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.path.len > rhs.path.len;
    }
};

pub fn main() !void {
    // TODO: convert whole function to subcommand "notes"
    // TODO: remove useless copy of strings
    // TODO: use areana allocator

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var notes_path: []u8 = undefined;
    if (args.len < 2) {
        std.debug.print("You must pass the path to the notes directory as the first argument.\n", .{});
        return;
    } else {
        notes_path = args[1];
    }

    var notes_dir = try std.fs.openDirAbsolute(notes_path, .{ .iterate = true });
    defer notes_dir.close();

    var walker = try notes_dir.walk(allocator);
    defer walker.deinit();

    var notes = std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        while (notes.pop()) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        notes.deinit();
    }

    var paths = std.ArrayList(Entry).init(allocator);
    defer paths.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, ".md", std.fs.path.extension(entry.basename))) continue;
        try paths.append(.{
            .name = try allocator.dupe(u8, entry.basename),
            .path = try allocator.dupe(u8, entry.path),
        });
    }

    std.mem.sort(Entry, paths.items, {}, Entry.sortByPathLen);

    while (paths.pop()) |entry| {
        defer allocator.free(entry.name);
        defer allocator.free(entry.path);

        var title = std.ArrayList(u8).init(allocator);

        var file = try notes_dir.openFile(entry.path, .{ .mode = .read_only });
        defer file.close();

        var reader = file.reader();
        const first_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) orelse "";
        defer allocator.free(first_line);

        if (std.mem.eql(u8, "---", first_line)) {
            const title_section = "title: ";
            while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) |line| {
                defer allocator.free(line);
                if (std.mem.eql(u8, line, "---")) break;
                if (line.len > title_section.len and std.mem.eql(u8, line[0..title_section.len], title_section)) {
                    try title.appendSlice(line[title_section.len..]);
                    break;
                }
            }
        }
        if (title.items.len == 0) {
            try title.appendSlice(entry.name[0 .. entry.name.len - 3]);
        }
        const path = try std.fs.path.join(allocator, &.{ notes_path, entry.path });
        if (notes.contains(title.items)) {
            if (!std.mem.eql(u8, entry.path, notes.get(title.items).?)) {
                title.clearAndFree();
                try title.appendSlice(entry.path[0 .. entry.path.len - 3]);
            }
        }
        if (notes.contains(title.items)) {
            std.debug.print("error: {s} = {s}\n", .{ title.items, path });
            std.debug.print("error: {s} = {s}\n", .{ title.items, notes.get(title.items).? });
        }
        try notes.put(try title.toOwnedSlice(), path);
    }

    // TODO: Somehow sort notes by name, maybe by converting it to Entry

    var json = std.ArrayList(u8).init(allocator);
    defer json.deinit();
    var write_stream = std.json.writeStream(json.writer(), .{});

    try write_stream.beginArray();
    for (notes.keys(), notes.values()) |key, value| {
        try write_stream.beginObject();
        try write_stream.objectField(key);
        try write_stream.write(value);
        try write_stream.endObject();
    }
    try write_stream.endArray();

    _ = try std.io.getStdIn().writer().print("{s}\n", .{json.items});
}
