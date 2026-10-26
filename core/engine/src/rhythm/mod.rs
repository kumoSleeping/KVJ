//! Tempo along a file, for the timeline: where the BPM changes, which is where
//! one song gives way to the next in a long mix. KDJ's V4 analysis (`v4`) finds
//! the beats and fits constant-tempo regions to them; on a mix that is many
//! more regions than songs (fills and transitions make 3–8 s pieces with a
//! wrong tempo), so `sections` tidies them into what a VJ cuts by. Cached on
//! disk like the waveform.
mod dsp;
mod v4;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    hash::{Hash, Hasher},
    path::Path,
};

/// Bumped whenever the analysis or the tidying changes what a file gives.
const REVISION: u32 = 1;
/// Slower than this V4 has locked onto a bar-long pattern, not the beat.
const SLOWEST_BPM: f64 = 60.;
/// No beats for longer than this is a section of its own.
const GAP_SECONDS: f64 = 6.;
/// Shorter than this a section is a transition or a fill, never a song part…
const SHORTEST_SECONDS: f64 = 10.;
/// …and so is a tempo this short that its beats hardly fit (a break without
/// beats is worth seeing).
const WEAK_SECONDS: f64 = 25.;
const WEAK_CONFIDENCE: f64 = 0.15;

/// One stretch at one tempo; `bpm` is `None` where no beat holds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub start: f64,
    pub end: f64,
    pub bpm: Option<f64>,
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tempo {
    pub duration: f64,
    pub sections: Vec<Section>,
}

/// The tempo sections of `path`, from `cache_dir` when made before. `None` when cancelled.
pub fn load(path: &Path, cache_dir: &Path, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<Option<Tempo>> {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    ("kvj-tempo", REVISION, v4::REVISION, path, super::index::signature(path)?).hash(&mut h);
    let file = cache_dir.join(format!("{:016x}.kbpm", h.finish()));
    if let Some(tempo) = fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()) {
        return Ok(Some(tempo));
    }
    let Some(tempo) = analyse(path, cancelled)? else {
        return Ok(None);
    };
    // A cache that cannot be written only costs the next analysis.
    let _ = fs::create_dir_all(cache_dir).and_then(|_| {
        let part = file.with_extension("part");
        fs::write(&part, serde_json::to_vec(&tempo)?)?;
        fs::rename(&part, &file)
    });
    Ok(Some(tempo))
}

