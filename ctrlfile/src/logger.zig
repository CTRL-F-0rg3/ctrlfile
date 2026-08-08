const std = @import("std");

pub const Logger = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Logger {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, path, .{});
        return Logger{ .file = file, .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Logger) void {
        self.file.close(self.io);
    }

    fn timestampString(io: std.Io, buf: []u8) []const u8 {
        const ts = std.Io.Clock.real.now(io);
        const secs: u64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
        const day = epoch_secs.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        }) catch "0000-00-00 00:00:00";
    }

    pub fn log(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        var tsbuf: [32]u8 = undefined;
        const ts = timestampString(self.io, &tsbuf);
        const line = std.fmt.allocPrint(self.allocator, "[{s}] " ++ fmt ++ "\n", .{ts} ++ args) catch return;
        defer self.allocator.free(line);
        self.file.writeStreamingAll(self.io, line) catch {};
    }
};
