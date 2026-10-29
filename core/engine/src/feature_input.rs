//! The live input: native capture turned into recognition features.
use super::{
    audio_input::{Capture, Ring, Selection},
    diagnostics::{InputState, InputStatus},
};
use anyhow::Result;
use kvj_recognize::{LiveFeatureStream, LiveFeatures};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
pub struct Observation {
    pub query: LiveFeatures,
    pub at: Instant,
    pub generation: u64,
}
pub struct Input {
    // Held for as long as the input is: dropping it stops capture.
    _capture: Capture,
    ring: Arc<Mutex<Ring>>,
    stream: LiveFeatureStream,
    generation: u64,
}
pub struct Poll {
    pub observation: Option<Observation>,
    pub status: InputStatus,
    pub feature_ms: f64,
    /// Capture continuity break reported by the audio backend since the last poll.
    pub notice: Option<String>,
    /// Now and then, how the capture timeline is holding up.
    pub report: Option<String>,
}
impl Input {
    pub fn start(selection: &Selection) -> Result<Self> {
        let (capture, ring) = Capture::start(selection)?;
        Ok(Self {
            _capture: capture,
            ring,
            stream: LiveFeatureStream::new(300),
            generation: 0,
        })
    }
    pub fn poll(&mut self, cancel: &AtomicBool) -> Result<Poll> {
        let (packet, status, notice, report) = {
            let mut ring = self.ring.lock().unwrap();
            if let Some(error) = &ring.error {
                anyhow::bail!("{error}");
            }
            (ring.take(), ring.status(), ring.notice.take(), ring.report())
        };
        let started = Instant::now();
        let mut observation = None;
        if let Some((pcm, at, generation)) = packet {
            if generation != self.generation {
                self.stream.reset();
                self.generation = generation;
            }
            self.stream.push(&pcm, &|| cancel.load(Ordering::Relaxed))?;
            if !matches!(
                status.state,
                InputState::Quiet | InputState::Stalled | InputState::Waiting
            ) {
                observation = self.stream.recent(0.55).map(|(query, tail)| Observation {
                    query,
                    at: at - Duration::from_secs_f64(tail),
                    generation,
                });
            }
        }
        Ok(Poll {
            observation,
            status,
            feature_ms: started.elapsed().as_secs_f64() * 1000.,
            notice,
            report,
        })
    }
}
