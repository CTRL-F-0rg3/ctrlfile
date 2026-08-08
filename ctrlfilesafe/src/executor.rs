use crate::ast::{Action, Program, WhenBlock};
use crate::config::Config;
use crate::eval::{eval, Value};
use crate::logger::Logger;
use serde_json::json;
use std::collections::HashSet;
use std::process::Command;
use std::time::Instant;

pub struct ActionResult {
    pub ok: bool,
    pub exit_code: i32,
    pub duration_ms: u128,
    pub stdout: String,
    pub stderr: String,
    pub argv: Vec<String>,
}

fn run_argv(argv: &[String]) -> ActionResult {
    let start = Instant::now();
    if argv.is_empty() {
        return ActionResult {
            ok: false,
            exit_code: -1,
            duration_ms: 0,
            stdout: String::new(),
            stderr: "pusta lista argumentow".into(),
            argv: argv.to_vec(),
        };
    }
    let output = Command::new(&argv[0]).args(&argv[1..]).output();
    let duration_ms = start.elapsed().as_millis();
    match output {
        Ok(out) => ActionResult {
            ok: out.status.success(),
            exit_code: out.status.code().unwrap_or(-1),
            duration_ms,
            stdout: String::from_utf8_lossy(&out.stdout).to_string(),
            stderr: String::from_utf8_lossy(&out.stderr).to_string(),
            argv: argv.to_vec(),
        },
        Err(e) => ActionResult {
            ok: false,
            exit_code: -1,
            duration_ms,
            stdout: String::new(),
            stderr: e.to_string(),
            argv: argv.to_vec(),
        },
    }
}

fn run_shell(cmd: &str) -> ActionResult {
    run_argv(&["sh".to_string(), "-c".to_string(), cmd.to_string()])
}

fn install_tool(config: &Config, tool: &str) -> ActionResult {
    if let Some(template) = config.get("installer.cmd") {
        let cmd = template.replace("{tool}", tool);
        return run_shell(&cmd);
    }
    let cmd = format!(
        "(command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y {t}) || \
         (command -v pacman >/dev/null 2>&1 && sudo pacman -S --noconfirm {t}) || \
         (command -v dnf >/dev/null 2>&1 && sudo dnf install -y {t}) || \
         (command -v brew >/dev/null 2>&1 && brew install {t})",
        t = tool
    );
    run_shell(&cmd)
}

fn run_action(config: &Config, action: &Action) -> ActionResult {
    match action {
        Action::Cmd(argv) => {
            let resolved: Vec<String> = argv.iter().map(|a| config.interpolate(a)).collect();
            run_argv(&resolved)
        }
        Action::Shell(s) => {
            let resolved = config.interpolate(s);
            run_shell(&resolved)
        }
        Action::Install(tool) => {
            let resolved = config.interpolate(tool);
            install_tool(config, &resolved)
        }
    }
}

fn action_kind_name(action: &Action) -> &'static str {
    match action {
        Action::Cmd(_) => "cmd",
        Action::Shell(_) => "shell",
        Action::Install(_) => "install",
    }
}

fn action_contributes_failure(action: &Action, result: &ActionResult, logger: &Logger) -> bool {
    if result.ok {
        return false;
    }
    if matches!(action, Action::Install(_)) {
        logger.log(json!({
            "event": "warning",
            "message": "instalacja nieudana, zainstaluj narzedzie recznie (sprawdz menedzera pakietow); kontynuuje wykonanie",
            "argv": result.argv,
        }));
        return false;
    }
    true
}

fn log_result(logger: &Logger, label: &str, action: &Action, result: &ActionResult) {
    logger.log(json!({
        "event": "step_result",
        "label": label,
        "kind": action_kind_name(action),
        "argv": result.argv,
        "ok": result.ok,
        "exit_code": result.exit_code,
        "duration_ms": result.duration_ms,
        "stdout": result.stdout.trim(),
        "stderr": result.stderr.trim(),
    }));
}

