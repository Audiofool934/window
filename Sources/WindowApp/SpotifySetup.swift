import AppKit
import SwiftUI
import WindowCore

/// Connects a Spotify account through the user's own developer app.
struct SpotifySetupView: View {
    @State var clientID: String
    @State private var state: Phase = .idle
    let connect: (String) async throws -> Void
    let close: () -> Void

    enum Phase: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a Spotify account")
                .font(.headline)
            Text("Window then shows whatever the account is playing, on a phone, a speaker, or this Mac. It uses your own Spotify developer app, whose owner needs Spotify Premium.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1) {
                    HStack(spacing: 4) {
                        Text("Create an app, or open one you have, in the")
                        Link("Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                }
                step(2) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add this Redirect URI and tick Web API:")
                        HStack {
                            Text(SpotifyAccount.registeredRedirect)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(SpotifyAccount.registeredRedirect, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                step(3) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste the app's Client ID:")
                        TextField("Client ID", text: $clientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            HStack {
                switch state {
                case .idle: EmptyView()
                case .waiting: Text("Finish signing in to Spotify in your browser.").foregroundStyle(.secondary)
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                    state = .waiting
                    Task {
                        do {
                            try await connect(id)
                            close()
                        } catch {
                            state = .failed(String(describing: error))
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).count < 16 || state == .waiting)
            }
            .font(.callout)
        }
        .padding(22)
        .frame(width: 460)
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            content()
        }
    }
}

enum SpotifySetupWindow {
    static func make(clientID: String, connect: @escaping (String) async throws -> Void) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Spotify Account"
        window.isReleasedWhenClosed = false
        let view = SpotifySetupView(clientID: clientID, connect: connect, close: { [weak window] in window?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        return window
    }
}
