#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]
include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

use std::ffi::CStr;

/// Writes `msg` to the platform's log; true when logd took it.
pub fn info(tag: &CStr, msg: &CStr) -> bool {
    unsafe {
        __android_log_write(
            android_LogPriority_ANDROID_LOG_INFO as i32,
            tag.as_ptr(),
            msg.as_ptr(),
        ) > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bindings_saw_the_api_level() {
        // bindgen parsed the NDK's headers for the preset's API level.
        assert_eq!(BB_ANDROID_API, 26);
    }

    #[test]
    fn logs() {
        assert!(info(c"breakbulk", c"alog-sys test"));
    }
}
