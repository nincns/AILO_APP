import Foundation
public final class CancellationToken: @unchecked Sendable {
    private let q = DispatchQueue(label: "cancellation.token.state")
    private var cancelled = false
    public init() {}
    public func cancel() { q.sync { cancelled = true } }
    public var isCancelled: Bool { q.sync { cancelled } }
}
