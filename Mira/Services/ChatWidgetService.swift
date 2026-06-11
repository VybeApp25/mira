import Foundation

// MARK: - Widget data models

enum ChatWidget: Equatable {
    case stock(StockQuote)
    case images([ImageResult])
    case place(PlaceResult)
    case artifact(ArtifactInfo)
}

struct ArtifactInfo: Equatable {
    let url:       URL
    let name:      String
    let ext:       String     // lowercase, no dot: "pdf", "docx", "py", etc.
    let sizeBytes: Int64

    var formattedSize: String {
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        if sizeBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(sizeBytes) / 1024) }
        return String(format: "%.1f MB", Double(sizeBytes) / (1024 * 1024))
    }

    var sfSymbol: String {
        switch ext {
        case "pdf":                                    return "doc.fill"
        case "docx", "doc":                            return "doc.richtext.fill"
        case "xlsx", "xls", "csv":                     return "tablecells.fill"
        case "py":                                     return "terminal.fill"
        case "swift":                                  return "swift"
        case "js", "ts", "jsx", "tsx":                return "curlybraces"
        case "html", "htm", "css":                     return "globe"
        case "json", "yaml", "yml", "toml":            return "curlybraces.square.fill"
        case "md", "txt", "rtf":                       return "doc.plaintext.fill"
        case "png", "jpg", "jpeg", "gif", "webp":      return "photo.fill"
        case "mp4", "mov", "avi":                      return "video.fill"
        case "mp3", "wav", "aac", "m4a":               return "music.note"
        case "zip", "tar", "gz", "7z":                 return "archivebox.fill"
        default:                                        return "doc.fill"
        }
    }

    var accentColor: String {
        switch ext {
        case "pdf":            return "red"
        case "docx", "doc":   return "blue"
        case "xlsx", "xls", "csv": return "green"
        case "py":            return "yellow"
        case "swift":         return "orange"
        case "png", "jpg", "jpeg", "gif", "webp": return "purple"
        default:              return "white"
        }
    }
}

struct StockQuote: Equatable {
    let symbol:        String
    let name:          String
    let price:         Double
    let change:        Double
    let changePercent: Double
    let currency:      String
    let marketState:   String   // "REGULAR", "PRE", "POST", "CLOSED"
}

struct ImageResult: Identifiable, Equatable {
    let id       = UUID()
    let title:    String
    let thumbURL: String
    let srcURL:   String
    static func == (a: ImageResult, b: ImageResult) -> Bool { a.id == b.id }
}

struct PlaceResult: Equatable {
    let name:     String
    let address:  String
    let lat:      Double
    let lon:      Double
    let category: String
}

// MARK: - ChatWidgetService

@MainActor
final class ChatWidgetService {
    static let shared = ChatWidgetService()
    private init() {}

    // MARK: - Stock (Yahoo Finance, no key)

    func fetchStock(query: String) async -> StockQuote? {
        let symbol = extractTicker(from: query)
        guard !symbol.isEmpty else { return nil }
        let urlStr = "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(symbol)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qr    = (json["quoteResponse"] as? [String: Any])?["result"] as? [[String: Any]],
              let q     = qr.first else { return nil }
        return StockQuote(
            symbol:        q["symbol"]                     as? String ?? symbol,
            name:          q["shortName"]                  as? String ?? symbol,
            price:         q["regularMarketPrice"]         as? Double ?? 0,
            change:        q["regularMarketChange"]        as? Double ?? 0,
            changePercent: q["regularMarketChangePercent"] as? Double ?? 0,
            currency:      q["currency"]                   as? String ?? "USD",
            marketState:   q["marketState"]                as? String ?? "REGULAR"
        )
    }

