import Foundation
#if canImport(HotCodePushBspatch)
import HotCodePushBspatch
#endif

/// FreeBSD's bspatch, the `HotCodePushBspatch` C target: a BSDIFF40 patch turns an old file into a new one.
enum Bspatch {
    enum Failure: Error, Equatable {
        case corruptPatch
        case ioError
        case outOfMemory
    }

    /// Writes the new file, never larger than `maximumBytes`. A control triple that reaches outside the old file adds nothing
    /// there, as bsdiff 4.3 defined it, so only the result's hash says the patch was the right one.
    static func apply(_ patch: URL, to old: URL, writingTo new: URL, maximumBytes: Int) throws {
        switch hotcodepush_bspatch(old.path, new.path, patch.path, off_t(maximumBytes)) {
        case HOTCODEPUSH_BSPATCH_OK: return
        case HOTCODEPUSH_BSPATCH_CORRUPT_PATCH: throw Failure.corruptPatch
        case HOTCODEPUSH_BSPATCH_OUT_OF_MEMORY: throw Failure.outOfMemory
        default: throw Failure.ioError
        }
    }
}
