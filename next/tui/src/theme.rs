/// Use the Windows console color table without touching stdin. Crossterm 0.29 has
/// no OSC 11 response event; pipe/PTY failures fall back to COLORFGBG, then dark.
pub fn light(explicit: Option<&str>) -> bool {
    if let Some(theme) = explicit {
        return theme == "light";
    }
    native_light()
        .or_else(|| {
            std::env::var("COLORFGBG")
                .ok()
                .and_then(|s| s.rsplit(';').next().and_then(|n| n.parse::<u8>().ok()))
                .map(|n| n >= 8)
        })
        .unwrap_or(false)
}
#[cfg(windows)]
fn native_light() -> Option<bool> {
    use std::ffi::c_void;
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct Coord {
        x: i16,
        y: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct SmallRect {
        left: i16,
        top: i16,
        right: i16,
        bottom: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Info {
        size: u32,
        buffer: Coord,
        cursor: Coord,
        attributes: u16,
        window: SmallRect,
        maximum: Coord,
        popup: u16,
        fullscreen: i32,
        colors: [u32; 16],
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetStdHandle(which: u32) -> *mut c_void;
        fn GetConsoleScreenBufferInfoEx(handle: *mut c_void, info: *mut Info) -> i32;
    }
    let mut info = Info {
        size: std::mem::size_of::<Info>() as u32,
        ..Default::default()
    };
    // SAFETY: the output handle is borrowed, and `info` is a correctly sized,
    // initialized CONSOLE_SCREEN_BUFFER_INFOEX that remains live for this call.
    if unsafe { GetConsoleScreenBufferInfoEx(GetStdHandle(-11i32 as u32), &mut info) } == 0 {
        return None;
    }
    let rgb = info.colors[((info.attributes >> 4) & 15) as usize];
    let r = (rgb & 255) as f64;
    let g = ((rgb >> 8) & 255) as f64;
    let b = ((rgb >> 16) & 255) as f64;
    Some(r * 0.2126 + g * 0.7152 + b * 0.0722 >= 128.0)
}
#[cfg(not(windows))]
fn native_light() -> Option<bool> {
    None
}
#[cfg(test)]
mod tests {
    #[test]
    fn explicit_theme_takes_precedence() {
        assert!(!super::light(Some("dark")));
        assert!(super::light(Some("light")));
    }
}
