//! The JavaScript behind `browser_snapshot`, `browser_click`, `browser_type` and `browser_wait_for`
//! (`BridgeBrowserScript` on the Mac). Everything the agent sends goes in as one JSON value, never pasted into the code,
//! so a selector or text cannot break out of its string. Each script is one expression that returns JSON text.
//!
//! One difference from the Mac: Nook's browser here hands a script's result back through a navigation (see
//! `src-tauri/src/workspace/browser.rs`), so a click or submit that starts a navigation at once could swallow the
//! answer. The click and the submit therefore run a moment after the script has answered.

use serde_json::{json, Map, Value};

/// How an element is found; exactly one is given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Ref(String),
    Selector(String),
    Text(String),
}

impl Target {
    /// The target from the tool's arguments, or the error for the agent.
    pub fn parse(arguments: &Map<String, Value>) -> Result<Self, &'static str> {
        let text = |k: &str| arguments.get(k).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty()).map(str::to_string);
        let given: Vec<Target> = [text("ref").map(Target::Ref), text("selector").map(Target::Selector), text("text").map(Target::Text)]
            .into_iter()
            .flatten()
            .collect();
        match given.as_slice() {
            [] => Err("Say which element: ref (from browser_snapshot), selector or text."),
            [Target::Ref(r)] if !r.chars().all(|c| c.is_ascii_alphanumeric()) => {
                Err("A ref looks like \"e7\"; take it from browser_snapshot.")
            }
            [one] => Ok(one.clone()),
            _ => Err("Give only one of ref, selector and text."),
        }
    }

    /// For the approval card and the audit log.
    pub fn summary(&self) -> String {
        match self {
            Self::Ref(r) => format!("ref {r}"),
            Self::Selector(s) => format!("selector {s}"),
            Self::Text(t) => format!("text \"{t}\""),
        }
    }

    fn json(&self) -> Value {
        match self {
            Self::Ref(r) => json!({"ref": r}),
            Self::Selector(s) => json!({"selector": s}),
            Self::Text(t) => json!({"text": t}),
        }
    }
}

/// The `ref`, `selector` and `text` properties of click and type.
pub fn target_properties() -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("ref".into(), json!({"type": "string", "description": "Element ref from browser_snapshot (e.g. \"e7\"; preferred)."}));
    m.insert("selector".into(), json!({"type": "string", "description": "Or CSS selector."}));
    m.insert("text".into(), json!({"type": "string", "description": "Or visible text of a link, button or label."}));
    m
}

/// A value as a JavaScript literal: JSON, with U+2028/2029 escaped (valid JSON, but a line end in older JavaScript).
pub fn literal(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into()).replace('\u{2028}', "\\u2028").replace('\u{2029}', "\\u2029")
}

/// Finds the element for a target, shared by click and type. Visible text matches exactly first, then as a part.
const FINDER: &str = r#"function __nookFind(t) {
    if (t.ref) return document.querySelector('[data-nook-ref="' + t.ref + '"]');
    if (t.selector) { try { return document.querySelector(t.selector); } catch (e) { throw new Error('Invalid CSS selector.'); } }
    var want = (t.text || '').trim().toLowerCase();
    var all = Array.prototype.slice.call(document.querySelectorAll('a,button,input[type=button],input[type=submit],[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],label,summary,option'));
    var shown = function (e) { return e.getClientRects().length > 0; };
    var name = function (e) { return ((e.innerText || e.value || e.getAttribute('aria-label') || '') + '').trim().toLowerCase(); };
    return all.find(function (e) { return shown(e) && name(e) === want; }) || all.find(function (e) { return shown(e) && name(e).indexOf(want) >= 0; }) || null;
  }
  function __nookDescribe(e) {
    var label = ((e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '') + '').trim().replace(/\s+/g, ' ');
    return e.tagName.toLowerCase() + (label ? ' "' + label.slice(0, 80) + '"' : '');
  }"#;

/// A ring where the agent acts, so the user sees where it clicks or types. Only drawn, never in the way of the page.
const AGENT_MARK: &str = r#"(function (t) { var r = t.getBoundingClientRect(), m = document.createElement('div');
    m.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;width:22px;height:22px;border-radius:50%;' +
      'border:2px solid #7c6cf0;background:rgba(124,108,240,.25);transition:transform .5s ease-out,opacity .5s ease-out;' +
      'left:' + (r.left + r.width / 2 - 11) + 'px;top:' + (r.top + r.height / 2 - 11) + 'px';
    document.documentElement.appendChild(m);
    requestAnimationFrame(function () { m.style.transform = 'scale(1.8)'; m.style.opacity = '0'; });
    setTimeout(function () { m.remove(); }, 700); })(e);"#;

/// How long after answering a click or submit happens (the answer leaves at 0 ms).
const ACT_DELAY_MS: u32 = 120;

/// The element limit of a snapshot: default 150, at most 400.
pub fn snapshot_limit(requested: Option<i64>) -> usize {
    requested.map(|n| n.clamp(1, 400) as usize).unwrap_or(150)
}

