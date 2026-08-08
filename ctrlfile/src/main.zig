const std = @import("std");
const toml = @import("toml.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const executor = @import("executor.zig");
const logger_mod = @import("logger.zig");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try file.readAll(buf);
    return buf;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("uzycie: ctrlfile <nazwa-run>\n", .{});
        std.process.exit(1);
    }
    const target_name = args[1];

    const toml_src = readFile(allocator, "ctrlfile.toml") catch |err| {
        std.debug.print("nie mozna odczytac ctrlfile.toml: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const dsl_src = readFile(allocator, "ctrlfilemaker") catch |err| {
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

    var log = logger_mod.Logger.init("logs.txt") catch |err| {
        std.debug.print("nie mozna otworzyc logs.txt: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer log.deinit();

    try executor.runWhens(allocator, &config, program.whens, &log);
    executor.runBlock(allocator, &config, program, target_name, &log) catch |err| {
        std.debug.print("blad wykonania '{s}': {s}\n", .{ target_name, @errorName(err) });
        std.process.exit(1);
    };
}
