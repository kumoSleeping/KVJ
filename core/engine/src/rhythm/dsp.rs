//! The few signal helpers V4 needs, from KDJ (`kdj-analysis/src/dsp.rs` and the
//! tempo-family choice in `tempo.rs`), unchanged so a file's tempo reads the same
//! in both apps.
use rustfft::{Fft, FftPlanner};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

const BPM_MIN: f64 = 60.0;
const BPM_MAX: f64 = 200.0;

struct Fft64Pair {
    forward: Arc<dyn Fft<f64>>,
    inverse: Arc<dyn Fft<f64>>,
}

static FFT64_PAIRS: OnceLock<Mutex<HashMap<usize, Arc<Fft64Pair>>>> = OnceLock::new();

fn fft64_pair(n_fft: usize) -> Arc<Fft64Pair> {
    let plans = FFT64_PAIRS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut plans = plans
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Arc::clone(plans.entry(n_fft).or_insert_with(|| {
        let mut planner = FftPlanner::<f64>::new();
        Arc::new(Fft64Pair {
            forward: planner.plan_fft_forward(n_fft),
            inverse: planner.plan_fft_inverse(n_fft),
        })
    }))
}

/// HTK 公式（不是 Slaney）。起音检测只关心刻度单调压缩，HTK 更简单。
pub fn hz_to_mel(hz: f64) -> f64 {
    2595.0 * (1.0 + hz / 700.0).log10()
}

pub fn mel_to_hz(mel: f64) -> f64 {
    700.0 * (10.0f64.powf(mel / 2595.0) - 1.0)
}

pub fn rfft_freqs(n_fft: usize, sr: f64) -> Vec<f64> {
    (0..=n_fft / 2)
        .map(|i| i as f64 * sr / n_fft as f64)
        .collect()
}

/// 三角滤波器组，`n_mels` 行 × `1 + n_fft/2` 列。峰值归一（不做 Slaney 面积归一）。
pub fn mel_filterbank(sr: f64, n_fft: usize, n_mels: usize, fmin: f64, fmax: f64) -> Vec<Vec<f32>> {
    let fmax = if fmax > sr / 2.0 { sr / 2.0 } else { fmax };
    let freqs = rfft_freqs(n_fft, sr);
    let mel_lo = hz_to_mel(fmin);
    let mel_hi = hz_to_mel(fmax);
    let edges: Vec<f64> = (0..n_mels + 2)
        .map(|i| {
            let t = i as f64 / (n_mels + 1) as f64;
            mel_to_hz(mel_lo + t * (mel_hi - mel_lo))
        })
        .collect();

    (0..n_mels)
        .map(|i| {
            let (left, center, right) = (edges[i], edges[i + 1], edges[i + 2]);
            if right <= left {
                return vec![0.0f32; freqs.len()];
            }
            freqs
                .iter()
                .map(|f| {
                    let rising = (f - left) / (center - left).max(1e-9);
                    let falling = (right - f) / (right - center).max(1e-9);
                    rising.min(falling).max(0.0) as f32
                })
                .collect()
        })
        .collect()
}

/// 一个 Mel 三角带只有很短一段连续非零权重。保存该区间可跳过绝大多数零乘法，
/// 同时仍按原来的 bin 顺序累加，因此浮点结果与稠密实现一致。
#[derive(Clone, Debug)]
pub struct SparseMelBand {
    pub start_bin: usize,
    pub weights: Vec<f32>,
}

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
struct MelFilterbankKey {
    sr_bits: u64,
    n_fft: usize,
    n_mels: usize,
    fmin_bits: u64,
    fmax_bits: u64,
}

static SPARSE_MEL_FILTERBANKS: OnceLock<Mutex<HashMap<MelFilterbankKey, Arc<[SparseMelBand]>>>> =
    OnceLock::new();

pub fn sparse_mel_filterbank(
    sr: f64,
    n_fft: usize,
    n_mels: usize,
    fmin: f64,
    fmax: f64,
) -> Arc<[SparseMelBand]> {
    let key = MelFilterbankKey {
        sr_bits: sr.to_bits(),
        n_fft,
        n_mels,
        fmin_bits: fmin.to_bits(),
        fmax_bits: fmax.to_bits(),
    };
    let cache = SPARSE_MEL_FILTERBANKS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut cache = cache
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Arc::clone(cache.entry(key).or_insert_with(|| {
        let dense = mel_filterbank(sr, n_fft, n_mels, fmin, fmax);
        let sparse: Vec<SparseMelBand> = dense
            .into_iter()
            .map(|row| {
                let start = row.iter().position(|weight| *weight != 0.0).unwrap_or(0);
                let end = row
                    .iter()
                    .rposition(|weight| *weight != 0.0)
                    .map_or(start, |index| index + 1);
                SparseMelBand {
                    start_bin: start,
                    weights: row[start..end].to_vec(),
                }
            })
            .collect();
        Arc::from(sparse)
    }))
}

