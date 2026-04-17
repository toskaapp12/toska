import SwiftUI

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
    
    // TODO: Move API key to Secrets.plist or server-side proxy before shipping
    // REPLACE with your Giphy API key from developers.giphy.com
    private let apiKey = "YOUR_GIPHY_API_KEY"
    
    var body: some View {
                VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(Color(hex: "999999"))
                }
                Spacer()
                Text("GIFs")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.toskaTextDark)
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(.clear)
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
            
            Rectangle().fill(Color(hex: "dfe1e5")).frame(height: 0.5)
            
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
                        .font(.system(size: 13))
                        .foregroundColor(Color.toskaTextLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if fetchError != nil {
                        Button {
                            fetchTrending()
                        } label: {
                            Text("retry")
                                .font(.system(size: 12, weight: .medium))
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
                        ForEach(gifs) { gif in
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
                                        Color(hex: "e4e6ea")
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
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "cccccc"))
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
        let urlString = "https://api.giphy.com/v1/gifs/trending?api_key=\(apiKey)&limit=30&rating=pg-13"
        fetchGifs(from: urlString)
    }
    
    func searchGifs(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let urlString = "https://api.giphy.com/v1/gifs/search?api_key=\(apiKey)&q=\(encoded)&limit=30&rating=pg-13"
        fetchGifs(from: urlString)
    }
    
    func fetchGifs(from urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor in
            fetchError = nil
            do {
                // 15s request timeout so a flaky Giphy call can't leave the
                // picker stuck on a spinner indefinitely.
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = json["data"] as? [[String: Any]] else {
                    isLoading = false
                    fetchError = "couldn't load GIFs. try again in a bit."
                    return
                }
                gifs = dataArray.compactMap { item in
                    guard let id = item["id"] as? String,
                          let images = item["images"] as? [String: Any] else { return nil }

                    let fullUrl: String
                    if let downsized = images["downsized_medium"] as? [String: Any],
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
            } catch {
                isLoading = false
                fetchError = "couldn't load GIFs — check your connection."
            }
        }
    }
}

struct GifItem: Identifiable {
    let id: String
    let url: String
    let previewUrl: String
}
