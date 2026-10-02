import CoreGraphics
import Foundation
import simd
import Testing
@testable import WindowCore

@Suite struct MusicTests {
    @Test func pkceMatchesTheRFC7636Example() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.verifier()
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let body = SpotifyAccount.formEncode(["redirect_uri": "http://127.0.0.1:5000/callback", "code": "a+b"])
        #expect(body == "code=a%2Bb&redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback")
    }

    @Test func parsesTheAccountsCurrentlyPlayingTrack() {
        let json = """
        {"is_playing":true,"progress_ms":60000,"currently_playing_type":"track","item":{"uri":"spotify:track:abc",
        "name":"Reckoner","duration_ms":290000,"artists":[{"name":"Radiohead"}],
        "album":{"name":"In Rainbows","images":[{"url":"https://i.scdn.co/image/small","width":64},
        {"url":"https://i.scdn.co/image/large","width":640}]}}}
        """
        let (state, remaining) = SpotifyWebSource.parse(Data(json.utf8))
        #expect(state == NowPlaying(uri: "spotify:track:abc", title: "Reckoner", artist: "Radiohead", album: "In Rainbows",
                                    artworkURL: URL(string: "https://i.scdn.co/image/large"), isPlaying: true))
        #expect(remaining == 230)
    }

    @Test func parsesAPodcastEpisode() {
        let json = """
        {"is_playing":false,"currently_playing_type":"episode","item":{"uri":"spotify:episode:xyz","name":"Episode",
        "show":{"name":"A Show"},"images":[{"url":"https://i.scdn.co/image/show","width":640}]}}
        """
        let (state, _) = SpotifyWebSource.parse(Data(json.utf8))
        #expect(state?.artist == "A Show")
        #expect(state?.artworkURL == URL(string: "https://i.scdn.co/image/show"))
        #expect(state?.isPlaying == false)
    }

    @Test func parsesTheLocalAppsAnswer() {
        guard case .playing(let state) = SpotifyLocalSource.parse("paused\tspotify:track:6HAU4ap2dBXwa5PYNn0z1B\t天長地久\t刘森\t天長地久\thttps://i.scdn.co/image/x") else {
            Issue.record("expected a track")
            return
        }
        #expect(state.title == "天長地久" && state.artist == "刘森" && !state.isPlaying)
        #expect(state.webURL == URL(string: "https://open.spotify.com/track/6HAU4ap2dBXwa5PYNn0z1B"))
        if case .stopped = SpotifyLocalSource.parse("stopped") {} else { Issue.record("expected stopped") }
        // Advertisements are not songs.
        if case .unavailable = SpotifyLocalSource.parse("playing\tspotify:ad:1\tAd\t\t\t") {} else { Issue.record("expected no song") }
    }

    @Test func upgradesOEmbedThumbnailsToTheFullCover() {
        let thumbnail = URL(string: "https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02255e131abc1410833be95673")!
        #expect(ArtworkLoader.largest(thumbnail).absoluteString.hasSuffix("ab67616d0000b273255e131abc1410833be95673"))
    }

    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let side = 8
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) { pixels[i * 4] = r; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = b }
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func aRedCoverWarmsTheLampRedAndAGreyOneLeavesItAlone() {
        let red = CoverPalette.lampColor(for: solid(200, 30, 40))
        #expect(red.x > red.y * 1.4 && red.x > red.z * 1.4)
        let blue = CoverPalette.lampColor(for: solid(40, 70, 210))
        #expect(blue.z > blue.x)
        let grey = CoverPalette.lampColor(for: solid(128, 128, 128))
        #expect(simd_length(grey - LampColor.incandescent) < 1e-9)
        // Lamplight keeps its brightness; only its colour follows the cover.
        let luminance = 0.2126 * red.x + 0.7152 * red.y + 0.0722 * red.z
        #expect(abs(luminance - 1) < 1e-6)
    }
}
