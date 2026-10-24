//! The one input owner: native capture feeding the incremental feature stream.
//! (KDJ's Bluetooth receiver is not part of this port yet.)
use super::{
    audio_input::{Capture, Ring, Selection},
    diagnostics::{InputState, InputStatus},
};
use anyhow::{bail, Result};
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
    /// Capture time of the query's last sample.
    pub at: Instant,
    pub generation: u64,
}
pub struct Input {
    local: (Capture, Arc<Mutex<Ring>>),
    stream: LiveFeatureStream,
    generation: u64,
}
pub struct Poll {
    pub observation: Option<Observation>,
    pub status: Option<InputStatus>,
    pub feature_ms: f64,
    pub epoch: u64,
    /// Capture continuity break reported by the audio backend since the last poll.
    pub notice: Option<String>,
}
impl Input {
    pub fn start(selection: &Selection) -> Result<Self> {
        Ok(Self {
            local: Capture::start(selection)?,
            stream: LiveFeatureStream::new(300),
            generation: 0,
        })
    }
    pub fn poll(&mut self, cancel: &AtomicBool) -> Result<Poll> {
        let (packet, status, notice) = {
            let mut ring = self.local.1.lock().unwrap();
            if let Some(error) = &ring.error {
                bail!("{error}");
            }
            (ring.take(), ring.status(), ring.notice.take())
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
            status: Some(status),
            feature_ms: started.elapsed().as_secs_f64() * 1000.,
            epoch: 0,
            notice,
        })
    }
}