/// Gives every visible element you can use a ref and lists them with the headings.
pub fn snapshot(limit: usize) -> String {
    let limit = limit.clamp(1, 400);
    format!(
        r#"(function () {{
  var limit = {limit};
  var nodes = document.querySelectorAll('a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=textbox],[contenteditable=true],h1,h2,h3');
  var lines = [], n = 0, more = false;
  document.querySelectorAll('[data-nook-ref]').forEach(function (e) {{ e.removeAttribute('data-nook-ref'); }});
  for (var i = 0; i < nodes.length; i++) {{
    var e = nodes[i];
    if (lines.length >= limit) {{ more = true; break; }}
    if (e.getClientRects().length === 0 || e.type === 'hidden') continue;
    var tag = e.tagName.toLowerCase();
    var text = ((e.innerText || e.getAttribute('aria-label') || e.getAttribute('title') || '') + '').trim().replace(/\s+/g, ' ').slice(0, 100);
    if (/^h[1-3]$/.test(tag)) {{ if (text) lines.push(tag + ' ' + JSON.stringify(text)); continue; }}
    n += 1;
    var ref = 'e' + n;
    e.setAttribute('data-nook-ref', ref);
    var role = e.getAttribute('role') || (tag === 'input' ? 'input[' + (e.type || 'text') + ']' : tag);
    var line = '[' + ref + '] ' + role;
    if (text) line += ' ' + JSON.stringify(text);
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {{
      var label = e.labels && e.labels[0] ? e.labels[0].innerText.trim() : '';
      if (label) line += ' label=' + JSON.stringify(label.slice(0, 60));
      if (e.name) line += ' name=' + JSON.stringify(e.name);
      if (e.placeholder) line += ' placeholder=' + JSON.stringify(e.placeholder.slice(0, 60));
      if (e.type === 'password') line += e.value ? ' value=(hidden)' : '';
      else if (e.type === 'checkbox' || e.type === 'radio') line += e.checked ? ' checked' : ' unchecked';
      else if (e.value) line += ' value=' + JSON.stringify(String(e.value).slice(0, 80));
      if (e.disabled) line += ' disabled';
    }}
    if (tag === 'a' && e.getAttribute('href')) line += ' href=' + JSON.stringify(e.getAttribute('href').slice(0, 120));
    lines.push(line);
  }}
  return JSON.stringify({{ title: document.title, url: location.href, lines: lines, more: more }});
}})()"#
    )
}

/// The snapshot's JSON as the text the agent reads.
pub fn snapshot_text(json: &str) -> String {
    let v: Value = serde_json::from_str(json).unwrap_or_default();
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let lines: Vec<&str> =
        v.get("lines").and_then(Value::as_array).map(|l| l.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let mut text = format!("# {}\nURL: {}\n\n", s("title"), s("url"));
    text += &if lines.is_empty() { "(nothing to interact with)".to_string() } else { lines.join("\n") };
    if v.get("more").and_then(Value::as_bool) == Some(true) {
        text += "\n… more elements; pass a higher limit (at most 400).";
    }
    text
}

pub fn click(target: &Target) -> String {
    format!(
        r#"(function () {{
  {FINDER}
  var e = __nookFind({t});
  if (!e) return JSON.stringify({{ ok: false, error: 'No such element on the page. Take a new browser_snapshot.' }});
  if (e.disabled) return JSON.stringify({{ ok: false, error: 'That element is disabled.' }});
  e.scrollIntoView({{ block: 'center' }});
  {AGENT_MARK}
  if (e.focus) e.focus();
  setTimeout(function () {{ e.click(); }}, {ACT_DELAY_MS});
  return JSON.stringify({{ ok: true, element: __nookDescribe(e) }});
}})()"#,
        t = literal(&target.json())
    )
}

/// Types through the field's own value setter and fires input and change, so frameworks such as React see it.
pub fn type_text(target: &Target, value: &str, append: bool, submit: bool) -> String {
    format!(
        r#"(function () {{
  {FINDER}
  var e = __nookFind({t});
  if (!e) return JSON.stringify({{ ok: false, error: 'No such element on the page. Take a new browser_snapshot.' }});
  if (e.tagName === 'LABEL' && e.control) e = e.control;
  if (e.disabled || e.readOnly) return JSON.stringify({{ ok: false, error: 'That field cannot be edited.' }});
  var value = {value}, append = {append};
  e.scrollIntoView({{ block: 'center' }});
  {AGENT_MARK}
  if (e.focus) e.focus();
  if (e.isContentEditable) {{
    if (!append) {{ document.execCommand('selectAll', false, null); }}
    document.execCommand('insertText', false, value);
  }} else if ('value' in e) {{
    var next = append ? String(e.value || '') + value : value;
    var proto = Object.getPrototypeOf(e);
    var setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) setter.set.call(e, next); else e.value = next;
    e.dispatchEvent(new Event('input', {{ bubbles: true }}));
    e.dispatchEvent(new Event('change', {{ bubbles: true }}));
  }} else {{
    return JSON.stringify({{ ok: false, error: 'That element is not a field you can type in.' }});
  }}
  var submitted = false;
  if ({submit}) {{
    var form = e.form || (e.closest ? e.closest('form') : null);
    setTimeout(function () {{
      if (form && form.requestSubmit) {{ form.requestSubmit(); return; }}
      ['keydown', 'keypress', 'keyup'].forEach(function (kind) {{
        e.dispatchEvent(new KeyboardEvent(kind, {{ key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }}));
      }});
    }}, {ACT_DELAY_MS});
    submitted = true;
  }}
  return JSON.stringify({{ ok: true, element: __nookDescribe(e), submitted: submitted }});
}})()"#,
        t = literal(&target.json()),
        value = literal(&Value::String(value.into())),
    )
}

