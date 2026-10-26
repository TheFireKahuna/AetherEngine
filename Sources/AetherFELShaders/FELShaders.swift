import Foundation

/// The Dolby Vision FEL composer's kernels, compiled into this module's bundle when the package builds. A target of its
/// own so a build without the `DualLayerDolbyVision` trait carries none of them.
public enum FELShaders {
    public static var bundle: Bundle { .module }
}
