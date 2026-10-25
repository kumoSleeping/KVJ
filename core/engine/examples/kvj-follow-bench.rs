//! Offline follow benchmark: how the live follower does on a Set's own songs heard
//! through a laptop speaker and microphone, and on songs outside the Set.
//!   kvj-follow-bench <kvj-sets.json> <cache dir> [--set N] [--secs S] [--threads T]
//!                    [--bins B] [--only TEXT] [--cond NAME] [--outside FILE]... [--diag]
//! Each round mirrors the engine in room mode: a 0.55 s query every 125 ms, local
//! tracking while locked, otherwise the rescue (tempo bins around the current
//! speed, B per round, each retrieved block verified in rank order), then the
//! recheck of earlier plausible positions, with room corroboration. `--diag`
//! instead reports, per query length, retrieval rank and which gates the true
//! and the best false positions pass.
use anyhow::{Context, Result};
use kvj_engine::decode::decode_audio_from;
use kvj_recognize::{
    recheck_live_prepared, track_live_prepared, verify_live_prepared, Corroboration, LiveFeatureStream,
    LiveFeatures, LiveHint, LiveIndex, SAMPLE_RATE,
};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    io::{BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    sync::{atomic::{AtomicUsize, Ordering}, Mutex},
};

struct Block {
    recording: usize,
    start: f64,
    features: LiveFeatures,
}
struct Clip {
    title: String,
    truth: Option<usize>,
    start: f64,
    pcm: Vec<f32>,
}
#[derive(Clone, Copy)]
struct Condition {
    name: &'static str,
    highpass: f32,
    rt60: f32,
    snr_db: f32,
}
const CONDITIONS: [Condition; 3] = [
    Condition { name: "直连", highpass: 0., rt60: 0., snr_db: 99. },
    Condition { name: "笔记本外放", highpass: 250., rt60: 0.4, snr_db: 20. },
    Condition { name: "嘈杂房间", highpass: 300., rt60: 0.8, snr_db: 10. },
];

