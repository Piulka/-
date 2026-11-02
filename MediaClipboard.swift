import AppKit

@MainActor enum MediaClipboard {
    // One item supports both pasting an inline image and attaching its saved file.
    static func screenshot(_ image:CGImage,file:URL,pasteboard:NSPasteboard = .general)->Bool {
        guard file.isFileURL,let png=try? Data(contentsOf:file) else{return false}
        let item=NSPasteboardItem()
        item.setString(file.absoluteString,forType:.fileURL)
        item.setData(png,forType:.png)
        if let tiff=NSBitmapImageRep(cgImage:image).tiffRepresentation{item.setData(tiff,forType:.tiff)}
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
    static func video(_ file:URL,pasteboard:NSPasteboard = .general)->Bool {
        guard file.isFileURL,FileManager.default.fileExists(atPath:file.path) else{return false}
        pasteboard.clearContents()
        return pasteboard.writeObjects([file as NSURL])
    }
}
