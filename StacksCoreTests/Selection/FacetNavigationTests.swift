import Testing
@testable import StacksCore

@Suite
struct FacetNavigationTests {
    @Test
    func initialSelectionIsAllBooks() {
        let state = FacetNavigation()
        #expect(state.category == nil)
        #expect(state.value == nil)
        #expect(state.activeFacet == nil)
        #expect(!state.showsMiddleColumn)
    }

    @Test
    func selectingCategoryShowsMiddleColumn() {
        var state = FacetNavigation()
        state.selectCategory(.author)
        #expect(state.category == .author)
        #expect(state.showsMiddleColumn)
        #expect(state.activeFacet == nil) // no value picked yet → all books
    }

    @Test
    func selectingValueBuildsActiveFacet() {
        var state = FacetNavigation()
        state.selectCategory(.author)
        state.selectValue("Ursula K. Le Guin")
        #expect(state.value == "Ursula K. Le Guin")
        #expect(state.activeFacet?.type == .author)
        #expect(state.activeFacet?.value == "Ursula K. Le Guin")
    }

    @Test
    func changedCategoryClearsValue() {
        var state = FacetNavigation()
        state.selectCategory(.author)
        state.selectValue("Ursula K. Le Guin")
        state.selectCategory(.series)
        #expect(state.category == .series)
        #expect(state.value == nil)
        #expect(state.activeFacet == nil)
    }

    @Test
    func reselectingSameCategoryKeepsValue() {
        var state = FacetNavigation()
        state.selectCategory(.author)
        state.selectValue("Ursula K. Le Guin")
        state.selectCategory(.author) // re-click: keep selection
        #expect(state.category == .author)
        #expect(state.value == "Ursula K. Le Guin")
    }

    @Test
    func reselectingSameValueTogglesOff() {
        var state = FacetNavigation()
        state.selectCategory(.tag)
        state.selectValue("Sci-Fi")
        state.selectValue("Sci-Fi") // re-click: toggle off, back to all books
        #expect(state.value == nil)
        #expect(state.activeFacet == nil)
    }

    @Test
    func selectingDifferentValueReplaces() {
        var state = FacetNavigation()
        state.selectCategory(.tag)
        state.selectValue("Sci-Fi")
        state.selectValue("Fantasy")
        #expect(state.value == "Fantasy")
        #expect(state.activeFacet?.value == "Fantasy")
    }

    @Test
    func selectingAllBooksClearsEverything() {
        var state = FacetNavigation()
        state.selectCategory(.format)
        state.selectValue("EPUB")
        state.selectCategory(nil) // All Books
        #expect(state.category == nil)
        #expect(state.value == nil)
        #expect(state.activeFacet == nil)
        #expect(!state.showsMiddleColumn)
    }

    @Test
    func clearResetsEverything() {
        var state = FacetNavigation()
        state.selectCategory(.author)
        state.selectValue("Ursula K. Le Guin")
        state.clear()
        #expect(state.category == nil)
        #expect(state.value == nil)
        #expect(state.activeFacet == nil)
    }

    @Test
    func valueWithoutCategoryIsIgnored() {
        var state = FacetNavigation()
        state.selectValue("Sci-Fi")
        #expect(state.value == nil)
    }
}
