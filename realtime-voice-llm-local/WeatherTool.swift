import Foundation

// Public, structured weather data avoids JavaScript-only forecast pages.
// The free endpoint is intended for this personal, non-commercial prototype.
enum WeatherTool {
    static func geocodingURL(location: String, countryCode: String) throws -> URL {
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (2...160).contains(place.count), country.isEmpty || (country.count == 2 && country.utf8.allSatisfy({ (65...90).contains($0) })) else { throw VoiceError("Provide a city and a valid two-letter country code for weather.") }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "5"), .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        if !country.isEmpty { url.queryItems?.append(.init(name: "countryCode", value: country)) }
        return url.url!
    }
    static func forecastURL(latitude: Double, longitude: Double) throws -> URL {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw VoiceError("Invalid weather location coordinates.") }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: "celsius"), .init(name: "wind_speed_unit", value: "kmh"), .init(name: "precipitation_unit", value: "mm")]
        return url.url!
    }
    static func lookup(location: String, countryCode: String) async throws -> String {
        let url = try geocodingURL(location: location, countryCode: countryCode)
        let geocoding = try await json(url)
        guard let results = geocoding["results"] as? [[String: Any]], !results.isEmpty else {
            return "No weather location matched. Try a simpler city name and its country code, or search another source."
        }
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let matches = results.filter { country.isEmpty || $0["country_code"] as? String == country }
        guard let place = matches.first else { return "No weather location matched that country. Clarify the location or try another source." }
        if country.isEmpty && !location.contains(",") && Set(matches.compactMap { $0["country_code"] as? String }).count > 1 {
            let names = matches.map { label($0) }.joined(separator: "; ")
            return "Ambiguous weather location. Use the country already given in the conversation, or ask which location: " + names
        }
        guard let latitude = place["latitude"] as? Double, let longitude = place["longitude"] as? Double else { throw VoiceError("The weather service returned an invalid location.") }
        let forecast = try await json(forecastURL(latitude: latitude, longitude: longitude))
        return try format(forecast, location: label(place))
    }
    private static func label(_ place: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["name", "admin1", "country"] { if let part = place[key] as? String, !parts.contains(part) { parts.append(part) } }
        return parts.joined(separator: ", ")
    }
    private static func json(_ url: URL) async throws -> [String: Any] {
        let text = try await LocalTools.fetch(url)
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], value["error"] as? Bool != true else { throw VoiceError("The weather service did not return usable data. Try another source.") }
        return value
    }
    static func format(_ forecast: [String: Any], location: String) throws -> String {
        guard var current = forecast["current"] as? [String: Any], let time = current["time"] as? String,
              current["temperature_2m"] as? Double != nil,
              let daily = forecast["daily"] as? [String: Any], let dates = daily["time"] as? [String], !dates.isEmpty else { throw VoiceError("The forecast is missing current conditions or dates. Try another source.") }
        if let code = current["weather_code"] as? Int { current["conditions"] = condition(code) }
        var days: [[String: Any]] = []
        for (i, date) in dates.prefix(7).enumerated() {
            var day: [String: Any] = ["date": date]
            for key in ["weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max", "precipitation_sum", "wind_speed_10m_max"] {
                if let values = daily[key] as? [Any], i < values.count { day[key] = values[i] }
            }
            if let code = day["weather_code"] as? Int { day["conditions"] = condition(code) }
            days.append(day)
        }
        let summary: [String: Any] = ["source": "Open-Meteo", "source_url": "https://open-meteo.com/", "location": location,
            "timezone": forecast["timezone"] ?? "unknown", "current_local_time": time,
            "retrieved_at_utc": ISO8601DateFormatter().string(from: Date()),
            "note": "Current conditions are weather-model estimates. Dates and times use the location timezone. Null values are unavailable, not zero. Answer with these weather details and briefly credit Open-Meteo.",
            "current": current, "current_units": forecast["current_units"] ?? [:], "daily": days, "daily_units": forecast["daily_units"] ?? [:]]
        return String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self)
    }
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51: return "Light drizzle"
        case 53: return "Moderate drizzle"
        case 55: return "Dense drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Slight rain"
        case 63: return "Moderate rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Slight snow"
        case 73: return "Moderate snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Slight rain showers"
        case 81: return "Moderate rain showers"
        case 82: return "Violent rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown weather condition (code \(code))"
        }
    }
}