pub fn analyse(path: &Path, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<Option<Tempo>> {
    let Some(analysis) = v4::analyze(path, true, cancelled)? else {
        return Ok(None);
    };
    let regions: Vec<_> = analysis.segments.iter().map(|s| (s.start_seconds, s.end_seconds, s.bpm, s.confidence)).collect();
    Ok(Some(Tempo { duration: analysis.duration, sections: sections(&regions, analysis.duration) }))
}

/// A section being built: the tempo is the mean over the parts that agreed on it.
#[derive(Clone, Copy)]
struct Piece {
    start: f64,
    end: f64,
    beat_seconds: f64,
    bpm_seconds: f64,
    confidence_seconds: f64,
}

impl Piece {
    fn len(&self) -> f64 {
        self.end - self.start
    }
    fn bpm(&self) -> Option<f64> {
        (self.beat_seconds > 0.).then(|| self.bpm_seconds / self.beat_seconds)
    }
    fn confidence(&self) -> f64 {
        self.confidence_seconds / self.len().max(1e-9)
    }
    /// The same tempo, within what pieces this long can tell apart: a whole
    /// song's tempo is good to a fraction of a BPM, ten seconds' to two or so.
    fn agrees(&self, other: &Piece) -> bool {
        match (self.bpm(), other.bpm()) {
            (Some(a), Some(b)) => (a / b - 1.).abs() <= 0.006 + 0.1 / self.len().min(other.len()).max(1.),
            (a, b) => a.is_none() && b.is_none(),
        }
    }
    /// Its tempo read at `factor` times what it was (half or double time).
    fn scaled(self, factor: f64) -> Piece {
        Piece { bpm_seconds: self.bpm_seconds * factor, ..self }
    }
    fn join(self, next: Piece) -> Piece {
        Piece {
            start: self.start,
            end: next.end,
            beat_seconds: self.beat_seconds + next.beat_seconds,
            bpm_seconds: self.bpm_seconds + next.bpm_seconds,
            confidence_seconds: self.confidence_seconds + next.confidence_seconds,
        }
    }
    fn weak(&self) -> bool {
        self.len() < SHORTEST_SECONDS
            || (self.bpm().is_some() && self.len() < WEAK_SECONDS && self.confidence() < WEAK_CONFIDENCE)
    }
}

/// V4's regions `(start, end, bpm, confidence)` as sections covering `0..duration`:
/// a short gap is split between its neighbours, a long one has no beat; a
/// piece at half or double the tempo its neighbours agree on is their tempo
/// (a half-time breakdown is no new song); the shortest weak piece goes, into
/// its neighbours when they agree, else split between them at its middle (a
/// transition's middle is the likeliest cut); neighbours that agree are one section.
pub fn sections(regions: &[(f64, f64, f64, f64)], duration: f64) -> Vec<Section> {
    let silent = |start: f64, end: f64| Piece { start, end, beat_seconds: 0., bpm_seconds: 0., confidence_seconds: 0. };
    let mut pieces: Vec<Piece> = Vec::new();
    let mut at = 0.;
    for &(start, end, bpm, confidence) in regions {
        let (start, end) = (start.max(at), end.min(duration));
        if end <= start {
            continue;
        }
        let len = end - start;
        let beat = if bpm >= SLOWEST_BPM { len } else { 0. };
        let mut piece = Piece { start, end, beat_seconds: beat, bpm_seconds: bpm * beat, confidence_seconds: confidence * len };
        let gap = start - at;
        if gap > GAP_SECONDS {
            pieces.push(silent(at, start));
        } else if let Some(last) = pieces.last_mut() {
            last.end = at + gap / 2.;
            piece.start = last.end;
        } else {
            piece.start = 0.;
        }
        pieces.push(piece);
        at = end;
    }
    if duration - at > GAP_SECONDS || pieces.is_empty() {
        pieces.push(silent(at, duration.max(at)));
    } else if let Some(last) = pieces.last_mut() {
        last.end = duration;
    }

    loop {
        let mut merged: Vec<Piece> = Vec::with_capacity(pieces.len());
        for piece in pieces {
            match merged.last_mut() {
                Some(last) if last.agrees(&piece) => *last = last.join(piece),
                _ => merged.push(piece),
            }
        }
        pieces = merged;
        if pieces.len() < 2 {
            break;
        }
        let octave = (1..pieces.len().saturating_sub(1)).find_map(|i| {
            let (l, r) = (&pieces[i - 1], &pieces[i + 1]);
            let factor = [2., 0.5].into_iter().find(|&f| pieces[i].bpm().is_some() && pieces[i].scaled(f).agrees(l))?;
            l.agrees(r).then_some((i, factor))
        });
        if let Some((i, factor)) = octave {
            pieces[i] = pieces[i].scaled(factor);
            continue;
        }
        let Some(i) = (0..pieces.len()).filter(|&i| pieces[i].weak()).min_by(|&a, &b| pieces[a].len().total_cmp(&pieces[b].len()))
        else {
            break;
        };
        let piece = pieces.remove(i);
        // Its tempo is dropped either way; its confidence stays with its time.
        let share = |p: &mut Piece, from: f64, to: f64| p.confidence_seconds += piece.confidence() * (to - from);
        match (i.checked_sub(1), (i < pieces.len()).then_some(i)) {
            (Some(l), Some(r)) if pieces[l].agrees(&pieces[r]) => {
                share(&mut pieces[l], piece.start, piece.end);
                pieces[l].end = piece.end;
            }
            (Some(l), Some(r)) => {
                let mid = (piece.start + piece.end) / 2.;
                share(&mut pieces[l], piece.start, mid);
                share(&mut pieces[r], mid, piece.end);
                pieces[l].end = mid;
                pieces[r].start = mid;
            }
            (Some(l), None) => {
                share(&mut pieces[l], piece.start, piece.end);
                pieces[l].end = piece.end;
            }
            (None, Some(r)) => {
                share(&mut pieces[r], piece.start, piece.end);
                pieces[r].start = piece.start;
            }
            (None, None) => unreachable!("two or more pieces"),
        }
    }
    pieces
        .iter()
        .map(|p| Section { start: p.start, end: p.end, bpm: p.bpm(), confidence: p.confidence() })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bpms(sections: &[Section]) -> Vec<Option<i64>> {
        sections.iter().map(|s| s.bpm.map(|b| b.round() as i64)).collect()
    }

    #[test]
    fn songs_at_different_tempi_are_sections_and_transitions_are_not() {
        let regions = [
            (0.5, 60., 140., 0.6),
            (60., 64., 121.7, 0.1), // a fill
            (64., 120., 140.2, 0.5),
            (120., 124., 150., 0.0), // the transition
            (124., 200., 170., 0.5),
        ];
        let s = sections(&regions, 201.);
        assert_eq!(bpms(&s), vec![Some(140), Some(170)]);
        assert_eq!((s[0].start, s[1].end), (0., 201.));
        assert_eq!(s[0].end, 122.);
    }

    #[test]
    fn a_long_gap_has_no_tempo_and_a_short_one_is_shared() {
        let regions = [(0., 50., 128., 0.5), (53., 100., 160., 0.5), (120., 180., 160., 0.5)];
        let s = sections(&regions, 180.);
        assert_eq!(bpms(&s), vec![Some(128), Some(160), None, Some(160)]);
        assert_eq!(s[0].end, 51.5);
        assert_eq!((s[2].start, s[2].end), (100., 120.));
    }

    #[test]
    fn a_bar_long_lock_is_no_tempo() {
        let regions = [(0., 60., 140., 0.5), (60., 120., 43., 0.0), (120., 180., 140., 0.5)];
        assert_eq!(bpms(&sections(&regions, 180.)), vec![Some(140), None, Some(140)]);
    }

    #[test]
    fn half_time_inside_a_song_is_no_new_section() {
        let regions = [(0., 100., 140., 0.5), (100., 160., 70., 0.6), (160., 260., 140.1, 0.5)];
        let s = sections(&regions, 260.);
        assert_eq!(bpms(&s), vec![Some(140)]);
        // Between two different songs it stays what it was heard as.
        let regions = [(0., 100., 140., 0.5), (100., 160., 70., 0.6), (160., 260., 170., 0.5)];
        assert_eq!(bpms(&sections(&regions, 260.)), vec![Some(140), Some(70), Some(170)]);
    }

    #[test]
    fn neighbouring_songs_two_bpm_apart_stay_apart() {
        let regions = [(0., 90., 195., 0.4), (90., 180., 193., 0.4)];
        assert_eq!(bpms(&sections(&regions, 180.)), vec![Some(195), Some(193)]);
        // Short pieces that close are one tempo measured roughly.
        let regions = [(0., 12., 178.2, 0.4), (12., 24., 180.1, 0.4)];
        assert_eq!(sections(&regions, 24.).len(), 1);
    }

    #[test]
    fn nothing_heard_is_one_section_without_tempo() {
        assert_eq!(bpms(&sections(&[], 30.)), vec![None]);
        assert_eq!(sections(&[], 30.)[0].end, 30.);
    }
}
