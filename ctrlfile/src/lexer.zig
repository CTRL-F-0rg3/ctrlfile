const std = @import("std");

pub const TokenType = enum {
    ident,
    string,
    number,
    lbrace,
    rbrace,
    lparen,
    rparen,
    colon,
    comma,
    amp,
    eqeq,
    noteq,
    andand,
    oror,
    not,
    question,
    kw_run,
    kw_when,
    kw_step,
    eof,
};

pub const Token = struct {
    kind: TokenType,
    text: []const u8,
    line: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Lexer {
        return Lexer{ .src = src, .allocator = allocator };
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) u8 {
        if (self.pos + offset >= self.src.len) return 0;
        return self.src[self.pos + offset];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.peek();
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn skipTrivia(self: *Lexer) void {
        while (true) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
            } else if (c == '#') {
                while (self.peek() != '\n' and self.peek() != 0) _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    pub fn tokenize(self: *Lexer) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        while (true) {
            self.skipTrivia();
            const line = self.line;
            const c = self.peek();
            if (c == 0) {
                try tokens.append(Token{ .kind = .eof, .text = "", .line = line });
                break;
            }

            if (isIdentStart(c)) {
                const start = self.pos;
                while (isIdentChar(self.peek())) _ = self.advance();
                const text = self.src[start..self.pos];
                if (std.mem.eql(u8, text, "run")) {
                    try tokens.append(Token{ .kind = .kw_run, .text = text, .line = line });
                } else if (std.mem.eql(u8, text, "when")) {
                    try tokens.append(Token{ .kind = .kw_when, .text = text, .line = line });
                } else if (std.mem.eql(u8, text, "step")) {
                    try tokens.append(Token{ .kind = .kw_step, .text = text, .line = line });
                } else {
                    try tokens.append(Token{ .kind = .ident, .text = text, .line = line });
                }
                continue;
            }

            if (std.ascii.isDigit(c)) {
                const start = self.pos;
                while (std.ascii.isDigit(self.peek())) _ = self.advance();
                try tokens.append(Token{ .kind = .number, .text = self.src[start..self.pos], .line = line });
                continue;
            }

            if (c == '"') {
                _ = self.advance();
                const start = self.pos;
                while (self.peek() != '"' and self.peek() != 0) {
                    if (self.peek() == '\\') _ = self.advance();
                    _ = self.advance();
                }
                const text = self.src[start..self.pos];
                _ = self.advance();
                try tokens.append(Token{ .kind = .string, .text = text, .line = line });
                continue;
            }

            switch (c) {
                '{' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .lbrace, .text = "{", .line = line });
                },
                '}' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .rbrace, .text = "}", .line = line });
                },
                '(' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .lparen, .text = "(", .line = line });
                },
                ')' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .rparen, .text = ")", .line = line });
                },
                ':' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .colon, .text = ":", .line = line });
                },
                ',' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .comma, .text = ",", .line = line });
                },
                '?' => {
                    _ = self.advance();
                    try tokens.append(Token{ .kind = .question, .text = "?", .line = line });
                },
                '&' => {
                    _ = self.advance();
                    if (self.peek() == '&') {
                        _ = self.advance();
                        try tokens.append(Token{ .kind = .andand, .text = "&&", .line = line });
                    } else {
                        try tokens.append(Token{ .kind = .amp, .text = "&", .line = line });
                    }
                },
                '|' => {
                    _ = self.advance();
                    if (self.peek() == '|') {
                        _ = self.advance();
                        try tokens.append(Token{ .kind = .oror, .text = "||", .line = line });
                    }
                },
                '=' => {
                    _ = self.advance();
                    if (self.peek() == '=') {
                        _ = self.advance();
                        try tokens.append(Token{ .kind = .eqeq, .text = "==", .line = line });
                    }
                },
                '!' => {
                    _ = self.advance();
                    if (self.peek() == '=') {
                        _ = self.advance();
                        try tokens.append(Token{ .kind = .noteq, .text = "!=", .line = line });
                    } else {
                        try tokens.append(Token{ .kind = .not, .text = "!", .line = line });
                    }
                },
                else => {
                    _ = self.advance();
                },
            }
        }
        return tokens.toOwnedSlice();
    }
};
