//! Live acoustic following: which recording is playing, where, and how fast.
//! Ported unchanged from KDJ's Live VJ (`crates/kdj-analysis/src/alignment/live*.rs`
//! at 00f377a). A short capture window is matched against a landmark index of the
//! whole Set, then verified on whitened spectra; this is not semantic song recognition.
use anyhow::{bail, Result};
use rustfft::{num_complex::Complex32, FftPlanner};

mod live;
mod live_features;
mod live_index;
pub use live::{track_live_prepared, verify_live_prepared, Corroboration, LiveAlignment, LiveHint};
pub use live_features::{LiveFeatureStream, LiveFeatures, LIVE_FEATURE_REVISION};
pub use live_index::{LiveIndex, LiveSeed};

/// Recognition audio is mono at 8 kHz on a 10 ms hop with 16 log bands.
pub const SAMPLE_RATE: usize = 8000;
const HOP: usize = 80;
const BANDS: usize = 16;
/// Upper bound for one recording's resident features and a query's vote table.
pub const FEATURE_MEMORY_BUDGET: usize = 32 * 1024 * 1024;

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic "song": a melody of short tones over a drifting chord and noise.
    fn song(seed: u32, seconds: f64) -> Vec<f32> {
        let mut state = seed;
        let mut random = move || {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            state as f32 / u32::MAX as f32
        };
        let notes: Vec<(f32, f32)> = (0..(seconds * 8.) as usize + 1)
            .map(|_| (220. * 2f32.powf((random() * 24.).floor() / 12.), 0.2 + 0.3 * random()))
            .collect();
        let n = (seconds * SAMPLE_RATE as f64) as usize;
        (0..n)
            .map(|i| {
                let t = i as f32 / SAMPLE_RATE as f32;
                let (frequency, level) = notes[(t * 8.) as usize];
                let attack = (1. - (t * 8.).fract()).powi(2);
                level * attack * (std::f32::consts::TAU * frequency * t).sin()
                    + 0.08 * (std::f32::consts::TAU * (110. + 20. * (t * 0.3).sin()) * t).sin()
                    + (random() - 0.5) * 0.01
            })
            .collect()
    }

    #[test]
    fn a_short_live_window_finds_its_recording_and_position() {
        let recordings = [song(7, 40.), song(99, 40.)];
        let mut index = LiveIndex::default();
        let features: Vec<_> = recordings
            .iter()
            .map(|pcm| LiveFeatures::prepare(pcm, &|| false).unwrap())
            .collect();
        for (target, f) in features.iter().enumerate() {
            index.add(target, f).unwrap();
        }
        index.warm(&|| false).unwrap();

        // Capture from 10 s to 22.55 s of the second recording, at a lower gain.
        let (from, to) = (10. * SAMPLE_RATE as f64, 22.55 * SAMPLE_RATE as f64);
        let capture: Vec<f32> = recordings[1][from as usize..to as usize].iter().map(|x| x * 0.4).collect();
        let mut stream = LiveFeatureStream::new(300);
        stream.push(&capture, &|| false).unwrap();
        let (query, tail) = stream.recent(0.55).expect("enough audio for a query");

        let seeds = index.search_slice_at_rate(&query, 1., &|| false).unwrap();
        let target = seeds.first().expect("retrieval proposes a candidate").target;
        assert_eq!(target, 1);
        let selected: Vec<_> = seeds.iter().filter(|s| s.target == target).copied().collect();
        let result = verify_live_prepared(&query, &features[target], &selected, false, &|| false).unwrap();
        assert!(result.matched || result.supported, "{result:?}");
        // The engine maps a verified offset to the recording position at the query's end.
        let position = LiveFeatures::origin_seconds() + result.offset_seconds
            + query.duration_ms() / 1000. * result.rate;
        let expected = 22.55 - tail;
        assert!((position - expected).abs() < 0.05, "position {position:.3} expected {expected:.3}");
    }

    /// A room heard through a microphone: early reflections, then a dense tail
    /// falling 60 dB in `rt60` seconds and carrying more energy than the direct sound.
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

    /// Denser than `song`: a melody with overtones, a bass line, a held chord and
    /// hi-hats, so a short window holds as many spectral peaks as real music.
    fn music(seed: u32, seconds: f64) -> Vec<f32> {
        let mut state = seed;
        let mut random = move || {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            state as f32 / u32::MAX as f32
        };
        let scale = [0, 2, 3, 5, 7, 8, 10];
        let mut pick = |octaves: f32| {
            let step = (random() * 7. * octaves) as usize;
            2f32.powf((12 * (step / 7) + scale[step % 7]) as f32 / 12.)
        };
        let melody: Vec<f32> = (0..(seconds * 8.) as usize + 1).map(|_| 220. * pick(2.)).collect();
        let bass: Vec<f32> = (0..(seconds * 2.) as usize + 1).map(|_| 55. * pick(1.)).collect();
        let chords: Vec<[f32; 3]> = (0..(seconds / 2.) as usize + 1)
            .map(|_| {
                let root = 110. * pick(1.);
                [root, root * 1.189, root * 1.498]
            })
            .collect();
        let n = (seconds * SAMPLE_RATE as f64) as usize;
        let mut previous = 0.;
        (0..n)
            .map(|i| {
                let t = i as f32 / SAMPLE_RATE as f32;
                let tone = |f: f32, overtones: usize| {
                    (1..=overtones)
                        .map(|h| (std::f32::consts::TAU * f * h as f32 * t).sin() / h as f32)
                        .sum::<f32>()
                };
                let (eighth, half) = ((t * 8.).fract() / 8., (t * 2.).fract() / 2.);
                let noise = random() - 0.5;
                let hat = (noise - previous) * (-eighth / 0.02).exp();
                previous = noise;
                0.3 * (-eighth / 0.12).exp() * tone(melody[(t * 8.) as usize], 3)
                    + 0.3 * (-half / 0.3).exp() * tone(bass[(t * 2.) as usize], 4)
                    + 0.05 * chords[(t / 2.) as usize].iter().map(|&f| tone(f, 2)).sum::<f32>()
                    + 0.15 * hat
            })
            .collect()
    }

    #[derive(Debug, Default, PartialEq)]
    struct Tally {
        /// Accepted at the right recording and within 50 ms.
        followed: usize,
        /// Accepted anywhere else (or at all, for audio outside the Set).
        wrong: usize,
    }
    /// The engine's rescue on `heard` (recording `truth` of the Set, or `None`:
    /// not in it) from 10 s to 25 s: a 0.55 s query every 125 ms, each retrieved
    /// recording verified in rank order, the first acceptance ending the round.
    fn follow(index: &mut LiveIndex, features: &[LiveFeatures], heard: &[f32], truth: Option<usize>, room: bool) -> Tally {
        let mut tally = Tally::default();
        let mut stream = LiveFeatureStream::new(300);
        let mut corroboration = Corroboration::default();
        let step = SAMPLE_RATE / 8;
        for from in (10 * SAMPLE_RATE..25 * SAMPLE_RATE).step_by(step) {
            stream.push(&heard[from..from + step], &|| false).unwrap();
            let Some((query, tail)) = stream.recent(0.55) else { continue };
            let at = (from + step) as f64 / SAMPLE_RATE as f64 - tail;
            let seeds = index.search_slice_at_rate(&query, 1., &|| false).unwrap();
            let mut targets: Vec<usize> = Vec::new();
            for seed in &seeds {
                if !targets.contains(&seed.target) {
                    targets.push(seed.target);
                }
            }
            for target in targets {
                let selected: Vec<_> = seeds.iter().filter(|s| s.target == target).copied().collect();
                let result = verify_live_prepared(&query, &features[target], &selected, room, &|| false).unwrap();
                let position = LiveFeatures::origin_seconds() + result.offset_seconds
                    + query.duration_ms() / 1000. * result.rate;
                let strict = result.matched || result.supported;
                let corroborated =
                    result.plausible && corroboration.confirm(at, target, position, result.rate);
                if !strict && !corroborated {
                    continue;
                }
                if Some(target) == truth && (position - at).abs() < 0.05 {
                    tally.followed += 1;
                } else {
                    tally.wrong += 1;
                }
                break;
            }
        }
        tally
    }

    #[test]
    fn room_mode_follows_through_reverberation_and_keeps_dry_input() {
        let recordings = [music(7, 40.), music(99, 40.)];
        let features: Vec<_> = recordings
            .iter()
            .map(|pcm| LiveFeatures::prepare(pcm, &|| false).unwrap())
            .collect();
        let mut index = LiveIndex::default();
        for (target, f) in features.iter().enumerate() {
            index.add(target, f).unwrap();
        }
        index.warm(&|| false).unwrap();
        let outside = music(3, 40.);
        let mut run = |pcm: &[f32], truth: Option<usize>| {
            let heard: Vec<f32> = pcm.iter().map(|x| x * 0.4).collect();
            let off = follow(&mut index, &features, &heard, truth, false);
            let on = follow(&mut index, &features, &heard, truth, true);
            (off, on)
        };

        // Direct input: room mode accepts exactly what it did without it.
        let (off, on) = run(&recordings[1], Some(1));
        assert_eq!(off, on);
        let (off, on) = run(&outside, None);
        assert_eq!(off, on);

        // A reverberant room: far more of the 116 windows follow, none goes astray.
        for rt60 in [0.8, 1.5, 2.5] {
            let (off, on) = run(&room(&recordings[1], rt60), Some(1));
            assert!(on.wrong == 0 && on.followed >= off.followed + 20, "RT60 {rt60}: {off:?} → {on:?}");
            let (_, on) = run(&room(&outside, rt60), None);
            assert_eq!(on.wrong, 0, "outside, RT60 {rt60}");
        }
    }
}