    private func extractTicker(from prompt: String) -> String {
        let upper = prompt.uppercased()
        let patterns = [
            #"\$([A-Z]{1,5})\b"#,
            #"\b([A-Z]{1,5})\s+(?:STOCK|SHARES|PRICE|QUOTE)\b"#,
            #"(?:PRICE\s+OF|STOCK\s+OF|QUOTE\s+FOR|TICKER)\s+([A-Z]{1,5})\b"#,
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            if let m = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: upper) {
                return String(upper[r])
            }
        }
        return ""
    }

    // MARK: - Images (DuckDuckGo informal)

    func fetchImages(query: String) async -> [ImageResult] {
        let q = imageQuery(from: query)
        guard let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }

        // Step 1: acquire vqd token from the search page
        guard let initURL = URL(string: "https://duckduckgo.com/?q=\(escaped)&iax=images&ia=images") else { return [] }
        var initReq = URLRequest(url: initURL)
        initReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        initReq.timeoutInterval = 8
        guard let (htmlData, _) = try? await URLSession.shared.data(for: initReq),
              let html = String(data: htmlData, encoding: .utf8),
              let vqd  = extractVQD(from: html) else { return [] }

        // Step 2: fetch image results JSON
        let imgStr = "https://duckduckgo.com/i.js?q=\(escaped)&o=json&vqd=\(vqd)&f=,,,,,&p=1"
        guard let imgURL = URL(string: imgStr) else { return [] }
        var imgReq = URLRequest(url: imgURL)
        imgReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        imgReq.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        imgReq.timeoutInterval = 8
        guard let (imgData, _) = try? await URLSession.shared.data(for: imgReq),
              let imgJSON  = try? JSONSerialization.jsonObject(with: imgData) as? [String: Any],
              let results  = imgJSON["results"] as? [[String: Any]] else { return [] }
        return results.prefix(6).compactMap { r in
            guard let thumb = r["thumbnail"] as? String ?? r["image"] as? String,
                  let src   = r["url"]       as? String else { return nil }
            return ImageResult(title: r["title"] as? String ?? "", thumbURL: thumb, srcURL: src)
        }
    }

    private func imageQuery(from prompt: String) -> String {
        let lower = prompt.lowercased()
        let strips = ["show me images of ", "images of ", "pictures of ", "show me pictures of ",
                      "search images for ", "find images of ", "search for images of "]
        for s in strips {
            if lower.hasPrefix(s) { return String(prompt.dropFirst(s.count)).trimmingCharacters(in: .whitespaces) }
        }
        return prompt
    }

    private func extractVQD(from html: String) -> String? {
        let patterns = [#"vqd=['"]([^'"]+)['"]"#, #"vqd=([\d\-a-zA-Z.]+)"#]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let m = regex.firstMatch(in: html, range: range),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }

    // MARK: - Place (Nominatim / OpenStreetMap, no key)

    func fetchPlace(query: String) async -> PlaceResult? {
        let q = placeQuery(from: query)
        guard !q.isEmpty,
              let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?q=\(escaped)&format=json&limit=1&addressdetails=1") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mira/1.0 macOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first   = results.first else { return nil }
        let lat     = Double(first["lat"] as? String ?? "") ?? 0
        let lon     = Double(first["lon"] as? String ?? "") ?? 0
        let display = first["display_name"] as? String ?? q
        let addr    = first["address"] as? [String: Any] ?? [:]
        let name    = addr["amenity"]  as? String
                   ?? addr["shop"]     as? String
                   ?? addr["tourism"]  as? String
                   ?? addr["leisure"]  as? String
                   ?? addr["building"] as? String
                   ?? display.components(separatedBy: ", ").first ?? q
        let road    = addr["road"]    as? String ?? ""
        let city    = addr["city"]    as? String
                   ?? addr["town"]    as? String
                   ?? addr["village"] as? String ?? ""
        let state   = addr["state"]   as? String ?? ""
        let country = addr["country"] as? String ?? ""
        let full    = [road, city, state, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return PlaceResult(name: name, address: full.isEmpty ? display : full,
                           lat: lat, lon: lon, category: first["type"] as? String ?? "")
    }

    private func placeQuery(from prompt: String) -> String {
        let lower = prompt.lowercased()
        let strips = ["where is ", "find ", "locate ", "directions to ", "how do i get to ",
                      "navigate to ", "map of ", "find a "]
        for s in strips {
            if lower.hasPrefix(s) { return String(prompt.dropFirst(s.count)).trimmingCharacters(in: .whitespaces) }
        }
        return prompt
    }
}
