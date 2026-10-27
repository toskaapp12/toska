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
        let urls = Array(urlStrings.prefix(cap))
        // The first few rows ahead are DECODED into the shared cache (off the
        // main thread) so they paint with zero decode on appear (2026-10-26).
        for raw in urls.prefix(6) { StableGifPreview.prefetch(raw) }
        // The rest just warm URLCache bytes. Request the WebP variant — the
        // render path now fetches .webp, so warming the .gif would be a cache
        // miss (StableGifPreview falls back to .gif only if the webp 404s).
        for raw in urls {
            let warm = GifLoadGuard.webpVariant(raw)
            guard !inFlight.contains(warm), let url = URL(string: warm) else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            // Bound the inFlight entry's lifetime — without this a hung
            // request parks its URL in the dedupe set for the 60s default.
            request.timeoutInterval = 15
            guard URLCache.shared.cachedResponse(for: request) == nil else { continue }
            inFlight.insert(warm)
            URLSession.shared.dataTask(with: request) { _, _, _ in
                Task { @MainActor in inFlight.remove(warm) }
            }.resume()
        }
    }
}
