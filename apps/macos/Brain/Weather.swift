import Foundation

/// The weather from Open-Meteo: free, no key, no account. A brain gets exact numbers instead of reading them from search
/// snippets, which small local models often get wrong ("18 degrees" from last week's page).
///
/// Without a place, Nook uses the city of the Mac's time zone (Europe/Amsterdam → Amsterdam): no location permission.
enum Weather {
    struct Place: Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    struct Day: Equatable {
        var date: String
        var code: Int
        var minimum: Double
        var maximum: Double
        var rainChance: Int?
        var rain: Double?
        var wind: Double?
    }

    struct Forecast: Equatable {
        var place: String
        var temperature: Double?
        var feelsLike: Double?
        var code: Int?
        var wind: Double?
        var days: [Day]
    }

    /// The city in the time zone's name, as a sensible default place.
    static func defaultPlace(timeZone: TimeZone = .current) -> String {
        let city = timeZone.identifier.split(separator: "/").last.map(String.init) ?? ""
        return city.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Parsing

    static func parsePlace(_ data: Data) -> Place? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = (object["results"] as? [[String: Any]])?.first,
              let name = first["name"] as? String,
              let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double else { return nil }
        let region = [first["admin1"] as? String, first["country"] as? String].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }
        return Place(name: ([name] + region.prefix(1)).joined(separator: ", "), latitude: latitude, longitude: longitude)
    }

    static func parseForecast(_ data: Data, place: String) -> Forecast? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let current = object["current"] as? [String: Any] ?? [:]
        let daily = object["daily"] as? [String: Any] ?? [:]
        let dates = daily["time"] as? [String] ?? []
        func column(_ key: String) -> [Any] { daily[key] as? [Any] ?? [] }
        func at(_ key: String, _ index: Int) -> Double? {
            let values = column(key)
            return index < values.count ? number(values[index]) : nil
        }
        let days: [Day] = dates.indices.compactMap { index in
            guard let minimum = at("temperature_2m_min", index), let maximum = at("temperature_2m_max", index) else { return nil }
            return Day(date: dates[index], code: Int(at("weather_code", index) ?? -1), minimum: minimum, maximum: maximum,
                       rainChance: at("precipitation_probability_max", index).map { Int($0.rounded()) },
                       rain: at("precipitation_sum", index), wind: at("wind_speed_10m_max", index))
        }
        guard !days.isEmpty || number(current["temperature_2m"]) != nil else { return nil }
        return Forecast(place: place, temperature: number(current["temperature_2m"]), feelsLike: number(current["apparent_temperature"]),
                        code: number(current["weather_code"]).map { Int($0) }, wind: number(current["wind_speed_10m"]), days: days)
    }

    // MARK: Text for the brain

    /// WMO weather codes, as Open-Meteo returns them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "violent rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "unknown"
        }
    }

    static func text(_ forecast: Forecast, today: String) -> String {
        func degrees(_ value: Double) -> String { "\(Int(value.rounded())) °C" }
        var lines = ["Weather for \(forecast.place) (Open-Meteo):"]
        if let temperature = forecast.temperature {
            var now = "Now: \(degrees(temperature))"
            if let code = forecast.code { now += ", \(describe(code))" }
            if let feels = forecast.feelsLike, abs(feels - temperature) >= 2 { now += ", feels like \(degrees(feels))" }
            if let wind = forecast.wind { now += ", wind \(Int(wind.rounded())) km/h" }
            lines.append(now + ".")
        }
        for day in forecast.days {
            var line = "\(day.date == today ? "Today" : day.date): \(describe(day.code)), \(degrees(day.minimum)) to \(degrees(day.maximum))"
            if let chance = day.rainChance { line += ", \(chance)% chance of rain" }
            if let rain = day.rain, rain >= 0.1 { line += " (\(String(format: "%.1f", rain)) mm)" }
            if let wind = day.wind { line += ", wind up to \(Int(wind.rounded())) km/h" }
            lines.append(line + ".")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Network

    static func forecast(for place: String, days: Int) async throws -> String {
        let name = place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPlace() : place
        var search = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        search?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                              URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
                              URLQueryItem(name: "format", value: "json")]
        guard let searchURL = search?.url else { throw NookError("Invalid place name.") }
        let (placeData, _) = try await URLSession.shared.data(from: searchURL)
        guard let found = parsePlace(placeData) else { return "No place called \"\(name)\" was found. Ask the user which town they mean." }

        var query = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        query?.queryItems = [
            URLQueryItem(name: "latitude", value: String(found.latitude)),
            URLQueryItem(name: "longitude", value: String(found.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(min(max(days, 1), 7)))
        ]
        guard let url = query?.url else { throw NookError("Invalid weather request.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let forecast = parseForecast(data, place: found.name) else {
            throw NookError("The weather service did not answer. Try again shortly.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return text(forecast, today: formatter.string(from: Date()))
    }
}
