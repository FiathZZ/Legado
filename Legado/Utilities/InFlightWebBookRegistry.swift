import Foundation

// MARK: - InFlightWebBookRegistry
/// Tracks active WebBook instances so callers can force-stop in-flight work during cancellation.
actor InFlightWebBookRegistry {
    private var books: [ObjectIdentifier: WebBook] = [:]

    func insert(_ book: WebBook) {
        books[ObjectIdentifier(book)] = book
    }

    func remove(_ book: WebBook) {
        books.removeValue(forKey: ObjectIdentifier(book))
    }

    func shutdownAndRemove(_ book: WebBook) {
        books.removeValue(forKey: ObjectIdentifier(book))
        book.shutdown()
    }

    func shutdownAll() {
        let activeBooks = Array(books.values)
        books.removeAll(keepingCapacity: false)
        activeBooks.forEach { $0.shutdown() }
    }
}
