import Foundation

struct WeatherInfo {
    var tempF:     String = "--"
    var condition: String = "--"
    var sfSymbol:  String = "cloud.fill"
    var location:  String = ""
    var highF:     String = "--"
    var lowF:      String = "--"
}

/// Fetches current weather from wttr.in (no API key required, auto-detects location).
final class WeatherService: ObservableObject {
    @Published var weather  = WeatherInfo()
    @Published var isLoaded = false

    func fetch() {
        guard let url = URL(string: "https://wttr.in/?format=j1") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur  = (json["current_condition"] as? [[String: Any]])?.first
            else { return }

            let tempF     = cur["temp_F"] as? String ?? "--"
            let desc      = (cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? ""
            let dayInfo   = (json["weather"] as? [[String: Any]])?.first
            let maxF      = dayInfo?["maxtempF"] as? String ?? "--"
            let minF      = dayInfo?["mintempF"] as? String ?? "--"
            let area      = (json["nearest_area"] as? [[String: Any]])?.first
            let city      = (area?["areaName"] as? [[String: Any]])?.first?["value"] as? String ?? ""

            DispatchQueue.main.async {
                self.weather = WeatherInfo(
                    tempF:     tempF,
                    condition: desc,
                    sfSymbol:  Self.symbol(for: desc),
                    location:  city,
                    highF:     maxF,
                    lowF:      minF
                )
                self.isLoaded = true
            }
        }.resume()
    }

    private static func symbol(for condition: String) -> String {
        let c = condition.lowercased()
        if c.contains("thunder")                    { return "cloud.bolt.fill"     }
        if c.contains("snow") || c.contains("bliz") { return "cloud.snow.fill"     }
        if c.contains("sleet") || c.contains("ice") { return "cloud.sleet.fill"    }
        if c.contains("rain") || c.contains("driz") { return "cloud.rain.fill"     }
        if c.contains("fog")  || c.contains("mist") { return "cloud.fog.fill"      }
        if c.contains("overcast")                   { return "cloud.fill"           }
        if c.contains("cloud") && (c.contains("partly") || c.contains("sunny")) {
            return "cloud.sun.fill"
        }
        if c.contains("cloud")                      { return "cloud.fill"           }
        if c.contains("clear") || c.contains("sun") { return "sun.max.fill"         }
        return "cloud.fill"
    }

    // MARK: - Spoken lookup (cheap text path, no screenshots)

    /// Fetches a one-line spoken weather summary for `city` (or the Mac's current
    /// location when nil) from wttr.in. Used by the router's `weather_lookup`
    /// route alongside visibly opening the native Weather app. No vision cost.
    static func lookup(city: String?) async -> String? {
        var path = "https://wttr.in/"
        if let city, !city.isEmpty,
           let enc = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            path += enc
        }
        path += "?format=j1"

        guard let url = URL(string: path),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur  = (json["current_condition"] as? [[String: Any]])?.first
        else { return nil }

        let tempF = cur["temp_F"] as? String ?? "--"
        let feels = cur["FeelsLikeF"] as? String ?? tempF
        let desc  = (cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "clear"
        let day   = (json["weather"] as? [[String: Any]])?.first
        let maxF  = day?["maxtempF"] as? String ?? "--"
        let minF  = day?["mintempF"] as? String ?? "--"
        let area  = (json["nearest_area"] as? [[String: Any]])?.first
        let place = (area?["areaName"] as? [[String: Any]])?.first?["value"] as? String
            ?? (city ?? "your area")

        return "It's \(tempF)°F and \(desc.lowercased()) in \(place), feels like \(feels)°. "
             + "Today's high \(maxF)°, low \(minF)°."
    }
}
