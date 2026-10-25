//! The timeline's waveform: KDJ's whole-track preview ("整曲预览", release
//! overview in `kdj-analysis/src/waveform.rs`), at a fixed 100 columns a second
//! instead of 4096 columns a track so that it still has detail zoomed in.
//!
//! Per column: the height (0..255) is the total band energy between the 5th and
//! 99th percentile of the file's energy over KDJ's buckets (a quarter second),
//! raised to 1.2, so a pixel showing the energy of its columns stands like
//! KDJ's preview while single columns still show the beat; R, G and B are the low
//! (< 200 Hz), mid (200–1500 Hz) and high (1500–8000 Hz) shares of the column
//! against their median share over the file, the same strengths KDJ hands its
//! palette. Analysis runs at the file's own rate, streamed, with a 64 ms Hann
//! window centred on each column; the result is cached on disk.
use anyhow::{bail, Context, Result};
use rustfft::{num_complex::Complex, FftPlanner};
use std::{
    fs,
    hash::{Hash, Hasher},
    io::Write,
    path::Path,
};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{DecoderOptions, CODEC_TYPE_NULL},
    errors::Error,
    formats::FormatOptions,
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};

/// Columns a second.
pub const RATE: f64 = 100.;
const REVISION: u32 = 2;
const MAGIC: &[u8; 8] = b"KVJWAVE\0";
const LOW_HZ: f64 = 200.;
const HIGH_HZ: f64 = 1500.;
const TOP_HZ: f64 = 8000.;
const AMP_GAMMA: f64 = 1.2;
const COLOR_GAMMA: f64 = 2.4;
const COLOR_FLOOR: f64 = 0.12;
/// Colour is smoothed over this long; KDJ smooths over 1/128 of a track
/// (about 2 s for four minutes), which would be minutes for a whole set.
const COLOR_SPAN_SECONDS: f64 = 1.;
/// KDJ averages energy over 4096 buckets a track before it normalises the
/// height: a quarter second or so for the usual song.
const BUCKET_SECONDS: f64 = 0.25;

pub struct Waveform {
    /// Heights, then R, G, B: `columns` bytes each.
    pub bytes: Vec<u8>,
    pub columns: usize,
}

/// The waveform of `path`, from `cache_dir` when it was made before. `None` when cancelled.
pub fn load(path: &Path, cache_dir: &Path, cancelled: &dyn Fn() -> bool) -> Result<Option<Waveform>> {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    ("kvj-wave", REVISION, path, super::index::signature(path)?).hash(&mut h);
    let file = cache_dir.join(format!("{:016x}.kwv", h.finish()));
    if let Some(wave) = fs::read(&file).ok().and_then(|data| parse(&data)) {
        return Ok(Some(wave));
    }
    let Some(wave) = analyse(path, cancelled)? else {
        return Ok(None);
    };
    // A cache that cannot be written only costs the next analysis.
    let _ = fs::create_dir_all(cache_dir).and_then(|_| {
        let part = file.with_extension("part");
        let mut out = fs::File::create(&part)?;
        out.write_all(MAGIC)?;
        out.write_all(&REVISION.to_le_bytes())?;
        out.write_all(&(wave.columns as u64).to_le_bytes())?;
        out.write_all(&wave.bytes)?;
        drop(out);
        fs::rename(&part, &file)
    });
    Ok(Some(wave))
}

fn parse(data: &[u8]) -> Option<Waveform> {
    let rest = data.strip_prefix(MAGIC)?;
    if u32::from_le_bytes(rest.get(..4)?.try_into().ok()?) != REVISION {
        return None;
    }
    let columns = u64::from_le_bytes(rest.get(4..12)?.try_into().ok()?) as usize;
    let bytes = rest.get(12..)?;
    (bytes.len() == columns.checked_mul(4)?).then(|| Waveform { bytes: bytes.to_vec(), columns })
}

/// Band energies of one 64 ms frame every 1/RATE s, the frame centred on its column.
struct Bands {
    sr: f64,
    n: usize,
    fft: std::sync::Arc<dyn rustfft::Fft<f32>>,
    window: Vec<f32>,
    edges: [usize; 3],
    buffer: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    /// Mono samples from absolute sample `origin` on; the first n/2 are the padding before 0.
    pending: Vec<f32>,
    origin: usize,
    next: usize,
    energy: [Vec<f64>; 3],
}

impl Bands {
    fn new(sr: u32) -> Self {
        let sr = sr as f64;
        // 64 ms like KDJ's 1024 points at 16 kHz, rounded to a size the FFT does fast.
        let n = ((sr * 0.064 / 64.).round() as usize).max(4) * 64;
        let fft = FftPlanner::new().plan_fft_forward(n);
        let window = (0..n)
            .map(|i| (0.5 - 0.5 * (2. * std::f64::consts::PI * i as f64 / n as f64).cos()) as f32)
            .collect();
        let bin = |hz: f64| ((hz * n as f64 / sr).ceil() as usize).min(n / 2 + 1);
        let scratch = vec![Complex::default(); fft.get_inplace_scratch_len()];
        Self {
            sr,
            n,
            fft,
            window,
            edges: [bin(LOW_HZ), bin(HIGH_HZ), bin(TOP_HZ)],
            buffer: vec![Complex::default(); n],
            scratch,
            pending: vec![0.; n / 2],
            origin: 0,
            next: 0,
            energy: Default::default(),
        }
    }

