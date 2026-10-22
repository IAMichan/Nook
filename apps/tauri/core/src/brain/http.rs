//! HTTP voor de breinen, met de foutmeldingen die gebruikers nodig hebben (server draait niet, sleutel fout, model onbekend).

use std::time::Duration;

use futures_util::{Stream, StreamExt};
use serde_json::Value;

use crate::provider::AIProvider;
use crate::{NookError, Result};

/// One shared client per timeout: a `reqwest::Client` is a handle to a connection pool, so reusing it keeps the
/// connection (and its TLS session) to the provider open between messages instead of building a new one every time.
pub fn client(provider: AIProvider) -> reqwest::Client {
    use std::sync::OnceLock;
    static LOCAL: OnceLock<reqwest::Client> = OnceLock::new();
    static REMOTE: OnceLock<reqwest::Client> = OnceLock::new();
    let build = |timeout: u64| {
        reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(timeout))
            .build()
            .unwrap_or_default()
    };
    if provider.is_local_server() {
        LOCAL.get_or_init(|| build(180)).clone()
    } else {
        REMOTE.get_or_init(|| build(120)).clone()
    }
}

pub fn connection_error(error: reqwest::Error, provider: AIProvider) -> NookError {
    if error.is_timeout() {
        return NookError(if provider.is_local_server() {
            format!("{} deed er te lang over. Een kleiner model antwoordt sneller; kies er een bij Instellingen › Brein.", provider.title())
        } else {
            format!("{} antwoordde niet op tijd.", provider.title())
        });
    }
    if error.is_connect() {
        return NookError(if provider.is_local_server() {
            format!("{} draait niet. Start hem en probeer het opnieuw.", provider.title())
        } else {
            format!("Kan {} niet bereiken. Staat er een firewall, VPN of proxy aan?", provider.title())
        });
    }
    NookError(format!("Netwerkfout: {error}"))
}

pub fn status_error(status: u16, object: &Value, provider: AIProvider, model: &str) -> NookError {
    let message = object
        .pointer("/error/message")
        .and_then(|v| v.as_str())
        .or_else(|| object.get("error").and_then(|v| v.as_str()))
        .map(str::to_string)
        .unwrap_or_else(|| format!("status {status}"));
    let title = provider.title();
    NookError(match (provider, status) {
        (AIProvider::Claude, 400) if message.to_lowercase().contains("credit") => {
            "Je Anthropic-tegoed is op. Vul het aan op console.anthropic.com › Plans & Billing.".into()
        }
        (_, 401) | (_, 403) => format!("{title} weigerde de API-sleutel: {message}"),
        (_, 404) => format!("Model {model} bestaat niet bij {title}. Kies een ander model bij Instellingen › Brein."),
        (_, 429) => format!("Limiet bereikt bij {title}. Wacht even."),
        (_, 500..=599) => format!("{title} heeft nu problemen ({status}). Probeer het zo opnieuw."),
        _ => format!("{title}: {message}"),
    })
}

/// Een POST die per regel terugkomt (Ollama: één JSON per regel; OpenAI en Anthropic: SSE `data:`-regels).
pub async fn post_lines(
    request: reqwest::RequestBuilder,
    body: &Value,
    provider: AIProvider,
    model: &str,
) -> Result<impl Stream<Item = Result<String>>> {
    let response = request.json(body).send().await.map_err(|e| connection_error(e, provider))?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        let object: Value = response.json().await.unwrap_or_default();
        return Err(status_error(status, &object, provider, model));
    }
    Ok(lines(response.bytes_stream().map(move |r| r.map_err(|e| connection_error(e, provider)))))
}

pub async fn post_json(request: reqwest::RequestBuilder, body: &Value, provider: AIProvider, model: &str) -> Result<Value> {
    let response = request.json(body).send().await.map_err(|e| connection_error(e, provider))?;
    let status = response.status().as_u16();
    let object: Value = response.json().await.unwrap_or_default();
    if !(200..300).contains(&status) {
        return Err(status_error(status, &object, provider, model));
    }
    Ok(object)
}

/// Bytes naar regels, ook als een regel over twee pakketjes verdeeld is.
pub fn lines<S, B>(stream: S) -> impl Stream<Item = Result<String>>
where
    S: Stream<Item = Result<B>> + Unpin,
    B: AsRef<[u8]>,
{
    futures_util::stream::unfold((stream, Vec::<u8>::new(), false), |(mut stream, mut buffer, mut done)| async move {
        loop {
            if let Some(pos) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=pos).collect();
                let text = String::from_utf8_lossy(&line).trim_end_matches(['\r', '\n']).to_string();
                return Some((Ok(text), (stream, buffer, done)));
            }
            if done {
                if buffer.is_empty() {
                    return None;
                }
                let text = String::from_utf8_lossy(&buffer).to_string();
                buffer.clear();
                return Some((Ok(text), (stream, buffer, done)));
            }
            match stream.next().await {
                Some(Ok(chunk)) => buffer.extend_from_slice(chunk.as_ref()),
                Some(Err(e)) => return Some((Err(e), (stream, buffer, true))),
                None => done = true,
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn splits_lines_across_chunks() {
        let chunks: Vec<Result<&[u8]>> = vec![Ok(b"data: {\"a\""), Ok(b":1}\n\ndata: [DONE]")];
        let out: Vec<String> = lines(futures_util::stream::iter(chunks)).map(|l| l.unwrap()).collect().await;
        assert_eq!(out, vec!["data: {\"a\":1}", "", "data: [DONE]"]);
    }
}
