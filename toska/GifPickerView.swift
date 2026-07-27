import SwiftUI
import FirebaseAuth
import FirebaseFunctions

@MainActor
struct GifPickerView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var gifs: [GifItem] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>? = nil
    // Surfaced when the Giphy fetch fails (timeout, JSON shape change, network)
    // so the empty grid doesn't get confused with a genuine zero-result query.
    @State private var fetchError: String? = nil

    // Giphy is proxied through the giphyProxy Cloud Function (functions/index.js).
    // Migrated from onRequest URL fetch to onCall callable on 2026-05-08 — the
    // Functions SDK now handles App Check token attachment + Firebase ID token
    // authentication, so this view dropped ~30 lines of manual token plumbing.
    // The GIPHY_KEY upstream secret stays server-side via Secret Manager.
    
    var body: some View {
                VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(Color.toskaTextLight)
                }
                .accessibilityLabel("close GIF picker")
                Spacer()
                Text("GIFs")
                    .font(ToskaFont.sans(13, weight: .semibold))
                    .foregroundColor(Color.toskaInkOnLight)
                Spacer()
                // Spacer placeholder to keep "GIFs" centered. Hidden from
                // VoiceOver so it doesn't get announced as a phantom button.
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(.clear)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(Color.toskaTextLight)
                
                TextField("search GIFs...", text: $searchText)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchText) { _, newValue in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled else { return }
                            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                                fetchTrending()
                            } else {
                                searchGifs(query: newValue)
                            }
                        }
                    }
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        fetchTrending()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color.toskaTimestamp)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "e8eaed"))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            
            Rectangle().fill(Color.toskaDividerHairline).frame(height: 0.5)
            
            // GIF grid
            if isLoading && gifs.isEmpty {
                Spacer()
                ProgressView().tint(Color.toskaBlue)
                Spacer()
            } else if gifs.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: fetchError != nil ? "exclamationmark.triangle" : "photo.on.rectangle.angled")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(Color.toskaDivider)
                    Text(fetchError ?? "no GIFs found")
                        .font(ToskaFont.sans(13))
                        .foregroundColor(Color.toskaTextLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if fetchError != nil {
                        Button {
                            fetchTrending()
                        } label: {
                            Text("retry")
                                .font(ToskaFont.sans(12, weight: .medium))
                                .foregroundColor(Color.toskaBlue)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.toskaBlue.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                        ForEach(Array(gifs.enumerated()), id: \.element.id) { index, gif in
                            Button {
                                onSelect(gif.url)
                                dismiss()
                            } label: {
                                AsyncImage(url: URL(string: gif.previewUrl), transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 120)
                                            .clipped()
                                            .transition(.opacity)
                                    case .failure:
                                        Color.toskaBorderLight
                                            .frame(height: 120)
                                            .overlay(
                                                Image(systemName: "photo.badge.exclamationmark")
                                                    .font(.system(size: 14, weight: .light))
                                                    .foregroundColor(Color.toskaTimestamp)
                                            )
                                    default:
                                        Color(hex: "e8eaed")
                                            .frame(height: 120)
                                            .overlay(ProgressView().scaleEffect(0.6))
                                    }
                                }
                                .cornerRadius(6)
                            }
                            // F5 (2026-07-27 full-audit): the cell's only content
                            // is an AsyncImage, so VoiceOver announced a bare
                            // "button" with no description. Give each an ordinal
                            // label so the grid is navigable.
                            .accessibilityLabel("gif \(index + 1)")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            
            // Giphy attribution (required by their terms)
            HStack {
                Spacer()
                Text("Powered by GIPHY")
                    .font(ToskaFont.sans(11))
                    .foregroundColor(Color.toskaPlaceholderGray)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .background(Color(hex: "f0f1f3"))
        .onAppear {
            fetchTrending()
        }
    }
    
    func fetchTrending() {
        isLoading = true
        fetchGifs(mode: "trending", query: nil)
    }

    func searchGifs(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        fetchGifs(mode: "search", query: trimmed)
    }

    func fetchGifs(mode: String, query: String?) {
        // Build the callable payload. The server reads `mode`, `limit`, and
        // (when mode=="search") `q`. App Check + Firebase ID token are
        // attached by Functions().httpsCallable automatically — no manual
        // header plumbing.
        var payload: [String: Any] = [
            "mode": mode,
            "limit": 30,
        ]
        if let query = query { payload["q"] = query }

        Task { @MainActor in
            fetchError = nil
            let callable = Functions.functions().httpsCallable("giphyProxy")
            let result: HTTPSCallableResult
            do {
                result = try await callable.call(payload)
            } catch let error as NSError {
                // FunctionsErrorDomain mapping. We surface a single generic
                // copy so we don't leak the difference between auth/network/
                // upstream failures to the user, but log the root cause to
                // Crashlytics so fixes don't have to chase blind reports of
                // "GIFs don't work."
                print("⚠️ giphyProxy callable failed: \(error.localizedDescription)")
                Telemetry.recordError(error, context: "Giphy.callable.\(mode)")
                isLoading = false
                fetchError = "couldn't load GIFs — try again."
                return
            }

            guard let json = result.data as? [String: Any],
                  let dataArray = json["data"] as? [[String: Any]] else {
                isLoading = false
                fetchError = "couldn't load GIFs. try again in a bit."
                return
            }
            gifs = dataArray.compactMap { item in
                guard let id = item["id"] as? String,
                      let images = item["images"] as? [String: Any] else { return nil }

                // Prefer fixed_width (~700KB, animated) for the post URL.
                // downsized_medium / original (~2.5MB) frequently fail to load
                // in SwiftUI AsyncImage on iOS — likely a decode/timeout issue
                // with larger animated GIFs — leaving compose with the
                // "couldn't load — pick another?" placeholder even when the
                // picker preview rendered fine. fixed_width is the same URL
                // the picker preview uses, so it's guaranteed to render in
                // the compose preview and in the eventual feed/reply post.
                // downsized (~1.4MB) and original are fallbacks if Giphy ever
                // omits fixed_width on a result.
                let fullUrl: String
                if let fixedWidth = images["fixed_width"] as? [String: Any],
                   let url = fixedWidth["url"] as? String {
                    fullUrl = url
                } else if let downsized = images["downsized"] as? [String: Any],
                          let url = downsized["url"] as? String {
                    fullUrl = url
                } else if let original = images["original"] as? [String: Any],
                          let url = original["url"] as? String {
                    fullUrl = url
                } else {
                    return nil
                }

                let previewUrl: String
                if let preview = images["fixed_width"] as? [String: Any],
                   let url = preview["url"] as? String {
                    previewUrl = url
                } else {
                    previewUrl = fullUrl
                }

                return GifItem(id: id, url: fullUrl, previewUrl: previewUrl)
            }
            isLoading = false
        }
    }
}

struct GifItem: Identifiable {
    let id: String
    let url: String
    let previewUrl: String
}
