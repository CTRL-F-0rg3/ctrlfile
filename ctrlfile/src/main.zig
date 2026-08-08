const std = @import("std");
const toml = @import("toml.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const executor = @import("executor.zig");
const logger_mod = @import("logger.zig");

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    _ = try file_reader.interface.streamRemaining(&alloc_writer.writer);
    return alloc_writer.written();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("uzycie: ctrlfile <nazwa-run>\n", .{});
        std.process.exit(1);
    }
    const target_name = args[1];

    const toml_src = readFile(allocator, io, "ctrlfile.toml") catch |err| {
        std.debug.print("nie mozna odczytac ctrlfile.toml: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const dsl_src = readFile(allocator, io, "ctrlfilemaker") catch |err| {
        std.debug.print("nie mozna odczytac ctrlfilemaker: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var config = toml.parse(allocator, toml_src) catch |err| {
        std.debug.print("blad parsowania ctrlfile.toml: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var lexer = lex.Lexer.init(allocator, dsl_src);
    const tokens = lexer.tokenize() catch |err| {
        std.debug.print("blad tokenizacji ctrlfilemaker: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var parser = parser_mod.Parser.init(allocator, tokens);
    const program = parser.parseProgram() catch |err| {
        std.debug.print("blad parsowania ctrlfilemaker: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var log = logger_mod.Logger.init(allocator, io, "logs.txt") catch |err| {
        std.debug.print("nie mozna otworzyc logs.txt: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer log.deinit();

    try executor.runWhens(allocator, io, init.environ_map, &config, program.whens, &log);
    executor.runBlock(allocator, io, &config, program, target_name, &log) catch |err| {
        std.debug.print("blad wykonania '{s}': {s}\n", .{ target_name, @errorName(err) });
        std.process.exit(1);
    };
}
