//! The picture's sound for playing (the app's AudioFollower): one file's audio
//! track read in order from any point, as interleaved stereo f32 at the file's
//! own rate. A seek lands on the exact frame: the packet it starts in is
//! decoded and the frames before the time are dropped. The host stretches the
//! sound in time and plays it.

use std::fs::File;
use std::path::Path;

use anyhow::{Context, Result};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::{Time, TimeBase};

use crate::decode::copy_audio_packet;

pub struct SoundStream {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    time_base: Option<TimeBase>,
    rate: u32,
    duration: f64,
    buffer: Option<SampleBuffer<f32>>,
    // Decoded stereo frames not read yet, from `cursor`.
    pending: Vec<f32>,
    cursor: usize,
    // After a seek: frames before this time are dropped.
    skip_to: Option<f64>,
    ended: bool,
    /// A read or seek panicked: its state is not trusted again (`ffi`).
    pub(crate) broken: bool,
}

impl SoundStream {
    pub fn open(path: &Path) -> Result<Self> {
        let file = File::open(path).with_context(|| format!("打开音频失败：{}", path.display()))?;
        let stream = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        let probed = symphonia::default::get_probe()
            .format(
                &hint,
                stream,
                &FormatOptions { enable_gapless: true, ..Default::default() },
                &MetadataOptions::default(),
            )
            .with_context(|| format!("无法识别音频格式：{}", path.display()))?;
        let format = probed.format;
        let track = format
            .tracks()
            .iter()
            .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
            .context("文件里没有可解码的音轨")?;
        let track_id = track.id;
        let params = track.codec_params.clone();
        let decoder = symphonia::default::get_codecs()
            .make(&params, &DecoderOptions::default())
            .context("没有可用的解码器")?;
        let rate = params.sample_rate.unwrap_or(0);
        let duration = match (params.n_frames, rate) {
            (Some(frames), rate) if rate > 0 => frames as f64 / rate as f64,
            _ => 0.0,
        };
        let mut sound = Self {
            format,
            decoder,
            track_id,
            time_base: params.time_base,
            rate,
            duration,
            buffer: None,
            pending: Vec::new(),
            cursor: 0,
            skip_to: None,
            ended: false,
            broken: false,
        };
        // Some files only tell their rate in the first decoded packet.
        if sound.rate == 0 {
            sound.fill();
        }
        anyhow::ensure!(sound.rate > 0, "音轨没有采样率");
        Ok(sound)
    }

    pub fn rate(&self) -> u32 {
        self.rate
    }

    pub fn duration(&self) -> f64 {
        self.duration
    }

    /// Reads on from `seconds`. False when the container cannot seek; reading
    /// then goes on from wherever it is.
    pub fn seek(&mut self, seconds: f64) -> bool {
        let seconds = if seconds.is_finite() { seconds.max(0.0) } else { 0.0 };
        self.pending.clear();
        self.cursor = 0;
        self.ended = false;
        let to = SeekTo::Time { time: Time::from(seconds), track_id: Some(self.track_id) };
        let ok = self.format.seek(SeekMode::Accurate, to).is_ok();
        self.decoder.reset();
        self.skip_to = ok.then_some(seconds);
        ok
    }

    /// Fills `out` (interleaved stereo) with up to `out.len() / 2` frames;
    /// fewer only at the end of the track.
    pub fn read(&mut self, out: &mut [f32]) -> usize {
        let want = out.len() / 2;
        let mut done = 0;
        while done < want {
            if self.cursor >= self.pending.len() {
                if !self.fill() {
                    break;
                }
                continue;
            }
            let n = ((self.pending.len() - self.cursor) / 2).min(want - done);
            out[done * 2..(done + n) * 2].copy_from_slice(&self.pending[self.cursor..self.cursor + n * 2]);
            self.cursor += n * 2;
            done += n;
        }
        done
    }

    // The next packet of the track, decoded into `pending`; false at the end.
    fn fill(&mut self) -> bool {
        while !self.ended {
            let packet = match self.format.next_packet() {
                Ok(packet) => packet,
                Err(_) => {
                    self.ended = true;
                    break;
                }
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            let audio = match self.decoder.decode(&packet) {
                Ok(audio) => audio,
                // One bad packet is skipped, not the end.
                Err(Error::DecodeError(_)) => continue,
                Err(_) => {
                    self.ended = true;
                    break;
                }
            };
            let spec = *audio.spec();
            if self.rate == 0 && spec.rate > 0 {
                self.rate = spec.rate;
            }
            let channels = spec.channels.count().max(1);
            let Ok(samples) = copy_audio_packet(&mut self.buffer, audio) else {
                continue;
            };
            let frames = samples.len() / channels;
            let mut first = 0;
            if let Some(to) = self.skip_to {
                if let Some(base) = self.time_base {
                    let start = base.calc_time(packet.ts());
                    let drop = ((to - (start.seconds as f64 + start.frac)) * self.rate as f64).round();
                    if drop >= frames as f64 {
                        continue;
                    }
                    first = drop.max(0.0) as usize;
                }
                self.skip_to = None;
            }
            self.pending.clear();
            self.cursor = 0;
            for frame in samples.chunks_exact(channels).skip(first) {
                let left = if frame[0].is_finite() { frame[0] } else { 0.0 };
                let right = if channels > 1 && frame[1].is_finite() { frame[1] } else { left };
                self.pending.push(left);
                self.pending.push(right);
            }
            if !self.pending.is_empty() {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A mono 16-bit WAV whose every sample is its own index (mod 30000).
    fn write_ramp_wav(path: &Path, rate: u32, frames: u32) {
        let mut bytes = Vec::new();
        let data = frames * 2;
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * 2).to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data.to_le_bytes());
        for i in 0..frames {
            bytes.extend_from_slice(&((i % 30000) as i16).to_le_bytes());
        }
        std::fs::write(path, bytes).unwrap();
    }

    fn index(sample: f32) -> i64 {
        (sample * 32768.0).round() as i64
    }

    #[test]
    fn reads_stereo_from_the_exact_frame_after_a_seek() {
        let path = std::env::temp_dir().join(format!("kvj-sound-{}.wav", std::process::id()));
        write_ramp_wav(&path, 8000, 8000 * 4);
        let mut sound = SoundStream::open(&path).unwrap();
        assert_eq!(sound.rate(), 8000);
        assert!((sound.duration() - 4.0).abs() < 1e-6);

        let mut out = vec![0f32; 2 * 100];
        assert_eq!(sound.read(&mut out), 100);
        assert_eq!(index(out[0]), 0);
        assert_eq!(index(out[2 * 99]), 99);
        // Mono comes out on both sides.
        assert_eq!(out[2 * 50], out[2 * 50 + 1]);

        assert!(sound.seek(1.2345));
        assert_eq!(sound.read(&mut out), 100);
        assert_eq!(index(out[0]), 9876);
        assert_eq!(index(out[2 * 99]), 9975);

        // Back again, and on to the end: fewer frames only there.
        assert!(sound.seek(3.99));
        let mut tail = vec![0f32; 2 * 1000];
        assert_eq!(sound.read(&mut tail), 80);
        std::fs::remove_file(&path).ok();
    }
}
