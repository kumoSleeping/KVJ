//! Live acoustic following: which recording is playing, where, and how fast.
//! Ported unchanged from KDJ's Live VJ (`crates/kdj-analysis/src/alignment/live*.rs`
//! at 00f377a). A short capture window is matched against a landmark index of the
//! whole Set, then verified on whitened spectra; this is not semantic song recognition.
use anyhow::{bail, Result};
use rustfft::{num_complex::Complex32, FftPlanner};

mod live;
mod live_features;
mod live_index;
pub use live::{track_live_prepared, verify_live_prepared, LiveAlignment, LiveHint};
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
        let result = verify_live_prepared(&query, &features[target], &selected, &|| false).unwrap();
        assert!(result.matched || result.supported, "{result:?}");
        // The engine maps a verified offset to the recording position at the query's end.
        let position = LiveFeatures::origin_seconds() + result.offset_seconds
            + query.duration_ms() / 1000. * result.rate;
        let expected = 22.55 - tail;
        assert!((position - expected).abs() < 0.05, "position {position:.3} expected {expected:.3}");

        // Among only the first recording, the second never takes a seed.
        let among = index.search_slice_at_rate_among(&query, 1., &|t| t == 0, &|| false).unwrap();
        assert!(among.iter().all(|s| s.target == 0));
    }
}
