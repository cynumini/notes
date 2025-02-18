const std = @import("std");

const Entry = struct {
    name: []const u8,
    path: []const u8,

    fn sortByPath(_: void, lhs: Entry, rhs: Entry) bool {
        return std.mem.order(u8, lhs.path, rhs.path) == .gt;
    }
};

pub fn main() !void {
    // TODO: use areana allocator

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    // Get note path
    const notes_path: []u8 = blk: {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len < 2) {
            std.debug.print("You must pass the path to the notes directory as the first argument.\n", .{});
            return;
        }
        break :blk try allocator.dupe(u8, args[1]);
    };
    defer allocator.free(notes_path);

    // Get entries
    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();
    {
        var notes_dir = try std.fs.openDirAbsolute(notes_path, .{ .iterate = true });
        defer notes_dir.close();

        var walker = try notes_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file or !std.mem.eql(u8, ".md", std.fs.path.extension(entry.basename))) continue;
            try entries.append(.{
                .name = try allocator.dupe(u8, entry.basename),
                .path = try allocator.dupe(u8, entry.path),
            });
        }
        std.mem.sort(Entry, entries.items, {}, Entry.sortByPath);
    }

    // Get notes
    var notes = std.StringArrayHashMap(?[]const u8).init(allocator);
    defer {
        while (notes.pop()) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value orelse continue);
        }
        notes.deinit();
    }
    while (entries.pop()) |entry| {
        defer allocator.free(entry.name);
        defer allocator.free(entry.path);

        var key = std.ArrayList(u8).init(allocator);
        const value = try std.fs.path.join(allocator, &.{ notes_path, entry.path });

        var file = try std.fs.openFileAbsolute(value, .{ .mode = .read_only });
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
                    try key.appendSlice(line[title_section.len..]);
                    break;
                }
            }
        }
        if (key.items.len == 0) {
            try key.appendSlice(entry.name[0 .. entry.name.len - 3]);
        }

        // Read links from file content
        var links = std.ArrayList(std.ArrayList(u8)).init(allocator);
        defer links.deinit();
        {
            const State = enum {
                nothing,
                possible_link,
                link_start,
                adding,
                ignoring,
            };
            var state = State.nothing;
            while (true) {
                const char = reader.readByte() catch break;
                switch (char) {
                    '[' => {
                        state = switch (state) {
                            .nothing => .possible_link,
                            .possible_link, .link_start => .link_start,
                            else => blk: {
                                links.items[links.items.len - 1].deinit();
                                _ = links.pop();
                                break :blk .nothing;
                            },
                        };
                    },
                    ']' => state = .nothing,
                    '|' => {
                        state = switch (state) {
                            .adding => .ignoring,
                            .ignoring => blk: {
                                links.items[links.items.len - 1].deinit();
                                _ = links.pop();
                                break :blk .nothing;
                            },
                            else => .nothing,
                        };
                    },
                    else => {
                        state = switch (state) {
                            .link_start, .adding => blk: {
                                if (state == .link_start) {
                                    try links.append(std.ArrayList(u8).init(allocator));
                                }
                                try links.items[links.items.len - 1].append(char);
                                break :blk .adding;
                            },
                            .ignoring => .ignoring,
                            else => .nothing,
                        };
                    },
                }
            }
        }

        // Adding links and entries to notes
        for (links.items) |_| {
            var link = links.pop() orelse break;
            if (!notes.contains(link.items)) {
                try notes.put(try link.toOwnedSlice(), null);
            } else {
                link.deinit();
            }
        }

        if (notes.contains(key.items)) {
            if (notes.get(key.items).? == null) {
                const kv = notes.fetchSwapRemove(key.items).?;
                allocator.free(kv.key);
            } else if (!std.mem.eql(u8, entry.path, notes.get(key.items).?.?)) {
                key.clearAndFree();
                try key.appendSlice(entry.path[0 .. entry.path.len - 3]);
                // if changed note exist as a link
                if (notes.contains(key.items) and notes.get(key.items).? == null) {
                    const kv = notes.fetchSwapRemove(key.items).?;
                    allocator.free(kv.key);
                }
            }
        }

        if (notes.contains(key.items)) {
            std.debug.print("error: new key - value = {s} - {s}\n", .{ key.items, value });
            std.debug.print("error: old key - value = {s} - {s}\n", .{ key.items, notes.get(key.items).? orelse "null" });
            unreachable;
        }

        try notes.put(try key.toOwnedSlice(), value);
    }

    // convert notes to json
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

    // print json
    _ = try std.io.getStdIn().writer().print("{s}\n", .{json.items});
}
