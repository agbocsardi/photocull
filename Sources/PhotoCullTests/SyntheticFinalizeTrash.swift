import Foundation
import PhotoCullCore

/// Move rejects out of their claim directories without touching macOS Trash.
/// The fixture owns and removes this directory along with its other outputs.
func syntheticFinalizeHooks(root: URL) -> FinalizeHooks {
    let trash = root.appendingPathComponent("synthetic-trash", isDirectory: true)
    return FinalizeHooks(trash: { owned in
        let fm = FileManager.default
        let destination = trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let rejected = destination.appendingPathComponent(owned.lastPathComponent)
        try fm.moveItem(at: owned, to: rejected)
        return rejected
    })
}
