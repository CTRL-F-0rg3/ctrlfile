mod ast;
mod config;
mod eval;
mod executor;
mod lexer;
mod logger;
mod parser;
mod validate;

use config::Config;
use executor::RunError;
use lexer::Lexer;
use logger::Logger;
use parser::Parser as DslParser;
use serde_json::json;

fn read_file(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("nie mozna odczytac {}: {}", path, e))
}

fn run_command(name: &str) -> i32 {
    let toml_src = match read_file("ctrlfile.toml") {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{}", e);
            return 1;
        }
    };
    let dsl_src = match read_file("ctrlfilemaker") {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{}", e);
            return 1;
        }
    };

    let config = match Config::parse(&toml_src) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("blad parsowania ctrlfile.toml: {}", e);
            return 1;
        }
    };

    let mut lexer = Lexer::new(&dsl_src);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("blad tokenizacji ctrlfilemaker: {}", e);
            return 1;
        }
    };

    let mut parser = DslParser::new(tokens);
    let program = match parser.parse_program() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("blad parsowania ctrlfilemaker: {}", e);
            return 1;
        }
    };

    let (errors, warnings) = validate::validate(&program, &config);
    for w in &warnings {
        eprintln!("OSTRZEZENIE: {}", w);
    }
    if !errors.is_empty() {
        eprintln!("walidacja nie powiodla sie:");
        for e in &errors {
            eprintln!("  - {}", e);
        }
        return 1;
    }

    let logger = match Logger::new("logs.jsonl") {
        Ok(l) => l,
        Err(e) => {
            eprintln!("nie mozna otworzyc logs.jsonl: {}", e);
            return 1;
        }
    };

    logger.log(json!({"event": "validation_ok", "run": name}));

    executor::run_whens(&config, &program.whens, &logger);

    match executor::run_block(&program, &config, name, &logger) {
        Ok(()) => {
            println!("RUN '{}' zakonczony sukcesem", name);
            0
        }
        Err(RunError::NotFound(n)) => {
            eprintln!("blad: brak bloku run o nazwie '{}'", n);
            1
        }
        Err(RunError::Cycle(n)) => {
            eprintln!("blad: wykryto cykl zaleznosci przy '{}'", n);
            1
        }
        Err(RunError::StepFailed(f)) => {
            eprintln!(
                "blad: run '{}' przerwany na step {}",
                f.run_name, f.step_number
            );
            1
        }
    }
}

fn verify_command(log_path: &str) -> i32 {
    match logger::verify_chain(log_path) {
        Ok(count) => {
            println!("OK: {} wpisow, lancuch hashy nienaruszony", count);
            0
        }
        Err(e) => {
            eprintln!("BLAD WERYFIKACJI: {}", e);
            1
        }
    }
}

fn print_usage() {
    eprintln!("uzycie:");
    eprintln!("  ctrlfilesafe run <nazwa-run>");
    eprintln!("  ctrlfilesafe verify [--log <sciezka>]");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        print_usage();
        std::process::exit(1);
    }

    let code = match args[1].as_str() {
        "run" => {
            if args.len() < 3 {
                print_usage();
                std::process::exit(1);
            }
            run_command(&args[2])
        }
        "verify" => {
            let mut log_path = "logs.jsonl".to_string();
            let mut i = 2;
            while i < args.len() {
                if args[i] == "--log" && i + 1 < args.len() {
                    log_path = args[i + 1].clone();
                    i += 2;
                } else {
                    i += 1;
                }
            }
            verify_command(&log_path)
        }
        _ => {
            print_usage();
            1
        }
    };
    std::process::exit(code);
}
