import Foundation
import CoreLocation

struct WeatherInfo {
    var tempF:     String = "--"
    var condition: String = "--"
    var sfSymbol:  String = "cloud.fill"
    var location:  String = ""
    var highF:     String = "--"
    var lowF:      String = "--"
}

/// One-shot async wrapper around Core Location. Returns the Mac's current
/// coordinate, prompting for permission the first time. Returns nil when
/// permission is denied/restricted or no fix is available.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Resolves to the current coordinate, or nil if unavailable. Safe to await
    /// from any context; only one request is in flight per provider at a time.
    @MainActor
    func current() async -> CLLocationCoordinate2D? {
        if continuation != nil { return nil }   // a request is already in flight
        return await withCheckedContinuation { cont in
            self.continuation = cont
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
                // locationManagerDidChangeAuthorization drives the next step.
            default:
                finish(nil)
            }
        }
    }

    private func finish(_ coord: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coord)
        continuation = nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break   // still .notDetermined — wait for the user to decide
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

/// Fetches current weather from wttr.in. Uses the Mac's GPS location so the
/// report matches where the user physically is, falling back to wttr.in's
/// IP-based geolocation only when location permission is unavailable.
final class WeatherService: ObservableObject {
    @Published var weather  = WeatherInfo()
    @Published var isLoaded = false

    private let locator = LocationProvider()

    func fetch() {
        Task { @MainActor in
            let coord = await locator.current()
            load(Self.url(for: coord))
        }
    }

    /// wttr.in endpoint for an explicit coordinate, or the IP-detected location
    /// when `coord` is nil.
    private static func url(for coord: CLLocationCoordinate2D?) -> URL? {
        var path = "https://wttr.in/"
        if let coord {
            let q = String(format: "%.4f,%.4f", coord.latitude, coord.longitude)
            path += q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        }
        path += "?format=j1"
        return URL(string: path)
    }

    private func load(_ url: URL?) {
        guard let url else { return }
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
    /// GPS location when nil) from wttr.in. Used by the router's `weather_lookup`
    /// route alongside visibly opening the native Weather app. No vision cost.
    static func lookup(city: String?) async -> String? {
        var path = "https://wttr.in/"
        if let city, !city.isEmpty,
           let enc = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            path += enc
        } else if let coord = await LocationProvider().current() {
            let q = String(format: "%.4f,%.4f", coord.latitude, coord.longitude)
            path += q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
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
