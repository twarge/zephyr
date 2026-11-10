import SwiftUI
import ZulipModel

#if !os(macOS)
/// Compact width only: the root list is the whole UI there, so it gets
/// its own searchable (same shared model) for the bar's search pin.
/// Regular width leaves search solely to the detail column.
struct CompactSidebarSearch: ViewModifier {
    let search: SidebarSearchModel
    @Binding var selection: Destination?
    /// The WINDOW's compactness, passed in from the split view — the
    /// sidebar column's own environment reads compact even in a full
    /// iPad window (columns are narrow), which wrongly attached the
    /// search field to the iPad sidebar.
    let isCompact: Bool

    func body(content: Content) -> some View {
        if isCompact {
            content.modifier(
                DetailSearchField(search: search, selection: $selection))
        } else {
            content
        }
    }
}

/// iOS: the sidebar-filtering search field, attached to the DETAIL
/// column so its minimized magnifier renders in the main view's toolbar
/// (macOS keeps the field on the sidebar list → window toolbar). The
/// field drives the same shared search model either way.
struct DetailSearchField: ViewModifier {
    @Bindable var search: SidebarSearchModel
    @Binding var selection: Destination?
    /// Compact composer views (transcript, channel) drop search
    /// entirely — the message field owns the bottom edge.
    var suppressWhenCompactComposer = false
    @Environment(KeyboardRouter.self) private var keys
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        if sizeClass == .compact {
            if suppressWhenCompactComposer {
                content
            } else {
                // Bottom-bar field, expanded (Messages-style) — no
                // minimize.
                searchable(content)
            }
        } else {
            searchable(content)
                .searchToolbarBehavior(.minimize)
        }
    }

    private func searchable(_ content: Content) -> some View {
        content
            // Explicit .toolbar placement: .automatic hoists the field
            // into the iPad sidebar (duplicating the main-bar magnifier)
            // and reserves the compact under-title drawer (a phantom top
            // margin). The DefaultToolbarItem pins own the position.
            .searchable(
                text: $search.filterText, tokens: $search.tokens,
                placement: .toolbar, prompt: "Filter or search"
            ) { token in
                Text(token.bubbleText)
            }
            .searchSuggestions {
                ForEach(search.suggestions) { token in
                    Label(token.suggestionTitle, systemImage: token.suggestionIcon)
                        .searchCompletion(token)
                }
            }
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { runSearch() }
            .onAppear {
                // The keyboard router's / shortcut focuses this field;
                // media selection blurs it so Space can Quick Look.
                let focus = $searchFocused
                keys.focusSearch = { focus.wrappedValue = true }
                keys.blurSearch = { focus.wrappedValue = false }
            }
    }

    private func runSearch() {
        let query = SearchQuery(tokens: search.tokens, text: search.filterText)
        guard !query.isEmpty else { return }
        search.recordSearch(query)
        search.filterText = ""
        search.tokens = []
        selection = .search(query)
    }
}
#endif
