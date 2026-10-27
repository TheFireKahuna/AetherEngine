import Foundation

/// AE#860: what an origin's `Content-Type` says about a source whose URL has no disc-image extension.
///
/// A HINT, never a verdict. It sends the open to the disc adapter, and `DiscReader.wrap` decides from
/// the ISO 9660 / UDF structure whether there is a disc there at all; a mislabelled response falls
/// back to the streaming reader. A source that did turn out to be a disc is recorded on its source cache
/// entry, so the paths that gate on `Demuxer.isDiscImageURL` before any byte is read (the probe reader,
/// the next open of the same item) treat it like an `.iso` without asking the origin again.
enum DiscImageMediaType {

    /// `application/x-iso9660-image` is what most servers send for `.iso`, `application/x-cd-image`
    /// is the freedesktop alias, `application/vnd.efi.iso` the IANA registration, and
    /// `application/x-raw-disk-image` the freedesktop type for `.img`, which the extension gate accepts.
    static let mediaTypes: Set<String> = [
        "application/x-iso9660-image",
        "application/x-cd-image",
        "application/vnd.efi.iso",
        "application/x-udf-image",
        "application/x-raw-disk-image",
    ]

    /// Parameters dropped, case folded: `Application/X-ISO9660-Image; charset=binary` is the same type.
    static func isDiscImage(contentType: String?) -> Bool {
        guard let contentType,
              let essence = contentType.split(separator: ";", omittingEmptySubsequences: false).first
        else { return false }
        return mediaTypes.contains(essence.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
