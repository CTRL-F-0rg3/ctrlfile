#[derive(Debug, Clone)]
pub enum Action {
    Cmd(Vec<String>),
    Shell(String),
    Install(String),
}

#[derive(Debug, Clone)]
pub struct Step {
    pub number: u32,
    pub actions: Vec<Action>,
}

#[derive(Debug, Clone)]
pub struct RunBlock {
    pub name: String,
    pub needs: Vec<String>,
    pub steps: Vec<Step>,
}

#[derive(Debug, Clone)]
pub enum Expr {
    Str(String),
    Call { name: String, arg: String },
    Eq(Box<Expr>, Box<Expr>),
    Neq(Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
    Ternary(Box<Expr>, Box<Expr>, Box<Expr>),
}

#[derive(Debug, Clone)]
pub struct WhenBlock {
    pub condition: Expr,
    pub actions: Vec<Action>,
}

#[derive(Debug, Clone, Default)]
pub struct Program {
    pub runs: Vec<RunBlock>,
    pub whens: Vec<WhenBlock>,
}
