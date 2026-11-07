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

/// C code compiled by clang-cl, through bindgen-generated declarations.
fn c_add(a: u32, b: u32) -> u32 {
    unsafe { sys::smoke_add(a, b) }
}

/// The process id three ways: C (kernel32 and the CRT), bindgen's
/// declaration of the SDK function, and windows-sys.
fn pids() -> (u32, u32, u32) {
    unsafe { (sys::smoke_pid(), sys::GetCurrentProcessId(), GetCurrentProcessId()) }
}

/// The RCDATA resource the build script compiles with $RC and links with
/// `rustc-link-arg-bins` (so bins and their test harnesses have it).
fn resource() -> String {
    let name = wide("SMOKE");
    let res = unsafe {
        let h = FindResourceW(std::ptr::null_mut(), name.as_ptr(), 10 as _);
        assert!(!h.is_null(), "resource not found");
        let len = SizeofResource(std::ptr::null_mut(), h) as usize;
        let data = LockResource(LoadResource(std::ptr::null_mut(), h)) as *const u8;
        std::slice::from_raw_parts(data, len)
    };
    std::str::from_utf8(res).unwrap().trim_end_matches('\0').to_owned()
}

fn main() {
    let sum = c_add(2, 40);
    let (c_pid, bg_pid, pid) = pids();
    assert_eq!(c_pid, pid);
    assert_eq!(bg_pid, pid);
    println!("smoke: c_add={sum} pid_match=true resource={}", resource());
}

#[cfg(test)]
mod tests {
    #[test]
    fn c_code() {
        assert_eq!(super::c_add(2, 40), 42);
    }

    #[test]
    fn pids_agree() {
        let (c, bg, ws) = super::pids();
        assert_eq!(c, ws);
        assert_eq!(bg, ws);
    }

    #[test]
    fn resource_linked() {
        assert_eq!(super::resource(), "resource-ok");
    }
}
