/// Use the Windows console color table without touching stdin. Crossterm 0.29 has
/// no OSC 11 response event; pipe/PTY failures fall back to COLORFGBG, then dark.
use ratatui::style::Color;

pub const SKINS: &[(&str, &str)] = &[
    ("terminal", "跟随终端"),
    ("midnight", "深海"),
    ("forest", "松石"),
    ("sakura", "樱夜"),
    ("ink", "墨黑"),
    ("paper", "月白"),
    ("snow", "纸白"),
    ("graphite", "石墨"),
    ("mist", "雾紫"),
    ("amber", "琥珀"),
    ("coffee", "咖啡"),
    ("glacier", "冰川"),
    ("matcha", "抹茶"),
    ("parchment", "羊皮纸"),
    ("rose", "玫瑰灰"),
    ("explosion", "爆裂红"),
];
pub const CODE_STYLES: &[(&str, &str)] = &[
    ("auto", "跟随皮肤"),
    ("github", "GitHub"),
    ("monokai", "Monokai"),
    ("dracula", "Dracula"),
];
#[derive(Clone, Copy, Default)]
pub struct SkinColors {
    pub user_background: Option<Color>,
    pub background: Option<Color>,
    pub foreground: Option<Color>,
    pub accent: Option<Color>,
    pub muted: Option<Color>,
    pub good: Option<Color>,
    pub warn: Option<Color>,
    pub bad: Option<Color>,
}
#[derive(Clone, Copy)]
pub struct CodeColors {
    pub keyword: Color,
    pub string: Color,
    pub number: Color,
    pub comment: Color,
    pub punctuation: Color,
}
pub fn parse_color(value: &str) -> Option<Color> {
    let h = value.strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    let rgb = u32::from_str_radix(h, 16).ok()?;
    Some(Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8))
}
pub fn skin_is_light(skin: &str) -> Option<bool> {
    match skin {
        "paper" | "snow" | "glacier" | "matcha" | "parchment" | "rose" => Some(true),
        "terminal" => None,
        _ => Some(false),
    }
}
pub fn appearance_is_light(skin: &str, background: Option<&str>, terminal: bool) -> bool {
    if let Some(Color::Rgb(r, g, b)) = background.and_then(parse_color) {
        return (u32::from(r) * 2126 + u32::from(g) * 7152 + u32::from(b) * 722) >= 128 * 10000;
    }
    skin_is_light(skin).unwrap_or(terminal)
}
pub fn effective_skin_colors(skin: &str, background: Option<&str>, light: bool) -> SkinColors {
    let mut colors = skin_colors(skin, light);
    if let Some(background) = background.and_then(parse_color) {
        if skin == "terminal" || skin_is_light(skin) != Some(light) {
            colors = skin_colors(if light { "paper" } else { "midnight" }, light);
        }
        colors.background = Some(background);
    }
    colors
}
pub fn skin_colors(skin: &str, _light: bool) -> SkinColors {
    let (bg, fg, accent, muted) = match skin {
        "midnight" => (0x101b30, 0xdbe7f2, 0x79bff2, 0x8da6bd),
        "forest" => (0x10251f, 0xe0eee4, 0x83ceb0, 0x94ada1),
        "sakura" => (0x241c2e, 0xf0e2ed, 0xe8a2c2, 0xb29cb8),
        "ink" => (0x101214, 0xe5e7ea, 0x8bb9df, 0x939ca6),
        "paper" => (0xf3f0e7, 0x353b3c, 0x426e7a, 0x727d7a),
        "snow" => (0xfafafa, 0x24292f, 0x0969da, 0x627180),
        "graphite" => (0x1c2026, 0xe3e8ef, 0x9eb8d4, 0x98a3b1),
        "mist" => (0x24212e, 0xe9e4f0, 0xbda7e5, 0xa99eb8),
        "amber" => (0x211c16, 0xf2e7d8, 0xefb366, 0xae9c83),
        "coffee" => (0x241c18, 0xefe4d9, 0xd7b18b, 0xb09b88),
        "glacier" => (0xeaf0f5, 0x293b4a, 0x316b96, 0x627b8e),
        "matcha" => (0xecf0e7, 0x334337, 0x497350, 0x6b7c65),
        "parchment" => (0xf3e8cf, 0x4a3d2d, 0x8b5d36, 0x85745d),
        "rose" => (0xf3e9ed, 0x4c3843, 0x9c4e6c, 0x8a6c7c),
        "explosion" => (0x241416, 0xf2e6dd, 0xffb454, 0xb69a9c),
        _ => return SkinColors::default(),
    };
    let rgb = |v: u32| Color::Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8);
    let light = skin_is_light(skin) == Some(true);
    SkinColors {
        user_background: (skin == "explosion").then(|| rgb(0x352024)),
        background: Some(rgb(bg)),
        foreground: Some(rgb(fg)),
        accent: Some(rgb(accent)),
        muted: Some(rgb(muted)),
        good: Some(rgb(if light { 0x28734c } else { 0x8fcca8 })),
        warn: Some(rgb(if light { 0x87591a } else { 0xe3bc72 })),
        bad: Some(rgb(if skin == "explosion" {
            0xff8585
        } else if light {
            0xa83e48
        } else {
            0xeaa1a8
        })),
    }
}
pub fn code_colors(style: &str, light: bool) -> CodeColors {
    let colors = match style {
        "github" => {
            if light {
                [0xcf222e, 0x0a3069, 0x0550ae, 0x6e7781, 0x57606a]
            } else {
                [0xff7b72, 0xa5d6ff, 0x79c0ff, 0x8b949e, 0xc9d1d9]
            }
        }
        "monokai" => {
            if light {
                [0xa5164b, 0x786000, 0x6f42c1, 0x68705f, 0x303b44]
            } else {
                [0xf92672, 0xe6db74, 0xae81ff, 0x8b9085, 0xf8f8f2]
            }
        }
        "dracula" => {
            if light {
                [0x9f2f69, 0x76650a, 0x6a43b0, 0x6b728e, 0x353348]
            } else {
                [0xff79c6, 0xf1fa8c, 0xbd93f9, 0x8a96ba, 0xf8f8f2]
            }
        }
        _ => {
            if light {
                [0x8250df, 0x116329, 0x0550ae, 0x6e7781, 0x57606a]
            } else {
                [0x8fc7ed, 0xa5d6a7, 0xe3bc72, 0x8a9aa3, 0xd9e2e8]
            }
        }
    };
    let c = |i: usize| {
        let v = colors[i];
        Color::Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
    };
    CodeColors {
        keyword: c(0),
        string: c(1),
        number: c(2),
        comment: c(3),
        punctuation: c(4),
    }
}
pub fn local_date() -> String {
    #[cfg(windows)]
    {
        #[repr(C)]
        #[derive(Default)]
        struct SystemTime {
            year: u16,
            month: u16,
            weekday: u16,
            day: u16,
            hour: u16,
            minute: u16,
            second: u16,
            millis: u16,
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetLocalTime(value: *mut SystemTime);
        }
        let mut value = SystemTime::default();
        // SAFETY: SYSTEMTIME contains the eight 16-bit fields required by GetLocalTime.
        unsafe { GetLocalTime(&mut value) };
        format!("{:04}-{:02}-{:02}", value.year, value.month, value.day)
    }
    #[cfg(not(windows))]
    {
        String::new()
    }
}

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
