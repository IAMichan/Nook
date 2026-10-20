//! An MCP tool as people read it (`McpToolName` on the Mac): `mcp__bestanden-mappen__move_file` is "Move file" from
//! "Bestanden mappen". Used for approval titles, the timeline, agent steps and Nook's own MCP connectors.

use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpToolName {
    pub server: String,
    pub tool: String,
}

impl McpToolName {
    /// The name an agent reports (`mcp__server__tool`); `None` for any other tool.
    pub fn parse(raw: &str) -> Option<Self> {
        let rest = raw.strip_prefix("mcp__")?;
        let parts: Vec<&str> = rest.split("__").collect();
        if parts.len() < 2 {
            return None;
        }
        let tool = parts.last().copied().filter(|t| !t.is_empty())?;
        let server = parts[..parts.len() - 1].join("__");
        if server.is_empty() {
            return None;
        }
        Some(Self { server, tool: tool.into() })
    }

    /// The server's name; claude.ai connectors lose their `claude_ai_` prefix ("claude_ai_Google_Drive" is
    /// "Google Drive").
    pub fn server_label(&self) -> String {
        let bare = match self.server.strip_prefix("claude_ai_") {
            Some(rest) if !rest.is_empty() => rest,
            _ => &self.server,
        };
        readable(bare)
    }

    pub fn tool_label(&self) -> String {
        readable(&self.tool)
    }

    /// "Bestanden mappen › Move file".
    pub fn label(&self) -> String {
        format!("{} › {}", self.server_label(), self.tool_label())
    }
}

/// An identifier as words: "move_file", "move-file" and "moveFile" read as "Move file". Acronyms and words written with
/// a capital after a separator keep their case ("get_URL" is "Get URL", "Google_Drive" is "Google Drive"); a name that
/// already has spaces stays as it is.
pub fn readable(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.contains(' ') {
        return trimmed.into();
    }
    // Each word, and whether it started at a camelCase hump rather than after a separator.
    let mut words: Vec<(String, bool)> = vec![];
    let mut current = String::new();
    let mut hump = false;
    for c in trimmed.chars() {
        if "_-./:".contains(c) {
            if !current.is_empty() {
                words.push((std::mem::take(&mut current), hump));
            }
            hump = false;
        } else if c.is_uppercase() && current.chars().last().is_some_and(|l| l.is_lowercase() || l.is_numeric()) {
            words.push((std::mem::take(&mut current), hump));
            current.push(c);
            hump = true;
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() {
        words.push((current, hump));
    }
    if words.is_empty() {
        return trimmed.into();
    }
    words
        .iter()
        .enumerate()
        .map(|(index, (text, hump))| {
            let acronym = text.chars().count() > 1 && *text == text.to_uppercase() && text.chars().any(char::is_alphabetic);
            if acronym {
                return text.clone();
            }
            if index == 0 {
                let mut chars = text.chars();
                let first = chars.next().map(|c| c.to_uppercase().collect::<String>()).unwrap_or_default();
                return first + &chars.as_str().to_lowercase();
            }
            if !hump && text.chars().next().is_some_and(char::is_uppercase) {
                return text.clone();
            }
            text.to_lowercase()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Every argument of a call as "Name: value" lines, sorted by name and never shortened: what is approved must be what
/// is shown.
pub fn arguments(input: &Value) -> String {
    argument_lines(input).join("\n")
}

pub fn argument_lines(input: &Value) -> Vec<String> {
    let Some(object) = input.as_object() else { return vec![] };
    let mut pairs: Vec<(&String, &Value)> = object.iter().collect();
    pairs.sort_by_key(|(k, _)| k.as_str());
    pairs
        .into_iter()
        .map(|(key, value)| {
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                other => serde_json::to_string(other).unwrap_or_default(),
            };
            format!("{}: {text}", readable(key))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mcp_tool_names_read_as_words() {
        let mv = McpToolName::parse("mcp__bestanden-mappen__move_file").unwrap();
        assert_eq!(mv.server_label(), "Bestanden mappen");
        assert_eq!(mv.tool_label(), "Move file");
        assert_eq!(mv.label(), "Bestanden mappen › Move file");
        assert_eq!(McpToolName::parse("mcp__claude_ai_Google_Drive__searchFiles").unwrap().label(), "Google Drive › Search files");
        assert_eq!(readable("get_URL"), "Get URL");
        assert_eq!(readable("Move file"), "Move file", "a title stays as it is");
        assert!(McpToolName::parse("Bash").is_none());
        assert!(McpToolName::parse("mcp__server").is_none());
        assert!(McpToolName::parse("mcp____tool").is_none());
        assert_eq!(arguments(&json!({"source": "/a.txt", "max_depth": 2})), "Max depth: 2\nSource: /a.txt");
        assert_eq!(arguments(&json!({"flags": [1, 2]})), "Flags: [1,2]");
    }
}
