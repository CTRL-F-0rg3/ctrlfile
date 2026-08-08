use crate::ast::{Action, Expr, Program, RunBlock, Step, WhenBlock};
use crate::lexer::{Token, TokenKind};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    fn peek(&self) -> &Token {
        &self.tokens[self.pos]
    }

    fn advance(&mut self) -> Token {
        let t = self.tokens[self.pos].clone();
        if self.pos + 1 < self.tokens.len() {
            self.pos += 1;
        }
        t
    }

    fn check(&self, kind: TokenKind) -> bool {
        self.peek().kind == kind
    }

    fn check_ident(&self, text: &str) -> bool {
        self.peek().kind == TokenKind::Ident && self.peek().text == text
    }

    fn expect(&mut self, kind: TokenKind) -> Result<Token, String> {
        if self.peek().kind != kind {
            return Err(format!(
                "linia {}: oczekiwano {:?}, jest '{}'",
                self.peek().line,
                kind,
                self.peek().text
            ));
        }
        Ok(self.advance())
    }

    pub fn parse_program(&mut self) -> Result<Program, String> {
        let mut program = Program::default();
        while !self.check(TokenKind::Eof) {
            if self.check(TokenKind::KwRun) {
                program.runs.push(self.parse_run_block()?);
            } else if self.check(TokenKind::KwWhen) {
                program.whens.push(self.parse_when_block()?);
            } else {
                return Err(format!(
                    "linia {}: oczekiwano 'run' lub 'when', jest '{}'",
                    self.peek().line,
                    self.peek().text
                ));
            }
        }
        Ok(program)
    }

    fn parse_run_block(&mut self) -> Result<RunBlock, String> {
        self.expect(TokenKind::KwRun)?;
        let name = self.expect(TokenKind::Str)?.text;

        let mut needs = Vec::new();
        if self.check_ident("needs") {
            self.advance();
            needs.push(self.expect(TokenKind::Str)?.text);
            while self.check(TokenKind::Comma) {
                self.advance();
                needs.push(self.expect(TokenKind::Str)?.text);
            }
        }

        self.expect(TokenKind::LBrace)?;
        let mut steps = Vec::new();
        while !self.check(TokenKind::RBrace) {
            steps.push(self.parse_step()?);
        }
        self.expect(TokenKind::RBrace)?;

        Ok(RunBlock { name, needs, steps })
    }

    fn parse_step(&mut self) -> Result<Step, String> {
        self.expect(TokenKind::KwStep)?;
        let num_tok = self.expect(TokenKind::Number)?;
        self.expect(TokenKind::Colon)?;

        let mut actions = vec![self.parse_action()?];
        while self.check(TokenKind::Amp) {
            self.advance();
            actions.push(self.parse_action()?);
        }

        let number: u32 = num_tok.text.parse().unwrap_or(0);
        Ok(Step { number, actions })
    }

    fn parse_action(&mut self) -> Result<Action, String> {
        let name_tok = self.expect(TokenKind::Ident)?;
        self.expect(TokenKind::LParen)?;

        let action = match name_tok.text.as_str() {
            "cmd" => {
                self.expect(TokenKind::LBracket)?;
                let mut argv = vec![self.expect(TokenKind::Str)?.text];
                while self.check(TokenKind::Comma) {
                    self.advance();
                    argv.push(self.expect(TokenKind::Str)?.text);
                }
                self.expect(TokenKind::RBracket)?;
                Action::Cmd(argv)
            }
            "shell" => {
                let s = self.expect(TokenKind::Str)?.text;
                Action::Shell(s)
            }
            "install" => {
                let s = self.expect(TokenKind::Str)?.text;
                Action::Install(s)
            }
            other => {
                return Err(format!(
                    "linia {}: nieznana akcja '{}'",
                    name_tok.line, other
                ))
            }
        };

        self.expect(TokenKind::RParen)?;
        Ok(action)
    }

    fn parse_when_block(&mut self) -> Result<WhenBlock, String> {
        self.expect(TokenKind::KwWhen)?;
        let condition = self.parse_expr()?;
        self.expect(TokenKind::LBrace)?;
        let mut actions = Vec::new();
        while !self.check(TokenKind::RBrace) {
            actions.push(self.parse_action()?);
        }
        self.expect(TokenKind::RBrace)?;
        Ok(WhenBlock { condition, actions })
    }

    fn parse_expr(&mut self) -> Result<Expr, String> {
        self.parse_ternary()
    }

    fn parse_ternary(&mut self) -> Result<Expr, String> {
        let cond = self.parse_or()?;
        if self.check(TokenKind::Question) {
            self.advance();
            let then_e = self.parse_expr()?;
            self.expect(TokenKind::Colon)?;
            let else_e = self.parse_expr()?;
            return Ok(Expr::Ternary(Box::new(cond), Box::new(then_e), Box::new(else_e)));
        }
        Ok(cond)
    }

    fn parse_or(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_and()?;
        while self.check(TokenKind::OrOr) {
            self.advance();
            let right = self.parse_and()?;
            left = Expr::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_equality()?;
        while self.check(TokenKind::AndAnd) {
            self.advance();
            let right = self.parse_equality()?;
            left = Expr::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_equality(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_unary()?;
        loop {
            if self.check(TokenKind::EqEq) {
                self.advance();
                let right = self.parse_unary()?;
                left = Expr::Eq(Box::new(left), Box::new(right));
            } else if self.check(TokenKind::NotEq) {
                self.advance();
                let right = self.parse_unary()?;
                left = Expr::Neq(Box::new(left), Box::new(right));
            } else {
                break;
            }
        }
        Ok(left)
    }

    fn parse_unary(&mut self) -> Result<Expr, String> {
        if self.check(TokenKind::Not) {
            self.advance();
            let inner = self.parse_unary()?;
            return Ok(Expr::Not(Box::new(inner)));
        }
        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<Expr, String> {
        if self.check(TokenKind::LParen) {
            self.advance();
            let inner = self.parse_expr()?;
            self.expect(TokenKind::RParen)?;
            return Ok(inner);
        }
        if self.check(TokenKind::Str) {
            let t = self.advance();
            return Ok(Expr::Str(t.text));
        }
        if self.check(TokenKind::Ident) {
            let name_tok = self.advance();
            self.expect(TokenKind::LParen)?;
            let arg_tok = self.expect(TokenKind::Str)?;
            self.expect(TokenKind::RParen)?;
            return Ok(Expr::Call { name: name_tok.text, arg: arg_tok.text });
        }
        Err(format!(
            "linia {}: nieoczekiwany token w wyrazeniu '{}'",
            self.peek().line,
            self.peek().text
        ))
    }
}