    /// Start of frame `i` in padded samples.
    fn start(&self, i: usize) -> usize {
        (i as f64 * self.sr / RATE).round() as usize
    }

    fn push(&mut self, mono: impl Iterator<Item = f32>, cancelled: &dyn Fn() -> bool) -> bool {
        self.pending.extend(mono);
        while self.start(self.next) + self.n <= self.origin + self.pending.len() {
            if self.next % 256 == 0 && cancelled() {
                return false;
            }
            let at = self.start(self.next) - self.origin;
            for ((slot, x), w) in self.buffer.iter_mut().zip(&self.pending[at..at + self.n]).zip(&self.window) {
                *slot = Complex::new(x * w, 0.);
            }
            self.fft.process_with_scratch(&mut self.buffer, &mut self.scratch);
            let mut from = 0;
            for (band, &to) in self.edges.iter().enumerate() {
                let sum: f64 = self.buffer[from..to].iter().map(|v| v.norm_sqr() as f64).sum();
                self.energy[band].push(sum);
                from = to;
            }
            self.next += 1;
        }
        let keep = self.start(self.next) - self.origin;
        self.pending.drain(..keep.min(self.pending.len()));
        self.origin += keep;
        true
    }

    /// Pads the end and takes frames up to the last real sample.
    fn finish(mut self, samples: usize, cancelled: &dyn Fn() -> bool) -> Option<[Vec<f64>; 3]> {
        let columns = (samples as f64 * RATE / self.sr).ceil() as usize;
        let pad = self.n / 2 + self.n;
        if !self.push(std::iter::repeat_n(0., pad), cancelled) {
            return None;
        }
        for band in &mut self.energy {
            band.truncate(columns);
        }
        Some(self.energy)
    }
}

