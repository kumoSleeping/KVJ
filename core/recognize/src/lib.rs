//! Live acoustic following: which recording is playing, where, and how fast.
//! Ported unchanged from KDJ's Live VJ (`crates/kdj-analysis/src/alignment/live*.rs`
//! at 00f377a). A short capture window is matched against a landmark index of the
//! whole Set, then verified on whitened spectra; this is not semantic song recognition.
use anyhow::{bail, Result};
use rustfft::{num_complex::Complex32, FftPlanner};

mod live;
mod live_features;
mod live_index;
pub use live::{
    recheck_live_prepared, track_live_prepared, verify_live_prepared, Corroboration, LiveAlignment, LiveHint,
};
pub use live_features::{LiveFeatureStream, LiveFeatures, LIVE_FEATURE_REVISION};
pub use live_index::{LiveIndex, LiveSeed};

/// Recognition audio is mono at 8 kHz on a 10 ms hop with 16 log bands.
pub const SAMPLE_RATE: usize = 8000;
const HOP: usize = 80;
const BANDS: usize = 16;
/// Upper bound for one recording's resident features and a query's vote table.
pub const FEATURE_MEMORY_BUDGET: usize = 32 * 1024 * 1024;
