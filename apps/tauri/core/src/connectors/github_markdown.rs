//! GitHub-flavoured Markdown as written in pull request descriptions, reviews and comments, rewritten into the plain
//! Markdown Nook's renderer draws (`src/lib/markdown.ts`, which escapes everything, so no HTML ever reaches the page).
//! Reviews (review bots above all) mix in HTML that GitHub renders and Nook would show as raw tags: `<details>` and
//! `<summary>`, `<!-- … -->` markers, `<b>`, `<a href>`, `<sub>`, entities. Code blocks nested in a list item are moved
//! out of the item, so they draw as code instead of being glued onto the item's text. Port of `GitHubMarkdown` on the Mac.

use std::sync::LazyLock;

use regex::{Captures, Regex};

fn rx(pattern: &str) -> Regex {
    Regex::new(&format!("(?is){pattern}")).expect("valid pattern")
}

static SPAN: LazyLock<Regex> = LazyLock::new(|| rx(r"`[^`\n]+`"));
static PLACEHOLDER: LazyLock<Regex> = LazyLock::new(|| rx("\u{E000}([0-9]+)\u{E001}"));
static COMMENT: LazyLock<Regex> = LazyLock::new(|| rx(r"<!--.*?(?:-->|$)"));
static SUMMARY: LazyLock<Regex> = LazyLock::new(|| rx(r"<summary[^>]*>(.*?)</summary>"));
static HEADING: LazyLock<Regex> = LazyLock::new(|| rx(r"<h([1-6])[^>]*>(.*?)</h[1-6]>"));
static LINK: LazyLock<Regex> = LazyLock::new(|| rx(r#"<a\s[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#));
static IMAGE: LazyLock<Regex> = LazyLock::new(|| rx(r"<img\s[^>]*?>"));
static ALT: LazyLock<Regex> = LazyLock::new(|| rx(r#"\balt\s*=\s*["']([^"']*)["']"#));
static BREAK: LazyLock<Regex> = LazyLock::new(|| rx(r"<br\s*/?>"));
static RULE: LazyLock<Regex> = LazyLock::new(|| rx(r"<hr\s*/?>"));
static BOLD: LazyLock<Regex> = LazyLock::new(|| rx(r"</?(?:b|strong)\s*>"));
static ITALIC: LazyLock<Regex> = LazyLock::new(|| rx(r"</?(?:i|em)\s*>"));
static CODE: LazyLock<Regex> = LazyLock::new(|| rx(r"</?(?:code|kbd|tt)\s*>"));
static ITEM: LazyLock<Regex> = LazyLock::new(|| rx(r"<li[^>]*>"));
static BLOCK: LazyLock<Regex> = LazyLock::new(|| rx(r"</?(?:details|p|div|ul|ol|table|blockquote|pre|center)(?:\s[^>]*)?>|</li\s*>"));
/// Tags that only style a run of text; what is inside stays.
static INLINE: LazyLock<Regex> =
    LazyLock::new(|| rx(r"</?(?:sub|sup|small|span|ins|u|mark|font|picture|source|a|del|s|strike|summary|img)(?:\s[^>]*)?/?>"));

fn replace(text: &str, re: &Regex, mut transform: impl FnMut(&Captures) -> String) -> String {
    re.replace_all(text, |c: &Captures| transform(c)).into_owned()
}

fn group<'a>(c: &'a Captures, index: usize) -> &'a str {
    c.get(index).map(|m| m.as_str()).unwrap_or("")
}

/// The Markdown for a description, review or comment.
pub fn markdown(raw: &str) -> String {
    let text = raw.replace("\r\n", "\n");
    let mut output: Vec<String> = vec![];
    let mut prose: Vec<&str> = vec![];
    let mut lines = text.split('\n');

    fn flush(prose: &mut Vec<&str>, output: &mut Vec<String>) {
        if !prose.is_empty() {
            output.push(html(&prose.join("\n")));
            prose.clear();
        }
    }

    while let Some(line) = lines.next() {
        let trimmed = line.trim_matches(|c| c == ' ' || c == '\t');
        let Some(fence) = ["```", "~~~"].into_iter().find(|f| trimmed.starts_with(f)) else {
            prose.push(line);
            continue;
        };
        flush(&mut prose, &mut output);
        // A fence indented under a list item: its lines lose that indent, so the block stands on its own.
        let indent = line.chars().take_while(|c| *c == ' ' || *c == '\t').count();
        let mut block = vec![format!("```{}", &trimmed[fence.len()..])];
        for inner in lines.by_ref() {
            if inner.trim_matches(|c| c == ' ' || c == '\t').starts_with(fence) {
                break;
            }
            let lead = indent.min(inner.chars().take_while(|c| *c == ' ' || *c == '\t').count());
            block.push(inner.chars().skip(lead).collect());
        }
        block.push("```".into());
        output.push(format!("\n{}\n", block.join("\n")));
    }
    flush(&mut prose, &mut output);
    collapse(&output.join("\n")).trim().to_string()
}

/// The text inside a tag, on one line and without the tags or emphasis around it.
fn plain(text: &str) -> String {
    let flat = replace(&replace(text, &BOLD, |_| String::new()), &INLINE, |_| String::new()).replace("**", "");
    flat.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn html(text: &str) -> String {
    if !text.contains('<') && !text.contains('&') {
        return text.to_string();
    }
    // Inline code keeps its tags and entities: set aside before, put back after.
    let mut spans: Vec<String> = vec![];
    let mut text = replace(text, &SPAN, |c| {
        spans.push(group(c, 0).to_string());
        format!("\u{E000}{}\u{E001}", spans.len() - 1)
    });
    text = replace(&text, &COMMENT, |_| String::new());
    text = replace(&text, &SUMMARY, |c| {
        let title = plain(group(c, 1));
        if title.is_empty() {
            "\n\n".into()
        } else {
            format!("\n\n**{title}**\n\n")
        }
    });
    text = replace(&text, &HEADING, |c| {
        let level = group(c, 1).parse::<usize>().unwrap_or(3);
        format!("\n\n{} {}\n\n", "#".repeat(level), plain(group(c, 2)))
    });
    text = replace(&text, &IMAGE, |c| ALT.captures(group(c, 0)).map(|a| group(&a, 1).to_string()).unwrap_or_default());
    text = replace(&text, &LINK, |c| {
        let label = plain(group(c, 2));
        let url = group(c, 1);
        if !url.starts_with("http") {
            return label;
        }
        format!("[{}]({url})", if label.is_empty() { url } else { &label })
    });
    text = replace(&text, &BREAK, |_| "\n".into());
    text = replace(&text, &RULE, |_| "\n\n---\n\n".into());
    text = replace(&text, &BOLD, |_| "**".into());
    text = replace(&text, &ITALIC, |_| "*".into());
    text = replace(&text, &CODE, |_| "`".into());
    text = replace(&text, &ITEM, |_| "\n- ".into());
    text = replace(&text, &BLOCK, |_| "\n\n".into());
    text = replace(&text, &INLINE, |_| String::new());
    replace(&entities(&text), &PLACEHOLDER, |c| group(c, 1).parse::<usize>().ok().and_then(|i| spans.get(i).cloned()).unwrap_or_default())
}

const NAMED_ENTITIES: [(&str, &str); 14] = [
    ("&nbsp;", " "),
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&quot;", "\""),
    ("&apos;", "'"),
    ("&#39;", "'"),
    ("&#x27;", "'"),
    ("&mdash;", "—"),
    ("&ndash;", "–"),
    ("&hellip;", "…"),
    ("&rarr;", "→"),
    ("&larr;", "←"),
    ("&check;", "✓"),
    ("&times;", "×"),
];

fn entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }
    let mut result = text.to_string();
    for (entity, value) in NAMED_ENTITIES {
        result = result.replace(entity, value);
    }
    // Last, so "&amp;lt;" stays the literal text "&lt;".
    result.replace("&amp;", "&")
}