/// True (as JSON) when the condition holds now; called repeatedly until it does.
pub fn condition(text: Option<&str>, selector: Option<&str>, gone: bool) -> String {
    format!(
        r#"(function () {{
  var text = {text}, selector = {selector};
  var found = true;
  if (text) found = !!(document.body && document.body.innerText.indexOf(text) >= 0);
  if (found && selector) {{ try {{ found = !!document.querySelector(selector); }} catch (e) {{ return JSON.stringify({{ error: 'Invalid CSS selector.' }}); }} }}
  return JSON.stringify({{ met: {met} }});
}})()"#,
        text = literal(&Value::String(text.unwrap_or("").into())),
        selector = literal(&Value::String(selector.unwrap_or("").into())),
        met = if gone { "!found" } else { "found" },
    )
}

/// The wait in seconds: default 10, between 1 and 30.
pub fn wait_seconds(requested: Option<i64>) -> u64 {
    requested.map(|n| n.clamp(1, 30) as u64).unwrap_or(10)
}

/// The `{ok, error, …}` object a script returned; empty when it was not JSON.
pub fn result(text: &str) -> Map<String, Value> {
    serde_json::from_str::<Value>(text).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn exactly_one_target() {
        assert_eq!(Target::parse(&args(json!({"ref": "e7"}))), Ok(Target::Ref("e7".into())));
        assert_eq!(Target::parse(&args(json!({"text": " Save "}))), Ok(Target::Text("Save".into())));
        assert!(Target::parse(&args(json!({}))).unwrap_err().starts_with("Say which element"));
        assert!(Target::parse(&args(json!({"ref": "e1", "text": "x"}))).unwrap_err().starts_with("Give only one"));
        assert!(Target::parse(&args(json!({"ref": "e1\"]"}))).unwrap_err().starts_with("A ref looks like"));
        assert_eq!(Target::Selector("#go".into()).summary(), "selector #go");
    }

    #[test]
    fn agent_text_cannot_break_out_of_its_string() {
        let evil = "'); alert(1); ('\u{2028}</script>";
        let script = type_text(&Target::Selector(evil.into()), evil, false, true);
        // Inside a JSON (double-quoted) string, where a single quote ends nothing.
        assert!(script.contains(r#"var value = "'); alert(1); ('\u2028</script>""#), "{script}");
        assert!(script.contains(r#"__nookFind({"selector":"'); alert(1); ('\u2028</script>"})"#));
        assert!(script.contains("\\u2028"));
        assert!(!script.contains('\u{2028}'));
        assert!(condition(Some("a\"b"), None, true).contains(r#"var text = "a\"b""#));
        assert!(condition(None, None, true).contains("met: !found"));
    }

    #[test]
    fn click_and_submit_run_after_the_answer() {
        assert!(click(&Target::Ref("e2".into())).contains("setTimeout(function () { e.click(); }, 120)"));
        assert!(type_text(&Target::Ref("e2".into()), "x", true, false).contains("if (false) {"));
        assert!(type_text(&Target::Ref("e2".into()), "x", false, true).contains("if (true) {"));
        assert!(type_text(&Target::Ref("e2".into()), "x", true, true).contains("append = true"));
    }

    #[test]
    fn limits_and_snapshot_text() {
        assert_eq!(snapshot_limit(None), 150);
        assert_eq!(snapshot_limit(Some(0)), 1);
        assert_eq!(snapshot_limit(Some(9999)), 400);
        assert!(snapshot(9999).contains("var limit = 400;"));
        assert_eq!(wait_seconds(None), 10);
        assert_eq!(wait_seconds(Some(100)), 30);
        let text =
            snapshot_text(r#"{"title":"Shop","url":"http://localhost:3000/","lines":["h1 \"Cart\"","[e1] button \"Pay\""],"more":true}"#);
        assert_eq!(
            text,
            "# Shop\nURL: http://localhost:3000/\n\nh1 \"Cart\"\n[e1] button \"Pay\"\n… more elements; pass a higher limit (at most 400)."
        );
        assert!(snapshot_text("{}").ends_with("(nothing to interact with)"));
        assert_eq!(result("{\"ok\":true}").get("ok"), Some(&Value::Bool(true)));
        assert!(result("nope").is_empty());
    }
}
