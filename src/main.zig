const std = @import("std");

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // 2 subcommand, that work almost same. First is list of all notes in json
    // format, second is find duplicate notes, and warn about them.

    // get subcommand name
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // since in both case, I need subcommand + path, I just check if args count is 2 (3)

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

    const command: []const u8 = args[1];
    const notes_path: []const u8 = args[2];

    std.debug.print("{s}\n{s}\n", .{ command, notes_path });

    return 0;
}
