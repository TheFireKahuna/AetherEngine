// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Foundation
import os
import Dovi

/// The RPU NAL every composed FEL frame carries in place of its own (`AetherEngine.felComposedRpuOverride`), on
/// both routes that compose: the software host's `DualLayerVideoDecoder` and the native route's
/// `FelOverlayRenderer`. A display-path experiment, process-wide like `DoviFelComposer.outputMode`: read once per
/// composed frame, so it takes effect from the next one. A frame delivered as its raw base layer keeps the RPU with
/// its mapping, override or not: its pixels were never reshaped.
enum DoviComposedRpuOverride {
    private static let value = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)

    static var current: [UInt8]? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    /// The RPU a composed frame carries: the override when one is set, else the frame's own composed RPU.
    static func rpu(forComposed own: [UInt8]?) -> [UInt8]? {
        current ?? own
    }

    /// `bytes` as an unspec62 NAL that `DoviDisplayMetadata.attach` takes (2-byte `0x7C 0x01` header, emulation
    /// prevention in place: what `dovi_write_unspec62_nalu` returns), or nil when libdovi cannot parse it behind
    /// `DoviRpuGuard`. A header-less payload (starting `0x19`, the attachment's own form) gets the header put back.
    static func validated(_ bytes: Data) -> [UInt8]? {
        var nal = [UInt8](bytes)
        if nal.first == 0x19 { nal.insert(contentsOf: [0x7C, 0x01], at: 0) }
        guard nal.count > 2, nal[0] == 0x7C, nal[1] == 0x01 else { return nil }
        let parsed = nal.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress, let rpu = DoviRpuGuard.parse(base, buf.count) else { return false }
            dovi_rpu_free(rpu)
            return true
        }
        return parsed ? nal : nil
    }
}
#endif