/// 滑动均值（边缘 edge 复制补齐），前缀和实现 O(n)。
pub fn moving_average(x: &[f64], win: usize) -> Vec<f64> {
    let win = win.max(1);
    if win <= 1 || x.is_empty() {
        return x.to_vec();
    }
    let pad_left = win / 2;
    let pad_right = win - 1 - pad_left;
    let mut padded = Vec::with_capacity(x.len() + win);
    padded.extend(std::iter::repeat(x[0]).take(pad_left));
    padded.extend_from_slice(x);
    padded.extend(std::iter::repeat(x[x.len() - 1]).take(pad_right));

    let mut prefix = vec![0.0f64; padded.len() + 1];
    for (i, value) in padded.iter().enumerate() {
        prefix[i + 1] = prefix[i] + value;
    }
    (0..x.len())
        .map(|i| (prefix[i + win] - prefix[i]) / win as f64)
        .collect()
}

/// 循环自相关（补零到 2N 以上避免 wrap），返回 lag = 0..=max_lag 的**无偏**估计。
///
/// 无偏这一步不能省：lag 越大重叠样本越少，不除以重叠数会让长 lag 系统性偏小，
/// 慢速的曲子会被系统性判快。
pub fn autocorrelate(x: &[f64], max_lag: usize) -> Vec<f64> {
    let n = x.len();
    if n == 0 {
        return vec![0.0; max_lag + 1];
    }
    let mean = x.iter().sum::<f64>() / n as f64;
    let nfft = (2 * n).max(2).next_power_of_two();

    let plans = fft64_pair(nfft);
    let mut buffer: Vec<rustfft::num_complex::Complex<f64>> = (0..nfft)
        .map(|i| {
            let value = if i < n { x[i] - mean } else { 0.0 };
            rustfft::num_complex::Complex::new(value, 0.0)
        })
        .collect();
    let scratch_len = plans
        .forward
        .get_inplace_scratch_len()
        .max(plans.inverse.get_inplace_scratch_len());
    let mut scratch = vec![rustfft::num_complex::Complex::new(0.0, 0.0); scratch_len];
    plans
        .forward
        .process_with_scratch(&mut buffer, &mut scratch);
    for slot in buffer.iter_mut() {
        // |X|²：功率谱，逆变换回来就是自相关
        *slot = rustfft::num_complex::Complex::new(slot.norm_sqr(), 0.0);
    }
    plans
        .inverse
        .process_with_scratch(&mut buffer, &mut scratch);

    (0..=max_lag.min(nfft - 1))
        .map(|lag| {
            let overlap = (n as f64 - lag as f64).max(1.0);
            buffer[lag].re / nfft as f64 / overlap
        })
        .chain(std::iter::repeat(0.0))
        .take(max_lag + 1)
        .collect()
}

/// 抛物线插值求亚采样峰位。
///
/// 自相关的 lag 只有整数分辨率，不插值 BPM 误差可达 2%（174 BPM 时差 3 个数）。
pub fn parabolic_peak(values: &[f64], idx: usize) -> f64 {
    if idx == 0 || idx + 1 >= values.len() {
        return idx as f64;
    }
    let (a, b, c) = (values[idx - 1], values[idx], values[idx + 1]);
    let denom = a - 2.0 * b + c;
    if denom.abs() < 1e-12 {
        return idx as f64;
    }
    let shift = 0.5 * (a - c) / denom;
    if !shift.is_finite() || shift.abs() > 1.0 {
        return idx as f64;
    }
    idx as f64 + shift
}

pub fn median(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    }
}

/// 线性插值取值，等价 `np.interp(pos, arange(n), values)`。
pub fn interp_at(values: &[f64], pos: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let clamped = pos.clamp(0.0, (values.len() - 1) as f64);
    let low = clamped.floor() as usize;
    let high = clamped.ceil() as usize;
    if low == high {
        return values[low];
    }
    let frac = clamped - low as f64;
    values[low] * (1.0 - frac) + values[high] * frac
}

