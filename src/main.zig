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

const Command = enum { json, duplicate, rename };
const help = [_][]const u8{
    "Print a list of notes along with their paths in JSON format",
    "Show a list of notes with identical names",
    "Rename a note",
};
const subcommand_help = [_][]const u8{
    "usage: notes json <path to notes>",
    "usage: notes duplicate <path to notes>",
    "usage: notes rename <path to notes> <current name> <new name>",
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const std_err = std.io.getStdErr().writer();
    const std_out = std.io.getStdOut().writer();

    // I need the names of the Command fields to find out what command the user
    // entered
    const commands = comptime blk: {
        const commands_fields = @typeInfo(Command).@"enum".fields;
        var result: [commands_fields.len][:0]const u8 = undefined;
        for (commands_fields, 0..) |field, i| {
            result[i] = field.name;
        }
        break :blk result;
    };

    // Check if the user input is correct
    var possible_command: ?Command = undefined;
    const show_help, const show_subcommand_help = blk: {
        if (args.len < 2) break :blk .{ true, false };

        for (commands, 0..) |valid_command, i| {
            if (std.mem.eql(u8, args[1], valid_command)) {
                possible_command = @enumFromInt(i);
                break;
            }
        } else {
            break :blk .{ true, false };
        }

        if (args.len < 3) break :blk .{ true, true };

        if (possible_command.? == .rename and args.len < 5) break :blk .{ true, true };

        const notes_path = args[2];

        if (!std.fs.path.isAbsolute(notes_path)) {
            _ = try std_err.print("Path \"{s}\" not exists.\n", .{notes_path});
            break :blk .{ true, true };
        }

        var path = std.fs.openDirAbsolute(notes_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                _ = try std_err.print("Path \"{s}\" not exists.\n", .{notes_path});
                break :blk .{ true, true };
            },
            error.NotDir => {
                _ = try std_err.print("Path \"{s}\" is not a dir.\n", .{notes_path});
                break :blk .{ true, true };
            },
            else => {
                _ = try std_err.print("Can't access \"{s}\".\n", .{notes_path});
                break :blk .{ true, true };
            },
        };
        path.close();

        break :blk .{ false, false };
    };

    // Show help if user input is incorrect
    if (show_help and !show_subcommand_help) {
        _ = try std_out.write("usage: notes <command>\n\n");
        const offset = comptime blk: {
            var result: usize = 0;
            for (commands) |command| {
                result = @max(result, command.len);
            }
            break :blk result;
        };
        inline for (commands, 0..) |command, i| {
            const spaces = comptime offset - command.len + 4;
            _ = try std_out.print("{s}{s}{s}\n", .{ command, " " ** spaces, help[i] });
        }
        return 0;
    } else if (show_help and show_subcommand_help) {
        _ = try std_out.print("{s}\n", .{subcommand_help[@intFromEnum(possible_command.?)]});
        return 0;
    }

    const command: Command = possible_command.?;
    const notes_path: []const u8 = args[2];

    var notes_dir = try std.fs.openDirAbsolute(notes_path, .{ .iterate = true });
    defer notes_dir.close();

    var walker = try notes_dir.walk(allocator);
    defer walker.deinit();

    switch (command) {
        .duplicate, .json => {
            var notes = std.StringArrayHashMap(?[]const u8).init(allocator);
            defer notes.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind != .file or !std.mem.eql(
                    u8,
                    ".md",
                    std.fs.path.extension(entry.basename),
                )) continue;

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
        },
        .rename => {
            const old_name = args[3];
            const new_name = args[4];

            while (try walker.next()) |entry| {
                if (entry.kind != .file or !std.mem.eql(
                    u8,
                    ".md",
                    std.fs.path.extension(entry.basename),
                )) continue;

                var file = try notes_dir.openFile(entry.path, .{ .mode = .read_only });
                defer file.close();

                const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
                var offset: usize = 0;

                const TitleState = enum {
                    no_yaml,
                    yaml,
                    yaml_and_title,
                };

                var title_state = TitleState.no_yaml;
                const title_key = "title: ";

                const title: []const u8 = blk: {
                    var end = std.mem.indexOf(u8, text, "\n") orelse 0;
                    offset += end + 1;
                    const first_line = text[0..end];

                    if (std.mem.eql(u8, "---", first_line)) {
                        title_state = .yaml;
                        while (offset < text.len) {
                            end = std.mem.indexOf(u8, text[offset..], "\n") orelse 0;
                            const line = text[offset .. offset + end];
                            offset += end + 1;
                            if (std.mem.eql(u8, line, "---")) break;
                            if (line.len > title_key.len and std.mem.eql(u8, line[0..title_key.len], title_key)) {
                                title_state = .yaml_and_title;
                                break :blk line[title_key.len..];
                            }
                        }
                    }
                    break :blk entry.basename[0 .. entry.basename.len - 3];
                };

                if (std.mem.eql(u8, title, old_name)) {
                    const new_text = blk: {
                        switch (title_state) {
                            .no_yaml => {
                                break :blk try std.fmt.allocPrint(allocator, "---\ntitle: {s}\n---\n{s}", .{ new_name, text });
                            },
                            .yaml => {
                                break :blk try std.fmt.allocPrint(allocator, "---\ntitle: {s}\n{s}", .{ new_name, text[4..] });
                            },
                            .yaml_and_title => {
                                const title_start = std.mem.indexOf(u8, text, "title: ").?;
                                break :blk try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                                    text[0 .. title_start + title_key.len],
                                    new_name,
                                    text[title_start + title_key.len + old_name.len ..],
                                });
                            },
                        }
                    };
                    file.close();
                    file = try notes_dir.createFile(entry.path, .{ .truncate = true });
                    _ = try file.writeAll(new_text);
                }

                var buffer: [256]u8 = undefined;
                var len: usize = 0;
                offset = 0;
                var state = State.nothing;

                var need_update = false;

                var new_text = std.ArrayList(u8).init(allocator);
                defer new_text.deinit();

                for (text, 0..) |char, i| {
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
                                if (std.mem.eql(u8, buffer[0..len], old_name)) {
                                    try new_text.appendSlice(text[offset .. i - len]);
                                    try new_text.appendSlice(new_name);
                                    offset = i;
                                    need_update = true;
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

                if (need_update) {
                    try new_text.appendSlice(text[offset..]);
                    file.close();
                    file = try notes_dir.createFile(entry.path, .{ .truncate = true });
                    _ = try file.writeAll(new_text.items);
                    _ = try std_out.print("Change links in the file - \"{s}\"\n", .{entry.path});
                }
            }
        },
    }

    return 0;
}
