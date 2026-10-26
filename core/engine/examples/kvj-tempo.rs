//! The timeline's tempo sections of media files, uncached:
//!   kvj-tempo <file>...            a line a section
//!   kvj-tempo --json <file>...     the sections as kvj_tempo hands them over
use kvj_engine::rhythm;
use std::{path::Path, time::Instant};

fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().position(|a| a == "--json").map(|i| args.remove(i)).is_some();
    let clock = |t: f64| format!("{}:{:04.1}", (t / 60.) as u32, t % 60.);
    for path in &args {
        let started = Instant::now();
        let Some(tempo) = rhythm::analyse(Path::new(path), &|| false)? else { continue };
        if json {
            println!("{}", serde_json::to_string(&tempo)?);
            continue;
        }
        println!("{path}  {:.0} s, {} sections, {:.1} s", tempo.duration, tempo.sections.len(), started.elapsed().as_secs_f64());
        for s in &tempo.sections {
            let bpm = s.bpm.map_or("    ?".into(), |b| format!("{b:5.1}"));
            println!("  {:>7}–{:<7} {bpm}  {:4.0} s  c {:.2}", clock(s.start), clock(s.end), s.end - s.start, s.confidence);
        }
    }
    Ok(())
}
