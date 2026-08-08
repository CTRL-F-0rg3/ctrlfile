const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    list: [][]const u8,
};

pub const Section = std.StringHashMap(Value);

pub const Config = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .sections = std.StringHashMap(Section).init(allocator),
        };
    }

    pub fn get(self: *Config, path: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, path, '.');
        const section_name = it.next() orelse return null;
        const key = it.next() orelse return null;
        const section = self.sections.get(section_name) orelse return null;
        const value = section.get(key) orelse return null;
        return switch (value) {
            .string => |s| s,
            .list => null,
        };
    }

    pub fn getList(self: *Config, path: []const u8) ?[][]const u8 {
        var it = std.mem.splitScalar(u8, path, '.');
        const section_name = it.next() orelse return null;
        const key = it.next() orelse return null;
        const section = self.sections.get(section_name) orelse return null;
        const value = section.get(key) orelse return null;
        return switch (value) {
            .list => |l| l,
            .string => null,
        };
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseStringLiteral(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const inner = std.mem.trim(u8, raw, " \t");
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
        return try allocator.dupe(u8, inner[1 .. inner.len - 1]);
    }
    return try allocator.dupe(u8, inner);
}

fn parseListLiteral(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const inner = std.mem.trim(u8, raw, " \t");
    var body = inner;
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') {
        body = body[1 .. body.len - 1];
    }
    var items: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |chunk| {
        const c = trim(chunk);
        if (c.len == 0) continue;
        const s = try parseStringLiteral(allocator, c);
        try items.append(allocator, s);
    }
    return items.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Config {
    var config = Config.init(allocator);
    var current_section = try allocator.dupe(u8, "");
    try config.sections.put(current_section, Section.init(allocator));

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = trim(line[1 .. line.len - 1]);
            current_section = try allocator.dupe(u8, name);
            if (!config.sections.contains(current_section)) {
                try config.sections.put(current_section, Section.init(allocator));
            }
            continue;
        }

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq_pos]);
        const rhs = trim(line[eq_pos + 1 ..]);

        var section_ptr = config.sections.getPtr(current_section).?;
        const key_owned = try allocator.dupe(u8, key);

        if (rhs.len > 0 and rhs[0] == '[') {
            const list = try parseListLiteral(allocator, rhs);
            try section_ptr.put(key_owned, Value{ .list = list });
        } else {
            const s = try parseStringLiteral(allocator, rhs);
            try section_ptr.put(key_owned, Value{ .string = s });
        }
    }

    return config;
}
