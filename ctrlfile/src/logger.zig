const std = @import("std");

pub const Logger = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Logger {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        try file.seekFromEnd(0);
        return Logger{ .file = file, .allocator = allocator };
    }

    pub fn deinit(self: *Logger) void {
        self.file.close();
    }

    fn timestamp(buf: []u8) []const u8 {
        const secs: u64 = @intCast(std.time.timestamp());
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
        self.mutex.lock();
        defer self.mutex.unlock();
        var tsbuf: [32]u8 = undefined;
        const ts = timestamp(&tsbuf);
        const line = std.fmt.allocPrint(self.allocator, "[{s}] " ++ fmt ++ "\n", .{ts} ++ args) catch return;
        defer self.allocator.free(line);
        self.file.writeAll(line) catch {};
    }
};
