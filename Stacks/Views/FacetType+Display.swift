import StacksCore

extension FacetType {
    /// User-facing category name for the sidebar rows and the middle-column
    /// title.
    var displayName: String {
        switch self {
        case .author: "Authors"
        case .series: "Series"
        case .tag: "Tags"
        case .format: "Formats"
        }
    }

    /// SF Symbol for the sidebar row.
    var sidebarSymbol: String {
        switch self {
        case .author: "person.2"
        case .series: "rectangle.stack"
        case .tag: "tag"
        case .format: "doc.text"
        }
    }
}
