use crate::ast::{Action, Program};
use crate::config::Config;
use std::collections::{HashMap, HashSet};

fn extract_vars(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 1 < bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            let start = i + 2;
            let mut j = start;
            while j + 1 < bytes.len() && !(bytes[j] == b'}' && bytes[j + 1] == b'}') {
                j += 1;
            }
            out.push(s[start..j].trim().to_string());
            i = j + 2;
        } else {
            i += 1;
        }
    }
    out
}

fn action_strings(action: &Action) -> Vec<&str> {
    match action {
        Action::Cmd(argv) => argv.iter().map(|s| s.as_str()).collect(),
        Action::Shell(s) => vec![s.as_str()],
        Action::Install(s) => vec![s.as_str()],
    }
}

pub fn validate(program: &Program, config: &Config) -> (Vec<String>, Vec<String>) {
    let mut errors = Vec::new();
    let warnings = Vec::new();

    let mut seen_names: HashMap<String, usize> = HashMap::new();
    for r in &program.runs {
        *seen_names.entry(r.name.clone()).or_insert(0) += 1;
    }
    for (name, count) in &seen_names {
        if *count > 1 {
            errors.push(format!("zduplikowana nazwa run: '{}' wystepuje {} razy", name, count));
        }
    }

    let known_names: HashSet<&str> = program.runs.iter().map(|r| r.name.as_str()).collect();
    for r in &program.runs {
        for dep in &r.needs {
            if !known_names.contains(dep.as_str()) {
                errors.push(format!(
                    "run '{}' wymaga '{}', ktory nie istnieje",
                    r.name, dep
                ));
            }
        }
    }

    for r in &program.runs {
        let mut visiting = HashSet::new();
        if let Some(cycle) = detect_cycle(program, &r.name, &mut visiting) {
            errors.push(format!("cykl zaleznosci needs: {}", cycle));
        }
    }

    for r in &program.runs {
        for step in &r.steps {
            for action in &step.actions {
                for s in action_strings(action) {
                    for key in extract_vars(s) {
                        if config.get(&key).is_none() {
                            errors.push(format!(
                                "run '{}' step {}: nieznana zmienna '{{{{{}}}}}' (brak w ctrlfile.toml)",
                                r.name, step.number, key
                            ));
                        }
                    }
                }
            }
        }
    }

    for w in &program.whens {
        for action in &w.actions {
            for s in action_strings(action) {
                for key in extract_vars(s) {
                    if config.get(&key).is_none() {
                        errors.push(format!(
                            "blok when: nieznana zmienna '{{{{{}}}}}' (brak w ctrlfile.toml)",
                            key
                        ));
                    }
                }
            }
        }
    }

    (errors, warnings)
}

fn detect_cycle(program: &Program, name: &str, visiting: &mut HashSet<String>) -> Option<String> {
    if visiting.contains(name) {
        return Some(name.to_string());
    }
    let block = program.runs.iter().find(|r| r.name == name)?;
    visiting.insert(name.to_string());
    for dep in &block.needs {
        if let Some(cycle) = detect_cycle(program, dep, visiting) {
            return Some(format!("{} -> {}", name, cycle));
        }
    }
    visiting.remove(name);
    None
}
