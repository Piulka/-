import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreText
import ApplicationServices

struct MediaFailure:LocalizedError {
    let message:String
    init(_ message:String){self.message=message}
    var errorDescription:String?{message}
}

enum CaptureChoice:String,CaseIterable,Identifiable {
    case first,second,iphone,androids,firstIPhone,secondIPhone
    var id:String{rawValue}
    var slots:[Int]{switch self{case .first,.firstIPhone:return [0];case .second,.secondIPhone:return [1];case .androids:return [0,1];case .iphone:return []}}
    var includesIPhone:Bool{[.iphone,.firstIPhone,.secondIPhone].contains(self)}

}

struct CaptureSource {
    let slot:Int? // nil is the genuine iPhone Mirroring window
    let serial:String
    let name:String
}

// Retained frame buffers are immutable after delivery; encoding only reads them.
enum CapturedFrame:@unchecked Sendable {
    case pixel(CVPixelBuffer),croppedPixel(CVPixelBuffer,CGRect),image(CGImage)
    var size:CGSize{switch self{case .pixel(let p):return CGSize(width:CVPixelBufferGetWidth(p),height:CVPixelBufferGetHeight(p));case .croppedPixel(let p,let crop):return CGSize(width:CGFloat(CVPixelBufferGetWidth(p))*crop.width,height:CGFloat(CVPixelBufferGetHeight(p))*crop.height);case .image(let i):return CGSize(width:i.width,height:i.height)}}
}

private final class MediaDeadline<T>:@unchecked Sendable {
    private let lock=NSLock()
    private var pending:CheckedContinuation<T,Error>?
    init(_ continuation:CheckedContinuation<T,Error>){pending=continuation}
    func finish(_ result:Result<T,Error>){let c=lock.withLock{let result=pending;pending=nil;return result};c?.resume(with:result)}
}
private func mediaDeadline<T>(_ body:@escaping ()async throws->T)async throws->T {
    try await withCheckedThrowingContinuation{continuation in
        let gate=MediaDeadline(continuation)
        Task{do{gate.finish(.success(try await body()))}catch{gate.finish(.failure(error))}}
        Task{try? await Task.sleep(nanoseconds:10_000_000_000);gate.finish(.failure(MediaFailure("Нет ответа от видеоповтора iPhone")))}
    }
}

