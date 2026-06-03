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
}
