const std = @import("std");
const ast = @import("ast.zig");
const toml = @import("toml.zig");
const eval = @import("eval.zig");
const logger_mod = @import("logger.zig");

pub const ExecError = error{
    RunBlockNotFound,
    CycleDetected,
    OutOfMemory,
};

fn interpolate(allocator: std.mem.Allocator, config: *toml.Config, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '{' and s[i + 1] == '{') {
            const start = i + 2;
            var j = start;
            while (j + 1 < s.len and !(s[j] == '}' and s[j + 1] == '}')) : (j += 1) {}
            const key = std.mem.trim(u8, s[start..j], " \t");
            if (config.get(key)) |val| {
                try out.appendSlice(allocator, val);
            }
            i = j + 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const ActionResult = struct {
    ok: bool,
    exit_code: i32,
    duration_ms: i64,
    stdout: []const u8,
    stderr: []const u8,
    resolved_cmd: []const u8,
};

fn runShell(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8) !ActionResult {
    const start = std.Io.Clock.awake.now(io);

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "sh", "-c", cmd },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        return ActionResult{
            .ok = false,
            .exit_code = -1,
            .duration_ms = 0,
            .stdout = "",
            .stderr = @errorName(err),
            .resolved_cmd = cmd,
        };
    };

    var stdout_alloc = std.Io.Writer.Allocating.init(allocator);
    var stderr_alloc = std.Io.Writer.Allocating.init(allocator);

    if (child.stdout) |out_file| {
        var read_buf: [4096]u8 = undefined;
        var out_reader = out_file.reader(io, &read_buf);
        _ = out_reader.interface.streamRemaining(&stdout_alloc.writer) catch {};
        out_file.close(io);
    }
    if (child.stderr) |err_file| {
        var read_buf: [4096]u8 = undefined;
        var err_reader = err_file.reader(io, &read_buf);
        _ = err_reader.interface.streamRemaining(&stderr_alloc.writer) catch {};
        err_file.close(io);
    }

    const term = child.wait(io) catch |err| {
        const dur = start.durationTo(std.Io.Clock.awake.now(io));
        return ActionResult{
            .ok = false,
            .exit_code = -1,
            .duration_ms = @intCast(@divFloor(dur.nanoseconds, std.time.ns_per_ms)),
            .stdout = stdout_alloc.written(),
            .stderr = @errorName(err),
            .resolved_cmd = cmd,
        };
    };

    const dur = start.durationTo(std.Io.Clock.awake.now(io));
    const duration_ms: i64 = @intCast(@divFloor(dur.nanoseconds, std.time.ns_per_ms));
    const code: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };

    return ActionResult{
        .ok = code == 0,
        .exit_code = code,
        .duration_ms = duration_ms,
        .stdout = stdout_alloc.written(),
        .stderr = stderr_alloc.written(),
        .resolved_cmd = cmd,
    };
}

fn installTool(allocator: std.mem.Allocator, io: std.Io, config: *toml.Config, tool: []const u8) !ActionResult {
    if (config.get("installer.cmd")) |template| {
        const cmd = try replaceTool(allocator, template, tool);
        return runShell(allocator, io, cmd);
    }
    const cmd = try std.fmt.allocPrint(
        allocator,
        "(command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y {s}) || (command -v pacman >/dev/null 2>&1 && sudo pacman -S --noconfirm {s}) || (command -v dnf >/dev/null 2>&1 && sudo dnf install -y {s}) || (command -v brew >/dev/null 2>&1 && brew install {s})",
        .{ tool, tool, tool, tool },
    );
    return runShell(allocator, io, cmd);
}

