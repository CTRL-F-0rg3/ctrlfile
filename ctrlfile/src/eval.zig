const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");

pub const Value = union(enum) {
    boolean: bool,
    string: []const u8,
};

fn toBool(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .string => |s| s.len > 0,
    };
}

fn toStr(v: Value) []const u8 {
    return switch (v) {
        .boolean => |b| if (b) "true" else "false",
        .string => |s| s,
    };
}

fn toolMissing(allocator: std.mem.Allocator, tool: []const u8) bool {
    const cmd = std.fmt.allocPrint(allocator, "command -v {s} >/dev/null 2>&1", .{tool}) catch return true;
    defer allocator.free(cmd);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", cmd },
    }) catch return true;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn currentOsName() []const u8 {
    return switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };
}

pub fn eval(allocator: std.mem.Allocator, expr: *ast.Expr) Value {
    return switch (expr.kind) {
        .string => Value{ .string = expr.str },
        .call => blk: {
            if (std.mem.eql(u8, expr.call_name, "missing")) {
                break :blk Value{ .boolean = toolMissing(allocator, expr.call_arg) };
            } else if (std.mem.eql(u8, expr.call_name, "exists")) {
                break :blk Value{ .boolean = pathExists(expr.call_arg) };
            } else if (std.mem.eql(u8, expr.call_name, "env")) {
                const v = std.process.getEnvVarOwned(allocator, expr.call_arg) catch break :blk Value{ .string = "" };
                break :blk Value{ .string = v };
            } else if (std.mem.eql(u8, expr.call_name, "os")) {
                break :blk Value{ .boolean = std.mem.eql(u8, currentOsName(), expr.call_arg) };
            }
            break :blk Value{ .boolean = false };
        },
        .eq => blk: {
            const l = eval(allocator, expr.left.?);
            const r = eval(allocator, expr.right.?);
            break :blk Value{ .boolean = std.mem.eql(u8, toStr(l), toStr(r)) };
        },
        .neq => blk: {
            const l = eval(allocator, expr.left.?);
            const r = eval(allocator, expr.right.?);
            break :blk Value{ .boolean = !std.mem.eql(u8, toStr(l), toStr(r)) };
        },
        .and_ => blk: {
            const l = eval(allocator, expr.left.?);
            if (!toBool(l)) break :blk Value{ .boolean = false };
            const r = eval(allocator, expr.right.?);
            break :blk Value{ .boolean = toBool(r) };
        },
        .or_ => blk: {
            const l = eval(allocator, expr.left.?);
            if (toBool(l)) break :blk Value{ .boolean = true };
            const r = eval(allocator, expr.right.?);
            break :blk Value{ .boolean = toBool(r) };
        },
        .not_ => blk: {
            const l = eval(allocator, expr.left.?);
            break :blk Value{ .boolean = !toBool(l) };
        },
        .ternary => blk: {
            const c = eval(allocator, expr.cond.?);
            if (toBool(c)) {
                break :blk eval(allocator, expr.then_expr.?);
            }
            break :blk eval(allocator, expr.else_expr.?);
        },
    };
}
