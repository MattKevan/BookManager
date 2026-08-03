import BookManagerCore
import SwiftUI

/// The middle column of the 3-column browser: the value list for the active
/// facet category (authors, series, tags, or formats), with counts and a
/// filter field. Shown only while a facet category is active in the sidebar.
struct FacetListView: View {
    @Bindable var session: LibrarySession
    @State private var filterText = ""

    /// The full value list for the active category.
    private var values: [(value: String, count: Int)] {
        switch session.facetNavigation.category {
        case .author: session.authors
        case .series: session.series
        case .tag: session.tags
        case .format: session.formats
        case nil: []
        }
    }

    /// Values narrowed by the filter field (case-insensitive substring).
    private var filteredValues: [(value: String, count: Int)] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter { $0.value.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(selection: Binding<String?>(
            get: { session.facetNavigation.value },
            set: { session.selectValue($0) }
        )) {
            ForEach(filteredValues, id: \.value) { item in
                HStack {
                    Text(item.value)
                    Spacer()
                    Text("\(item.count)")
                        .foregroundStyle(.secondary)
                }
                .tag(item.value)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(session.facetNavigation.category?.displayName ?? "")
        .searchable(text: $filterText, prompt: "Filter")
    }
}
