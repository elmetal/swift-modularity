struct App {
    let library = Library()

    var search: SearchView {
        SearchView(library: library)
    }
}
