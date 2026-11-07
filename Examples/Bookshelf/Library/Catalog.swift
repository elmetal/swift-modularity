struct Catalog {
    private var titles: [String: Book] = [:]

    mutating func index(_ book: Book) {
        titles[book.title] = book
    }

    func isListed(_ book: Book, in library: Library) -> Bool {
        library.books.contains { $0.title == book.title }
    }
}
