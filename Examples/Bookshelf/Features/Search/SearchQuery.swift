struct SearchQuery {
    var text: String

    func matches(_ book: Book) -> Bool {
        text.isEmpty || book.title.contains(text)
    }
}
