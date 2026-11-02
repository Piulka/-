import AppKit

@main struct MediaClipboardTests {
    @MainActor static func main()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let board=NSPasteboard.withUniqueName()
        defer{board.releaseGlobally()}
        let canvas=CGContext(data:nil,width:4,height:2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(NSColor.red.cgColor);canvas.fill(CGRect(x:0,y:0,width:4,height:2))
        let image=canvas.makeImage()!,png=directory.appendingPathComponent("Скрин с разметкой.png")
        let pngData=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
        try pngData.write(to:png)
        precondition(MediaClipboard.screenshot(image,file:png,pasteboard:board))
        precondition(board.pasteboardItems?.count==1) // No duplicate attachments.
        precondition(board.data(forType:.png)==pngData)
        precondition(NSImage(pasteboard:board)?.representations.first?.pixelsWide==4)
        precondition((board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true])?.first as? URL)==png)
        let video=directory.appendingPathComponent("Видео с пробелом.mp4")
        try Data([0,1,2,3]).write(to:video) // Payload is irrelevant to file-URL pasteboard transport.
        precondition(MediaClipboard.video(video,pasteboard:board))
        precondition(board.pasteboardItems?.count==1 && board.data(forType:.png)==nil)
        precondition((board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true])?.first as? URL)==video)
        let before=board.changeCount
        precondition(!MediaClipboard.video(directory.appendingPathComponent("missing.mp4"),pasteboard:board))
        precondition(!MediaClipboard.screenshot(image,file:directory.appendingPathComponent("missing.png"),pasteboard:board))
        precondition(board.changeCount==before) // Failed preparation preserves the existing clipboard.
        print("Screenshot image/file and video file clipboard interoperability: passed")
    }
}
