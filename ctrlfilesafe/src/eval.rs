use crate::ast::Expr;
use std::path::Path;

pub enum Value {
    Bool(bool),
    Str(String),
}

fn to_bool(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Str(s) => !s.is_empty(),
    }
}

fn to_str(v: &Value) -> String {
    match v {
        Value::Bool(b) => b.to_string(),
        Value::Str(s) => s.clone(),
    }
}

fn tool_missing(tool: &str) -> bool {
    let path_var = match std::env::var("PATH") {
        Ok(p) => p,
        Err(_) => return true,
    };
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(tool);
        if let Ok(meta) = std::fs::metadata(&candidate) {
            if meta.is_file() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if meta.permissions().mode() & 0o111 != 0 {
                        return false;
                    }
                }
                #[cfg(not(unix))]
                {
                    return false;
                }
            }
        }
    }
    true
}

fn path_exists(path: &str) -> bool {
    Path::new(path).exists()
}

fn current_os() -> &'static str {
    std::env::consts::OS
}

pub fn eval(expr: &Expr) -> Value {
    match expr {
        Expr::Str(s) => Value::Str(s.clone()),
        Expr::Call { name, arg } => match name.as_str() {
            "missing" => Value::Bool(tool_missing(arg)),
            "exists" => Value::Bool(path_exists(arg)),
            "env" => Value::Str(std::env::var(arg).unwrap_or_default()),
            "os" => Value::Bool(current_os() == arg),
            _ => Value::Bool(false),
        },
        Expr::Eq(l, r) => Value::Bool(to_str(&eval(l)) == to_str(&eval(r))),
        Expr::Neq(l, r) => Value::Bool(to_str(&eval(l)) != to_str(&eval(r))),
        Expr::And(l, r) => {
            let lv = eval(l);
            if !to_bool(&lv) {
                Value::Bool(false)
            } else {
                Value::Bool(to_bool(&eval(r)))
            }
        }
        Expr::Or(l, r) => {
            let lv = eval(l);
            if to_bool(&lv) {
                Value::Bool(true)
            } else {
                Value::Bool(to_bool(&eval(r)))
            }
        }
        Expr::Not(inner) => Value::Bool(!to_bool(&eval(inner))),
        Expr::Ternary(c, then_e, else_e) => {
            if to_bool(&eval(c)) {
                eval(then_e)
            } else {
                eval(else_e)
            }
        }
    }
}