private final class MirrorVideoSource:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    private let lock=NSLock()
    private var latest:CVPixelBuffer?
    private var lost=false
    private var stream:SCStream?
    private var crop=CGRect(x:0,y:0,width:1,height:1)
    private let queue=DispatchQueue(label:"pomogator.mirror.capture")
    static func checkConnection()throws {
        guard AXIsProcessTrusted(),let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.ScreenContinuity").first else{return}
        let root=AXUIElementCreateApplication(app.processIdentifier)
        var windows:CFTypeRef?;AXUIElementCopyAttributeValue(root,kAXWindowsAttribute as CFString,&windows)
        var nodes=windows as? [AXUIElement] ?? [],count=0
        while !nodes.isEmpty && count<120 {
            let node=nodes.removeFirst();count += 1
            for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute]{
                var value:CFTypeRef?;AXUIElementCopyAttributeValue(node,key as CFString,&value)
                if let text=value as? String,["Возобновить","Повторить попытку","Resume","Try Again","Подключение прервано","Подключение приостановлено","iPhone используется","iPhone in Use"].contains(where:{text.contains($0)}){throw MediaFailure("Возобновите подключение в окне видеоповтора iPhone")}
            }
            var children:CFTypeRef?;AXUIElementCopyAttributeValue(node,kAXChildrenAttribute as CFString,&children)
            if let list=children as? [AXUIElement]{nodes.append(contentsOf:list)}
        }
    }
    // Apple Mirroring's current window has an 8 pt bezel and a 38 pt toolbar.
    // Crop in normalized coordinates so stream resolution never changes the inset.
    static func phoneCrop(_ window:SCWindow)->CGRect {
        let size=window.frame.size
        return CGRect(x:8/size.width,y:38/size.height,width:(size.width-16)/size.width,height:(size.height-46)/size.height)
    }
    static func target()async throws->SCWindow {
        try checkConnection()
        guard CGPreflightScreenCaptureAccess() else{throw MediaFailure("Разрешите запись экрана для Помогатора в настройках macOS")}
        let content=try await mediaDeadline{try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)}
        guard let target=content.windows.filter({$0.owningApplication?.bundleIdentifier=="com.apple.ScreenContinuity" && $0.frame.height>300 && $0.frame.width>150}).max(by:{$0.frame.height<$1.frame.height}) else{throw MediaFailure("Откройте видеоповтор iPhone и подключитесь")}
        return target
    }
    static func configuration(_ target:SCWindow)->SCStreamConfiguration {
        let config=SCStreamConfiguration()
        let scale=min(2,1920/target.frame.height)
        config.width=Int(target.frame.width*scale);config.height=Int(target.frame.height*scale)
        config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.capturesAudio=false;config.scalesToFit=true
        config.queueDepth=3;config.minimumFrameInterval=CMTime(value:1,timescale:30);config.pixelFormat=kCVPixelFormatType_32BGRA
        return config
    }
    static func screenshot()async throws->CGImage {
        let window=try await target(),config=configuration(window)
        let image=try await mediaDeadline{try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)}
        return try FrameCompositor.crop(image,normalized:phoneCrop(window))
    }
    func start()async throws {
        let window=try await Self.target()
        crop=Self.phoneCrop(window)
        let source=SCStream(filter:SCContentFilter(desktopIndependentWindow:window),configuration:Self.configuration(window),delegate:self)
        try source.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue);stream=source
        try await mediaDeadline{try await source.startCapture()}
        for _ in 0..<40{if frame() != nil{return};try await Task.sleep(nanoseconds:50_000_000)}
        throw MediaFailure("Нет изображения iPhone. Возобновите видеоповтор")
    }
    func frame()->CapturedFrame?{lock.withLock{guard !lost,let latest else{return nil};return .croppedPixel(latest,crop)}}
    func stop()async{try? await stream?.stopCapture();stream=nil;lock.withLock{latest=nil;lost=true}}
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType){
        guard type == .screen,sampleBuffer.isValid,let pixel=sampleBuffer.imageBuffer,
              let list=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let raw=list.first?[.status] as? Int,SCFrameStatus(rawValue:raw) == .complete else{return}
        lock.withLock{latest=pixel}
    }
    func stream(_ stream:SCStream,didStopWithError error:Error){lock.withLock{lost=true;latest=nil}}
}

