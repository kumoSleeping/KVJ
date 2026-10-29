//! Entries of a Set that share their sound: the same song put in twice, as
//! another file. Following cannot tell such entries apart, so the library
//! marks them. Found once per index, in the background while following, by
//! listening to each entry's own features every `STEP` s in the others.
use super::{index::PreparedSet, runtime::position};
use kvj_recognize::{verify_live_prepared, LiveFeatures};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    io::BufReader,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};

/// One query this often in each entry, this long.
const STEP: f64 = 15.;
const QUERY: f64 = 2.;
/// Places heard elsewhere before two entries are said to share their sound:
/// one alone can be a common sample or a chance alignment.
const HITS: u32 = 2;
/// Close to the same audio, not merely the same song played again.
const SCORE: f64 = 0.8;

/// `entry`, from `at` s, sounds like `other` from `other_at` s, in `hits`
/// of the places listened to.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Shared {
    pub entry: String,
    pub other: String,
    pub at: f64,
    pub other_at: f64,
    pub hits: u32,
}

/// None when canceled: nothing is kept then, the next session scans again.
pub fn scan(set: &PreparedSet, cancel: &AtomicBool) -> Option<Vec<Shared>> {
    let canceled = || cancel.load(Ordering::Relaxed);
    let mut found: HashMap<(usize, usize), Shared> = HashMap::new();
    let mut references: Vec<(usize, Arc<LiveFeatures>)> = Vec::new();
    for block in &set.targets {
        let own = block.recording;
        let Some(features) = read(&block.path) else { continue };
        let span = (features.duration_ms() / 1000. - QUERY).min(300.);
        let mut from = STEP / 2.;
        while from <= span {
            if canceled() {
                return None;
            }
            let Some(query) = features.slice(from, QUERY) else { break };
            from += STEP;
            let path = &set.recordings[own].entry.path;
            let allowed = |t: usize| set.recordings[set.targets[t].recording].entry.path != *path;
            let seeds = match set.index.lock().unwrap().search_slice_at_rate_among(&query, 1., &allowed, &canceled) {
                Ok(seeds) => seeds,
                Err(_) if canceled() => return None,
                Err(_) => continue,
            };
            let Some(target) = seeds.first().map(|s| s.target) else { continue };
            let reference = match references.iter().find(|(t, _)| *t == target) {
                Some((_, f)) => f.clone(),
                None => {
                    let Some(f) = read(&set.targets[target].path) else { continue };
                    let f = Arc::new(f);
                    references.push((target, f.clone()));
                    if references.len() > 4 {
                        references.remove(0);
                    }
                    f
                }
            };
            let selected: Vec<_> = seeds.iter().filter(|s| s.target == target).copied().collect();
            let Ok(result) = verify_live_prepared(&query, &reference, &selected, false, &canceled) else { continue };
            if result.matched && result.score >= SCORE {
                let other = set.targets[target].recording;
                // Where the query began, in both.
                let at = block.start + set.recordings[own].entry.audio_offset + LiveFeatures::origin_seconds() + from - STEP;
                let other_at = position(set, target, &query, &result) - query.duration_ms() / 1000. * result.rate;
                let shared = found.entry((own, other)).or_insert_with(|| Shared {
                    entry: set.recordings[own].entry.id.clone(),
                    other: set.recordings[other].entry.id.clone(),
                    at,
                    other_at,
                    hits: 0,
                });
                shared.hits += 1;
            }
            // Following shares the index: leave it room.
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let mut shared: Vec<_> = found.into_values().filter(|s| s.hits >= HITS).collect();
    shared.sort_by(|a, b| (&a.entry, &a.other).cmp(&(&b.entry, &b.other)));
    Some(shared)
}
fn read(path: &Path) -> Option<LiveFeatures> {
    LiveFeatures::read_from(BufReader::new(fs::File::open(path).ok()?)).ok()
}
/// Where a Set's scan is kept: it depends only on the files, like its index.
pub fn file(cache: &Path, key: &str) -> std::path::PathBuf {
    cache.join(format!("alike-{key}.json"))
}
pub fn load(cache: &Path, key: &str) -> Option<Vec<Shared>> {
    serde_json::from_slice(&fs::read(file(cache, key)).ok()?).ok()
}
