const std = @import("std");

// | '['         | ']'      | '|'      | else     | chars
// |-------------|----------|----------|----------|
// | .maybe_link | .nothing | .nothing | .nothing | maybe_link
// | .link_start | .nothing | .nothing | .nothing | possible_link
// | .link_start | .nothing | .nothing | .add     | link_start
// | .nothing    | .nothing | .ignore  | .add     | add
// | .nothing    | .nothing | .nothing | .ignore  | ignore
const State = enum {
    nothing,
    maybe_link,
    link_start,
    add,
    ignore,
};

const Command = enum { json, duplicate };

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const std_err = std.io.getStdErr().writer();
    const std_out = std.io.getStdOut().writer();

    const show_help = blk: {
        if (args.len != 3) break :blk true;

        const command = args[1];
        const notes_path = args[2];

        for ([2][]const u8{ "json", "duplicate" }) |valid_command| {
            if (std.mem.eql(u8, command, valid_command)) break;
        } else {
            break :blk true;
        }

        var path = std.fs.openDirAbsolute(notes_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                _ = try std_err.print("Path {s} not exists.\n", .{notes_path});
                break :blk true;
            },
            error.NotDir => {
                _ = try std_err.print("Path {s} is not a dir.\n", .{notes_path});
                break :blk true;
            },
            else => {
                _ = try std_err.print("Can't access {s}.\n", .{notes_path});
                break :blk true;
            },
        };
        path.close();

        break :blk false;
    };

    if (show_help) {
        _ = try std_out.write(
            \\usage: notes <command> <path to notes>
            \\
            \\json         Print a list of notes along with their paths in JSON format
            \\duplicate    Show a list of notes with identical names
        );
        _ = try std_out.write("\n");
        return 0;
    }

    const command: Command = if (std.mem.eql(u8, "json", args[1])) .json else .duplicate;
    const notes_path: []const u8 = args[2];

    var notes_dir = try std.fs.openDirAbsolute(notes_path, .{ .iterate = true });
    defer notes_dir.close();

    var walker = try notes_dir.walk(allocator);
    defer walker.deinit();

    var notes = std.StringArrayHashMap(?[]const u8).init(allocator);
    defer notes.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, ".md", std.fs.path.extension(entry.basename))) continue;

        var file = try notes_dir.openFile(entry.path, .{ .mode = .read_only });
        defer file.close();

        const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        var offset: usize = 0;

        const title: []const u8 = blk: {
            var end = std.mem.indexOf(u8, text, "\n") orelse 0;
            offset += end + 1;
            const first_line = text[0..end];
            const title_key = "title: ";

            if (std.mem.eql(u8, "---", first_line)) {
                while (offset < text.len) {
                    end = std.mem.indexOf(u8, text[offset..], "\n") orelse 0;
                    const line = text[offset .. offset + end];
                    offset += end + 1;
                    if (std.mem.eql(u8, line, "---")) break;
                    if (line.len > title_key.len and std.mem.eql(u8, line[0..title_key.len], title_key)) {
                        break :blk line[title_key.len..];
                    }
                }
            }
            if (notes.getKey(entry.basename[0 .. entry.basename.len - 3])) |key| {
                break :blk key;
            } else {
                break :blk try allocator.dupe(u8, entry.basename[0 .. entry.basename.len - 3]);
            }
        };

        try file.seekTo(0);

        var buffer: [256]u8 = undefined;
        var len: usize = 0;
        var state = State.nothing;

        for (text) |char| {
            state = switch (char) {
                '[' => switch (state) {
                    .nothing => .maybe_link,
                    .maybe_link, .link_start => .link_start,
                    else => blk: {
                        len = 0;
                        break :blk .nothing;
                    },
                },
                ']' => blk: {
                    if (state == .add) {
                        if (!notes.contains(buffer[0..len])) {
                            try notes.put(try allocator.dupe(u8, buffer[0..len]), null);
                        }
                    }
                    len = 0;
                    break :blk .nothing;
                },
                '|' => switch (state) {
                    .add => .ignore,
                    else => .nothing,
                },
                else => switch (state) {
                    .link_start, .add => blk: {
                        buffer[len] = char;
                        len += 1;
                        break :blk .add;
                    },
                    .ignore => .ignore,
                    else => .nothing,
                },
            };
        }

        if (notes.getEntry(title)) |*note| {
            const replace_path = blk: {
                if (note.value_ptr.*) |value| {
                    if (command == .duplicate) {
                        _ = try std_out.print("Duplicate: {s} - {s}\n", .{ entry.path, note.value_ptr.*.? });
                    }
                    if (value.len < entry.path.len) break :blk false;
                }
                break :blk true;
            };
            if (replace_path) {
                try notes.put(title, try allocator.dupe(u8, entry.path));
            }
        } else {
            try notes.put(title, try allocator.dupe(u8, entry.path));
        }
    }

    if (command == .json) {
        var json = std.ArrayList(u8).init(allocator);
        defer json.deinit();

        var write_stream = std.json.writeStream(json.writer(), .{});

        try write_stream.beginObject();
        for (notes.keys(), notes.values()) |key, value| {
            try write_stream.objectField(key);
            try write_stream.write(value);
        }
        try write_stream.endObject();

        _ = try std_out.print("{s}\n", .{json.items});
    }
    return 0;
}
