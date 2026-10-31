import Foundation
#if canImport(HotCodePushBspatch)
internal import HotCodePushBspatch
#endif

enum Bspatch {
    enum Failure: Error, Equatable {
        case corruptPatch
        case ioError
        case outOfMemory
    }

    // A control triple that reaches outside the old file adds nothing there, as bsdiff 4.3 defined it.
    // So only the hash of the result shows that the patch was the right one.
    static func apply(_ patch: URL, to old: URL, writingTo new: URL, maximumBytes: Int) throws {
        switch hotcodepush_bspatch(old.path, new.path, patch.path, off_t(maximumBytes)) {
        case HOTCODEPUSH_BSPATCH_OK: return
        case HOTCODEPUSH_BSPATCH_CORRUPT_PATCH: throw Failure.corruptPatch
        case HOTCODEPUSH_BSPATCH_OUT_OF_MEMORY: throw Failure.outOfMemory
        default: throw Failure.ioError
        }
    }
}