fn analyse(path: &Path, cancelled: &dyn Fn() -> bool) -> Result<Option<Waveform>> {
    let input = MediaSourceStream::new(Box::new(fs::File::open(path)?), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
        hint.with_extension(ext);
    }
    let probe = symphonia::default::get_probe().format(
        &hint,
        input,
        &FormatOptions { enable_gapless: true, ..Default::default() },
        &MetadataOptions::default(),
    )?;
    let mut format = probe.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .context("没有音轨")?;
    let id = track.id;
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?;
    let mut bands: Option<Bands> = None;
    let mut buffer: Option<SampleBuffer<f32>> = None;
    let mut samples = 0usize;
    loop {
        if cancelled() {
            return Ok(None);
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(Error::ResetRequired) => break,
            Err(e) => {
                tracing::debug!("波形：读取音频包结束：{e}");
                break;
            }
        };
        if packet.track_id() != id {
            continue;
        }
        let audio = match decoder.decode(&packet) {
            Ok(audio) => audio,
            Err(Error::DecodeError(e)) => {
                tracing::debug!("波形：跳过损坏的音频包：{e}");
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        let spec = *audio.spec();
        let b = bands.get_or_insert_with(|| Bands::new(spec.rate));
        if b.sr != spec.rate as f64 {
            bail!("音轨中途改变采样率");
        }
        let channels = spec.channels.count().max(1);
        let required = audio.capacity() * channels;
        if buffer.as_ref().is_none_or(|s| s.capacity() < required) {
            buffer = Some(SampleBuffer::new(audio.capacity() as u64, spec));
        }
        let slot = buffer.as_mut().unwrap();
        slot.copy_interleaved_ref(audio);
        let frames = slot.samples().chunks(channels).map(|f| {
            let v = f.iter().sum::<f32>();
            if v.is_finite() { v } else { 0. }
        });
        samples += slot.samples().len() / channels;
        if !b.push(frames, cancelled) {
            return Ok(None);
        }
    }
    let Some(b) = bands else { bail!("解码结果为空") };
    let Some(energy) = b.finish(samples, cancelled) else {
        return Ok(None);
    };
    Ok(Some(shape(&energy)))
}

/// KDJ's release-overview height and colour over the band energies.
fn shape(bands: &[Vec<f64>; 3]) -> Waveform {
    let count = bands[0].len();
    let mut bytes = vec![0u8; count * 4];
    if count == 0 {
        return Waveform { bytes, columns: 0 };
    }
    let energy: Vec<f64> = (0..count).map(|i| bands[0][i] + bands[1][i] + bands[2][i]).collect();
    let amp: Vec<f64> = energy.iter().map(|e| e.sqrt()).collect();
    let bucket = ((BUCKET_SECONDS * RATE) as usize).max(1) | 1;
    let mut sorted: Vec<f64> = if count > bucket { moving_average(&energy, bucket) } else { energy }
        .into_iter()
        .map(f64::sqrt)
        .collect();
    sorted.sort_by(f64::total_cmp);
    let hi = percentile(&sorted, 99.).max(1e-9);
    let lo = percentile(&sorted, 5.);
    for (slot, value) in bytes[..count].iter_mut().zip(&amp) {
        let v = ((value - lo) / (hi - lo).max(1e-9)).clamp(0., 1.).powf(AMP_GAMMA);
        *slot = (v * 255.).round() as u8;
    }

    let span = ((COLOR_SPAN_SECONDS * RATE) as usize).max(3) | 1;
    let mag: [Vec<f64>; 3] = std::array::from_fn(|band| {
        let row: Vec<f64> = bands[band].iter().map(|v| v.sqrt()).collect();
        if count > span { moving_average(&row, span) } else { row }
    });
    let share: [Vec<f64>; 3] = std::array::from_fn(|band| {
        (0..count)
            .map(|i| mag[band][i] / (mag[0][i] + mag[1][i] + mag[2][i]).max(1e-12))
            .collect()
    });
    let reference: [f64; 3] = std::array::from_fn(|band| {
        let mut values = share[band].clone();
        values.sort_by(f64::total_cmp);
        let value = percentile(&values, 50.);
        if value <= 0. { 1. } else { value }
    });
    for i in 0..count {
        let dev: [f64; 3] = std::array::from_fn(|band| (share[band][i] / reference[band]).powf(COLOR_GAMMA));
        let peak = dev.iter().cloned().fold(0., f64::max).max(1e-9);
        for band in 0..3 {
            let lifted = COLOR_FLOOR + (1. - COLOR_FLOOR) * (dev[band] / peak).clamp(0., 1.);
            bytes[(band + 1) * count + i] = (lifted * 255.).round() as u8;
        }
    }
    Waveform { bytes, columns: count }
}

/// Linear interpolation on sorted values, `p` in 0..=100.
fn percentile(sorted: &[f64], p: f64) -> f64 {
    let at = p / 100. * (sorted.len() - 1) as f64;
    let (a, b) = (at.floor() as usize, at.ceil() as usize);
    sorted[a] + (sorted[b] - sorted[a]) * (at - a as f64)
}

/// Centred box average over `span` (odd) values, the edges repeated.
fn moving_average(values: &[f64], span: usize) -> Vec<f64> {
    let half = span / 2;
    let last = values.len() - 1;
    let at = |i: isize| values[i.clamp(0, last as isize) as usize];
    let mut sum: f64 = (-(half as isize)..=half as isize).map(at).sum();
    let mut out = Vec::with_capacity(values.len());
    for i in 0..values.len() as isize {
        out.push(sum / span as f64);
        sum += at(i + half as isize + 1) - at(i - half as isize);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f64, seconds: f64, sr: u32) -> Vec<f32> {
        (0..(seconds * sr as f64) as usize)
            .map(|i| (2. * std::f64::consts::PI * hz * i as f64 / sr as f64).sin() as f32)
            .collect()
    }

    fn bands_of(samples: &[f32], sr: u32) -> [Vec<f64>; 3] {
        let mut b = Bands::new(sr);
        for chunk in samples.chunks(1024) {
            assert!(b.push(chunk.iter().copied(), &|| false));
        }
        b.finish(samples.len(), &|| false).unwrap()
    }

    #[test]
    fn a_column_every_hundredth_of_a_second() {
        let bands = bands_of(&tone(100., 3.005, 44_100), 44_100);
        assert_eq!(bands[0].len(), 301);
        assert!(bands.iter().all(|b| b.len() == 301));
    }

    #[test]
    fn bass_then_hats_colour_red_then_blue() {
        let sr = 48_000;
        let mut samples = tone(80., 4., sr);
        samples.extend(tone(5000., 4., sr));
        let wave = shape(&bands_of(&samples, sr));
        let n = wave.columns;
        let rgb = |i: usize| (wave.bytes[n + i], wave.bytes[2 * n + i], wave.bytes[3 * n + i]);
        let (r, _, b) = rgb(100);
        assert!(r > 200 && b < 80, "bass {:?}", rgb(100));
        let (r, _, b) = rgb(700);
        assert!(b > 200 && r < 80, "hats {:?}", rgb(700));
    }

    #[test]
    fn silence_is_flat_and_loud_is_tall() {
        let sr = 22_050;
        let mut samples = vec![0f32; sr as usize * 2];
        samples.extend(tone(440., 2., sr));
        let wave = shape(&bands_of(&samples, sr));
        assert_eq!(wave.bytes[50], 0);
        assert!(wave.bytes[300] > 200);
    }

    #[test]
    fn moving_average_keeps_a_constant() {
        assert_eq!(moving_average(&[2., 2., 2., 2.], 3), vec![2.; 4]);
        assert_eq!(moving_average(&[0., 3., 0.], 3), vec![1., 1., 1.]);
    }
}
