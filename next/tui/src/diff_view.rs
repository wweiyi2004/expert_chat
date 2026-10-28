use crate::app::items;
use serde_json::Value;

pub struct DiffRow {
    pub kind: char,
    pub old: Option<usize>,
    pub new: Option<usize>,
    pub text: String,
}
pub fn rows(change: &Value) -> Vec<DiffRow> {
    let lines = items(change, "diff");
    let unified = lines
        .iter()
        .filter_map(Value::as_str)
        .any(|s| s.starts_with("@@ "));
    let (mut old, mut new) = (1usize, 1usize);
    let mut result = vec![];
    for value in lines {
        let Some(line) = value.as_str() else {
            continue;
        };
        if line.starts_with("@@ ") {
            let parts: Vec<_> = line.split_whitespace().collect();
            let start = |s: Option<&&str>| {
                s.and_then(|v| v.get(1..))
                    .and_then(|s| s.split(',').next())
                    .and_then(|s| s.parse().ok())
            };
            if let (Some(a), Some(b)) = (start(parts.get(1)), start(parts.get(2))) {
                old = a;
                new = b;
            }
            continue;
        }
        if unified
            && (line.starts_with("--- ")
                || line.starts_with("+++ ")
                || line.starts_with("diff --git")
                || line.starts_with("index ")
                || line.starts_with("\\ No newline"))
        {
            continue;
        }
        let kind = line.chars().next().unwrap_or('!');
        let (old_line, new_line) = match kind {
            '+' => {
                let n = new;
                new += 1;
                (None, Some(n))
            }
            '-' => {
                let n = old;
                old += 1;
                (Some(n), None)
            }
            ' ' => {
                let pair = (Some(old), Some(new));
                old += 1;
                new += 1;
                pair
            }
            _ => (None, None),
        };
        result.push(DiffRow {
            kind,
            old: old_line,
            new: new_line,
            text: if matches!(kind, '+' | '-' | ' ') {
                line[1..].into()
            } else {
                line.into()
            },
        });
    }
    result
}
pub fn language(path: &str) -> &str {
    match path.rsplit('.').next().unwrap_or("") {
        "py" => "python",
        "rs" => "rust",
        "js" | "jsx" => "javascript",
        "ts" | "tsx" => "typescript",
        "h" | "hpp" => "cpp",
        "yml" => "yaml",
        other => other,
    }
}