fn replaceTool(allocator: std.mem.Allocator, template: []const u8, tool: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 6 <= template.len and std.mem.eql(u8, template[i .. i + 6], "{tool}")) {
            try out.appendSlice(allocator, tool);
            i += 6;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn runAction(allocator: std.mem.Allocator, io: std.Io, config: *toml.Config, action: ast.Action) !ActionResult {
    const resolved = try interpolate(allocator, config, action.value);
    return switch (action.kind) {
        .cmd => runShell(allocator, io, resolved),
        .install => installTool(allocator, io, config, resolved),
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
    io: std.Io,
    config: *toml.Config,
    action: ast.Action,
    result: ActionResult = undefined,
};

fn threadWorker(ctx: *ThreadCtx) void {
    ctx.result = runAction(ctx.allocator, ctx.io, ctx.config, ctx.action) catch ActionResult{
        .ok = false,
        .exit_code = -1,
        .duration_ms = 0,
        .stdout = "",
        .stderr = "blad wewnetrzny",
        .resolved_cmd = ctx.action.value,
    };
}

fn actionContributesFailure(kind: ast.ActionKind, ok: bool, log: *logger_mod.Logger) bool {
    if (ok) return false;
    if (kind == .install) {
        log.log("  OSTRZEZENIE: instalacja nieudana, zainstaluj narzedzie recznie (sprawdz menedzera pakietow); kontynuuje wykonanie", .{});
        return false;
    }
    return true;
}

fn runActionsParallel(allocator: std.mem.Allocator, io: std.Io, config: *toml.Config, actions: []ast.Action, log: *logger_mod.Logger, label: []const u8) !bool {
    if (actions.len == 1) {
        const r = try runAction(allocator, io, config, actions[0]);
        logResult(log, label, r);
        const failed = actionContributesFailure(actions[0].kind, r.ok, log);
        return !failed;
    }

    var contexts = try allocator.alloc(ThreadCtx, actions.len);
    var threads = try allocator.alloc(std.Thread, actions.len);

    for (actions, 0..) |a, idx| {
        contexts[idx] = ThreadCtx{ .allocator = allocator, .io = io, .config = config, .action = a };
    }
    for (0..actions.len) |idx| {
        threads[idx] = try std.Thread.spawn(.{}, threadWorker, .{&contexts[idx]});
    }
    for (threads) |t| t.join();

    var all_ok = true;
    for (contexts, 0..) |ctx, idx| {
        const sub_label = std.fmt.allocPrint(allocator, "{s} [rownolegle {d}/{d}]", .{ label, idx + 1, actions.len }) catch label;
        logResult(log, sub_label, ctx.result);
        const failed = actionContributesFailure(ctx.action.kind, ctx.result.ok, log);
        if (failed) all_ok = false;
    }
    return all_ok;
}

pub fn runWhens(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, config: *toml.Config, whens: []ast.WhenBlock, log: *logger_mod.Logger) !void {
    for (whens, 0..) |w, idx| {
        const v = eval.eval(allocator, io, environ, w.condition);
        const truthy = switch (v) {
            .boolean => |b| b,
            .string => |s| s.len > 0,
        };
        log.log("WHEN {d}: warunek = {}", .{ idx + 1, truthy });
        if (!truthy) continue;
        for (w.actions) |a| {
            const r = try runAction(allocator, io, config, a);
            logResult(log, "  WHEN akcja", r);
        }
    }
}

fn findRunBlock(program: ast.Program, name: []const u8) ?ast.RunBlock {
    for (program.runs) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn runBlockRec(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *toml.Config,
    program: ast.Program,
    name: []const u8,
    log: *logger_mod.Logger,
    executed: *std.StringHashMap(void),
    visiting: *std.StringHashMap(void),
) !void {
    if (executed.contains(name)) return;
    if (visiting.contains(name)) {
        log.log("BLAD: wykryto cykl zaleznosci przy '{s}'", .{name});
        return ExecError.CycleDetected;
    }

    const block = findRunBlock(program, name) orelse {
        log.log("BLAD: brak bloku run o nazwie '{s}'", .{name});
        return ExecError.RunBlockNotFound;
    };

    try visiting.put(name, {});
    for (block.needs) |dep| {
        log.log("RUN '{s}' wymaga '{s}'", .{ name, dep });
        try runBlockRec(allocator, io, config, program, dep, log, executed, visiting);
    }
    _ = visiting.remove(name);

    const steps = try allocator.dupe(ast.Step, block.steps);
    std.mem.sort(ast.Step, steps, {}, struct {
        fn lessThan(_: void, a: ast.Step, b: ast.Step) bool {
            return a.number < b.number;
        }
    }.lessThan);

    log.log("RUN '{s}' start", .{name});
    for (steps) |step| {
        const label = try std.fmt.allocPrint(allocator, "RUN {s} / STEP {d}", .{ name, step.number });
        const ok = try runActionsParallel(allocator, io, config, step.actions, log, label);
        if (!ok) {
            log.log("RUN '{s}' przerwany na STEP {d}", .{ name, step.number });
            return;
        }
    }
    log.log("RUN '{s}' zakonczony sukcesem", .{name});
    try executed.put(name, {});
}

pub fn runBlock(allocator: std.mem.Allocator, io: std.Io, config: *toml.Config, program: ast.Program, name: []const u8, log: *logger_mod.Logger) !void {
    var executed = std.StringHashMap(void).init(allocator);
    var visiting = std.StringHashMap(void).init(allocator);
    try runBlockRec(allocator, io, config, program, name, log, &executed, &visiting);
}
