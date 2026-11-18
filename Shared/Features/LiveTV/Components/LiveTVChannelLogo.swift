import SwiftUI

/// A channel's logo, or its number and name when the server has none or when loading fails.
struct LiveTVChannelLogo: View {
    @Environment(ServerRegistry.self) private var registry: ServerRegistry?
    @Environment(MediaServices.self) private var scopedServices: MediaServices?

    let channel: LiveTVChannel
    var showsNumber = true

    @State private var loadedImage: Image?
    @State private var loadedKey: String?

    private var cacheKey: String? {
        guard let thumbPath = channel.thumbPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !thumbPath.isEmpty
        else { return nil }
        return "\(scopedServices?.identity.id ?? "default")|\(thumbPath)"
    }

    private var currentImage: Image? {
        guard let cacheKey else { return nil }
        if loadedKey == cacheKey, let loadedImage {
            return loadedImage
        }
        return Self.cache[cacheKey]
    }

    var body: some View {
        Group {
            if let image = currentImage {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .accessibilityLabel(Text(channel.displayTitle))
            } else {
                fallbackText
            }
        }
        .task(id: cacheKey) {
            await loadLogo()
        }
    }

    private var fallbackText: some View {
        VStack(spacing: 2) {
            if showsNumber, let number = channel.number, !number.isEmpty {
                Text(number)
                    .font(.cardTitle.monospacedDigit())
            }
            Text(channel.callSign ?? channel.title)
                .font(.cardMetadata.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.textSecondary)
        .minimumScaleFactor(0.7)
    }

    @MainActor private static var cache: [String: Image] = [:]

    private func resolvedServices() -> MediaServices? {
        if let scopedServices {
            return scopedServices
        }
        return registry?.liveTVServices.first ?? registry?.activeSessions.compactMap(\.services).first
    }

    private func loadLogo() async {
        guard let cacheKey,
              currentImage == nil,
              let rawPath = channel.thumbPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else { return }

        // 1. If rawPath is already a direct http/https URL, try direct download first (avoids Plex transcoder SSRF/400 on IPTV/XMLTV URLs)
        if let directURL = URL(string: rawPath),
           let scheme = directURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            if let image = await ArtworkResourceView.image(for: .url(directURL)) {
                guard !Task.isCancelled else { return }
                Self.cache[cacheKey] = image
                loadedKey = cacheKey
                loadedImage = image
                return
            }
        }

        // 2. Try via server's artwork service (handles relative paths like /library/... or /livetv/... and Plex transcoding)
        if let services = resolvedServices(),
           let resource = try? await services.artwork.artwork(path: rawPath, width: 320, height: 180),
           let image = await ArtworkResourceView.image(for: resource)
        {
            guard !Task.isCancelled else { return }
            Self.cache[cacheKey] = image
            loadedKey = cacheKey
            loadedImage = image
        }
    }
}
