extension Sequence where Element: Sendable {
    /// `map` running the transform for every element concurrently; results are in input order.
    func concurrentMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            var count = 0
            for (index, element) in self.enumerated() {
                group.addTask { (index, await transform(element)) }
                count += 1
            }
            var results = [T?](repeating: nil, count: count)
            for await (index, value) in group {
                results[index] = value
            }
            return results.map { $0! }
        }
    }
}