/// 对数正态先验，中心 120 BPM，σ = 0.9 个八度。抑制自相关天然偏爱的长 lag。
fn tempo_prior(bpm: f64) -> f64 {
    (-0.5 * ((bpm / 120.0).log2() / 0.9).powi(2)).exp()
}

/// 梳状滤波打分：按 period 折叠包络，取最优相位下的「拍上能量 − 拍间能量」。
///
/// 只看拍上能量是分不出 T 和 2T 的（2T 的每一次命中都落在真拍上，均值一样高）。
/// 减掉偏移半个周期的"拍间能量"就能分开：
/// - period = 真周期 → 拍间是弱拍，差值大；
/// - period = 2×真周期 → 拍间正好是另一半真拍，差值 ≈ 0；
/// - period = 0.5×真周期 → 拍上一半命中空档，均值本身就低。
///
/// 这正是舞曲 128 被判成 64/256 的解药。
pub fn comb_score(env: &[f64], period: f64) -> f64 {
    let n = env.len();
    if period < 2.0 || n < 8 {
        return 0.0;
    }
    let n_cycles = ((n - 1) as f64 / period) as usize;
    if n_cycles < 3 {
        return 0.0;
    }
    let n_phase = (period.ceil() as usize).max(2);
    let limit = (n - 1) as f64;

    let mut best_on = f64::NEG_INFINITY;
    let mut best_off = 0.0;
    for phase in 0..n_phase {
        let mut on_sum = 0.0;
        let mut on_count = 0usize;
        let mut off_sum = 0.0;
        let mut off_count = 0usize;
        for cycle in 0..=n_cycles {
            let pos_on = phase as f64 + period * cycle as f64;
            if pos_on <= limit {
                on_sum += interp_at(env, pos_on);
                on_count += 1;
            }
            let pos_off = pos_on + period / 2.0;
            if pos_off <= limit {
                off_sum += interp_at(env, pos_off);
                off_count += 1;
            }
        }
        let on = on_sum / on_count.max(1) as f64;
        if on > best_on {
            best_on = on;
            best_off = off_sum / off_count.max(1) as f64;
        }
    }
    let contrast = (best_on - best_off).max(0.0);
    // 加一点绝对能量：全曲毫无拍间对比时（纯 pad / 氛围）至少还能按能量排出个先后
    contrast + 0.05 * best_on
}