struct CaptureLayout {
    let size:CGSize
    let cells:[CGRect]
    let labels:Bool
    init(frames:[CapturedFrame],video:Bool=false){
        let height=(frames.map{$0.size.height}.max() ?? 1280)
        let h=video ? min(height,1600) : height
        let header:CGFloat=frames.count>1 ? 32 : 0
        var cells:[CGRect]=[],x:CGFloat=0
        for frame in frames {
            let width=(h*frame.size.width/frame.size.height).rounded(.up)
            cells.append(CGRect(x:x,y:0,width:width,height:h));x += width+12
        }
        self.cells=cells;labels=frames.count>1
        size=CGSize(width:ceil(max(2,x-12)/2)*2,height:ceil((h+header)/2)*2)
    }
}
final class FrameCompositor {
    private let context=CIContext(options:[.cacheIntermediates:false])
    func cgImage(_ frame:CapturedFrame)throws->CGImage {
        switch frame {
        case .image(let image):return image
        case .pixel(let pixel):return try read(pixel)
        case .croppedPixel(let pixel,let rect):return try Self.crop(read(pixel),normalized:rect)
        }
    }
    private func read(_ pixel:CVPixelBuffer)throws->CGImage {
        let image=CIImage(cvPixelBuffer:pixel)
        guard let cg=context.createCGImage(image,from:image.extent) else{throw MediaFailure("Не удалось прочитать кадр")};return cg
    }
    static func crop(_ image:CGImage,normalized rect:CGRect)throws->CGImage {
        let area=CGRect(x:rect.minX*CGFloat(image.width),y:rect.minY*CGFloat(image.height),width:rect.width*CGFloat(image.width),height:rect.height*CGFloat(image.height)).integral
        guard let result=image.cropping(to:area) else{throw MediaFailure("Не удалось выделить экран iPhone")};return result
    }
    func draw(_ frames:[CapturedFrame],names:[String],layout:CaptureLayout,in context:CGContext)throws {
        context.setFillColor(CGColor(gray:0.035,alpha:1));context.fill(CGRect(origin:.zero,size:layout.size))
        context.interpolationQuality = .high
        for (index,frame) in frames.enumerated(){
            let image=try cgImage(frame),cell=layout.cells[index]
            let scale=min(cell.width/CGFloat(image.width),cell.height/CGFloat(image.height))
            let rect=CGRect(x:cell.midX-CGFloat(image.width)*scale/2,y:cell.midY-CGFloat(image.height)*scale/2,width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
            context.draw(image,in:rect)
            if layout.labels {
                let line=CTLineCreateWithAttributedString(NSAttributedString(string:names[index],attributes:[.font:NSFont.systemFont(ofSize:16,weight:.medium),.foregroundColor:NSColor.white]))
                context.textMatrix = .identity;context.textPosition=CGPoint(x:cell.minX+8,y:layout.size.height-22);CTLineDraw(line,context)
            }
        }
    }
    func image(_ frames:[CapturedFrame],names:[String])throws->CGImage {
        if frames.count==1{return try cgImage(frames[0])}
        let layout=CaptureLayout(frames:frames)
        guard let canvas=CGContext(data:nil,width:Int(layout.size.width),height:Int(layout.size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw MediaFailure("Не хватило памяти для изображения")}
        try draw(frames,names:names,layout:layout,in:canvas)
        guard let image=canvas.makeImage() else{throw MediaFailure("Не удалось собрать изображение")};return image
    }
    static func savePNG(_ image:CGImage,to url:URL)throws {
        guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw MediaFailure("Не удалось создать PNG")}
        try data.write(to:url,options:.atomic)
    }
}

private final class MovieEncoder:@unchecked Sendable {
    private let writer:AVAssetWriter
    private let input:AVAssetWriterInput
    private let adaptor:AVAssetWriterInputPixelBufferAdaptor
    private let layout:CaptureLayout
    private let compositor=FrameCompositor()
    private let queue=DispatchQueue(label:"pomogator.movie.writer",qos:.userInitiated)
    private let temporary:URL
    let destination:URL
    private var last=CMTime.invalid
    private var count=0
    init(frames:[CapturedFrame],destination:URL)throws {
        self.destination=destination;temporary=destination.deletingLastPathComponent().appendingPathComponent(".recording-\(UUID().uuidString).mp4")
        layout=CaptureLayout(frames:frames,video:true)
        writer=try AVAssetWriter(outputURL:temporary,fileType:.mp4)
        input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(layout.size.width),AVVideoHeightKey:Int(layout.size.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:frames.count*6_000_000,AVVideoExpectedSourceFrameRateKey:30,AVVideoMaxKeyFrameIntervalKey:60]])
        input.expectsMediaDataInRealTime=true
        adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:Int(layout.size.width),kCVPixelBufferHeightKey as String:Int(layout.size.height),kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.canAdd(input) else{throw MediaFailure("Не удалось подготовить MP4")};writer.add(input)
        guard writer.startWriting() else{throw MediaFailure("Не удалось создать видео. Проверьте папку и свободное место")}
        writer.startSession(atSourceTime:.zero)
    }
    func append(_ frames:[CapturedFrame],names:[String],seconds:Double)async throws {
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            queue.async{do{try autoreleasepool{try self.write(frames,names:names,seconds:seconds)};continuation.resume()}catch{continuation.resume(throwing:error)}}
        }
    }
    private func write(_ frames:[CapturedFrame],names:[String],seconds:Double)throws {
        guard writer.status == .writing else{throw MediaFailure("Ошибка записи видео. Проверьте свободное место")}
        guard input.isReadyForMoreMediaData else{if count==0{throw MediaFailure("Кодировщик видео не готов")};return}
        let pts=CMTime(seconds:max(0,seconds),preferredTimescale:60_000)
        if last.isValid && CMTimeCompare(pts,last)<=0{return}
        var pixel:CVPixelBuffer?
        guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&pixel)==kCVReturnSuccess,let pixel else{throw MediaFailure("Не удалось создать видеокадр")}
        CVPixelBufferLockBaseAddress(pixel,[]);defer{CVPixelBufferUnlockBaseAddress(pixel,[])}
        guard let canvas=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:Int(layout.size.width),height:Int(layout.size.height),bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else{throw MediaFailure("Не удалось собрать видеокадр")}
        try compositor.draw(frames,names:names,layout:layout,in:canvas)
        guard adaptor.append(pixel,withPresentationTime:pts) else{throw MediaFailure("Не удалось записать видеокадр")}
        count += 1;last=pts
    }
    func finish(seconds:Double)async throws->URL {
        try await withCheckedThrowingContinuation{continuation in
            queue.async{
                guard self.writer.status == .writing,self.count>0 else{self.writer.cancelWriting();try? FileManager.default.removeItem(at:self.temporary);continuation.resume(throwing:MediaFailure("Видео не удалось сохранить"));return}
                self.writer.endSession(atSourceTime:CMTimeMaximum(CMTime(seconds:seconds,preferredTimescale:60_000),CMTimeAdd(self.last,CMTime(value:1,timescale:30))))
                self.input.markAsFinished()
                self.writer.finishWriting {
                    do {
                        guard self.writer.status == .completed else{throw MediaFailure("Не удалось завершить MP4. Проверьте свободное место")}
                        try FileManager.default.moveItem(at:self.temporary,to:self.destination)
                        continuation.resume(returning:self.destination)
                    }catch{try? FileManager.default.removeItem(at:self.temporary);continuation.resume(throwing:error)}
                }
            }
        }
    }
    func discard(){writer.cancelWriting();try? FileManager.default.removeItem(at:temporary)}
}

