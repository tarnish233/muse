/// 容量固定的 FIFO 集合：查询 O(1)，插入只在驱逐时移动一小段有界数组。
///
/// 适合缓存确定性失败等“记住最近若干 key”场景；不承载正文或可变渲染产物。
struct BoundedFIFOSet<Element: Hashable> {
    let capacity: Int
    private var elements = Set<Element>()
    private var insertionOrder: [Element] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var count: Int { elements.count }

    func contains(_ element: Element) -> Bool {
        elements.contains(element)
    }

    mutating func insert(_ element: Element) {
        guard capacity > 0, elements.insert(element).inserted else { return }
        insertionOrder.append(element)
        if insertionOrder.count > capacity {
            elements.remove(insertionOrder.removeFirst())
        }
    }

    mutating func remove(_ element: Element) {
        guard elements.remove(element) != nil else { return }
        insertionOrder.removeAll { $0 == element }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        elements.removeAll(keepingCapacity: keepingCapacity)
        insertionOrder.removeAll(keepingCapacity: keepingCapacity)
    }
}