fn main() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let diag = args.iter().position(|a| a == "--diag").map(|i| args.remove(i)).is_some();
    let mut take = |name: &str| {
        let mut values = Vec::new();
        while let Some(i) = args.iter().position(|a| a == name) {
            args.remove(i);
            values.push(args.remove(i));
        }
        values
    };
    let set_index: usize = take("--set").pop().map_or(Ok(0), |v| v.parse())?;
    let secs: f64 = take("--secs").pop().map_or(Ok(20.), |v| v.parse())?;
    let threads: usize = take("--threads").pop().map_or(Ok(3), |v| v.parse())?;
    let bins: usize = take("--bins").pop().map_or(Ok(2), |v| v.parse())?;
    let only = take("--only");
    let conditions = take("--cond");
    let outside = take("--outside");
    anyhow::ensure!(args.len() == 2, "usage: kvj-follow-bench <kvj-sets.json> <cache dir> [options]");
    let cache = PathBuf::from(&args[1]);
    std::fs::create_dir_all(&cache)?;
    let doc: serde_json::Value = serde_json::from_slice(&std::fs::read(&args[0])?)?;
    let entries: Vec<(String, String, f64)> = doc["sets"][set_index]["entries"]
        .as_array()
        .context("no such Set")?
        .iter()
        .map(|e| (e["path"].as_str().unwrap().to_string(), e["title"].as_str().unwrap().to_string(), e["duration"].as_f64().unwrap()))
        .collect();

    // The engine's blocks: 316 s windows every 300 s, 8 s of overlap each side.
    let mut blocks = Vec::new();
    for (recording, (path, title, duration)) in entries.iter().enumerate() {
        for core in (0..duration.ceil() as usize).step_by(300) {
            let start = (core as f64 - 8.).max(0.);
            let end = (core as f64 + 308.).min(*duration);
            let mut h = DefaultHasher::new();
            (path, start.to_bits(), end.to_bits(), kvj_recognize::LIVE_FEATURE_REVISION).hash(&mut h);
            let file = cache.join(format!("{:016x}.afp", h.finish()));
            let features = match std::fs::File::open(&file).ok().and_then(|f| LiveFeatures::read_from(BufReader::new(f)).ok()) {
                Some(f) => f,
                None => {
                    eprintln!("提取 {title} {start:.0}–{end:.0} s");
                    let audio = decode_audio_from(Path::new(path), 8000, Some(end - start), start)?;
                    let f = LiveFeatures::prepare(&audio.samples, &|| false)?;
                    let mut w = BufWriter::new(std::fs::File::create(&file)?);
                    f.write_to(&mut w)?;
                    w.flush()?;
                    f
                }
            };
            blocks.push(Block { recording, start, features });
        }
    }
    let mut index = LiveIndex::default();
    for (i, b) in blocks.iter().enumerate() {
        index.add(i, &b.features)?;
    }
    let mut packed = Vec::new();
    index.write_to(&mut packed)?;
    eprintln!("{} 首 / {} 个区块 / {} 条地标", entries.len(), blocks.len(), index.landmark_count());

    let mut clips = Vec::new();
    for (recording, (path, title, duration)) in entries.iter().enumerate() {
        if !only.is_empty() && !only.iter().any(|o| title.contains(o.as_str())) {
            continue;
        }
        if *duration < secs + 20. {
            continue;
        }
        let start = (duration * 0.35).floor();
        let pcm = decode_audio_from(Path::new(path), 8000, Some(secs), start)?.samples;
        clips.push(Clip { title: title.clone(), truth: Some(recording), start, pcm });
    }
    for path in &outside {
        let audio = decode_audio_from(Path::new(path), 8000, None, 0.)?;
        let start = (audio.samples.len() as f64 / 8000. * 0.35).floor();
        let s = start as usize * 8000;
        let pcm = audio.samples[s..(s + (secs * 8000.) as usize).min(audio.samples.len())].to_vec();
        let title = Path::new(path).file_stem().unwrap().to_string_lossy().into_owned();
        clips.push(Clip { title, truth: None, start, pcm });
    }

    let conditions: Vec<Condition> = CONDITIONS
        .into_iter()
        .filter(|c| conditions.is_empty() || conditions.iter().any(|n| n == c.name))
        .collect();
    let jobs: Vec<(usize, Condition)> = conditions
        .iter()
        .flat_map(|&c| (0..clips.len()).map(move |i| (i, c)))
        .collect();
    if diag {
        return diagnose(&packed, &blocks, &clips, &conditions, threads);
    }
    let next = AtomicUsize::new(0);
    let results = Mutex::new(Vec::new());
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| {
                let mut index = LiveIndex::read_from(&packed[..]).unwrap();
                index.warm(&|| false).unwrap();
                loop {
                    let job = next.fetch_add(1, Ordering::Relaxed);
                    let Some(&(clip, condition)) = jobs.get(job) else { break };
                    let heard = degrade(&clips[clip].pcm, condition, clip as u32 + 1);
                    let tally = follow(&mut index, &blocks, &clips[clip], &heard, bins);
                    results.lock().unwrap().push((job, tally));
                }
            });
        }
    });
    let mut results = results.into_inner().unwrap();
    results.sort_by_key(|r| r.0);
    for &condition in &conditions {
        println!("== {} ==", condition.name);
        let mut total = Tally::default();
        let (mut locked, mut inside) = (0, 0);
        for (job, t) in &results {
            if jobs[*job].1.name != condition.name {
                continue;
            }
            let clip = &clips[jobs[*job].0];
            println!(
                "  {:<28} {:>6} {:>5.0}% 正确  错收 {:>3}（别的歌 {}；跟踪/门槛/印证/复核 {:?}）  错跳 {:>2}  首锁 {}",
                clip.title.chars().take(28).collect::<String>(),
                if clip.truth.is_some() { "Set" } else { "Set 外" },
                100. * t.shown as f64 / t.rounds.max(1) as f64,
                t.wrong,
                t.other,
                t.wrong_via,
                t.wrong_jumps,
                t.first.map_or("—".into(), |f| format!("{f:.1} s")),
            );
            if clip.truth.is_some() {
                inside += 1;
                locked += usize::from(t.first.is_some());
            }
            if clip.truth.is_some() {
                total.rounds += t.rounds;
                total.shown += t.shown;
            }
            total.wrong += t.wrong;
            total.wrong_jumps += t.wrong_jumps;
            total.other += t.other;
            for k in 0..4 {
                total.wrong_via[k] += t.wrong_via[k];
            }
            total.accepted += t.accepted;
        }
        let firsts: Vec<f64> = results
            .iter()
            .filter(|(j, _)| jobs[*j].1.name == condition.name)
            .filter_map(|(_, t)| t.first)
            .collect();
        let mut sorted = firsts.clone();
        sorted.sort_by(f64::total_cmp);
        println!(
            "  合计：锁定 {locked}/{inside} 首 · Set 内画面正确 {:.1}% 轮 · 首锁中位 {} · 错收 {}（别的歌 {}；跟踪/门槛/印证/复核 {:?}）/ 接受 {} · 错跳 {}",
            100. * total.shown as f64 / total.rounds.max(1) as f64,
            sorted.get(sorted.len() / 2).map_or("—".into(), |m| format!("{m:.2} s")),
            total.wrong,
            total.other,
            total.wrong_via,
            total.accepted,
            total.wrong_jumps
        );
    }
    Ok(())
}

