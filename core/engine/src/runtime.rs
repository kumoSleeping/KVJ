//! One recognition worker and one playback clock. Follow a verified local match;
//! search on a miss and publish the first verified rescue immediately. No second
//! acceptance gate, confirmation history, or periodic tempo audit.
use super::{
    clock_ms,
    diagnostics::{InputState, Level, ListenerState, ListenerStatus, ScanResult, Stage},
    document::Set,
    index::{self, PreparedSet},
    now_ms, Engine, Match, View,
};
use anyhow::{bail, Result};
use kvj_recognize::{
    recheck_live_prepared, Corroboration, LiveAlignment, LiveFeatures, LiveHint,
    FEATURE_MEMORY_BUDGET,
};
use std::{
    collections::VecDeque,
    fs,
    io::BufReader,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};


pub(super) fn publish(engine: &Engine, id: &str, edit: impl FnOnce(&mut View)) {
    engine.update(id, edit);
}
pub(super) fn log(engine: &Engine, session: &str, level: Level, stage: Stage, message: String) {
    engine.log(session, level, stage, message);
}
struct FeatureCache(VecDeque<(PathBuf, Arc<LiveFeatures>)>);
impl FeatureCache {
    fn get(&mut self, path: &Path) -> Result<Arc<LiveFeatures>> {
        if let Some(i) = self.0.iter().position(|(p, _)| p == path) {
            let pair = self.0.remove(i).unwrap();
            let value = pair.1.clone();
            self.0.push_back(pair);
            return Ok(value);
        }
        let value = Arc::new(LiveFeatures::read_from(BufReader::new(fs::File::open(
            path,
        )?))?);
        while self.0.iter().map(|(_, f)| f.memory_bytes()).sum::<usize>() + value.memory_bytes()
            > FEATURE_MEMORY_BUDGET
        {
            if self.0.pop_front().is_none() {
                break;
            }
        }
        self.0.push_back((path.to_owned(), value.clone()));
        Ok(value)
    }
}
#[derive(Clone, Copy)]
struct Evidence {
    target: usize,
    recording: usize,
    position: f64,
    at: Instant,
    rate: f64,
    score: f64,
    margin: f64,
}
impl Evidence {
    fn now(&self) -> f64 {
        self.position + self.at.elapsed().as_secs_f64() * self.rate
    }
    fn same_position(&self, other: &Self) -> bool {
        self.recording == other.recording && (self.now() - other.now()).abs() < 0.15
    }
    fn discontinuity(&self, other: &Self) -> bool {
        // Keep sub-2.5s corrections on the visible decoder's live rate plan.
        // Acoustic agreement remains stricter; it must not define presentation cuts.
        self.recording != other.recording || (self.now() - other.now()).abs() >= 2.5
    }
    fn agrees(&self, other: &Self) -> bool {
        self.same_position(other) && (self.rate - other.rate).abs() < 0.06
    }
    /// `later`, heard at least `CONFIRM_AFTER` s after this one on mostly new
    /// audio, is where this one said the music would be by then.
    fn confirmed_by(&self, later: &Self) -> bool {
        later.at.saturating_duration_since(self.at).as_secs_f64() >= CONFIRM_AFTER
            && self.recording == later.recording
            && (self.now() - later.now()).abs() < 0.25
            && (self.rate - later.rate).abs() < 0.06
    }
}
/// A jump away from the place the picture shows (another entry, or 2.5 s or
/// more within one) is taken only once a second observation, heard at least
/// this long after the first, lands where the first said the music would be.
/// One round can align by chance, most often just after the DJ jumps, while
/// the 550 ms query still holds the audio from before: the picture would cut
/// there and, a moment later, back. Queries this far apart share little audio.
const CONFIRM_AFTER: f64 = 0.5;
/// Unconfirmed jumps are kept this long, at most this many.
const PENDING_SECONDS: f64 = 3.;
const PENDING_MAX: usize = 6;
/// Room mode, searching: a plausible position not yet confirmed. Retrieval seldom
/// ranks a reverberant song's position first twice, so once found it is checked
/// again each round where the music should be by now.
#[derive(Clone, Copy)]
struct Candidate {
    found: Evidence,
    retrieval_score: f64,
}
fn remember(candidates: &mut Vec<Candidate>, candidate: Candidate) {
    let c = candidate.found;
    candidates.retain(|old| {
        let since = c.at.saturating_duration_since(old.found.at).as_secs_f64();
        old.found.recording != c.recording
            || (old.found.position + since * old.found.rate - c.position).abs() >= 0.15
    });
    candidates.push(candidate);
    if candidates.len() > 6 {
        candidates.remove(0);
    }
}
/// Tempo is a slope across observations, not the noisy slope of one second.
/// Never turn every acoustic grid refinement into a playbackRate write.
struct ClockEstimate {
    points: VecDeque<Evidence>,
    rate: f64,
    updated: Instant,
}
impl ClockEstimate {
    fn new(found: Evidence) -> Self {
        Self {
            points: VecDeque::new(),
            rate: (found.rate * 200.).round() / 200.,
            updated: found.at,
        }
    }
    fn observe(&mut self, found: Evidence) -> (f64, f64, f64) {
        if self.points.back().is_some_and(|old| !found.agrees(old)) {
            *self = Self::new(found);
        }
        self.points.push_back(found);
        while self.points.len() > 32
            || self
                .points
                .front()
                .is_some_and(|p| found.at.saturating_duration_since(p.at).as_secs_f64() > 3.)
        {
            self.points.pop_front();
        }
        let first = self.points.front().unwrap();
        let span = found.at.saturating_duration_since(first.at).as_secs_f64();
        if span < 1. || self.points.len() < 5 {
            return (found.position, self.rate, 0.);
        }
        let n = self.points.len() as f64;
        let mx = self
            .points
            .iter()
            .map(|p| p.at.saturating_duration_since(first.at).as_secs_f64())
            .sum::<f64>()
            / n;
        let my = self.points.iter().map(|p| p.position).sum::<f64>() / n;
        let mut xx = 0.;
        let mut xy = 0.;
        for p in &self.points {
            let x = p.at.saturating_duration_since(first.at).as_secs_f64() - mx;
            xx += x * x;
            xy += x * (p.position - my);
        }
        let slope = xy / xx.max(1e-9);
        let residual = (self
            .points
            .iter()
            .map(|p| {
                let x = p.at.saturating_duration_since(first.at).as_secs_f64();
                (p.position - my - slope * (x - mx)).powi(2)
            })
            .sum::<f64>()
            / n)
            .sqrt();
        if !(0.80..=1.25).contains(&slope) || residual > 0.04 {
            return (found.position, self.rate, 0.);
        }
        // Within 1% the slope is mostly the fit's own noise; the position,
        // re-anchored on every observation, takes up a real difference that small.
        if found
            .at
            .saturating_duration_since(self.updated)
            .as_secs_f64()
            >= 0.5
            && (slope - self.rate).abs() >= 0.01
        {
            self.rate = (slope * 500.).round() / 500.;
            self.updated = found.at;
        }
        (
            my + slope * (span - mx),
            self.rate,
            (1. - residual / 0.04) * (span / 2.).min(1.),
        )
    }
}
/// Recording position (seconds) at the end of `query`.
fn position(set: &PreparedSet, target: usize, query: &LiveFeatures, result: &LiveAlignment) -> f64 {
    let block = &set.targets[target];
    block.start
        + set.recordings[block.recording].entry.audio_offset
        + LiveFeatures::origin_seconds()
        + result.offset_seconds
        + query.duration_ms() / 1000. * result.rate
}
/// `corroborated`: room mode confirmed a plausible result over time.
#[allow(clippy::too_many_arguments)]
fn record(
    set: &PreparedSet,
    target: usize,
    query: &LiveFeatures,
    at: Instant,
    result: &LiveAlignment,
    corroborated: bool,
    elapsed_ms: f64,
    scanned: &mut Vec<ScanResult>,
) -> Option<Evidence> {
    let block = &set.targets[target];
    let recording = &set.recordings[block.recording];
    tracing::debug!(target: "kvj_probe", target, block_start = block.start,
        query_ms = query.duration_ms(), capture_clock_ms = clock_ms() - at.elapsed().as_secs_f64() * 1000.,
        offset = result.offset_seconds, rate = result.rate, score = result.score,
        weakest = result.weakest_score, runner_up = result.runner_up, support = result.retrieval_score,
        matched = result.matched, supported = result.supported, plausible = result.plausible,
        corroborated, elapsed_ms, "verification");
    let accepted = result.matched || result.supported || corroborated;
    scanned.push(ScanResult {
        entry_id: recording.entry.id.clone(),
        title: recording.entry.title.clone(),
        block_start: block.start,
        elapsed_ms,
        matched: accepted,
        reason: format!(
            "{} · 位置 {:.3} s · 得分 {:.3} / 最弱窗 {:.3} / 次选 {:.3} · {:.3}×",
            if result.matched || result.supported {
                "定位通过"
            } else if corroborated {
                "现场印证通过"
            } else {
                &result.reason
            },
            position(set, target, query, result),
            result.score,
            result.weakest_score,
            result.runner_up,
            result.rate
        ),
    });
    // The acoustic matcher is the sole acceptance authority. A supported
    // short-window result is usable now, not a request for another confirmation.
    accepted.then_some(Evidence {
        target,
        recording: block.recording,
        position: position(set, target, query, result),
        at,
        rate: result.rate,
        score: result.score,
        margin: result.score - result.runner_up,
    })
}
fn presentation(
    set: &PreparedSet,
    found: Evidence,
    rate_confidence: f64,
    lock_revision: u64,
) -> Match {
    let age = found.at.elapsed().as_secs_f64() * 1000.;
    Match {
        entry: set.recordings[found.recording].entry.clone(),
        position: found.position,
        observed_at_ms: now_ms() - age,
        clock_at_ms: clock_ms() - age,
        rate: found.rate,
        confidence: found.score,
        margin: found.margin,
        rate_confidence,
        lock_revision,
    }
}
pub fn run(
    engine: &Arc<Engine>,
    session: String,
    set: Set,
    cache: PathBuf,
    cancel: Arc<AtomicBool>,
    prepare_only: bool,
    input: super::audio_input::Selection,
    track: u8,
) {
    let _background = super::qos::prefer_background();
    // A panic (a decoder library on a damaged file) fails the session, which
    // says so, instead of leaving it on "indexing" with its thread gone.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
        publish(&engine, &session, |v| {
            let preparing = ListenerStatus {
                state: ListenerState::Preparing,
                ..Default::default()
            };
            v.rescue = Some(preparing.clone());
            v.tracking = Some(preparing);
        });
        let ready = index::prepare(&engine, &session, &set, &cache, &cancel)?;
        if cancel.load(Ordering::Relaxed) {
            return Ok(());
        }
        if prepare_only {
            publish(&engine, &session, |v| v.phase = "prepared".into());
            return Ok(());
        }
        run_inner(&engine, &session, &ready, &cancel, &input, track)
    }))
    .unwrap_or_else(|_| Err(anyhow::anyhow!("引擎内部错误，请重新开始")));
    if cancel.load(Ordering::Relaxed) {
        return;
    }
    if let Err(error) = result {
        log(
            &engine,
            &session,
            Level::Error,
            Stage::Session,
            format!("会话失败：{error:#}"),
        );
        publish(&engine, &session, |v| {
            v.phase = "failed".into();
            v.error = format!("{error:#}");
            v.scanning = None;
        });
    }
}
fn run_inner(engine: &Arc<Engine>, session: &str, set: &PreparedSet, cancel: &AtomicBool, input: &super::audio_input::Selection, track: u8) -> Result<()> {
    {
        if set.recordings.is_empty() {
            bail!("Set 没有素材")
        }
        super::qos::prefer_live_audio();
        publish(engine, session, |v| v.phase = "permission".into());
        // Opened once here (a refusal ends the session); lost later, it is
        // reopened while the session goes on.
        let mut source = Some(super::feature_input::Input::start(engine, input)?);
        let mut reopen_at = Instant::now();
        // A loopback that went quiet is reopened (no error ever comes): when it
        // was (re)opened, the next wait in seconds, and whether one was.
        let loopback = input.loopback();
        let (mut opened, mut stall_wait, mut stall_reopened) = (Instant::now(), 3u64, false);
        // A loopback that never heard music hints at an output it cannot hear.
        let (session_started, mut heard_music, mut hinted) = (Instant::now(), false, false);
        publish(engine, session, |v| v.phase = "listening".into());
        log(
            engine,
            session,
            Level::Info,
            Stage::Input,
            "声音输入已启动 · 短窗地标检索 / 增量特征 / 音频包时间戳".into(),
        );
        log(
            engine,
            session,
            Level::Info,
            Stage::Scan,
            "监听就绪 · 550 ms 音频窗 / 远跳经两次印证 / 失锁时逐档检索".into(),
        );
        let room = input.room;
        if room {
            log(
                engine,
                session,
                Level::Info,
                Stage::Scan,
                "现场模式 · 混响下的较弱证据在 3 s 内三次一致（窗口互不重叠）即采用，待印证位置逐轮复核".into(),
            );
        }
        let mut corroboration = Corroboration::default();
        let mut candidates: Vec<Candidate> = Vec::new();
        // Jumps away from the shown place, heard once, not yet confirmed.
        let mut pending: Vec<Evidence> = Vec::new();
        // When local tracking began to hold, round after round.
        let mut held_since: Option<Instant> = None;
        let mut generation = 0;
        let mut input_epoch = 0;
        let mut features = FeatureCache(VecDeque::new());
        let mut current: Option<Evidence> = None;
        let mut estimate: Option<ClockEstimate> = None;
        let mut lost = false;
        let mut scan = 0;
        // Resume the remaining tempo bins on fresh audio instead of blocking
        // one observation behind an exhaustive 19-rate search.
        let mut search_cursor = 0;
        let mut last_input_state = None;
        let mut lock_revision = 0;
        let mut rescue_status = ListenerStatus::default();
        let mut tracking_status = ListenerStatus::default();
        let mut source_checked = Instant::now();
        let mut last_rejection: Option<Instant> = None;
        let (mut last_notice, mut notices): (Option<Instant>, u32) = (None, 0);
        // Recordings left out of the search for now: their file is gone or
        // changed (back once it is as it was), or their features are unreadable.
        let mut unavailable = vec![false; set.recordings.len()];
        let mut unreadable = vec![false; set.recordings.len()];
        while !cancel.load(Ordering::Relaxed) {
            let tick = Instant::now();
            let polled = match source.as_mut().map(|s| s.poll(cancel)) {
                Some(Ok(polled)) => polled,
                failed => {
                    if cancel.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                    // An unplugged interface, a driver hiccup or a changed output
                    // format must not end following during a show.
                    if let Some(Err(error)) = failed {
                        source = None;
                        reopen_at = Instant::now() + Duration::from_secs(2);
                        log(engine, session, Level::Warn, Stage::Input, format!("声音输入中断：{error:#}；正在重新打开"));
                        if current.is_some() {
                            publish(engine, session, |v| v.phase = "searching".into());
                        }
                        current = None; estimate = None; lost = false;
                        generation = 0; search_cursor = 0; corroboration.clear(); pending.clear();
                    } else if Instant::now() >= reopen_at {
                        match super::feature_input::Input::start(engine, input) {
                            Ok(reopened) => {
                                source = Some(reopened);
                                opened = Instant::now();
                                // Reopened for want of packets: recovered once they come.
                                if !stall_reopened {
                                    log(engine, session, Level::Info, Stage::Input, "声音输入已恢复".into());
                                }
                                continue;
                            }
                            Err(error) => {
                                reopen_at = Instant::now() + Duration::from_secs(2);
                                tracing::debug!("reopening input failed: {error:#}");
                            }
                        }
                    }
                    publish(engine, session, |v| {
                        if let Some(input) = &mut v.input {
                            input.state = InputState::Stalled;
                        }
                    });
                    let until = tick + Duration::from_millis(250);
                    while Instant::now() < until && !cancel.load(Ordering::Relaxed) {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    continue;
                }
            };
            let epoch = polled.epoch;
            if input_epoch != epoch {
                input_epoch = epoch; current = None; estimate = None; lost = false;
                generation = 0; search_cursor = 0; last_rejection = None;
                corroboration.clear(); candidates.clear(); pending.clear();
            }
            if let Some(notice) = polled.notice {
                // At most one warning every 5 s so a flaky driver cannot flush the bounded
                // log; the gap counter keeps the exact total.
                notices += 1;
                if last_notice.is_none_or(|at| at.elapsed() >= Duration::from_secs(5)) {
                    let message = if notices > 1 { format!("{notice}（自上条记录起共 {notices} 次）") } else { notice };
                    log(engine, session, Level::Warn, Stage::Input, message);
                    (last_notice, notices) = (Some(Instant::now()), 0);
                }
            }
            if let Some(report) = polled.report {
                log(engine, session, Level::Info, Stage::Input, report);
            }
            let feature_ms = polled.feature_ms;
            let packet = polled.observation;
            publish(engine, session, |v| v.bluetooth = polled.bluetooth);
            let mut input = polled.status.unwrap_or_else(|| super::diagnostics::InputStatus {
                state: InputState::Waiting, source: "蓝牙".into(), sample_rate: 8000,
                channels: vec![], rms_dbfs: None, peak_dbfs: None, buffered_seconds: 0.,
                packet_age_ms: None, packets: 0, gaps: 0,
            });
            if last_input_state != Some(input.state) {
                log(
                    engine,
                    session,
                    Level::Info,
                    Stage::Input,
                    format!(
                        "系统音频 · RMS {:.1} dBFS · 包 {} · 包龄 {:.1} ms · 断流 {} 次",
                        input.rms_dbfs.unwrap_or(-120.),
                        input.packets,
                        input.packet_age_ms.unwrap_or(0.),
                        input.gaps
                    ),
                );
                last_input_state = Some(input.state);
            }
            // WASAPI loopback does not fail when the default output changes or
            // its device is reset: the packets just stop. With none for 3 s it
            // is opened again, then after 6, 12, up to 30 s while none come (as
            // when nothing plays at all; a reopen costs little).
            if loopback {
                let silent = input.packet_age_ms.map_or_else(|| opened.elapsed().as_secs_f64(), |ms| ms / 1000.);
                if silent < 1. {
                    if stall_reopened {
                        stall_reopened = false;
                        log(engine, session, Level::Info, Stage::Input, "声音输入已恢复".into());
                    }
                    stall_wait = 3;
                } else if silent >= stall_wait as f64 {
                    log(engine, session, Level::Warn, Stage::Input, format!("声音输入 {silent:.0} 秒无数据，正在重新打开"));
                    stall_wait = (stall_wait * 2).min(30);
                    stall_reopened = true;
                    source = None;
                    reopen_at = Instant::now();
                    if current.is_some() {
                        publish(engine, session, |v| v.phase = "searching".into());
                    }
                    current = None; estimate = None; lost = false;
                    generation = 0; search_cursor = 0; corroboration.clear(); pending.clear();
                    continue;
                }
                // Only silence (or nothing) for 10 s since the start: DJ software
                // playing through ASIO or an exclusive output is not in the mix.
                heard_music |= matches!(input.state, InputState::Buffering | InputState::Receiving);
                if !heard_music && session_started.elapsed() >= Duration::from_secs(10) {
                    const HINT: &str = "（DJ 软件若用 ASIO/独占输出，回环听不到，请改选声卡的输入或回送通道）";
                    input.source.push_str(HINT);
                    if !hinted {
                        hinted = true;
                        log(engine, session, Level::Warn, Stage::Input, format!("系统混音 10 秒未听到声音{HINT}"));
                    }
                }
            }
            let audible = !matches!(
                input.state,
                InputState::Quiet | InputState::Stalled | InputState::Waiting
            );
            if !audible {
                let state = match input.state {
                    InputState::Stalled => ListenerState::Interrupted,
                    InputState::Waiting => ListenerState::Waiting,
                    _ => ListenerState::Quiet,
                };
                rescue_status.state = state;
                tracking_status.state = state;
            }
            publish(engine, session, |v| {
                v.input = Some(input);
                v.rescue = Some(rescue_status.clone());
                v.tracking = Some(tracking_status.clone());
            });
            // A file gone (a drive asleep or unplugged) or changed leaves only
            // that entry out until it is back as it was indexed; following goes on.
            if source_checked.elapsed().as_secs() >= 5 {
                for (i, r) in set.recordings.iter().enumerate() {
                    let ok = index::signature(Path::new(&r.entry.path)).is_ok_and(|s| s == r.signature);
                    if ok == unavailable[i] {
                        unavailable[i] = !ok;
                        if ok {
                            log(engine, session, Level::Info, Stage::Input, format!("素材已恢复：{}", r.entry.title));
                        } else {
                            log(engine, session, Level::Warn, Stage::Input, format!(
                                "素材不可用或已变化，暂不跟随它（重新开始监听会重新预处理）：{}",
                                r.entry.title
                            ));
                        }
                    }
                }
                source_checked = Instant::now();
            }
            // What the DJ has on right now. Turning off the entry being followed
            // lets it go: the picture stays until another entry is found.
            let on: Vec<bool> = {
                let off = engine.off.lock().unwrap();
                set.recordings
                    .iter()
                    .enumerate()
                    .map(|(i, r)| followed(&r.entry, &off, track) && !unavailable[i] && !unreadable[i])
                    .collect()
            };
            if current.is_some_and(|c| !on[c.recording]) {
                log(engine, session, Level::Info, Stage::Decision, format!(
                    "{} 已停用或不可用，改在其余素材中检索",
                    set.recordings[current.unwrap().recording].entry.title
                ));
                current = None;
                estimate = None;
                lost = true;
                search_cursor = 0;
                publish(engine, session, |v| v.phase = "searching".into());
            }
            if current.is_some_and(|c| c.at.elapsed().as_secs_f64() > 2.) && !lost {
                lost = true;
                publish(engine, session, |v| v.phase = "searching".into());
            }
            // A query of the wrong length (a bad packet from a sender) is skipped.
            let packet = packet.filter(|o| (350. ..=3000.).contains(&o.query.duration_ms()));
            if let Some(observation) = packet {
                let next_generation = observation.generation;
                if next_generation != generation {
                    if next_generation & (1 << 63) != 0 { current = None; }
                    estimate = None;
                    lost = current.is_some();
                    generation = next_generation;
                    search_cursor = 0;
                    corroboration.clear();
                    candidates.clear();
                    pending.clear();
                    engine
                        .present(session, |v| v.candidate = None);
                }
                if audible {
                    let query = observation.query;
                    let at = observation.at;
                    let mut scanned = Vec::new();
                    let mut retrieval_ms = 0.;
                    let mut verify_ms = 0.;
                    let mut local = None;
                    let trackable = current.filter(|c| c.at.elapsed().as_secs_f64() < 2.);
                    if let Some(old) = trackable {
                        tracking_status.state = ListenerState::Verifying;
                        tracking_status.target =
                            Some(set.recordings[old.recording].entry.title.clone());
                        publish(engine, session, |v| v.tracking = Some(tracking_status.clone()));
                        let block = &set.targets[old.target];
                        let predicted = old.position
                            + at.saturating_duration_since(old.at).as_secs_f64() * old.rate;
                        let started = Instant::now();
                        // Unreadable features leave that entry out, not the session.
                        let reference = match features.get(&block.path) {
                            Ok(reference) => reference,
                            Err(error) => {
                                unreadable[old.recording] = true;
                                log(engine, session, Level::Warn, Stage::Scan, format!(
                                    "特征缓存读取失败，暂不跟随它：{}：{error:#}",
                                    set.recordings[old.recording].entry.title
                                ));
                                continue;
                            }
                        };
                        let result = kvj_recognize::track_live_prepared(
                            &query,
                            &reference,
                            LiveHint {
                                offset_seconds: predicted
                                    - query.duration_ms() / 1000. * old.rate
                                    - block.start
                                    - set.recordings[old.recording].entry.audio_offset
                                    - LiveFeatures::origin_seconds(),
                                rate: old.rate,
                            },
                            &|| cancel.load(Ordering::Relaxed),
                        )?;
                        verify_ms += started.elapsed().as_secs_f64() * 1000.;
                        local = record(
                            set,
                            old.target,
                            &query,
                            at,
                            &result,
                            false,
                            verify_ms,
                            &mut scanned,
                        );
                    }
                    let tracking = local.is_some();
                    tracking_status = ListenerStatus {
                        state: if tracking {
                            ListenerState::Tracking
                        } else {
                            ListenerState::Searching
                        },
                        target: trackable.map(|c| set.recordings[c.recording].entry.title.clone()),
                        runs: tracking_status.runs + u64::from(trackable.is_some()),
                        elapsed_ms: verify_ms,
                        query_seconds: query.duration_ms() / 1000.,
                        position: local.map(|c| c.position),
                        rate: current.map(|c| c.rate),
                        error_ms: local
                            .zip(current)
                            .map(|(new, old)| (new.now() - old.now()) * 1000.),
                    };
                    scanned.clear();
                    let mut rescued = None;
                    // Room mode's corroboration already heard it agree over 3 s.
                    let mut vouched = false;
                    let rescue_ran = !tracking && on.contains(&true);
                    if tracking {
                        search_cursor = 0;
                    }
                    if rescue_ran {
                        rescue_status.state = ListenerState::Retrieving;
                        rescue_status.target = None;
                        publish(engine, session, |v| {
                            v.tracking = Some(tracking_status.clone());
                            v.rescue = Some(rescue_status.clone());
                        });
                        if !tracking && current.is_some() && !lost {
                            log(
                                engine,
                                session,
                                Level::Info,
                                Stage::Decision,
                                "局部证据不足；救场复核，保留当前画面".into(),
                            );
                        }
                        // Known tempo first, then nearby bins, then the rest of
                        // 0.80–1.25×. Verify after EACH bin and stop on the first
                        // accepted result. Yield between bins after 125 ms so
                        // the next attempt uses fresh audio, not an old query.
                        // A jump heard once is looked for again at its own
                        // tempo first: its second hearing must not wait behind
                        // the old tempo's bins (nor miss the pending window).
                        let preferred = pending
                            .iter()
                            .rev()
                            .find(|p| on[p.recording] && at.saturating_duration_since(p.at).as_secs_f64() <= PENDING_SECONDS)
                            .copied()
                            .or(current)
                            .map_or(1., |c| c.rate.clamp(0.80, 1.25));
                        let mut rates: [f64; 19] = std::array::from_fn(|i| 0.80 + i as f64 * 0.025);
                        rates.sort_by(|a, b| {
                            (a - preferred).abs().total_cmp(&(b - preferred).abs())
                        });
                        let search_started = Instant::now();
                        'search: for (step, rate) in std::iter::once(preferred)
                            .chain(rates)
                            .enumerate()
                            .skip(search_cursor)
                        {
                            search_cursor = step + 1;
                            if step > 0 && (rate - preferred).abs() < 0.001 {
                                continue;
                            }
                            let started = Instant::now();
                            let seeds = {
                                let mut index = set.index.lock().unwrap();
                                let canceled = || cancel.load(Ordering::Relaxed);
                                let allowed = |t: usize| on[set.targets[t].recording];
                                index.search_slice_at_rate_among(&query, rate, &allowed, &canceled)?
                            };
                            retrieval_ms += started.elapsed().as_secs_f64() * 1000.;
                            tracing::debug!(target: "kvj_probe", scan = scan + 1,
                            query_ms = query.duration_ms(), preferred = rate, seed_count = seeds.len(),
                            leading = ?seeds.first(), retrieval_ms, "retrieval");
                            let mut targets = Vec::new();
                            for seed in &seeds {
                                if !targets.contains(&seed.target) {
                                    targets.push(seed.target);
                                }
                            }
                            // Visit retrieved blocks in rank order; a verified
                            // match ends this rescue without checking more rivals.
                            for target in targets {
                                if cancel.load(Ordering::Relaxed) {
                                    return Ok(());
                                }
                                rescue_status.state = ListenerState::Verifying;
                                rescue_status.target = Some(
                                    set.recordings[set.targets[target].recording]
                                        .entry
                                        .title
                                        .clone(),
                                );
                                publish(engine, session, |v| v.rescue = Some(rescue_status.clone()));
                                let selected: Vec<_> = seeds
                                    .iter()
                                    .filter(|s| s.target == target)
                                    .copied()
                                    .collect();
                                let started = Instant::now();
                                let recording = set.targets[target].recording;
                                let reference = match features.get(&set.targets[target].path) {
                                    Ok(reference) => reference,
                                    Err(error) => {
                                        unreadable[recording] = true;
                                        log(engine, session, Level::Warn, Stage::Scan, format!(
                                            "特征缓存读取失败，暂不跟随它：{}：{error:#}",
                                            set.recordings[recording].entry.title
                                        ));
                                        continue;
                                    }
                                };
                                let result = kvj_recognize::verify_live_prepared(
                                    &query,
                                    &reference,
                                    &selected,
                                    room,
                                    &|| cancel.load(Ordering::Relaxed),
                                )?;
                                let ms = started.elapsed().as_secs_f64() * 1000.;
                                verify_ms += ms;
                                let corroborated = result.plausible
                                    && corroboration.confirm(
                                        (clock_ms() - at.elapsed().as_secs_f64() * 1000.) / 1000.,
                                        set.targets[target].recording,
                                        position(set, target, &query, &result),
                                        result.rate,
                                    );
                                rescued = record(
                                    set,
                                    target,
                                    &query,
                                    at,
                                    &result,
                                    corroborated,
                                    ms,
                                    &mut scanned,
                                );
                                if rescued.is_some() {
                                    vouched = corroborated;
                                    break 'search;
                                }
                                if room && result.plausible {
                                    remember(&mut candidates, Candidate {
                                        found: Evidence {
                                            target,
                                            recording: set.targets[target].recording,
                                            position: position(set, target, &query, &result),
                                            at,
                                            rate: result.rate,
                                            score: result.score,
                                            margin: result.score - result.runner_up,
                                        },
                                        retrieval_score: result.retrieval_score,
                                    });
                                }
                            }
                            if search_started.elapsed() >= Duration::from_millis(125) {
                                break;
                            }
                        }
                        // Earlier rounds' candidates, where they should be now. A
                        // recheck searched around a guess, so even a pass of the
                        // usual gates is taken only on a spaced agreement.
                        candidates.retain(|c| {
                            on[c.found.recording] && at.saturating_duration_since(c.found.at).as_secs_f64() <= 2.
                        });
                        for i in 0..candidates.len() {
                            if rescued.is_some() || cancel.load(Ordering::Relaxed) {
                                break;
                            }
                            let c = candidates[i];
                            if c.found.at == at {
                                continue;
                            }
                            let block = &set.targets[c.found.target];
                            let predicted = c.found.position
                                + at.saturating_duration_since(c.found.at).as_secs_f64() * c.found.rate;
                            let started = Instant::now();
                            let reference = features.get(&block.path)?;
                            let result = recheck_live_prepared(
                                &query,
                                &reference,
                                LiveHint {
                                    offset_seconds: predicted
                                        - query.duration_ms() / 1000. * c.found.rate
                                        - block.start
                                        - set.recordings[c.found.recording].entry.audio_offset
                                        - LiveFeatures::origin_seconds(),
                                    rate: c.found.rate,
                                },
                                c.retrieval_score,
                                &|| cancel.load(Ordering::Relaxed),
                            )?;
                            let ms = started.elapsed().as_secs_f64() * 1000.;
                            verify_ms += ms;
                            let heard = result.matched || result.supported || result.plausible;
                            let found = position(set, c.found.target, &query, &result);
                            let confirmed = heard
                                && corroboration.confirm(
                                    (clock_ms() - at.elapsed().as_secs_f64() * 1000.) / 1000.,
                                    c.found.recording,
                                    found,
                                    result.rate,
                                );
                            let gated = LiveAlignment {
                                matched: false,
                                supported: false,
                                reason: if heard { "复核待印证".into() } else { result.reason.clone() },
                                ..result.clone()
                            };
                            rescued = record(set, c.found.target, &query, at, &gated, confirmed, ms, &mut scanned);
                            vouched = confirmed;
                            if heard {
                                candidates[i].found = Evidence {
                                    position: found,
                                    at,
                                    rate: result.rate,
                                    score: result.score,
                                    margin: result.score - result.runner_up,
                                    ..c.found
                                };
                            }
                        }
                    }
                    if rescued.is_some() || search_cursor >= 20 {
                        search_cursor = 0;
                    }
                    if rescue_ran
                        && rescued.is_none()
                        && !tracking
                        && last_rejection.is_none_or(|t| t.elapsed().as_secs_f64() >= 1.)
                    {
                        let reason = scanned
                            .first()
                            .map_or_else(|| "未召回地标候选".into(), |r| r.reason.clone());
                        log(engine, session, Level::Info, Stage::Scan, format!(
                            "本轮未识别：{reason} · 查询 {:.0} ms / 检索 {:.1} ms / 校验 {:.1} ms / 证据龄 {:.1} ms",
                            query.duration_ms(), retrieval_ms, verify_ms, at.elapsed().as_secs_f64() * 1000.
                        ));
                        last_rejection = Some(Instant::now());
                    }
                    if rescue_ran {
                        rescue_status = ListenerStatus {
                            state: if rescued.is_some() {
                                ListenerState::Locked
                            } else {
                                ListenerState::Searching
                            },
                            target: rescued
                                .map(|c| set.recordings[c.recording].entry.title.clone()),
                            runs: rescue_status.runs + 1,
                            elapsed_ms: retrieval_ms + verify_ms - tracking_status.elapsed_ms,
                            query_seconds: query.duration_ms() / 1000.,
                            position: rescued.map(|c| c.position),
                            rate: rescued.map(|c| c.rate),
                            error_ms: None,
                        };
                    }
                    // The music is where the picture is, heard so for CONFIRM_AFTER:
                    // earlier jumps heard elsewhere go. One round at the old place
                    // can align by chance too (a looped phrase), and must not
                    // starve a real jump; unconfirmed, those age out instead.
                    if tracking {
                        let since = *held_since.get_or_insert(at);
                        if at.saturating_duration_since(since).as_secs_f64() >= CONFIRM_AFTER {
                            pending.clear();
                        }
                    } else {
                        held_since = None;
                    }
                    // A jump away from the shown place waits for its confirmation
                    // (CONFIRM_AFTER); the picture stays meanwhile.
                    let rescued = match rescued {
                        Some(found) if !vouched && current.is_some_and(|old| found.discontinuity(&old)) => {
                            pending.retain(|p| {
                                on[p.recording] && at.saturating_duration_since(p.at).as_secs_f64() <= PENDING_SECONDS
                            });
                            if pending.iter().any(|p| p.confirmed_by(&found)) {
                                pending.clear();
                                Some(found)
                            } else {
                                if !pending.iter().any(|p| p.recording == found.recording && (p.now() - found.now()).abs() < 0.25) {
                                    log(engine, session, Level::Info, Stage::Decision, format!(
                                        "新位置待印证：{} · {:.3} 秒 · {:.3}×，保留当前画面",
                                        set.recordings[found.recording].entry.title, found.now(), found.rate
                                    ));
                                }
                                pending.push(found);
                                if pending.len() > PENDING_MAX {
                                    pending.remove(0);
                                }
                                None
                            }
                        }
                        other => other,
                    };
                    // Exactly one accepted observation updates the playback clock.
                    let chosen = local.or(rescued);
                    if let Some(mut chosen) = chosen {
                        let jumped = current.is_none_or(|old| chosen.discontinuity(&old));
                        if jumped {
                            lock_revision += 1;
                            estimate = Some(ClockEstimate::new(chosen));
                            tracking_status.state = ListenerState::Waiting;
                            tracking_status.position = None;
                            tracking_status.error_ms = None;
                        }
                        let clock = estimate.get_or_insert_with(|| ClockEstimate::new(chosen));
                        let old_rate = clock.rate;
                        let (position, rate, rate_confidence) = clock.observe(chosen);
                        chosen.position = position;
                        chosen.rate = rate;
                        tracking_status.rate = Some(rate);
                        if jumped || lost {
                            log(
                                engine,
                                session,
                                Level::Info,
                                Stage::Decision,
                                format!(
                                    "救场定位：{} · {:.3} 秒 · {:.3}× · 本轮 {:.2} ms",
                                    set.recordings[chosen.recording].entry.title,
                                    chosen.now(),
                                    rate,
                                    tick.elapsed().as_secs_f64() * 1000.
                                ),
                            );
                        } else if (old_rate - rate).abs() >= 0.01 && rate_confidence >= 0.7 {
                            log(
                                engine,
                                session,
                                Level::Info,
                                Stage::Decision,
                                format!("持续漂移 · 基准速度估计 {:.3}× → {:.3}×", old_rate, rate),
                            );
                        }
                        current = Some(chosen);
                        lost = false;
                        candidates.clear();
                        engine.present(session, |v| {
                            if v.presentation_epoch != epoch { return; }
                            v.phase = "matched".into();
                            v.candidate = None;
                            v.matched =
                                Some(presentation(set, chosen, rate_confidence, lock_revision));
                        });
                    } else {
                        lost = current.is_some();
                        engine.present(session, |v| {
                            if v.presentation_epoch != epoch { return; }
                            v.candidate = None;
                            if lost {
                                v.phase = "searching".into();
                            }
                        });
                    }
                    scan += 1;
                    let elapsed = tick.elapsed().as_secs_f64() * 1000.;
                    tracing::debug!(target: "kvj_probe", scan, tracking, accepted = current.is_some_and(|c| c.at == at),
                        rescue_ran, lock_revision, query_ms = query.duration_ms(), feature_ms, retrieval_ms, verify_ms, round_ms = elapsed,
                        data_age_ms = at.elapsed().as_secs_f64() * 1000., capture_clock_ms = clock_ms() - at.elapsed().as_secs_f64() * 1000.,
                        position = current.map(|c| c.position), rate = current.map(|c| c.rate), "round");

                    publish(engine, session, |v| {
                        v.scan = scan;
                        v.scan_ms = elapsed;
                        if rescue_ran {
                            v.scanned = scanned;
                        }
                        v.rescue = Some(rescue_status.clone());
                        v.tracking = Some(tracking_status.clone());
                        v.scanning = None;
                        v.priority = current
                            .map(|c| vec![set.recordings[c.recording].entry.id.clone()])
                            .unwrap_or_default();
                    });
                }
            }
            // Capture never waits for recognition; no backlog of obsolete queries.
            let until = tick + Duration::from_millis(125);
            while Instant::now() < until && !cancel.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        Ok(())
    }
}
/// Whether following looks for an entry: turned on and on the followed track.
/// The other tracks' entries stay in the index; they are never matched.
fn followed(entry: &super::Entry, off: &std::collections::HashSet<String>, track: u8) -> bool {
    entry.track == track && !off.contains(&entry.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_followed_tracks_entries_on_are_followed() {
        let set: Set = serde_json::from_value(serde_json::json!({
            "id": "s", "name": "Set 1",
            "entries": [
                {"id": "a", "path": "/a.mp4", "title": "a", "duration": 60.0, "video": true, "presentation": "video"},
                {"id": "b", "path": "/b.mp4", "title": "b", "duration": 60.0, "video": true, "presentation": "video", "track": 1},
                {"id": "c", "path": "/c.mp4", "title": "c", "duration": 60.0, "video": true, "presentation": "video", "track": 1},
            ]
        }))
        .unwrap();
        let off: std::collections::HashSet<String> = ["c".to_string()].into();
        let mask = |track| set.entries.iter().map(|e| followed(e, &off, track)).collect::<Vec<_>>();
        assert_eq!(mask(0), [true, false, false]);
        assert_eq!(mask(1), [false, true, false]);
        assert_eq!(mask(2), [false, false, false]);
    }

    #[test]
    fn a_jump_is_confirmed_only_by_a_later_observation_that_agrees() {
        let t0 = Instant::now() - Duration::from_secs(10);
        let heard = |s: f64, recording, position| Evidence {
            target: 0, recording, position, at: t0 + Duration::from_secs_f64(s), rate: 1., score: 0.7, margin: 0.2,
        };
        let first = heard(0., 0, 100.);
        assert!(first.confirmed_by(&heard(0.6, 0, 100.6)));
        assert!(first.confirmed_by(&heard(2.0, 0, 102.1)));
        // Too soon: mostly the same audio.
        assert!(!first.confirmed_by(&heard(0.25, 0, 100.25)));
        // Elsewhere, or in another entry.
        assert!(!first.confirmed_by(&heard(0.6, 0, 257.)));
        assert!(!first.confirmed_by(&heard(0.6, 1, 100.6)));
    }
}
