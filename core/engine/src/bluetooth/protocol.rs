//! Versioned feature wire contract and monotonic clock mapping.
use super::transport::Connection;
use anyhow::{Context, Result};
use kvj_recognize::LIVE_FEATURE_REVISION;
use std::{
    collections::VecDeque,
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};
pub(super) const HELLO: u8 = 1;
pub(super) const PING: u8 = 2;
pub(super) const PONG: u8 = 3;
pub(super) const FEATURES: u8 = 4;
pub(super) const ACK: u8 = 5;
pub(super) const SELECT: u8 = 6;
pub(super) const STREAM: u8 = 7;
/// Receiver → sender: [1] paired (remembered or just allowed), [0] refused.
pub(super) const PAIR: u8 = 8;
/// Contract 3: HELLO carries the install's pairing token; PAIR confirms it.
fn contract(role: u8) -> Vec<u8> {
    let mut bytes = b"KVJF".to_vec();
    bytes.extend(3u32.to_le_bytes());
    bytes.extend(LIVE_FEATURE_REVISION.to_le_bytes());
    bytes.push(role);
    bytes
}
/// The versioned contract, this install's pairing token, then this computer's
/// name for the other side's list.
pub(super) fn hello(role: u8, token: &str) -> Vec<u8> {
    let mut bytes = contract(role);
    bytes.extend(token.as_bytes());
    let name = super::transport::host_name();
    let mut end = name.len().min(128);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    bytes.extend(name[..end].as_bytes());
    bytes
}
/// Checks the contract and returns the peer's pairing token and name.
pub(super) fn check_hello(bytes: &[u8], role: u8) -> Result<(String, String)> {
    let expected = contract(role);
    let start = expected.len() + 32;
    anyhow::ensure!(
        bytes.len() >= start && bytes.len() <= start + 128 && bytes.starts_with(&expected),
        "KVJ 蓝牙协议或特征版本不一致，请更新两端"
    );
    let token = std::str::from_utf8(&bytes[expected.len()..start]).unwrap_or_default();
    anyhow::ensure!(super::pairing::valid_token(token), "KVJ 蓝牙配对信息无效，请更新两端");
    Ok((token.to_owned(), String::from_utf8_lossy(&bytes[start..]).trim().to_owned()))
}
pub(super) fn number(bytes: &[u8]) -> Result<f64> {
    let value = f64::from_le_bytes(bytes.try_into()?);
    anyhow::ensure!(
        value.is_finite() && (0. ..1e15).contains(&value),
        "蓝牙时间戳无效"
    );
    Ok(value)
}
pub(super) fn pong(connection: &mut Connection, body: Vec<u8>, cancel: &AtomicBool) -> Result<()> {
    number(&body)?;
    let mut response = body;
    response.extend(crate::clock_ms().to_le_bytes());
    response.extend(crate::clock_ms().to_le_bytes());
    connection.send(PONG, &response, cancel)
}
/// A rolling minimum-RTT mapping limits queuing bias; RTT/2 is an uncertainty
/// estimate, not evidence of path symmetry or measured screen latency.
#[derive(Default)]
pub(super) struct Clock {
    samples: VecDeque<(Instant, f64, f64)>,
    pub offset: Option<f64>,
    pub rtt: f64,
}
impl Clock {
    pub fn observe(&mut self, t1: f64, t2: f64, t3: f64, t4: f64) -> Result<bool> {
        let rtt = (t4 - t1) - (t3 - t2);
        anyhow::ensure!(
            t3 >= t2 && t4 >= t1 && (0. ..=2000.).contains(&rtt),
            "蓝牙时钟校准超时或无效"
        );
        self.samples
            .push_back((Instant::now(), rtt, ((t1 - t2) + (t4 - t3)) / 2.));
        while self
            .samples
            .front()
            .is_some_and(|s| s.0.elapsed() > Duration::from_secs(30))
            || self.samples.len() > 32
        {
            self.samples.pop_front();
        }
        let best = self
            .samples
            .iter()
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .context("缺少时钟样本")?;
        self.rtt = best.1;
        let jumped = self.offset.is_some_and(|old| (old - best.2).abs() > 25.);
        self.offset = Some(match self.offset {
            Some(old) if !jumped => old + (best.2 - old).clamp(-1., 1.),
            _ => best.2,
        });
        Ok(jumped)
    }
}
