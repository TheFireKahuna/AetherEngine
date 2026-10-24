import CryptoKit
import Foundation

/// Which bytes of a source are held, as sorted, disjoint, half-open spans. Touching spans merge, so
/// a run of contiguous deliveries is one span however many pieces it arrived in.
///
/// Shared by the two books kept per source: `SourceByteLedger`, which only counts what a span adds,
/// and `SourceByteCache`, which also has to answer where the held bytes are and give them back up.
struct ByteSpanSet: Sendable, Equatable {
    struct Span: Sendable, Equatable {
        let start: Int64
        let end: Int64
        var length: Int64 { end - start }
    }

    private(set) var spans: [Span] = []

    var totalBytes: Int64 { spans.reduce(0) { $0 + $1.length } }

    /// Adds `[start, end)` and returns how many of its bytes were not already held.
    @discardableResult
    mutating func insert(start: Int64, end: Int64) -> Int64 {
        guard end > start else { return 0 }
        let low = firstIndex(endingAtOrAfter: start)
        var mergedStart = start, mergedEnd = end
        var covered: Int64 = 0
        var last = low
        while last < spans.count, spans[last].start <= end {
            let span = spans[last]
            covered += max(0, min(end, span.end) - max(start, span.start))
            mergedStart = min(mergedStart, span.start)
            mergedEnd = max(mergedEnd, span.end)
            last += 1
        }
        spans.replaceSubrange(low..<last, with: [Span(start: mergedStart, end: mergedEnd)])
        return (end - start) - covered
    }

    /// Drops `[start, end)`, splitting a span that straddles either edge.
    mutating func remove(start: Int64, end: Int64) {
        guard end > start else { return }
        var low = firstIndex(endingAtOrAfter: start)
        if low < spans.count, spans[low].end == start { low += 1 }
        var last = low
        var kept: [Span] = []
        while last < spans.count, spans[last].start < end {
            let span = spans[last]
            if span.start < start { kept.append(Span(start: span.start, end: start)) }
            if span.end > end { kept.append(Span(start: end, end: span.end)) }
            last += 1
        }
        spans.replaceSubrange(low..<last, with: kept)
    }

    /// How many bytes from `offset` on are held without a gap; 0 when `offset` itself is not.
    func contiguousLength(from offset: Int64) -> Int64 {
        let index = firstIndex(endingAtOrAfter: offset + 1)
        guard index < spans.count, spans[index].start <= offset else { return 0 }
        return spans[index].end - offset
    }

    /// The first held span that starts after `offset` and before `limit`, at least `minLength`
    /// long. A span that covers `offset` itself is not "next": `contiguousLength` answers for it.
    func nextSpan(after offset: Int64, before limit: Int64, minLength: Int64 = 1) -> Span? {
        var index = firstIndex(endingAtOrAfter: offset + 1)
        while index < spans.count, spans[index].start < limit {
            let span = spans[index]
            if span.start > offset, span.length >= minLength { return span }
            index += 1
        }
        return nil
    }

    /// First span whose end is at or after `offset`: everything before it lies wholly to the left.
    private func firstIndex(endingAtOrAfter offset: Int64) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].end < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// What makes two URLs the same source: the URL without its credential query items, so a re-minted
/// token is the same bytes and no key, file name or log line ever carries one.
enum SourceIdentity {
    /// Query items that carry a credential and must neither split a source nor reach a log line.
    static let credentialQueryItems: Set<String> = ["api_key", "apikey", "x-emby-token", "token"]

    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.fragment = nil
        let kept = parts.queryItems?.filter { !credentialQueryItems.contains($0.name.lowercased()) }
        parts.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        return parts.string ?? url.absoluteString
    }

    /// Host and the last two path components: enough to tell sources apart in a log, no query.
    static func display(_ url: URL) -> String {
        let tail = url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/")
        return "\(url.host ?? "?")/\(tail)"
    }
}

/// Which bytes the source cache may hand from one reader to another: the same source asked for the
/// same way. The URL alone is not enough, for the reason #551 refuses a warm fetched under other
/// headers: an origin that varies on Authorization, a cookie or a Referer answers a different body
/// under the same URL, and a cache keyed only on the URL would hand one user's bytes to another. So
/// the key is the credential-free URL plus a digest of the credentials and request headers. Readers
/// of one session share them; a different user, token or header set is a different entry.
struct SourceCacheKey: Hashable, Sendable {
    let id: String
    /// Credential-free, for log lines.
    let display: String

    init(url: URL, headers: [String: String]) {
        var material = ""
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where SourceIdentity.credentialQueryItems.contains(item.name.lowercased()) {
                material += "q:\(item.name.lowercased())=\(item.value ?? "")\n"
            }
        }
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            material += "h:\(name.lowercased())=\(value)\n"
        }
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        id = SourceIdentity.key(url) + "#" + digest
        display = SourceIdentity.display(url)
    }
}
