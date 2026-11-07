final class Library {
    private(set) var books: [Book] = []
    let shelf = Shelf()

    func add(_ book: Book) {
        books.append(book)
        shelf.place(book)
        Log.write("added \(book.title)")
    }
}
