//! Headless driver for the engine: list inputs, index a folder, or follow live audio.
//!   kvj-cli devices
//!   kvj-cli bluetooth                               paired devices, then the KVJ receivers among them
//!   kvj-cli prepare <folder|file>...                 index only, then exit
//!   kvj-cli follow  <folder|file>... [--device ID] [--channel N]
//! Data (Set document and caches) goes to $KVJ_DATA_DIR or the temp directory.
use kvj_engine::{Edit, Engine, Selection};
use std::{path::PathBuf, time::Duration};

fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let command = if args.is_empty() { "help".into() } else { args.remove(0) };
    let mut option = |name: &str| {
        args.iter().position(|a| a == name).map(|i| {
            args.remove(i);
            args.remove(i)
        })
    };
    let device = option("--device").unwrap_or_else(|| "auto".into());
    let channel_start = option("--channel").map_or(Ok(0), |c| c.parse())?;
    let data = std::env::var_os("KVJ_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("kvj-cli"));
    let engine = Engine::new(
        data.clone(),
        Box::new(|view| {
            if let Some(m) = &view.matched {
                println!(
                    "match  {} @ {:.3}s ×{:.3} (confidence {:.2}, lock {})",
                    m.entry.title, m.position, m.rate, m.confidence, m.lock_revision
                );
            }
        }),
    );
    match command.as_str() {
        "devices" => {
            for d in engine.devices()? {
                println!("{:<48} {:>2}ch  {}{}", d.id, d.channels, d.label,
                    d.error.map(|e| format!("  ⚠ {e}")).unwrap_or_default());
            }
        }
        "prepare" | "follow" => {
            anyhow::ensure!(!args.is_empty(), "give at least one folder or file");
            let doc = engine.document()?;
            let doc = match doc.sets.iter().find(|s| s.name == "CLI") {
                Some(_) => doc,
                None => engine.edit(doc.revision, Edit::Create { name: "CLI".into() })?,
            };
            let set = doc.sets.iter().find(|s| s.name == "CLI").unwrap().id.clone();
            let doc = engine.import(&set, doc.revision, &args)?;
            let count = doc.sets.iter().find(|s| s.id == set).map_or(0, |s| s.entries.len());
            println!("data   {} · Set CLI · {count} entries", data.display());
            engine.start(&set, Selection { device, channel_start }, command == "prepare")?;
            let mut cursor = Some(0);
            loop {
                std::thread::sleep(Duration::from_millis(500));
                let status = engine.status(cursor);
                for log in &status.logs {
                    println!("{:<6} {}", format!("{:?}", log.stage).to_lowercase(), log.message);
                    cursor = Some(log.id);
                }
                match status.view.phase.as_str() {
                    "prepared" | "stopped" => break,
                    "failed" => anyhow::bail!("{}", status.view.error),
                    _ => {}
                }
            }
            engine.shutdown();
        }
        "bluetooth" => {
            for d in kvj_engine::bluetooth_paired()? {
                println!("paired {:<20} computer={:<5} {}", d.id, d.computer, d.name);
            }
            for d in engine.bluetooth_scan(false)? {
                println!("KVJ    {:<20} {}", d.id, d.name);
            }
        }
        _ => println!("usage: kvj-cli devices | bluetooth | prepare <paths>... | follow <paths>... [--device ID] [--channel N]"),
    }
    Ok(())
}