@MainActor final class MediaCoordinator:ObservableObject {
    enum Phase {case idle,preparing,recording,paused,saving}
    weak var model:DeskModel?
    @Published var choice:CaptureChoice = .androids {didSet{UserDefaults.standard.set(choice.rawValue,forKey:"captureChoice");notice="";failed=false}}
    @Published var phase:Phase = .idle
    @Published var takingScreenshot=false
    @Published var elapsed:Double=0
    @Published var notice=""
    @Published var failed=false
    @Published var lastURL:URL?
    @Published var editor:AnnotationDocument?
    @Published var folder:URL {didSet{UserDefaults.standard.set(folder.path,forKey:"captureFolder")}}
    private var folderPanel:NSOpenPanel?
    private var mirror:MirrorVideoSource?
    private var recordingTask:Task<Void,Never>?
    private var stopRequested=false
    private var lastMirrorCheck:Double=0
    private var started:Double=0,pausedAt:Double=0,pausedTotal:Double=0
    var recording:Bool{phase == .recording || phase == .paused}
    var working:Bool{phase != .idle}
    var clock:String{String(format:"%02d:%02d",Int(elapsed)/60,Int(elapsed)%60)}
    init(){
        choice=CaptureChoice(rawValue:UserDefaults.standard.string(forKey:"captureChoice") ?? "") ?? .androids
        let path=UserDefaults.standard.string(forKey:"captureFolder")
        folder=path.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask)[0].appendingPathComponent("Жмякее",isDirectory:true)
    }
    func title(_ choice:CaptureChoice)->String {
        guard let model else{return "Устройства"}
        var labels=choice.slots.map{slot in model.devices.first(where:{$0.id==model.selection[slot]})?.name ?? "Android \(slot+1)"}
        if choice.includesIPhone{labels.append("iPhone")};return labels.map{$0.components(separatedBy:" · ")[0]}.joined(separator:" + ")
    }
    func shortTitle(_ choice:CaptureChoice)->String {
        if choice == .iphone{return "iPhone"}
        let names=choice.slots.map{slot in model?.devices.first(where:{$0.id==model?.selection[slot]})?.name.components(separatedBy:" · ").first ?? "A\(slot+1)"}
        if names.count==1 && !choice.includesIPhone{return names[0]}
        var labels=names.map{String($0.prefix(1))}
        if labels.count==2 && labels[0]==labels[1]{labels=["1","2"]}
        if choice.includesIPhone{labels.append("iP")};return labels.joined(separator:"+")
    }
    func chooseFolder(){
        if let folderPanel{folderPanel.makeKeyAndOrderFront(nil);return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.prompt="Выбрать";panel.message="Папка для скриншотов и видео";panel.directoryURL=folder
        folderPanel=panel
        let completed:(NSApplication.ModalResponse)->Void={[weak self,weak panel] response in
            Task{@MainActor in
                guard let self else{return};let selected=panel?.url;self.folderPanel=nil
                if response == .OK,let selected{self.folder=selected}
            }
        }
        if let window=NSApp.keyWindow{panel.beginSheetModal(for:window,completionHandler:completed)}else{panel.begin(completionHandler:completed)}
    }
    func showFolder(){do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);NSWorkspace.shared.open(folder)}catch{report("Не удалось открыть папку сохранения")}}
    func revealLast(){if let lastURL{NSWorkspace.shared.activateFileViewerSelecting([lastURL])}}
    private func report(_ text:String){notice=text;failed=true}
    private func sources()throws->[CaptureSource] {
        guard let model else{throw MediaFailure("Устройства не готовы")}
        var sources:[CaptureSource]=[]
        for slot in choice.slots {
            let serial=model.selection[slot]
            guard !serial.isEmpty,model.sessions[slot].connected else{throw MediaFailure("Подключите выбранный Android")}
            sources.append(CaptureSource(slot:slot,serial:serial,name:model.devices.first(where:{$0.id==serial})?.name ?? "Android \(slot+1)"))
        }
        if choice.includesIPhone{sources.append(CaptureSource(slot:nil,serial:"iphone",name:"iPhone"))};return sources
    }
    private func frames(_ sources:[CaptureSource])async throws->[CapturedFrame] {
        guard let model else{throw MediaFailure("Устройства недоступны")}
        var result:[CapturedFrame]=[]
        for source in sources {
            if let slot=source.slot {
                guard model.selection[slot]==source.serial,model.sessions[slot].connected,let pixel=model.sessions[slot].pixelFrame else{throw MediaFailure("Android отключён или заменён")}
                result.append(.pixel(pixel))
            }else if let mirror {
                if CACurrentMediaTime()-lastMirrorCheck>1{try MirrorVideoSource.checkConnection();lastMirrorCheck=CACurrentMediaTime()}
                guard let frame=mirror.frame() else{throw MediaFailure("Видеоповтор iPhone прерван")};result.append(frame)
            }else{result.append(.image(try await MirrorVideoSource.screenshot()))}
        };return result
    }
    private func destination(names:[String],kind:String,ext:String)throws->URL {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.dateFormat="yyyy-MM-dd_HH-mm-ss-SSS"
        let tags=names.joined(separator:"+").replacingOccurrences(of:" · ",with:"-").replacingOccurrences(of:" ",with:"-")
        return folder.appendingPathComponent("\(format.string(from:Date()))_\(tags)_\(kind)_\(UUID().uuidString.prefix(8)).\(ext)")
    }
    func screenshot(annotate:Bool=false)async {
        guard !takingScreenshot,phase != .preparing,phase != .saving else{return}
        if annotate,editor != nil{return}
        takingScreenshot=true;defer{takingScreenshot=false}
        do {
            let targets=try sources(),captured=try await frames(targets),names=targets.map(\.name)
            let image=try await Task.detached(priority:.userInitiated){try FrameCompositor().image(captured,names:names)}.value
            if annotate{editor=AnnotationDocument(image:image,names:names);return}
            let url=try destination(names:names,kind:"screen",ext:"png")
            try await Task.detached(priority:.userInitiated){try FrameCompositor.savePNG(image,to:url)}.value
            let copied=MediaClipboard.screenshot(image,file:url)
            lastURL=url;notice=copied ? "Скриншот сохранён и скопирован" : "Скриншот сохранён · буфер недоступен";failed = !copied
        }catch{report(error.localizedDescription)}
    }
    func saveEdited()async {
        guard let editor,!takingScreenshot else{return};takingScreenshot=true;defer{takingScreenshot=false}
        do {
            let image=try editor.export(),url=try destination(names:editor.names,kind:"marked",ext:"png")
            try await Task.detached(priority:.userInitiated){try FrameCompositor.savePNG(image,to:url)}.value
            let copied=MediaClipboard.screenshot(image,file:url)
            self.editor=nil;lastURL=url;notice=copied ? "Разметка сохранена и скопирована" : "Разметка сохранена · буфер недоступен";failed = !copied
        }catch{report(error.localizedDescription)}
    }
    func startRecording(){
        guard phase == .idle,!takingScreenshot else{return}
        phase = .preparing;elapsed=0;stopRequested=false;notice="Готовлю запись…";failed=false
        recordingTask=Task{
            var encoder:MovieEncoder?,interruption:String?
            defer{phase = .idle;recordingTask=nil}
            do {
                let targets=try sources(),names=targets.map(\.name)
                let output=try destination(names:names,kind:"video",ext:"mp4")
                if targets.contains(where:{$0.slot==nil}){let source=MirrorVideoSource();mirror=source;try await source.start()}
                let initial=try await frames(targets)
                let movie=try MovieEncoder(frames:initial,destination:output);encoder=movie
                try await movie.append(initial,names:names,seconds:0)
                started=CACurrentMediaTime();pausedTotal=0;pausedAt=0;phase = .recording;notice=""
                while !stopRequested {
                    if phase == .paused{try await Task.sleep(nanoseconds:80_000_000);continue}
                    let began=CACurrentMediaTime()
                    do {
                        let captured=try await frames(targets)
                        let time=activeTime();if Int(time) != Int(elapsed){elapsed=time}
                        try await movie.append(captured,names:names,seconds:time)
                    }catch{interruption=error.localizedDescription;break}
                    let wait=max(0.001,1/30-(CACurrentMediaTime()-began))
                    try await Task.sleep(nanoseconds:UInt64(wait*1e9))
                }
                let time=activeTime();elapsed=time;phase = .saving
                let saved=try await movie.finish(seconds:time);encoder=nil
                let copied=MediaClipboard.video(saved)
                let result=copied ? "Видео сохранено и скопировано" : "Видео сохранено · буфер недоступен"
                lastURL=saved;notice=interruption.map{"\($0). \(result)"} ?? result;failed=interruption != nil || !copied
            }catch{encoder?.discard();report(error.localizedDescription)}
            if let source=mirror{await source.stop();mirror=nil}
        }
    }
    private func activeTime()->Double{max(0,(phase == .paused ? pausedAt : CACurrentMediaTime())-started-pausedTotal)}
    func togglePause(){
        if phase == .recording{pausedAt=CACurrentMediaTime();elapsed=activeTime();phase = .paused}
        else if phase == .paused{pausedTotal += CACurrentMediaTime()-pausedAt;phase = .recording}
    }
    func stopRecording(){stopRequested=true}
    func finishBeforeQuit()async{stopRequested=true;await recordingTask?.value;while takingScreenshot{try? await Task.sleep(nanoseconds:50_000_000)}}
}

