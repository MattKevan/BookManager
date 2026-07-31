import BookManagerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        List(selection: $session.selectedFacet) {
            Section {
                Label("All Books", systemImage: "books.vertical")
                    .tag(nil as LibrarySession.FacetSelection?)
            }
            Section("Authors") {
                ForEach(session.authors, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .author)
                }
            }
            Section("Series") {
                ForEach(session.series, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .series)
                }
            }
            Section("Tags") {
                ForEach(session.tags, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .tag)
                }
            }
            Section("Formats") {
                ForEach(session.formats, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .format)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct FacetRow: View {
        let title: String
        let count: Int
        let type: FacetType

        var body: some View {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .tag(LibrarySession.FacetSelection(type: type, value: title))
        }
    }
}

private struct LibrarySessionKey: EnvironmentKey {
    static let defaultValue: LibrarySession? = nil
}

extension EnvironmentValues {
    var librarySession: LibrarySession? {
        get { self[LibrarySessionKey.self] }
        set { self[LibrarySessionKey.self] = newValue }
    }
}
