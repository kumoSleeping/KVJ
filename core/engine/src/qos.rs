//! Best-effort scheduling hints: listening outranks indexing. Failures are ignored.

/// The recognition loop that turns fresh capture into a presented position.
pub fn prefer_live_audio() {
    #[cfg(target_os = "macos")]
    unsafe {
        let _ = libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0);
    }
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Threading::*;
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    }
}

/// Held while indexing; the thread gets its normal priority back when dropped.
#[must_use = "the thread returns to its normal priority when this is dropped"]
pub struct BackgroundPriority(());
impl Drop for BackgroundPriority {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        unsafe {
            let _ = libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_DEFAULT, 0);
        }
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::System::Threading::*;
            let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
        }
    }
}
pub fn prefer_background() -> BackgroundPriority {
    #[cfg(target_os = "macos")]
    unsafe {
        let _ = libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0);
    }
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Threading::*;
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
    BackgroundPriority(())
}