/// 自相关粗估：在 `[BPM_MIN, BPM_MAX]` 对应的 lag 区间取前 `top` 个峰。
pub fn tempo_candidates(env: &[f64], fps: f64, top: usize) -> Vec<f64> {
    if env.len() < 16 {
        return Vec::new();
    }
    let min_lag = ((60.0 * fps / BPM_MAX).floor() as usize).max(2);
    let max_lag = ((60.0 * fps / BPM_MIN).ceil() as usize).min(env.len().saturating_sub(2));
    if max_lag <= min_lag + 1 {
        return Vec::new();
    }

    let ac = autocorrelate(env, max_lag);
    let mut weighted = vec![0.0f64; ac.len()];
    for lag in min_lag..=max_lag {
        let bpm = 60.0 * fps / (lag as f64).max(1e-9);
        weighted[lag] = ac[lag].max(0.0) * tempo_prior(bpm);
    }

    let mut peaks: Vec<usize> = (min_lag + 1..max_lag)
        .filter(|lag| {
            weighted[*lag] > weighted[lag - 1]
                && weighted[*lag] >= weighted[lag + 1]
                && weighted[*lag] > 0.0
        })
        .collect();
    if peaks.is_empty() {
        let argmax = weighted
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(i, _)| i)
            .unwrap_or(min_lag);
        peaks.push(argmax);
    }
    peaks.sort_by(|a, b| {
        weighted[*b]
            .partial_cmp(&weighted[*a])
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    peaks
        .into_iter()
        .take(top)
        .filter_map(|idx| {
            let lag = parabolic_peak(&weighted, idx);
            (lag > 0.0).then(|| 60.0 * fps / lag)
        })
        .collect()
}

/// 在自相关候选里找与 `bpm_raw` 成 `lo..=hi` 倍关系的峰。
fn find_ratio_peak(bpm_raw: f64, candidates: &[f64], lo: f64, hi: f64) -> Option<f64> {
    candidates
        .iter()
        .copied()
        .find(|candidate| (lo..=hi).contains(&(*candidate / bpm_raw)))
}

/// 在候选里取与 raw 成近 2× 的最快峰。
fn find_double_peak(bpm_raw: f64, candidates: &[f64]) -> Option<f64> {
    candidates
        .iter()
        .copied()
        .filter(|candidate| {
            let ratio = *candidate / bpm_raw;
            (1.95..=2.05).contains(&ratio)
        })
        .max_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
}

/// 起音包络里局部峰的密度（峰/秒）。阈值 0.15 对应归一化后的中等起音。
fn onset_peak_rate(env: &[f64], fps: f64) -> f64 {
    if env.len() < 3 || fps <= 0.0 {
        return 0.0;
    }
    let mut peaks = 0usize;
    for i in 1..env.len() - 1 {
        if env[i] >= 0.15 && env[i] > env[i - 1] && env[i] >= env[i + 1] {
            peaks += 1;
        }
    }
    let duration = env.len() as f64 / fps;
    if duration <= 0.0 {
        0.0
    } else {
        peaks as f64 / duration
    }
}

/// 若把 `bpm` 当拍速，平均每拍落多少起音峰。>1 说明网格偏慢（细分被算成拍）。
fn onsets_per_beat(env: &[f64], fps: f64, bpm: f64) -> f64 {
    if bpm <= 0.0 {
        return 0.0;
    }
    onset_peak_rate(env, fps) / (bpm / 60.0)
}

/// 4:3 提升：主峰常是「每三拍一组」的慢网格，真四分在 4/3 倍。
///
/// Our Chant：raw 92、次峰 184（2×）、第三峰 123（4/3）；梳状分 123 最高 → 123。
/// 只有当 4/3 峰的梳状分不弱于 raw **且不弱于 2×** 才升，避免和真倍速抢。
fn promote_four_three(env: &[f64], fps: f64, bpm_raw: f64, candidates: &[f64]) -> Option<f64> {
    // 只修「主峰偏慢」：raw 已在常见舞曲区就别再抬（Sky High 128 不该→172）。
    if bpm_raw >= 110.0 {
        return None;
    }
    let mid = find_ratio_peak(bpm_raw, candidates, 1.28, 1.40)?;
    // 起音过密（每拍 >1.4 个峰）是典型「高速曲被听成半速」：交给 2×，
    // 不让差一点的 4:3 峰（VICTORY 的 127）截胡真 2×（188）。
    if onsets_per_beat(env, fps, bpm_raw) >= 1.4 {
        return None;
    }
    let raw_score = comb_score(env, 60.0 * fps / bpm_raw);
    let mid_score = comb_score(env, 60.0 * fps / mid);
    if mid_score < raw_score {
        return None;
    }
    if let Some(double) = find_double_peak(bpm_raw, candidates) {
        let double_score = comb_score(env, 60.0 * fps / double);
        // 必须明显优于 2×，平局或微弱优势都留给倍速通道。
        if mid_score < double_score * 1.15 {
            return None;
        }
    }
    Some(mid)
}

/// 2× 半速救援。
///
/// - `bpm_raw < 75` 或 `85..90`：历史无条件提升（只要 2× 已是自相关峰）。
/// - 其它区间：单靠梳状会在 EDM 100↔200 与动画高速曲上互打脸
///   （Full Glory 梳状站 99、Summersong 梳状站 199，真相相反）。
///   用「每拍起音数」辅助：raw 上每拍 >~1.4 个起音 → 网格偏慢，抬到 2×；
///   每拍 ≤1 且只是梳状略偏 2× → 保持 raw（Summersong ~100）。
fn promote_double_tempo(env: &[f64], fps: f64, bpm_raw: f64, candidates: &[f64]) -> Option<f64> {
    let fast = find_double_peak(bpm_raw, candidates)?;
    let allow_unconditional = bpm_raw < 75.0 || (85.0..90.0).contains(&bpm_raw);
    if allow_unconditional {
        return Some(fast);
    }

    let raw_score = comb_score(env, 60.0 * fps / bpm_raw);
    let fast_score = comb_score(env, 60.0 * fps / fast);
    let opb = onsets_per_beat(env, fps, bpm_raw);

    // 起音明显密于「一拍一下」→ 主峰是半速（Full Glory opb≈1.6 / VICTORY≈1.5）。
    if opb >= 1.4 {
        return Some(fast);
    }
    let comb_ratio = fast_score / raw_score.max(1e-9);
    // 起音极稀（铺底长、鼓点很晚才进，如 ONENESS 约 21s 后才上速度）：
    // 密度统计失真，改信梳状。限定 raw∈[85,105]（高速曲半速主峰的典型落点），
    // 避免和 Summersong（opb≈0.95、同样 comb 略偏 2×）搅在一起。
    if opb < 0.5 && comb_ratio >= 1.3 && (85.0..105.0).contains(&bpm_raw) {
        return Some(fast);
    }
    // 梳状明显偏好 2× + 不算稀疏：BRAVE JEWEL（comb×3、opb≈1.0）。
    if comb_ratio >= 1.5 && opb >= 1.0 {
        return Some(fast);
    }
    // 梳状压倒性偏好 2×（≥2.5×）：流行朋克半速主峰（The Other Line comb×3.5、
    // opb≈0.71）。Summersong 2025 只有 comb×1.7 且 opb≈0.95，不会误触。
    if comb_ratio >= 2.5 && opb >= 0.65 {
        return Some(fast);
    }
    // 梳状略偏 2× + 中等偏密。
    if comb_ratio >= 1.0 && opb >= 1.25 {
        return Some(fast);
    }
    None
}

/// 3:2（×1.5）提升：每三个八分音符的强重音会把自相关主峰钉在真速度的 ⅔。
///
/// - `bpm_raw < 100`：历史规则，直接升到 1.5×（85→128/171、93→141 一类偶像曲）。
/// - `bpm_raw ≥ 100`：必须 1.5× 已是自相关峰，且梳状对比**不弱于**主峰才升。
///   Sing Alive 官方 195：主峰 129（=195×⅔），次峰 195，梳状分 195≥129 → 提升；
///   对正确的 120 不会仅仅因为存在弱 180 峰就被拉走。
fn promote_three_two(env: &[f64], fps: f64, bpm_raw: f64, candidates: &[f64]) -> Option<f64> {
    let fast = find_ratio_peak(bpm_raw, candidates, 1.45, 1.55)?;
    if bpm_raw < 100.0 {
        return Some(fast);
    }
    let raw_score = comb_score(env, 60.0 * fps / bpm_raw);
    let fast_score = comb_score(env, 60.0 * fps / fast);
    (fast_score >= raw_score).then_some(fast)
}

/// 返回 `(最终 bpm, 自相关粗估 bpm)`。倍频修正在这里做。
pub fn choose_tempo(env: &[f64], fps: f64) -> (f64, f64) {
    // 五个峰仍很便宜，却能保住 4:3 层级较弱的那一支（真实曲库里常落在第 4 峰）。
    let cands = tempo_candidates(env, fps, 5);
    let Some(&bpm_raw) = cands.first() else {
        return (0.0, 0.0);
    };

    // 以最强自相关峰为主，不再让梳状滤波在互不相关的速度族之间投票。
    // 后者会把 150 BPM 的 final phase 稳定选成三连音脉冲 100 BPM。
    //
    // 同一速度族内的关系按「更细 → 更粗」试：3:2、4:3、2:1。
    // 候选必须已经是自相关强峰，不会凭空造速度。
    if let Some(fast) = promote_three_two(env, fps, bpm_raw, &cands) {
        return (fast, bpm_raw);
    }
    // 4:3 必须在 2× 之前：否则 Our Chant 会先被 92→184 吃掉。
    if let Some(mid) = promote_four_three(env, fps, bpm_raw, &cands) {
        return (mid, bpm_raw);
    }
    if let Some(fast) = promote_double_tempo(env, fps, bpm_raw, &cands) {
        return (fast, bpm_raw);
    }

    // 高速主峰也可能只是细分拍。这里只在同一速度族内部比较梳状对比度：
    // 半速必须比高速更像“拍上强、拍间弱”；3:4 层则允许很小余量，因为
    // shuffle / 三连音编曲的四分音符并不一定拥有更强的全频瞬态。
    let raw_score = comb_score(env, 60.0 * fps / bpm_raw);
    let slower = cands.iter().copied().find(|candidate| {
        let ratio = *candidate / bpm_raw;
        let candidate_score = comb_score(env, 60.0 * fps / *candidate);
        ((0.48..=0.52).contains(&ratio)
            && (((155.0..=165.0).contains(&bpm_raw) && candidate_score > raw_score)
                || ((150.0..155.0).contains(&bpm_raw) && candidate_score > 3.0 * raw_score)))
            || ((100.0..=125.0).contains(&bpm_raw)
                && (0.73..=0.77).contains(&ratio)
                && candidate_score >= 0.85 * raw_score)
    });
    (slower.unwrap_or(bpm_raw), bpm_raw)
}

