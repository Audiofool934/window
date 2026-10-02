import CoreGraphics
import Foundation
import ImageIO

/// Finds and fetches cover art. A known artwork URL is used directly; otherwise the track id is looked up
/// through Spotify's public oEmbed endpoint, which needs no login.
public final class ArtworkLoader {
    private let session: URLSession
    private var urlCache: [String: URL] = [:]
    private var imageCache: [URL: CGImage] = [:]
    private var order: [URL] = []

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func image(for item: NowPlaying) async -> (url: URL, image: CGImage)? {
        guard let url = await artworkURL(for: item) else { return nil }
        if let cached = imageCache[url] { return (url, cached) }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        imageCache[url] = image
        order.append(url)
        if order.count > 24 { imageCache[order.removeFirst()] = nil }
        return (url, image)
    }

    func artworkURL(for item: NowPlaying) async -> URL? {
        if let url = item.artworkURL { return url }
        if let cached = urlCache[item.uri] { return cached }
        guard let page = item.webURL,
              var components = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        guard let endpoint = components.url,
              let (data, _) = try? await session.data(from: endpoint),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumbnail = (object["thumbnail_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let url = Self.largest(thumbnail)
        urlCache[item.uri] = url
        return url
    }

    /// oEmbed answers with the 300 px image; the same image id with another prefix is the 640 px original.
    static func largest(_ url: URL) -> URL {
        let text = url.absoluteString
        guard text.contains("ab67616d00001e02") else { return url }
        return URL(string: text.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273")) ?? url
    }
}
