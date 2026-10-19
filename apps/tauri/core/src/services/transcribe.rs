//! Spraak naar tekst via een externe dienst die de gebruiker zelf koos (OpenAI of Groq, `audio/transcriptions`), en
//! het lezen van wat whisper.cpp lokaal schrijft. Woorden komen terug met hun tijd, voor de Notetaker.

use serde_json::Value;

use super::audio;
use super::notes::TimedWord;
use super::prefs::SpeechEngine;
use crate::provider::AIProvider;
use crate::{nook_err, Result};

/// Adres, model en sleutel-dienst van een externe herkenning.
pub fn endpoint(engine: SpeechEngine) -> Option<(&'static str, &'static str, AIProvider)> {
    match engine {
        SpeechEngine::Openai => Some(("https://api.openai.com/v1/audio/transcriptions", "whisper-1", AIProvider::Openai)),
        SpeechEngine::Groq => Some(("https://api.groq.com/openai/v1/audio/transcriptions", "whisper-large-v3-turbo", AIProvider::Groq)),
        SpeechEngine::Local => None,
    }
}

/// Een multipart-formulier met het geluid en de velden (zonder extra afhankelijkheid).
pub fn multipart(boundary: &str, fields: &[(&str, &str)], wav: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"nook.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// Tekst en woorden uit een `verbose_json`-antwoord. Zonder woordtijden krijgen de segmenten hun tijd.
pub fn parse_verbose(json: &Value, offset: f64) -> (String, Vec<TimedWord>) {
    let text = json.get("text").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let timed = |items: &Value, key: &str| -> Vec<TimedWord> {
        items
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|w| {
                let word = w.get(key)?.as_str()?.trim();
                let start = w.get("start")?.as_f64()?;
                let end = w.get("end")?.as_f64()?;
                (!word.is_empty()).then(|| TimedWord { text: word.into(), start: offset + start, end: offset + end.max(start + 0.05) })
            })
            .collect()
    };
    let mut words = json.get("words").map(|w| timed(w, "word")).unwrap_or_default();
    if words.is_empty() {
        words = json.get("segments").map(|s| timed(s, "text")).unwrap_or_default();
    }
    (text, words)
}

/// Stuurt 16 kHz mono naar de gekozen dienst. `language` is een tweelettercode of leeg.
pub async fn remote(engine: SpeechEngine, key: &str, samples: &[f32], language: &str, offset: f64) -> Result<(String, Vec<TimedWord>)> {
    let Some((url, model, _)) = endpoint(engine) else { return Err(nook_err!("Geen externe spraakherkenning gekozen.")) };
    let wav = audio::wav(samples, 16_000);
    let boundary = format!("nook{}", uuid::Uuid::new_v4().simple());
    let mut fields = vec![("model", model), ("response_format", "verbose_json"), ("timestamp_granularities[]", "word")];
    if engine == SpeechEngine::Openai {
        fields.push(("timestamp_granularities[]", "segment"));
    }
    if language.len() == 2 {
        fields.push(("language", language));
    }
    let body = multipart(&boundary, &fields, &wav);
    let response = reqwest::Client::new()
        .post(url)
        .bearer_auth(key)
        .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
        .timeout(std::time::Duration::from_secs(90))
        .body(body)
        .send()
        .await?;
    let status = response.status();
    let json: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let message = json.pointer("/error/message").and_then(Value::as_str).unwrap_or("onbekende fout");
        return Err(nook_err!("De spraakherkenning gaf een fout ({status}): {message}"));
    }
    Ok(parse_verbose(&json, offset))
}

/// De JSON die `whisper-cli -oj` schrijft: `transcription` met `offsets` in milliseconden.
pub fn parse_whisper_cpp(json: &Value, offset: f64) -> (String, Vec<TimedWord>) {
    let mut words = Vec::new();
    let mut text = Vec::new();
    for segment in json.get("transcription").and_then(Value::as_array).into_iter().flatten() {
        let piece = segment.get("text").and_then(Value::as_str).unwrap_or("").trim();
        if piece.is_empty() {
            continue;
        }
        text.push(piece.to_string());
        let from = segment.pointer("/offsets/from").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        let to = segment.pointer("/offsets/to").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        // Per segment de woorden gelijk verdeeld over de tijd: genoeg voor regels in het transcript.
        let parts: Vec<&str> = piece.split_whitespace().collect();
        let step = ((to - from) / parts.len().max(1) as f64).max(0.05);
        for (i, part) in parts.iter().enumerate() {
            let start = offset + from + i as f64 * step;
            words.push(TimedWord { text: (*part).into(), start, end: start + step * 0.9 });
        }
    }
    (text.join(" "), words)
}

/// De taal voor de herkenning: de antwoordtaal, of bij "auto" de taal van de interface.
pub fn language_code(answer: &str, app: &str) -> String {
    let code = if answer == "auto" { app } else { answer };
    if code.len() == 2 {
        code.into()
    } else {
        "nl".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_words_with_their_time() {
        let json = json!({"text": " Hallo daar ", "words": [{"word": "Hallo", "start": 0.1, "end": 0.4}, {"word": "daar", "start": 0.5, "end": 0.9}]});
        let (text, words) = parse_verbose(&json, 10.0);
        assert_eq!(text, "Hallo daar");
        assert_eq!(words.len(), 2);
        assert!((words[1].start - 10.5).abs() < 1e-9);
        let segments = json!({"text": "Hoi", "segments": [{"text": "Hoi", "start": 1.0, "end": 1.5}]});
        assert_eq!(parse_verbose(&segments, 0.0).1[0].text, "Hoi");
    }

    #[test]
    fn whisper_cpp_output() {
        let json = json!({"transcription": [{"offsets": {"from": 0, "to": 1000}, "text": " goede morgen"}]});
        let (text, words) = parse_whisper_cpp(&json, 2.0);
        assert_eq!(text, "goede morgen");
        assert_eq!(words.len(), 2);
        assert!((words[1].start - 2.5).abs() < 1e-9);
    }

    #[test]
    fn multipart_has_the_file_and_fields() {
        let body = String::from_utf8_lossy(&multipart("b", &[("model", "whisper-1")], b"RIFF")).to_string();
        assert!(body.starts_with("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"));
        assert!(body.contains("filename=\"nook.wav\""));
        assert!(body.ends_with("RIFF\r\n--b--\r\n"));
        assert_eq!(endpoint(SpeechEngine::Local), None);
        assert_eq!(language_code("auto", "en"), "en");
    }
}
