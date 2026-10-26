//! OSC 8 links for visible, verified files in the current local workspace.
//! Link metadata is separate from model text; arbitrary terminal escapes never
//! enter the buffer. Refresh old link cells too, even if their text is unchanged.
use crate::{
    app::{App, text},
    ui::FileLink,
};
use ratatui::{
    backend::{Backend, ClearType, CrosstermBackend, WindowSize},
    buffer::{Buffer, Cell},
    layout::{Position, Rect, Size},
    style::Modifier,
};
use std::{
    collections::{BTreeMap, HashMap},
    io::{self, Write},
    path::{Component, Path},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use unicode_width::UnicodeWidthStr;

#[derive(Clone, Default)]
pub struct LinkState(Arc<Mutex<LinkFrame>>);
#[derive(Default)]
struct LinkFrame {
    buffer: Option<Buffer>,
    links: Vec<(Rect, String)>,
    cache: HashMap<(String, String), (Instant, Option<String>)>,
}
impl LinkState {
    pub fn prepare(&self, app: &App, buffer: &mut Buffer, files: Vec<FileLink>) {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        state.links.clear();
        let session = &app.snapshot["session"];
        let root = text(session, "workspace_path");
        let remote = text(session, "workspace_id").starts_with("ssh:")
            || session["remote"] == true
            || root.starts_with("ssh:");
        if !remote && !root.is_empty() {
            if state.cache.len() > 256 {
                state.cache.clear();
            }
            for file in files {
                let key = (root.to_owned(), file.path.clone());
                let value = state
                    .cache
                    .entry(key)
                    .or_insert_with(|| (Instant::now(), file_uri(Path::new(root), &file.path)));
                if value.0.elapsed() > Duration::from_secs(5) {
                    *value = (Instant::now(), file_uri(Path::new(root), &file.path));
                }
                if let Some(uri) = value.1.clone() {
                    state.links.push((file.area, uri));
                    for y in file.area.y..file.area.bottom() {
                        for x in file.area.x..file.area.right() {
                            if let Some(cell) = buffer.cell_mut((x, y)) {
                                cell.modifier.insert(Modifier::UNDERLINED);
                            }
                        }
                    }
                }
            }
        }
        state.buffer = Some(buffer.clone());
    }
}
fn file_uri(root: &Path, raw: &str) -> Option<String> {
    if raw.chars().any(char::is_control) || !root.is_absolute() {
        return None;
    }
    let path = Path::new(raw);
    if path.components().any(|c| matches!(c, Component::ParentDir)) {
        return None;
    }
    let root = root.canonicalize().ok()?;
    let target = if path.is_absolute() {
        path.to_owned()
    } else {
        root.join(path)
    }
    .canonicalize()
    .ok()?;
    if !target.starts_with(&root) || !target.is_file() {
        return None;
    }
    let absolute = target
        .to_str()?
        .strip_prefix(r"\\?\")
        .unwrap_or(target.to_str()?)
        .replace('\\', "/");
    if absolute.starts_with("//") || absolute.starts_with("UNC/") {
        return None;
    }
    let mut encoded = String::new();
    for byte in absolute.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~:".contains(&byte) {
            encoded.push(byte as char);
        } else {
            use std::fmt::Write as _;
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    Some(format!(
        "file://{}{}",
        if encoded.starts_with('/') { "" } else { "/" },
        encoded
    ))
}

pub struct HyperlinkBackend<W: Write> {
    inner: CrosstermBackend<W>,
    state: LinkState,
    previous: Vec<Rect>,
}
impl<W: Write> HyperlinkBackend<W> {
    pub fn new(writer: W, state: LinkState) -> Self {
        Self {
            inner: CrosstermBackend::new(writer),
            state,
            previous: vec![],
        }
    }
}
impl<W: Write> Backend for HyperlinkBackend<W> {
    type Error = io::Error;
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        let state = self.state.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut cells: BTreeMap<(u16, u16), Cell> =
            content.map(|(x, y, c)| ((y, x), c.clone())).collect();
        if let Some(buffer) = &state.buffer {
            for y in buffer.area.y..buffer.area.bottom() {
                let mut x = buffer.area.x;
                while x < buffer.area.right() {
                    let cell = &buffer[(x, y)];
                    let width = cell.symbol().width().max(1) as u16;
                    if cell.diff_option != ratatui::buffer::CellDiffOption::Skip
                        && self
                            .previous
                            .iter()
                            .chain(state.links.iter().map(|(r, _)| r))
                            .any(|r| {
                                y >= r.y
                                    && y < r.bottom()
                                    && x < r.right()
                                    && x.saturating_add(width) > r.x
                            })
                    {
                        cells.insert((y, x), cell.clone());
                    }
                    x = x.saturating_add(width);
                }
            }
        }
        let cells: Vec<_> = cells.into_iter().collect();
        let link_at = |y: u16, x: u16| {
            state
                .links
                .iter()
                .find(|(r, _)| r.contains(Position::new(x, y)))
                .map(|(_, s)| s.as_str())
        };
        let mut start = 0;
        while start < cells.len() {
            let ((y, x), _) = &cells[start];
            let link = link_at(*y, *x);
            let mut end = start + 1;
            while end < cells.len() && link_at(cells[end].0.0, cells[end].0.1) == link {
                end += 1;
            }
            if let Some(uri) = link {
                write!(self.inner, "\x1b]8;;{uri}\x1b\\")?;
            } else {
                write!(self.inner, "\x1b]8;;\x1b\\")?;
            }
            let result = self
                .inner
                .draw(cells[start..end].iter().map(|((y, x), c)| (*x, *y, c)));
            let closed = write!(self.inner, "\x1b]8;;\x1b\\");
            result?;
            closed?;
            start = end;
        }
        self.previous = state.links.iter().map(|(r, _)| *r).collect();
        Ok(())
    }
    fn hide_cursor(&mut self) -> io::Result<()> {
        self.inner.hide_cursor()
    }
    fn show_cursor(&mut self) -> io::Result<()> {
        self.inner.show_cursor()
    }
    fn get_cursor_position(&mut self) -> io::Result<Position> {
        self.inner.get_cursor_position()
    }
    fn set_cursor_position<P: Into<Position>>(&mut self, p: P) -> io::Result<()> {
        self.inner.set_cursor_position(p)
    }
    fn clear(&mut self) -> io::Result<()> {
        self.previous.clear();
        self.inner.clear()
    }
    fn clear_region(&mut self, c: ClearType) -> io::Result<()> {
        self.inner.clear_region(c)
    }
    fn size(&self) -> io::Result<Size> {
        self.inner.size()
    }
    fn window_size(&mut self) -> io::Result<WindowSize> {
        self.inner.window_size()
    }
    fn flush(&mut self) -> io::Result<()> {
        Backend::flush(&mut self.inner)
    }
    fn append_lines(&mut self, n: u16) -> io::Result<()> {
        self.inner.append_lines(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);
    impl Write for Capture {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    #[test]
    fn links_encode_names_and_reject_escape_and_nonfiles() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("中文 #.rs"), "test").unwrap();
        let uri = file_uri(dir.path(), "中文 #.rs").unwrap();
        assert!(uri.starts_with("file:///"));
        assert!(uri.contains("%20%23.rs"));
        assert!(file_uri(dir.path(), "../outside.rs").is_none());
        assert!(file_uri(dir.path(), ".").is_none());
        assert!(file_uri(dir.path(), "bad\x1b]52").is_none());
    }
    #[test]
    fn osc_links_are_closed_and_old_metadata_is_removed_without_text_changes() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.rs"), "x").unwrap();
        let app = App {
            snapshot: serde_json::json!({"session":{"workspace_path":dir.path(),"workspace_id":"w"}}),
            ..Default::default()
        };
        let links = LinkState::default();
        let mut buffer = Buffer::empty(Rect::new(0, 0, 10, 1));
        buffer.set_string(0, 0, "a.rs", ratatui::style::Style::default());
        links.prepare(
            &app,
            &mut buffer,
            vec![FileLink {
                area: Rect::new(0, 0, 4, 1),
                path: "a.rs".into(),
            }],
        );
        let capture = Capture::default();
        let mut backend = HyperlinkBackend::new(capture.clone(), links.clone());
        backend.draw(std::iter::empty()).unwrap();
        let output = String::from_utf8(capture.0.lock().unwrap().clone()).unwrap();
        assert!(output.contains("\x1b]8;;file:///"));
        assert!(output.ends_with("\x1b]8;;\x1b\\"));
        capture.0.lock().unwrap().clear();
        links.prepare(&app, &mut buffer, vec![]);
        backend.draw(std::iter::empty()).unwrap();
        let output = String::from_utf8(capture.0.lock().unwrap().clone()).unwrap();
        assert!(output.contains("a.rs"));
        assert!(!output.contains("file:///"));
    }
}