/// A laptop speaker in a room heard by its own microphone: no bass, early
/// reflections and a reverberant tail, then pink noise at `snr_db`.
fn degrade(pcm: &[f32], c: Condition, seed: u32) -> Vec<f32> {
    let mut y: Vec<f32> = pcm.iter().map(|x| x * 0.4).collect();
    if c.highpass > 0. {
        for _ in 0..2 {
            y = highpass(&y, c.highpass);
        }
    }
    if c.rt60 > 0. {
        y = room(&y, c.rt60);
    }
    if c.snr_db < 90. {
        let rms = (y.iter().map(|x| x * x).sum::<f32>() / y.len() as f32).sqrt();
        let mut state = seed;
        let mut b = [0f32; 3];
        let noise: Vec<f32> = (0..y.len())
            .map(|_| {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                let white = state as f32 / u32::MAX as f32 - 0.5;
                b[0] = 0.99765 * b[0] + white * 0.0990460;
                b[1] = 0.96300 * b[1] + white * 0.2965164;
                b[2] = 0.57000 * b[2] + white * 1.0526913;
                b[0] + b[1] + b[2] + white * 0.1848
            })
            .collect();
        let nrms = (noise.iter().map(|x| x * x).sum::<f32>() / noise.len() as f32).sqrt();
        let gain = rms / nrms / 10f32.powf(c.snr_db / 20.);
        for (v, n) in y.iter_mut().zip(noise) {
            *v += gain * n;
        }
    }
    y
}
fn highpass(x: &[f32], cutoff: f32) -> Vec<f32> {
    let w = std::f32::consts::TAU * cutoff / SAMPLE_RATE as f32;
    let alpha = w.sin() / (2. * std::f32::consts::FRAC_1_SQRT_2);
    let (b0, b1, b2) = ((1. + w.cos()) / 2., -(1. + w.cos()), (1. + w.cos()) / 2.);
    let (a0, a1, a2) = (1. + alpha, -2. * w.cos(), 1. - alpha);
    let (mut x1, mut x2, mut y1, mut y2) = (0., 0., 0., 0.);
    x.iter()
        .map(|&v| {
            let out = (b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
            (x2, x1, y2, y1) = (x1, v, y1, out);
            out
        })
        .collect()
}
/// The recognizer tests' room: early reflections, then a dense tail falling
/// 60 dB in `rt60` seconds and carrying more energy than the direct sound.
fn room(pcm: &[f32], rt60: f32) -> Vec<f32> {
    let rate = SAMPLE_RATE as f32;
    let samples = |ms: f32| (ms * rate / 1000.) as usize;
    let mut combs: Vec<(Vec<f32>, f32, usize)> = [29.7, 37.1, 41.1, 43.7]
        .iter()
        .map(|&ms| {
            let d = samples(ms);
            (vec![0.; d], 10f32.powf(-3. * d as f32 / rate / rt60), 0)
        })
        .collect();
    let mut allpasses: Vec<(Vec<f32>, usize)> =
        [5., 1.7].iter().map(|&ms| (vec![0.; samples(ms)], 0)).collect();
    let wet: Vec<f32> = pcm
        .iter()
        .map(|&x| {
            let mut y = 0.;
            for (line, g, i) in &mut combs {
                let out = line[*i];
                line[*i] = x + *g * out;
                *i = (*i + 1) % line.len();
                y += out / 4.;
            }
            for (line, i) in &mut allpasses {
                let delayed = line[*i];
                let v = y + 0.7 * delayed;
                line[*i] = v;
                *i = (*i + 1) % line.len();
                y = delayed - 0.7 * v;
            }
            y
        })
        .collect();
    let rms = |s: &[f32]| (s.iter().map(|x| x * x).sum::<f32>() / s.len() as f32).sqrt();
    let gain = 1.4 * rms(pcm) / rms(&wet).max(1e-9);
    let early = [(7., 0.6), (13., 0.45), (19., 0.35)];
    (0..pcm.len())
        .map(|n| {
            let mut y = pcm[n];
            for &(ms, g) in &early {
                if let Some(k) = n.checked_sub(samples(ms)) {
                    y += g * pcm[k];
                }
            }
            y + gain * wet[n]
        })
        .collect()
}

#[derive(Default, Debug)]
struct Tally {
    rounds: usize,
    /// Rounds where the followed position is the right recording within 0.3 s.
    shown: usize,
    accepted: usize,
    /// Accepted observations at the wrong recording or more than 0.5 s off.
    wrong: usize,
    /// Locks (new recording or a cut of 2.5 s or more) onto something wrong.
    wrong_jumps: usize,
    /// Of `wrong`, those at another recording (or any, outside the Set).
    other: usize,
    /// Of `wrong`, by how they were accepted (see `Held::via`).
    wrong_via: [usize; 4],
    first: Option<f64>,
}
#[derive(Clone, Copy)]
struct Held {
    target: usize,
    recording: usize,
    position: f64,
    at: f64,
    rate: f64,
    /// How it was accepted: 0 local track, 1 rescue gates, 2 rescue corroborated, 3 recheck.
    via: usize,
}
impl Held {
    fn now(&self, t: f64) -> f64 {
        self.position + (t - self.at) * self.rate
    }
}
/// A plausible position seen while searching, rechecked until confirmed or stale.
#[derive(Clone, Copy)]
struct Candidate {
    held: Held,
    retrieval_score: f64,
}
fn remember(candidates: &mut Vec<Candidate>, c: Candidate) {
    candidates.retain(|old| {
        old.held.recording != c.held.recording || (old.held.now(c.held.at) - c.held.position).abs() >= 0.15
    });
    candidates.push(c);
    if candidates.len() > 6 {
        candidates.remove(0);
    }
}
fn place(block: &Block, query: &LiveFeatures, offset: f64, rate: f64) -> f64 {
    block.start + LiveFeatures::origin_seconds() + offset + query.duration_ms() / 1000. * rate
}
fn hint(block: &Block, query: &LiveFeatures, held: Held, at: f64) -> LiveHint {
    LiveHint {
        offset_seconds: held.now(at) - query.duration_ms() / 1000. * held.rate - block.start - LiveFeatures::origin_seconds(),
        rate: held.rate,
    }
}
#[allow(clippy::too_many_arguments)]
fn rescue_at(
    index: &mut LiveIndex,
    blocks: &[Block],
    query: &LiveFeatures,
    rate: f64,
    at: f64,
    corroboration: &mut Corroboration,
    candidates: &mut Vec<Candidate>,
) -> Option<Held> {
    let seeds = index.search_slice_at_rate(query, rate, &|| false).unwrap();
    let mut targets = Vec::new();
    for seed in &seeds {
        if !targets.contains(&seed.target) {
            targets.push(seed.target);
        }
    }
    for target in targets {
        let selected: Vec<_> = seeds.iter().filter(|s| s.target == target).copied().collect();
        let r = verify_live_prepared(query, &blocks[target].features, &selected, true, &|| false).unwrap();
        let p = place(&blocks[target], query, r.offset_seconds, r.rate);
        let held = Held { target, recording: blocks[target].recording, position: p, at, rate: r.rate, via: 1 };
        if r.matched || r.supported {
            return Some(held);
        }
        if r.plausible && corroboration.confirm(at, held.recording, p, r.rate) {
            return Some(Held { via: 2, ..held });
        }
        if r.plausible {
            remember(candidates, Candidate { held, retrieval_score: r.retrieval_score });
        }
    }
    None
}
/// The engine's recheck: earlier candidates where they should be now, taken only
/// on a spaced agreement.
fn recheck(blocks: &[Block], query: &LiveFeatures, at: f64, corroboration: &mut Corroboration, candidates: &mut Vec<Candidate>) -> Option<Held> {
    candidates.retain(|c| at - c.held.at <= 2.);
    for i in 0..candidates.len() {
        let c = candidates[i];
        if c.held.at == at {
            continue;
        }
        let block = &blocks[c.held.target];
        let r = recheck_live_prepared(query, &block.features, hint(block, query, c.held, at), c.retrieval_score, &|| false).unwrap();
        if !(r.matched || r.supported || r.plausible) {
            continue;
        }
        let held = Held { target: c.held.target, recording: c.held.recording, position: place(block, query, r.offset_seconds, r.rate), at, rate: r.rate, via: 3 };
        if corroboration.confirm(at, held.recording, held.position, held.rate) {
            return Some(held);
        }
        candidates[i].held = held;
    }
    None
}
fn track(blocks: &[Block], query: &LiveFeatures, old: Held, at: f64) -> Option<Held> {
    let block = &blocks[old.target];
    let r = track_live_prepared(query, &block.features, hint(block, query, old, at), &|| false).unwrap();
    (r.matched || r.supported).then(|| Held {
        target: old.target,
        recording: old.recording,
        position: place(block, query, r.offset_seconds, r.rate),
        at,
        rate: r.rate,
        via: 0,
    })
}
fn follow(index: &mut LiveIndex, blocks: &[Block], clip: &Clip, heard: &[f32], bins: usize) -> Tally {
    let mut tally = Tally::default();
    let mut stream = LiveFeatureStream::new(400);
    let mut corroboration = Corroboration::default();
    let mut candidates = Vec::new();
    let mut current: Option<Held> = None;
    let mut cursor = 0;
    let step = SAMPLE_RATE / 8;
    let correct = |recording: usize, pos: f64, at: f64, tolerance: f64| {
        clip.truth == Some(recording) && (pos - (clip.start + at)).abs() < tolerance
    };
    for from in (0..heard.len().saturating_sub(step)).step_by(step) {
        stream.push(&heard[from..from + step], &|| false).unwrap();
        let Some((query, tail)) = stream.recent(0.55) else { continue };
        // Seconds of the clip at the end of the query.
        let at = (from + step) as f64 / SAMPLE_RATE as f64 - tail;
        let mut chosen = current.filter(|c| at - c.at < 2.).and_then(|old| track(blocks, &query, old, at));
        if chosen.is_some() {
            cursor = 0;
        } else {
            let preferred = current.map_or(1., |c| c.rate);
            let mut rates: [f64; 19] = std::array::from_fn(|i| 0.80 + i as f64 * 0.025);
            rates.sort_by(|a, b| (a - preferred).abs().total_cmp(&(b - preferred).abs()));
            let mut searched = 0;
            for (s, rate) in std::iter::once(preferred).chain(rates).enumerate().skip(cursor) {
                cursor = s + 1;
                if s > 0 && (rate - preferred).abs() < 0.001 {
                    continue;
                }
                chosen = rescue_at(index, blocks, &query, rate, at, &mut corroboration, &mut candidates);
                searched += 1;
                if chosen.is_some() || searched >= bins {
                    break;
                }
            }
            if chosen.is_none() {
                chosen = recheck(blocks, &query, at, &mut corroboration, &mut candidates);
            }
            if chosen.is_some() || cursor >= 20 {
                cursor = 0;
            }
        }
        if let Some(c) = chosen {
            candidates.clear();
            tally.accepted += 1;
            let right = correct(c.recording, c.position, at, 0.5);
            if !right {
                tally.wrong += 1;
                tally.other += usize::from(clip.truth != Some(c.recording));
                tally.wrong_via[c.via] += 1;
            }
            let jumped = current.is_none_or(|old| old.recording != c.recording || (old.now(at) - c.position).abs() >= 2.5);
            if jumped && !right {
                tally.wrong_jumps += 1;
            }
            if right && tally.first.is_none() {
                tally.first = Some(at);
            }
            current = Some(c);
        }
        tally.rounds += 1;
        if current.is_some_and(|c| correct(c.recording, c.now(at), at, 0.3)) {
            tally.shown += 1;
        }
    }
    tally
}

/// Per query length: where retrieval ranks the true position, which gate the
/// true position passes when verified alone, and which the best false one passes.
fn diagnose(packed: &[u8], blocks: &[Block], clips: &[Clip], conditions: &[Condition], threads: usize) -> Result<()> {
    const LENGTHS: [f64; 4] = [0.55, 1., 2., 3.];
    #[derive(Default, Clone, Copy)]
    struct Row {
        n: usize,
        top1: usize,
        top5: usize,
        // matched or supported / plausible
        true_strict: usize,
        true_plausible: usize,
        false_strict: usize,
        false_plausible: usize,
        ms: f64,
    }
    for &condition in conditions {
        let next = AtomicUsize::new(0);
        let rows = Mutex::new([[Row::default(); LENGTHS.len()]; 2]);
        std::thread::scope(|s| {
            for _ in 0..threads {
                s.spawn(|| {
                    let mut index = LiveIndex::read_from(packed).unwrap();
                    index.warm(&|| false).unwrap();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(clip) = clips.get(i) else { break };
                        let heard = degrade(&clip.pcm, condition, i as u32 + 1);
                        let mut stream = LiveFeatureStream::new(400);
                        let step = SAMPLE_RATE / 2;
                        let mut local = [[Row::default(); LENGTHS.len()]; 2];
                        for from in (0..heard.len().saturating_sub(step)).step_by(step) {
                            stream.push(&heard[from..from + step], &|| false).unwrap();
                            for (l, &length) in LENGTHS.iter().enumerate() {
                                let Some((query, tail)) = stream.recent(length) else { continue };
                                let at = (from + step) as f64 / SAMPLE_RATE as f64 - tail;
                                let started = std::time::Instant::now();
                                let seeds = index.search_slice_at_rate(&query, 1., &|| false).unwrap();
                                let row = &mut local[usize::from(clip.truth.is_none())][l];
                                row.ms += started.elapsed().as_secs_f64() * 1000.;
                                row.n += 1;
                                let place = |t: usize, offset: f64| {
                                    blocks[t].start + LiveFeatures::origin_seconds() + offset + query.duration_ms() / 1000.
                                };
                                let truth = |t: usize, offset: f64| {
                                    clip.truth == Some(blocks[t].recording) && (place(t, offset) - (clip.start + at)).abs() < 0.15
                                };
                                if let Some(rank) = seeds.iter().position(|s| truth(s.target, s.offset_seconds)) {
                                    row.top1 += usize::from(rank == 0);
                                    row.top5 += usize::from(rank < 5);
                                }
                                // The true position verified alone, seeded where it is.
                                if let Some(recording) = clip.truth {
                                    let target = blocks
                                        .iter()
                                        .enumerate()
                                        .filter(|(_, b)| b.recording == recording)
                                        .map(|(t, _)| t)
                                        .find(|&t| clip.start + at - blocks[t].start < 310.)
                                        .unwrap();
                                    let offset = clip.start + at - blocks[target].start - LiveFeatures::origin_seconds() - query.duration_ms() / 1000.;
                                    let seed = kvj_recognize::LiveSeed { target, offset_seconds: offset, rate: 1., retrieval_score: 1. };
                                    let r = verify_live_prepared(&query, &blocks[target].features, &[seed], true, &|| false).unwrap();
                                    row.true_strict += usize::from(r.matched || r.supported);
                                    row.true_plausible += usize::from(r.plausible);
                                }
                                // The best false target, as the rescue would verify it.
                                let mut targets = Vec::new();
                                for seed in &seeds {
                                    if !targets.contains(&seed.target) {
                                        targets.push(seed.target);
                                    }
                                }
                                let (mut strict, mut plausible) = (false, false);
                                for target in targets.into_iter().take(3) {
                                    let selected: Vec<_> = seeds
                                        .iter()
                                        .filter(|s| s.target == target && !truth(s.target, s.offset_seconds))
                                        .copied()
                                        .collect();
                                    if selected.is_empty() {
                                        continue;
                                    }
                                    let r = verify_live_prepared(&query, &blocks[target].features, &selected, true, &|| false).unwrap();
                                    if truth(target, r.offset_seconds) {
                                        continue;
                                    }
                                    strict |= r.matched || r.supported;
                                    plausible |= r.plausible;
                                }
                                row.false_strict += usize::from(strict);
                                row.false_plausible += usize::from(plausible);
                            }
                        }
                        let mut all = rows.lock().unwrap();
                        for k in 0..2 {
                            for l in 0..LENGTHS.len() {
                                let (a, b) = (&mut all[k][l], local[k][l]);
                                a.n += b.n;
                                a.top1 += b.top1;
                                a.top5 += b.top5;
                                a.true_strict += b.true_strict;
                                a.true_plausible += b.true_plausible;
                                a.false_strict += b.false_strict;
                                a.false_plausible += b.false_plausible;
                                a.ms += b.ms;
                            }
                        }
                    }
                });
            }
        });
        let rows = rows.into_inner().unwrap();
        println!("== {} ==", condition.name);
        for (k, name) in ["Set 内", "Set 外"].iter().enumerate() {
            for (l, length) in LENGTHS.iter().enumerate() {
                let r = rows[k][l];
                let pct = |v: usize| 100. * v as f64 / r.n.max(1) as f64;
                println!(
                    "  {name} {length:.2} s · {:>4} 次 · 检索第一 {:5.1}% 前五 {:5.1}% · 真位置 通过 {:5.1}% 待印证 {:5.1}% · 假位置 通过 {:5.2}% 待印证 {:5.1}% · 检索 {:.0} ms",
                    r.n, pct(r.top1), pct(r.top5), pct(r.true_strict), pct(r.true_plausible),
                    pct(r.false_strict), pct(r.false_plausible), r.ms / r.n.max(1) as f64
                );
            }
        }
    }
    Ok(())
}
