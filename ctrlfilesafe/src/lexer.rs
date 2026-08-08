#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    Ident,
    Str,
    Number,
    LBrace,
    RBrace,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Colon,
    Comma,
    Amp,
    EqEq,
    NotEq,
    AndAnd,
    OrOr,
    Not,
    Question,
    KwRun,
    KwWhen,
    KwStep,
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub kind: TokenKind,
    pub text: String,
    pub line: u32,
}

pub struct Lexer<'a> {
    src: &'a [u8],
    pos: usize,
    line: u32,
}

impl<'a> Lexer<'a> {
    pub fn new(src: &'a str) -> Self {
        Lexer { src: src.as_bytes(), pos: 0, line: 1 }
    }

    fn peek(&self) -> u8 {
        *self.src.get(self.pos).unwrap_or(&0)
    }

    #[allow(dead_code)]
    fn peek_at(&self, offset: usize) -> u8 {
        *self.src.get(self.pos + offset).unwrap_or(&0)
    }

    fn advance(&mut self) -> u8 {
        let c = self.peek();
        self.pos += 1;
        if c == b'\n' {
            self.line += 1;
        }
        c
    }

    fn skip_trivia(&mut self) {
        loop {
            let c = self.peek();
            if c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' {
                self.advance();
            } else if c == b'#' {
                while self.peek() != b'\n' && self.peek() != 0 {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn is_ident_start(c: u8) -> bool {
        c.is_ascii_alphabetic() || c == b'_'
    }

    fn is_ident_char(c: u8) -> bool {
        c.is_ascii_alphanumeric() || c == b'_'
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, String> {
        let mut tokens = Vec::new();
        loop {
            self.skip_trivia();
            let line = self.line;
            let c = self.peek();
            if c == 0 {
                tokens.push(Token { kind: TokenKind::Eof, text: String::new(), line });
                break;
            }

            if Self::is_ident_start(c) {
                let start = self.pos;
                while Self::is_ident_char(self.peek()) {
                    self.advance();
                }
                let text = String::from_utf8_lossy(&self.src[start..self.pos]).to_string();
                let kind = match text.as_str() {
                    "run" => TokenKind::KwRun,
                    "when" => TokenKind::KwWhen,
                    "step" => TokenKind::KwStep,
                    _ => TokenKind::Ident,
                };
                tokens.push(Token { kind, text, line });
                continue;
            }

            if c.is_ascii_digit() {
                let start = self.pos;
                while self.peek().is_ascii_digit() {
                    self.advance();
                }
                let text = String::from_utf8_lossy(&self.src[start..self.pos]).to_string();
                tokens.push(Token { kind: TokenKind::Number, text, line });
                continue;
            }

            if c == b'"' {
                self.advance();
                let start = self.pos;
                while self.peek() != b'"' && self.peek() != 0 {
                    if self.peek() == b'\\' {
                        self.advance();
                    }
                    self.advance();
                }
                let text = String::from_utf8_lossy(&self.src[start..self.pos]).to_string();
                self.advance();
                tokens.push(Token { kind: TokenKind::Str, text, line });
                continue;
            }

            match c {
                b'{' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::LBrace, text: "{".into(), line });
                }
                b'}' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::RBrace, text: "}".into(), line });
                }
                b'(' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::LParen, text: "(".into(), line });
                }
                b')' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::RParen, text: ")".into(), line });
                }
                b'[' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::LBracket, text: "[".into(), line });
                }
                b']' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::RBracket, text: "]".into(), line });
                }
                b':' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::Colon, text: ":".into(), line });
                }
                b',' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::Comma, text: ",".into(), line });
                }
                b'?' => {
                    self.advance();
                    tokens.push(Token { kind: TokenKind::Question, text: "?".into(), line });
                }
                b'&' => {
                    self.advance();
                    if self.peek() == b'&' {
                        self.advance();
                        tokens.push(Token { kind: TokenKind::AndAnd, text: "&&".into(), line });
                    } else {
                        tokens.push(Token { kind: TokenKind::Amp, text: "&".into(), line });
                    }
                }
                b'|' => {
                    self.advance();
                    if self.peek() == b'|' {
                        self.advance();
                        tokens.push(Token { kind: TokenKind::OrOr, text: "||".into(), line });
                    }
                }
                b'=' => {
                    self.advance();
                    if self.peek() == b'=' {
                        self.advance();
                        tokens.push(Token { kind: TokenKind::EqEq, text: "==".into(), line });
                    }
                }
                b'!' => {
                    self.advance();
                    if self.peek() == b'=' {
                        self.advance();
                        tokens.push(Token { kind: TokenKind::NotEq, text: "!=".into(), line });
                    } else {
                        tokens.push(Token { kind: TokenKind::Not, text: "!".into(), line });
                    }
                }
                _ => {
                    self.advance();
                }
            }
        }
        Ok(tokens)
    }
}
