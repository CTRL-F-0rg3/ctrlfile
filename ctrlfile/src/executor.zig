const std = @import("std");
const ast = @import("ast.zig");
const toml = @import("toml.zig");
const eval = @import("eval.zig");
const logger_mod = @import("logger.zig");

pub const ExecError = error{
    RunBlockNotFound,
    OutOfMemory,
};

fn interpolate(allocator: std.mem.Allocator, config: *toml.Config, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '{' and s[i + 1] == '{') {
            const start = i + 2;
            var j = start;
            while (j + 1 < s.len and !(s[j] == '}' and s[j + 1] == '}')) : (j += 1) {}
            const key = std.mem.trim(u8, s[start..j], " \t");
            if (config.get(key)) |val| {
                try out.appendSlice(val);
            }
            i = j + 2;
        } else {
            try out.append(s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

const ActionResult = struct {
    ok: bool,
    exit_code: i32,
    duration_ms: i64,
    stdout: []const u8,
    stderr: []const u8,
    resolved_cmd: []const u8,
};

fn runShell(allocator: std.mem.Allocator, cmd: []const u8) !ActionResult {
    const start = std.time.milliTimestamp();
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", cmd },
    }) catch |err| {
        return ActionResult{
            .ok = false,
            .exit_code = -1,
            .duration_ms = std.time.milliTimestamp() - start,
            .stdout = "",
            .stderr = @errorName(err),
            .resolved_cmd = cmd,
        };
    };
    const duration = std.time.milliTimestamp() - start;
    const code: i32 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
    return ActionResult{
        .ok = code == 0,
        .exit_code = code,
        .duration_ms = duration,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .resolved_cmd = cmd,
    };
}

fn installTool(allocator: std.mem.Allocator, tool: []const u8) !ActionResult {
    const cmd = try std.fmt.allocPrint(
        allocator,
        "(command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y {s}) || (command -v brew >/dev/null 2>&1 && brew install {s}) || (command -v pacman >/dev/null 2>&1 && sudo pacman -S --noconfirm {s})",
        .{ tool, tool, tool },
    );
    return runShell(allocator, cmd);
}

fn runAction(allocator: std.mem.Allocator, config: *toml.Config, action: ast.Action) !ActionResult {
    const resolved = try interpolate(allocator, config, action.value);
    return switch (action.kind) {
        .cmd => runShell(allocator, resolved),
        .install => installTool(allocator, resolved),
    };
}

fn logResult(log: *logger_mod.Logger, label: []const u8, r: ActionResult) void {
    log.log("{s}", .{label});
    log.log("  cmd: {s}", .{r.resolved_cmd});
    log.log("  exit: {d}", .{r.exit_code});
    log.log("  duration: {d}ms", .{r.duration_ms});
    if (r.stdout.len > 0) log.log("  stdout: {s}", .{std.mem.trim(u8, r.stdout, " \t\r\n")});
    if (r.stderr.len > 0) log.log("  stderr: {s}", .{std.mem.trim(u8, r.stderr, " \t\r\n")});
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    config: *toml.Config,
    action: ast.Action,
    result: ActionResult = undefined,
};

fn threadWorker(ctx: *ThreadCtx) void {
    ctx.result = runAction(ctx.allocator, ctx.config, ctx.action) catch ActionResult{
        .ok = false,
        .exit_code = -1,
        .duration_ms = 0,
        .stdout = "",
        .stderr = "blad wewnetrzny",
        .resolved_cmd = ctx.action.value,
    };
}

fn runActionsParallel(allocator: std.mem.Allocator, config: *toml.Config, actions: []ast.Action, log: *logger_mod.Logger, label: []const u8) !bool {
    if (actions.len == 1) {
        const r = try runAction(allocator, config, actions[0]);
        logResult(log, label, r);
        return r.ok;
    }

    var contexts = try allocator.alloc(ThreadCtx, actions.len);
    var threads = try allocator.alloc(std.Thread, actions.len);

    for (actions, 0..) |a, idx| {
        contexts[idx] = ThreadCtx{ .allocator = allocator, .config = config, .action = a };
    }
    for (0..actions.len) |idx| {
        threads[idx] = try std.Thread.spawn(.{}, threadWorker, .{&contexts[idx]});
    }
    for (threads) |t| t.join();

    var all_ok = true;
    for (contexts, 0..) |ctx, idx| {
        const sub_label = std.fmt.allocPrint(allocator, "{s} [rownolegle {d}/{d}]", .{ label, idx + 1, actions.len }) catch label;
        logResult(log, sub_label, ctx.result);
        if (!ctx.result.ok) all_ok = false;
    }
    return all_ok;
}

pub fn runWhens(allocator: std.mem.Allocator, config: *toml.Config, whens: []ast.WhenBlock, log: *logger_mod.Logger) !void {
    for (whens, 0..) |w, idx| {
        const v = eval.eval(allocator, w.condition);
        const truthy = switch (v) {
            .boolean => |b| b,
            .string => |s| s.len > 0,
        };
        log.log("WHEN {d}: warunek = {}", .{ idx + 1, truthy });
        if (!truthy) continue;
        for (w.actions) |a| {
            const r = try runAction(allocator, config, a);
            logResult(log, "  WHEN akcja", r);
        }
    }
}

pub fn runBlock(allocator: std.mem.Allocator, config: *toml.Config, program: ast.Program, name: []const u8, log: *logger_mod.Logger) !void {
    var target: ?ast.RunBlock = null;
    for (program.runs) |r| {
        if (std.mem.eql(u8, r.name, name)) {
            target = r;
            break;
        }
    }
    if (target == null) return ExecError.RunBlockNotFound;
    const block = target.?;

    var steps = try allocator.dupe(ast.Step, block.steps);
    std.mem.sort(ast.Step, steps, {}, struct {
        fn lessThan(_: void, a: ast.Step, b: ast.Step) bool {
            return a.number < b.number;
        }
    }.lessThan);

    log.log("RUN '{s}' start", .{name});
    for (steps) |step| {
        const label = try std.fmt.allocPrint(allocator, "RUN {s} / STEP {d}", .{ name, step.number });
        const ok = try runActionsParallel(allocator, config, step.actions, log, label);
        if (!ok) {
            log.log("RUN '{s}' przerwany na STEP {d}", .{ name, step.number });
            return;
        }
    }
    log.log("RUN '{s}' zakonczony sukcesem", .{name});
}