/// Lines left with only spaces become empty, and runs of empty lines one.
fn collapse(text: &str) -> String {
    let mut result: Vec<&str> = vec![];
    let mut in_code = false;
    for line in text.split('\n') {
        let trimmed = line.trim_matches(|c| c == ' ' || c == '\t');
        if trimmed.starts_with("```") {
            in_code = !in_code;
        }
        let blank = !in_code && trimmed.is_empty();
        if blank && result.last().is_none_or(|l| l.is_empty()) {
            continue;
        }
        result.push(if blank { "" } else { line });
    }
    result.join("\n")
}

#[cfg(test)]
mod tests {
    use super::markdown;

    #[test]
    fn details_and_summary_become_a_bold_line() {
        let raw = "<details>\n<summary><b>Walkthrough</b></summary>\n\nThe change adds a parser.\n</details>";
        assert_eq!(markdown(raw), "**Walkthrough**\n\nThe change adds a parser.");
    }

    #[test]
    fn markers_drop_out_and_entities_decode() {
        let raw = "<!-- This is an auto-generated comment: review by bot -->\nLooks good &mdash; ship it &amp; merge &amp;lt;3";
        assert_eq!(markdown(raw), "Looks good — ship it & merge &lt;3");
        // An unterminated marker hides the rest, as on GitHub.
        assert_eq!(markdown("Visible <!-- hidden"), "Visible");
    }

    #[test]
    fn links_images_and_emphasis_become_markdown() {
        let raw =
            r#"See <a href="https://example.com/x">the <b>docs</b></a>, <img src="x.png" alt="diagram"> and <i>this</i> <code>a<b</code>."#;
        assert_eq!(markdown(raw), "See [the docs](https://example.com/x), diagram and *this* `a<b`.");
        // A link that is not http(s) keeps only its label.
        assert_eq!(markdown(r#"<a href="javascript:alert(1)">click</a>"#), "click");
    }

    #[test]
    fn headings_lists_and_rules() {
        assert_eq!(markdown("<h2>Summary</h2><ul><li>One</li><li>Two</li></ul>"), "## Summary\n\n- One\n\n- Two");
        assert_eq!(markdown("a<br>b<hr/>c"), "a\nb\n\n---\n\nc");
        assert_eq!(markdown("<sub>small</sub> <span class=\"x\">text</span>"), "small text");
    }

    #[test]
    fn inline_code_and_code_blocks_keep_their_tags() {
        assert_eq!(markdown("Use `<details>` and `&amp;`"), "Use `<details>` and `&amp;`");
        let raw = "- Step one:\n  ```rust\n  let a = \"<b>\";\n  ```\n- Step two";
        assert_eq!(markdown(raw), "- Step one:\n\n```rust\nlet a = \"<b>\";\n```\n\n- Step two");
    }

    #[test]
    fn plain_text_passes_through() {
        assert_eq!(markdown("Just **Markdown**\r\nwith a [link](https://x.y)"), "Just **Markdown**\nwith a [link](https://x.y)");
        assert_eq!(markdown(""), "");
    }
}
