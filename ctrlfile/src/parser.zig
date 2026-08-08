const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []lex.Token,
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tokens: []lex.Token) Parser {
        return Parser{ .allocator = allocator, .tokens = tokens };
    }

    fn peek(self: *Parser) lex.Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) lex.Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn expect(self: *Parser, kind: lex.TokenType) ParseError!lex.Token {
        const t = self.peek();
        if (t.kind != kind) {
            std.debug.print("linia {d}: nieoczekiwany token '{s}'\n", .{ t.line, t.text });
            return ParseError.UnexpectedToken;
        }
        return self.advance();
    }

    fn check(self: *Parser, kind: lex.TokenType) bool {
        return self.peek().kind == kind;
    }

    pub fn parseProgram(self: *Parser) ParseError!ast.Program {
        var runs = std.ArrayList(ast.RunBlock).init(self.allocator);
        var whens = std.ArrayList(ast.WhenBlock).init(self.allocator);

        while (!self.check(.eof)) {
            if (self.check(.kw_run)) {
                try runs.append(try self.parseRunBlock());
            } else if (self.check(.kw_when)) {
                try whens.append(try self.parseWhenBlock());
            } else {
                std.debug.print("linia {d}: oczekiwano 'run' lub 'when', jest '{s}'\n", .{ self.peek().line, self.peek().text });
                return ParseError.UnexpectedToken;
            }
        }

        return ast.Program{
            .runs = try runs.toOwnedSlice(),
            .whens = try whens.toOwnedSlice(),
        };
    }

    fn parseRunBlock(self: *Parser) ParseError!ast.RunBlock {
        _ = try self.expect(.kw_run);
        const name_tok = try self.expect(.string);
        _ = try self.expect(.lbrace);

        var steps = std.ArrayList(ast.Step).init(self.allocator);
        while (!self.check(.rbrace)) {
            try steps.append(try self.parseStep());
        }
        _ = try self.expect(.rbrace);

        return ast.RunBlock{
            .name = name_tok.text,
            .steps = try steps.toOwnedSlice(),
        };
    }

    fn parseStep(self: *Parser) ParseError!ast.Step {
        _ = try self.expect(.kw_step);
        const num_tok = try self.expect(.number);
        _ = try self.expect(.colon);

        var actions = std.ArrayList(ast.Action).init(self.allocator);
        try actions.append(try self.parseAction());
        while (self.check(.amp)) {
            _ = self.advance();
            try actions.append(try self.parseAction());
        }

        const number = std.fmt.parseInt(u32, num_tok.text, 10) catch 0;
        return ast.Step{
            .number = number,
            .actions = try actions.toOwnedSlice(),
        };
    }

    fn parseAction(self: *Parser) ParseError!ast.Action {
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lparen);
        const arg_tok = try self.expect(.string);
        _ = try self.expect(.rparen);

        var kind: ast.ActionKind = .cmd;
        if (std.mem.eql(u8, name_tok.text, "install")) {
            kind = .install;
        } else if (!std.mem.eql(u8, name_tok.text, "cmd")) {
            std.debug.print("linia {d}: nieznana akcja '{s}'\n", .{ name_tok.line, name_tok.text });
            return ParseError.UnexpectedToken;
        }

        return ast.Action{ .kind = kind, .value = arg_tok.text };
    }

    fn parseWhenBlock(self: *Parser) ParseError!ast.WhenBlock {
        _ = try self.expect(.kw_when);
        const condition = try self.parseExpr();
        _ = try self.expect(.lbrace);

        var actions = std.ArrayList(ast.Action).init(self.allocator);
        while (!self.check(.rbrace)) {
            try actions.append(try self.parseAction());
        }
        _ = try self.expect(.rbrace);

        return ast.WhenBlock{
            .condition = condition,
            .actions = try actions.toOwnedSlice(),
        };
    }

    fn newExpr(self: *Parser, e: ast.Expr) ParseError!*ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        p.* = e;
        return p;
    }

    fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        return self.parseTernary();
    }

    fn parseTernary(self: *Parser) ParseError!*ast.Expr {
        const cond = try self.parseLogicOr();
        if (self.check(.question)) {
            _ = self.advance();
            const then_e = try self.parseExpr();
            _ = try self.expect(.colon);
            const else_e = try self.parseExpr();
            return self.newExpr(ast.Expr{
                .kind = .ternary,
                .cond = cond,
                .then_expr = then_e,
                .else_expr = else_e,
            });
        }
        return cond;
    }

    fn parseLogicOr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseLogicAnd();
        while (self.check(.oror)) {
            _ = self.advance();
            const right = try self.parseLogicAnd();
            left = try self.newExpr(ast.Expr{ .kind = .or_, .left = left, .right = right });
        }
        return left;
    }

    fn parseLogicAnd(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseEquality();
        while (self.check(.andand)) {
            _ = self.advance();
            const right = try self.parseEquality();
            left = try self.newExpr(ast.Expr{ .kind = .and_, .left = left, .right = right });
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseUnary();
        while (self.check(.eqeq) or self.check(.noteq)) {
            const op = self.advance();
            const right = try self.parseUnary();
            const kind: ast.ExprKind = if (op.kind == .eqeq) .eq else .neq;
            left = try self.newExpr(ast.Expr{ .kind = kind, .left = left, .right = right });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expr {
        if (self.check(.not)) {
            _ = self.advance();
            const inner = try self.parseUnary();
            return self.newExpr(ast.Expr{ .kind = .not_, .left = inner });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Expr {
        if (self.check(.lparen)) {
            _ = self.advance();
            const inner = try self.parseExpr();
            _ = try self.expect(.rparen);
            return inner;
        }
        if (self.check(.string)) {
            const t = self.advance();
            return self.newExpr(ast.Expr{ .kind = .string, .str = t.text });
        }
        if (self.check(.ident)) {
            const name_tok = self.advance();
            _ = try self.expect(.lparen);
            const arg_tok = try self.expect(.string);
            _ = try self.expect(.rparen);
            return self.newExpr(ast.Expr{
                .kind = .call,
                .call_name = name_tok.text,
                .call_arg = arg_tok.text,
            });
        }
        std.debug.print("linia {d}: nieoczekiwany token w wyrazeniu '{s}'\n", .{ self.peek().line, self.peek().text });
        return ParseError.UnexpectedToken;
    }
};
