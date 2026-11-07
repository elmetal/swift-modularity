final class Shelf {
    private var catalog = Catalog()

    func place(_ book: Book) {
        catalog.index(book)
    }
}
