import Foundation

// MARK: - GIF Prefetcher
//
// Warms URLCache with the GIFs of posts the user is about to scroll into,
// so rows render their media instantly instead of loading on first
// appearance. Feeds call this after each page lands; URLCache.shared
// (bumped to 64MB/256MB in toskaApp.init) is the single store — the row's
// normal loader then hits cache. Already-cached and in-flight URLs are
// skipped, so repeated calls with overlapping pages cost nothing.
@MainActor
enum GifPrefetcher {
    private static var inFlight: Set<String> = []

    static func prefetch(_ urlStrings: [String], cap: Int = 20) {
        for raw in urlStrings.prefix(cap) {
            guard !inFlight.contains(raw), let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            // Bound the inFlight entry's lifetime — without this a hung
            // request parks its URL in the dedupe set for the 60s default.
            request.timeoutInterval = 15
            guard URLCache.shared.cachedResponse(for: request) == nil else { continue }
            inFlight.insert(raw)
            URLSession.shared.dataTask(with: request) { _, _, _ in
                Task { @MainActor in inFlight.remove(raw) }
            }.resume()
        }
    }
}
