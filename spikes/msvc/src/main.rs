#[allow(non_camel_case_types, non_snake_case, dead_code)]
mod sys {
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

use windows_sys::Win32::System::LibraryLoader::{
    FindResourceW, LoadResource, LockResource, SizeofResource,
};
use windows_sys::Win32::System::Threading::GetCurrentProcessId;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn main() {
    // C code compiled by clang-cl, through bindgen-generated declarations.
    let sum = unsafe { sys::smoke_add(2, 40) };
    let c_pid = unsafe { sys::smoke_pid() };
    let bg_pid = unsafe { sys::GetCurrentProcessId() };
    // windows-sys.
    let pid = unsafe { GetCurrentProcessId() };
    assert_eq!(c_pid, pid);
    assert_eq!(bg_pid, pid);

    // The RCDATA resource embedded by lld-link (RT_RCDATA = 10).
    let name = wide("SMOKE");
    let res = unsafe {
        let h = FindResourceW(std::ptr::null_mut(), name.as_ptr(), 10 as _);
        assert!(!h.is_null(), "resource not found");
        let len = SizeofResource(std::ptr::null_mut(), h) as usize;
        let data = LockResource(LoadResource(std::ptr::null_mut(), h)) as *const u8;
        std::slice::from_raw_parts(data, len)
    };
    let res = std::str::from_utf8(res).unwrap().trim_end_matches('\0');

    println!("smoke: c_add={sum} pid_match=true resource={res}");
}