@MainActor final class DeskApplicationDelegate:NSObject,NSApplicationDelegate {
    weak var media:MediaCoordinator?
    weak var builds:BuildLibrary?
    weak var androidRepeat:AndroidRepeat?
    weak var otp:OTPBridge?
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if let builds,builds.installing{builds.message="Дождитесь завершения установки перед выходом";return .terminateCancel}
        guard media?.working == true || media?.takingScreenshot == true || androidRepeat?.engaged == true || otp?.working == true else{return .terminateNow}
        Task{await otp?.finishBeforeQuit();await androidRepeat?.stop();await media?.finishBeforeQuit();sender.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }
}

struct MediaSidebar:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var media:MediaCoordinator
    var edit:()->Void
    @AppStorage("captureExpanded") private var expanded=true
    var body:some View {
        VStack(alignment:.leading,spacing:9){
            Button{withAnimation(.easeInOut(duration:0.16)){expanded.toggle()}}label:{HStack{Text("СЪЁМКА").font(.system(size:9,weight:.semibold));Spacer();Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:9))}.foregroundStyle(.secondary).contentShape(Rectangle())}.buttonStyle(.plain).accessibilityIdentifier("capture.header")
            if expanded {
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:4),count:3),spacing:4){
                ForEach(CaptureChoice.allCases){choice in
                    Button{media.choice=choice}label:{Text(media.shortTitle(choice)).font(.system(size:9,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth:.infinity,minHeight:27).background(media.choice==choice ? Color(red:0.64,green:0.94,blue:0.18) : Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:6)).foregroundStyle(media.choice==choice ? Color.black : Color.primary)}
                    .buttonStyle(.plain).disabled(media.working).help(media.title(choice)).accessibilityLabel(media.title(choice)).accessibilityIdentifier("capture.target.\(choice.rawValue)")
                }
            }
            HStack(spacing:5){
                Button{Task{await media.screenshot()}}label:{Image(systemName:"camera").frame(maxWidth:.infinity)}.help("Скриншот в папку и буфер обмена").accessibilityLabel("Скриншот").accessibilityIdentifier("capture.screenshot")
                Button{if media.editor != nil{edit()}else{Task{await media.screenshot(annotate:true);if media.editor != nil{edit()}}}}label:{Image(systemName:"pencil.tip.crop.circle").frame(maxWidth:.infinity)}.help(media.editor == nil ? "Скриншот с разметкой" : "Продолжить разметку").accessibilityLabel("Скриншот с разметкой").accessibilityIdentifier("capture.annotate")
            }.disabled(media.takingScreenshot || media.phase == .preparing || media.phase == .saving)
            if !media.recording {
                Button{media.startRecording()}label:{Label(media.phase == .saving ? "Сохраняю…" : media.phase == .preparing ? "Подготовка…" : "Записать",systemImage:"record.circle").frame(maxWidth:.infinity)}.disabled(media.working || media.takingScreenshot).accessibilityIdentifier("capture.record")
            }
            }
            if media.recording {
                HStack(spacing:5){
                    Button{media.togglePause()}label:{Image(systemName:media.phase == .paused ? "play.fill" : "pause.fill").frame(maxWidth:.infinity)}.help(media.phase == .paused ? "Продолжить запись" : "Пауза").accessibilityLabel(media.phase == .paused ? "Продолжить запись" : "Пауза").accessibilityIdentifier("capture.pause")
                    Button{media.stopRecording()}label:{Image(systemName:"stop.fill").foregroundStyle(.red).frame(maxWidth:.infinity)}.help("Остановить и сохранить").accessibilityLabel("Остановить запись").accessibilityIdentifier("capture.stop")
                }
                Label(media.clock,systemImage:media.phase == .paused ? "pause.circle" : "record.circle").font(.system(size:12,design:.monospaced)).foregroundStyle(media.phase == .paused ? .orange : .red)
            }
            if media.takingScreenshot{ProgressView().controlSize(.mini)}
            if !media.notice.isEmpty{Text(media.notice).font(.system(size:10)).foregroundStyle(media.failed ? .orange : .secondary).lineLimit(4).help(media.notice).accessibilityIdentifier("capture.status")}
            if let url=media.lastURL{Button{media.revealLast()}label:{Label("Показать файл",systemImage:"folder").font(.system(size:10))}.buttonStyle(.plain).foregroundStyle(.secondary).help(url.lastPathComponent).accessibilityIdentifier("capture.reveal")}
        }.controlSize(.small).frame(maxWidth:.infinity,alignment:.leading)
    }
}
