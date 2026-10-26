//! Small FFI boundary to the CoreBluetooth transport in `macos.m`. Handles are
//! owned by one Rust worker; the Objective-C side serializes on its own queue.
use super::*;
use std::{
    ffi::{c_char, c_void, CStr, CString},
    marker::PhantomData,
    rc::Rc,
};
unsafe extern "C" {
    fn kvj_ble_scan(milliseconds: i32, error: *mut c_char, cap: usize) -> *mut c_char;
    fn kvj_ble_free_string(text: *mut c_char);
    fn kvj_ble_host_name() -> *mut c_char;
    fn kvj_ble_listen(name: *const c_char, error: *mut c_char, cap: usize) -> *mut c_void;
    fn kvj_ble_listening(handle: *mut c_void, error: *mut c_char, cap: usize) -> i32;
    fn kvj_ble_accept(handle: *mut c_void, peer: *mut c_char, cap: usize) -> *mut c_void;
    fn kvj_ble_connect(id: *const c_char, error: *mut c_char, cap: usize) -> *mut c_void;
    fn kvj_ble_connect_poll(handle: *mut c_void, error: *mut c_char, cap: usize) -> i32;
    fn kvj_ble_read(handle: *mut c_void, bytes: *mut u8, cap: usize) -> i32;
    fn kvj_ble_write(handle: *mut c_void, bytes: *const u8, len: usize) -> i32;
    fn kvj_ble_close(handle: *mut c_void);
}
fn message(buffer: &[c_char]) -> String {
    // Native functions always terminate within the zero-initialized buffer.
    unsafe {
        CStr::from_ptr(buffer.as_ptr())
            .to_string_lossy()
            .into_owned()
    }
}
fn owned(text: *mut c_char) -> String {
    // Returned strings are owned by the caller: copy, then free.
    unsafe {
        let value = CStr::from_ptr(text).to_string_lossy().into_owned();
        kvj_ble_free_string(text);
        value
    }
}
/// KVJ receivers advertising nearby, found by their service UUID alone.
pub fn scan(duration: Duration) -> Result<Vec<Device>> {
    let mut error = [0; 512];
    let text = unsafe { kvj_ble_scan(duration.as_millis() as i32, error.as_mut_ptr(), error.len()) };
    anyhow::ensure!(!text.is_null(), "{}", message(&error));
    Ok(serde_json::from_str(&owned(text))?)
}
/// Transport counters for the session log; CoreBluetooth delivers writes in order.
pub fn report() -> Option<String> {
    None
}
pub fn host_name() -> String {
    owned(unsafe { kvj_ble_host_name() })
}
pub struct Native {
    handle: *mut c_void,
    _thread: PhantomData<Rc<()>>,
}
impl Drop for Native {
    fn drop(&mut self) {
        unsafe {
            kvj_ble_close(self.handle);
        }
    }
}
impl Native {
    fn wrap(handle: *mut c_void) -> Self {
        Self {
            handle,
            _thread: PhantomData,
        }
    }
    /// Advertise the KVJ service under this computer's name.
    pub fn listen() -> Result<Self> {
        let name = CString::new(host_name()).unwrap_or_default();
        let mut error = [0; 512];
        let handle = unsafe { kvj_ble_listen(name.as_ptr(), error.as_mut_ptr(), error.len()) };
        anyhow::ensure!(!handle.is_null(), "{}", message(&error));
        Ok(Self::wrap(handle))
    }
    pub fn connect(id: &str, cancel: &AtomicBool) -> Result<Self> {
        let id = CString::new(id)?;
        let mut error = [0; 512];
        let handle = unsafe { kvj_ble_connect(id.as_ptr(), error.as_mut_ptr(), error.len()) };
        anyhow::ensure!(!handle.is_null(), "{}", message(&error));
        let native = Self::wrap(handle);
        let started = Instant::now();
        loop {
            canceled(cancel)?;
            anyhow::ensure!(
                started.elapsed() < Duration::from_secs(15),
                "蓝牙连接超时，请确认对方的 KVJ 正在接收"
            );
            match unsafe { kvj_ble_connect_poll(handle, error.as_mut_ptr(), error.len()) } {
                1 => return Ok(native),
                -1 => bail!("{}", message(&error)),
                _ => std::thread::sleep(Duration::from_millis(10)),
            }
        }
    }
    /// `Ok(None)` when nobody new has connected; an error while advertising has
    /// not started is reported by `waiting()`.
    pub fn accept(&mut self) -> Result<Option<(Self, String)>> {
        let mut error = [0; 512];
        match unsafe { kvj_ble_listening(self.handle, error.as_mut_ptr(), error.len()) } {
            -1 => bail!("{}", message(&error)),
            0 => return Ok(None),
            _ => {}
        }
        let mut peer = [0; 256];
        let handle = unsafe { kvj_ble_accept(self.handle, peer.as_mut_ptr(), peer.len()) };
        Ok((!handle.is_null()).then(|| (Self::wrap(handle), message(&peer))))
    }
    /// Why advertising has not started yet, if it has not.
    pub fn waiting(&mut self) -> Option<String> {
        let mut error = [0; 512];
        (unsafe { kvj_ble_listening(self.handle, error.as_mut_ptr(), error.len()) } == 0).then(|| message(&error))
    }
    pub fn read(&mut self, bytes: &mut [u8]) -> Result<usize> {
        let count = unsafe { kvj_ble_read(self.handle, bytes.as_mut_ptr(), bytes.len()) };
        anyhow::ensure!(count >= 0, "蓝牙连接已断开");
        Ok(count as usize)
    }
    /// Queues a whole message for sending. Waits only while the link's send
    /// buffer is full; a link that stays full for 750 ms is treated as stalled.
    pub fn write(&mut self, bytes: &[u8], cancel: &AtomicBool) -> Result<()> {
        let started = Instant::now();
        loop {
            canceled(cancel)?;
            let accepted = unsafe { kvj_ble_write(self.handle, bytes.as_ptr(), bytes.len()) };
            anyhow::ensure!(accepted >= 0, "蓝牙发送失败或连接已断开");
            if accepted > 0 || bytes.is_empty() {
                return Ok(());
            }
            anyhow::ensure!(
                started.elapsed() < Duration::from_millis(750),
                "蓝牙发送积压，连接已停止"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}