fn run_actions_parallel(config: &Config, actions: &[Action], logger: &Logger, label: &str) -> bool {
    if actions.len() == 1 {
        let r = run_action(config, &actions[0]);
        log_result(logger, label, &actions[0], &r);
        return !action_contributes_failure(&actions[0], &r, logger);
    }

    let results: Vec<ActionResult> = std::thread::scope(|scope| {
        let handles: Vec<_> = actions
            .iter()
            .map(|a| scope.spawn(|| run_action(config, a)))
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });

    let mut all_ok = true;
    for (idx, (a, r)) in actions.iter().zip(results.iter()).enumerate() {
        let sub_label = format!("{} [rownolegle {}/{}]", label, idx + 1, actions.len());
        log_result(logger, &sub_label, a, r);
        if action_contributes_failure(a, r, logger) {
            all_ok = false;
        }
    }
    all_ok
}

pub fn run_whens(config: &Config, whens: &[WhenBlock], logger: &Logger) {
    for (idx, w) in whens.iter().enumerate() {
        let v = eval(&w.condition);
        let truthy = match v {
            Value::Bool(b) => b,
            Value::Str(s) => !s.is_empty(),
        };
        logger.log(json!({
            "event": "when",
            "index": idx + 1,
            "truthy": truthy,
        }));
        if !truthy {
            continue;
        }
        for a in &w.actions {
            let r = run_action(config, a);
            log_result(logger, "when-akcja", a, &r);
        }
    }
}

fn find_run_block<'a>(program: &'a Program, name: &str) -> Option<&'a crate::ast::RunBlock> {
    program.runs.iter().find(|r| r.name == name)
}

pub struct StepFailure {
    pub run_name: String,
    pub step_number: u32,
}

pub enum RunError {
    NotFound(String),
    Cycle(String),
    StepFailed(StepFailure),
}

fn run_block_rec(
    program: &Program,
    config: &Config,
    name: &str,
    logger: &Logger,
    executed: &mut HashSet<String>,
    visiting: &mut HashSet<String>,
) -> Result<(), RunError> {
    if executed.contains(name) {
        return Ok(());
    }
    if visiting.contains(name) {
        logger.log(json!({"event": "error", "message": format!("wykryto cykl zaleznosci przy '{}'", name)}));
        return Err(RunError::Cycle(name.to_string()));
    }

    let block = match find_run_block(program, name) {
        Some(b) => b,
        None => {
            logger.log(json!({"event": "error", "message": format!("brak bloku run o nazwie '{}'", name)}));
            return Err(RunError::NotFound(name.to_string()));
        }
    };

    visiting.insert(name.to_string());
    for dep in &block.needs {
        logger.log(json!({"event": "dependency", "run": name, "needs": dep}));
        run_block_rec(program, config, dep, logger, executed, visiting)?;
    }
    visiting.remove(name);

    let mut steps = block.steps.clone();
    steps.sort_by_key(|s| s.number);

    logger.log(json!({"event": "run_start", "run": name}));
    for step in &steps {
        let label = format!("RUN {} / STEP {}", name, step.number);
        let ok = run_actions_parallel(config, &step.actions, logger, &label);
        if !ok {
            logger.log(json!({"event": "run_aborted", "run": name, "step": step.number}));
            return Err(RunError::StepFailed(StepFailure {
                run_name: name.to_string(),
                step_number: step.number,
            }));
        }
    }
    logger.log(json!({"event": "run_success", "run": name}));
    executed.insert(name.to_string());
    Ok(())
}

pub fn run_block(program: &Program, config: &Config, name: &str, logger: &Logger) -> Result<(), RunError> {
    let mut executed = HashSet::new();
    let mut visiting = HashSet::new();
    run_block_rec(program, config, name, logger, &mut executed, &mut visiting)
}
