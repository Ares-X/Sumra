#if os(macOS)
import SwiftUI

struct CHMKeyword: Decodable {
    let keyword: String
    let topics: [ContentsItem]

    static func matching(_ query: String, in entries: [CHMKeyword]) -> [CHMKeyword] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.keyword.localizedStandardContains(query) }
    }
}

struct CHMContentsPane<Contents: View>: View {
    @ObservedObject var state: ReaderState
    @ViewBuilder let contents: () -> Contents
    @State private var showIndex = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Navigation"), selection: $showIndex) {
                Text(L("Contents")).tag(false)
                Text(L("Index")).tag(true)
            }.pickerStyle(.segmented).padding(8)
            if showIndex {
                TextField(L("Search Index"), text: $query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 8)
                    .accessibilityLabel(L("Search Index"))
                let entries = CHMKeyword.matching(query, in: state.chmIndex)
                if entries.isEmpty {
                    Text(L("No results")).foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    List {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            if entry.topics.count == 1, let topic = entry.topics.first {
                                Button(entry.keyword) { state.navigate(.href(topic.target)) }
                                    .buttonStyle(.plain)
                            } else {
                                Section(entry.keyword) {
                                    ForEach(entry.topics.indices, id: \.self) { topic in
                                        Button(entry.topics[topic].title) {
                                            state.navigate(.href(entry.topics[topic].target))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }.listStyle(.sidebar)
                }
            } else { contents() }
        }
        .onChange(of: state.document?.id) { _ in showIndex = false; query = "" }
    }
}
#endif
