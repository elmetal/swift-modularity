struct SearchView {
    let library: Library
    var query = SearchQuery(text: "")

    func results() -> [Book] {
        library.books.filter { query.matches($0) }
    }
}
