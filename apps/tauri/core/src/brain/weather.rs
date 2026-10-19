//! Het weer van Open-Meteo: gratis, zonder sleutel of account. Het brein krijgt precieze getallen in plaats van ze uit
//! zoekresultaten te lezen, wat kleine lokale modellen vaak fout doen. Zonder plaats gebruikt Nook de stad van de
//! tijdzone van deze computer (Europe/Amsterdam → Amsterdam): geen locatietoestemming nodig.

use serde_json::Value;

use crate::{NookError, Result};

#[derive(Debug, Clone, PartialEq)]
pub struct Place {
    pub name: String,
    pub latitude: f64,
    pub longitude: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Day {
    pub date: String,
    pub code: i64,
    pub minimum: f64,
    pub maximum: f64,
    pub rain_chance: Option<i64>,
    pub rain: Option<f64>,
    pub wind: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Forecast {
    pub place: String,
    pub temperature: Option<f64>,
    pub feels_like: Option<f64>,
    pub code: Option<i64>,
    pub wind: Option<f64>,
    pub days: Vec<Day>,
}

/// De stad in de naam van de tijdzone, als redelijke standaardplek.
pub fn default_place(timezone: &str) -> String {
    timezone.rsplit('/').next().unwrap_or("").replace('_', " ")
}

pub fn parse_place(object: &Value) -> Option<Place> {
    let first = object["results"].as_array()?.first()?;
    let name = first["name"].as_str()?;
    let region: Vec<&str> = [first["admin1"].as_str(), first["country"].as_str()]
        .into_iter()
        .flatten()
        .filter(|r| !r.is_empty() && *r != name)
        .take(1)
        .collect();
    let full = std::iter::once(name).chain(region).collect::<Vec<_>>().join(", ");
    Some(Place { name: full, latitude: first["latitude"].as_f64()?, longitude: first["longitude"].as_f64()? })
}

pub fn parse_forecast(object: &Value, place: &str) -> Option<Forecast> {
    let current = &object["current"];
    let daily = &object["daily"];
    let dates: Vec<&str> = daily["time"].as_array().into_iter().flatten().filter_map(|v| v.as_str()).collect();
    let at = |key: &str, index: usize| daily[key].as_array().and_then(|a| a.get(index)).and_then(|v| v.as_f64());
    let days: Vec<Day> = dates
        .iter()
        .enumerate()
        .filter_map(|(i, date)| {
            Some(Day {
                date: date.to_string(),
                code: at("weather_code", i).unwrap_or(-1.0) as i64,
                minimum: at("temperature_2m_min", i)?,
                maximum: at("temperature_2m_max", i)?,
                rain_chance: at("precipitation_probability_max", i).map(|v| v.round() as i64),
                rain: at("precipitation_sum", i),
                wind: at("wind_speed_10m_max", i),
            })
        })
        .collect();
    let temperature = current["temperature_2m"].as_f64();
    if days.is_empty() && temperature.is_none() {
        return None;
    }
    Some(Forecast {
        place: place.into(),
        temperature,
        feels_like: current["apparent_temperature"].as_f64(),
        code: current["weather_code"].as_f64().map(|c| c as i64),
        wind: current["wind_speed_10m"].as_f64(),
        days,
    })
}

/// WMO-weercodes, zoals Open-Meteo ze geeft.
pub fn describe(code: i64) -> &'static str {
    match code {
        0 => "clear sky",
        1 => "mainly clear",
        2 => "partly cloudy",
        3 => "overcast",
        45 | 48 => "fog",
        51 | 53 | 55 => "drizzle",
        56 | 57 => "freezing drizzle",
        61 => "light rain",
        63 => "rain",
        65 => "heavy rain",
        66 | 67 => "freezing rain",
        71 => "light snow",
        73 => "snow",
        75 => "heavy snow",
        77 => "snow grains",
        80 | 81 => "rain showers",
        82 => "violent rain showers",
        85 | 86 => "snow showers",
        95 => "thunderstorm",
        96 | 99 => "thunderstorm with hail",
        _ => "unknown",
    }
}

pub fn text(forecast: &Forecast, today: &str) -> String {
    let degrees = |v: f64| format!("{} °C", v.round() as i64);
    let mut lines = vec![format!("Weather for {} (Open-Meteo):", forecast.place)];
    if let Some(temperature) = forecast.temperature {
        let mut now = format!("Now: {}", degrees(temperature));
        if let Some(code) = forecast.code {
            now += &format!(", {}", describe(code));
        }
        if let Some(feels) = forecast.feels_like.filter(|f| (f - temperature).abs() >= 2.0) {
            now += &format!(", feels like {}", degrees(feels));
        }
        if let Some(wind) = forecast.wind {
            now += &format!(", wind {} km/h", wind.round() as i64);
        }
        lines.push(format!("{now}."));
    }
    for day in &forecast.days {
        let label = if day.date == today { "Today".to_string() } else { day.date.clone() };
        let mut line = format!("{label}: {}, {} to {}", describe(day.code), degrees(day.minimum), degrees(day.maximum));
        if let Some(chance) = day.rain_chance {
            line += &format!(", {chance}% chance of rain");
        }
        if let Some(rain) = day.rain.filter(|r| *r >= 0.1) {
            line += &format!(" ({rain:.1} mm)");
        }
        if let Some(wind) = day.wind {
            line += &format!(", wind up to {} km/h", wind.round() as i64);
        }
        lines.push(format!("{line}."));
    }
    lines.join("\n")
}

pub async fn forecast(place: &str, days: i64, timezone: &str, language: &str) -> Result<String> {
    let name = if place.trim().is_empty() { default_place(timezone) } else { place.trim().to_string() };
    if name.is_empty() {
        return Ok("No place was given and the home town is unknown. Ask the user which town they mean.".into());
    }
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(10)).build()?;
    let mut search = url::Url::parse("https://geocoding-api.open-meteo.com/v1/search").expect("vast adres");
    search
        .query_pairs_mut()
        .append_pair("name", &name)
        .append_pair("count", "1")
        .append_pair("language", language)
        .append_pair("format", "json");
    let places: Value = client.get(search).send().await?.json().await.unwrap_or_default();
    let Some(found) = parse_place(&places) else {
        return Ok(format!("No place called \"{name}\" was found. Ask the user which town they mean."));
    };
    let mut query = url::Url::parse("https://api.open-meteo.com/v1/forecast").expect("vast adres");
    query
        .query_pairs_mut()
        .append_pair("latitude", &found.latitude.to_string())
        .append_pair("longitude", &found.longitude.to_string())
        .append_pair("current", "temperature_2m,apparent_temperature,weather_code,wind_speed_10m")
        .append_pair(
            "daily",
            "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max",
        )
        .append_pair("timezone", "auto")
        .append_pair("forecast_days", &days.clamp(1, 7).to_string());
    let response = client.get(query).send().await?;
    if response.status().as_u16() != 200 {
        return Err(NookError::new("De weerdienst antwoordde niet. Probeer het zo opnieuw."));
    }
    let object: Value = response.json().await.unwrap_or_default();
    let forecast =
        parse_forecast(&object, &found.name).ok_or_else(|| NookError::new("De weerdienst antwoordde niet. Probeer het zo opnieuw."))?;
    Ok(text(&forecast, &chrono::Local::now().format("%Y-%m-%d").to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_open_meteo() {
        let place = parse_place(
            &json!({"results": [{"name": "Utrecht", "admin1": "Utrecht", "country": "Nederland", "latitude": 52.09, "longitude": 5.12}]}),
        )
        .unwrap();
        assert_eq!(place.name, "Utrecht, Nederland");
        let object = json!({
            "current": {"temperature_2m": 12.4, "apparent_temperature": 9.8, "weather_code": 3, "wind_speed_10m": 18.0},
            "daily": {"time": ["2026-10-19", "2026-10-20"], "weather_code": [61, 0], "temperature_2m_max": [14.0, 16.0], "temperature_2m_min": [8.0, 7.0],
                      "precipitation_probability_max": [80, 5], "precipitation_sum": [3.2, 0.0], "wind_speed_10m_max": [30.0, 12.0]}
        });
        let forecast = parse_forecast(&object, "Utrecht").unwrap();
        let out = text(&forecast, "2026-10-19");
        assert!(out.contains("Now: 12 °C, overcast, feels like 10 °C, wind 18 km/h."));
        assert!(out.contains("Today: light rain, 8 °C to 14 °C, 80% chance of rain (3.2 mm), wind up to 30 km/h."));
        assert!(out.contains("2026-10-20: clear sky"));
        assert_eq!(default_place("Europe/Amsterdam"), "Amsterdam");
        assert_eq!(default_place("America/New_York"), "New York");
    }
}
