import Foundation

/// Pure navigation state for the 3-column browser: which facet category is
/// active in the sidebar (Authors/Series/Tags/Formats) and which specific
/// value is selected in the middle column. Tested in isolation; the session
/// and views stay thin.
///
/// Re-click semantics (approved design):
/// - re-clicking the active sidebar category keeps it (clear via All Books)
/// - re-clicking the selected middle-column value toggles it off
public struct FacetNavigation: Equatable, Sendable {
    /// The active category from the sidebar; nil = All Books.
    public private(set) var category: FacetType?
    /// The selected value in the middle column; nil = all books.
    public private(set) var value: String?

    public init() {}

    /// The facet filter to apply to the book list. Nil when there is no
    /// category+value pair — i.e. All Books, or a category with no value
    /// picked yet (design: category alone shows all books).
    public var activeFacet: (type: FacetType, value: String)? {
        guard let category, let value else { return nil }
        return (category, value)
    }

    /// True when the middle column should be visible.
    public var showsMiddleColumn: Bool { category != nil }

    /// Sidebar click. `nil` (All Books) clears everything. A changed category
    /// clears the value; re-clicking the active category keeps both.
    public mutating func selectCategory(_ category: FacetType?) {
        guard let category else {
            self.category = nil
            value = nil
            return
        }
        if self.category != category {
            self.category = category
            value = nil
        }
    }

    /// Middle-column click. Re-clicking the same value toggles it off (back
    /// to all books). Ignored while no category is active.
    public mutating func selectValue(_ value: String?) {
        guard let value else {
            self.value = nil
            return
        }
        guard category != nil else { return }
        self.value = (self.value == value) ? nil : value
    }

    /// All Books: clears category and value.
    public mutating func clear() {
        category = nil
        value = nil
    }
}
