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
        .listStyle(.inset)
        // No `.navigationTitle` here: a titlebar on the middle column would
        // make the middle↔detail divider stop below it. Chrome stays on the
        // detail column (its toolbar + title) so the divider runs the full
        // window height.
        // The filter is a plain TextField, not `.searchable`: on macOS a
        // `.searchable` field inside a NavigationSplitView column triggers a
        // reentrant NSHostingView layout crash (AppKit layout recursion,
        // "It's not legal to call -layoutSubtreeIfNeeded…" fatal).
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear filter")
                }
            }
            .padding(8)
            .background(.bar)
        }
    }
}
