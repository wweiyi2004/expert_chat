use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::collections::HashMap;

pub fn apply(previous: &Value, patch: &Value) -> Result<Value> {
    let mut next = previous.clone();
    let object = next.as_object_mut().context("missing snapshot")?;
    for (key, value) in patch["fields"]
        .as_object()
        .context("invalid patch fields")?
    {
        object.insert(key.clone(), value.clone());
    }
    for key in patch["remove"]
        .as_array()
        .context("invalid patch removals")?
    {
        object.remove(key.as_str().context("invalid field")?);
    }
    for (name, delta) in patch["arrays"]
        .as_object()
        .context("invalid patch arrays")?
    {
        ensure!(
            ["messages", "steps", "agents"].contains(&name.as_str()),
            "unknown patch array"
        );
        let mut rows: HashMap<String, Value> = object
            .get(name)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|row| {
                Ok((
                    row["id"].as_str().context("missing row id")?.to_owned(),
                    row.clone(),
                ))
            })
            .collect::<Result<_>>()?;
        for update in delta["updates"].as_array().context("invalid row updates")? {
            let id = update["id"].as_str().context("invalid row id")?;
            if let Some(replace) = update.get("replace") {
                ensure!(replace["id"] == id, "replacement identity mismatch");
                rows.insert(id.to_owned(), replace.clone());
                continue;
            }
            let row = rows
                .get_mut(id)
                .and_then(Value::as_object_mut)
                .context("missing row baseline")?;
            for (key, value) in update["fields"].as_object().context("invalid row fields")? {
                row.insert(key.clone(), value.clone());
            }
            for (key, suffix) in update["append"].as_object().context("invalid append")? {
                let before = row
                    .get(key)
                    .and_then(Value::as_str)
                    .context("missing append baseline")?;
                let suffix = suffix.as_str().context("invalid append text")?;
                row.insert(key.clone(), Value::String(format!("{before}{suffix}")));
            }
            for key in update["remove"]
                .as_array()
                .context("invalid row removals")?
            {
                row.remove(key.as_str().context("invalid row field")?);
            }
        }
        for id in delta["remove"].as_array().context("invalid removed ids")? {
            rows.remove(id.as_str().context("invalid id")?);
        }
        let mut ordered = vec![];
        for id in delta["order"].as_array().context("invalid row order")? {
            ordered.push(
                rows.remove(id.as_str().context("invalid order id")?)
                    .context("missing ordered row")?,
            );
        }
        ensure!(rows.is_empty(), "incomplete row order");
        object.insert(name.clone(), Value::Array(ordered));
    }
    Ok(next)
}
