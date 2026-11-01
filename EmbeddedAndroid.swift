import AppKit
import SwiftUI
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

private enum LinkError: Error { case unavailable }
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock();defer { lock.unlock() };if done { return false };done = true;return true }
}

final class EmbeddedAndroid: ObservableObject {
    @Published var state = "Не подключено"
    @Published var connected = false
    @Published var busy = false
    @Published var videoSize = CGSize(width: 9, height: 20)
    @Published var sample: CMSampleBuffer?
    @Published var pixelFrame: CVPixelBuffer?
    private let queue = DispatchQueue(label: "drivee.android.io", qos: .userInteractive)
    private let generationLock = NSLock()
    private var storedGeneration = UUID()
    private var generation: UUID {
        get { generationLock.lock();defer { generationLock.unlock() };return storedGeneration }
        set { generationLock.lock();storedGeneration = newValue;generationLock.unlock() }
    }
    private var video: NWConnection?
    private var control: NWConnection?
    private var server: Process?
    private var tunnel: (String,String,Int)?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var incoming = Data()
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(synchronous:true) }
    }

    @MainActor func start(serial: String, adb: String, maxSize: Int, fps: Int) async {
        stop()
        let id = generation
        busy = true; state = "Подключение…"
        let jar = Bundle.main.resourceURL!.appendingPathComponent("scrcpy-server").path
        guard FileManager.default.fileExists(atPath: jar) else { failed("Не найден компонент Android", id); return }
        let remote = "/data/local/tmp/drivee-qa-server.jar"
        let pushed = await LocalProcess.run(adb,["-s",serial,"push",jar,remote])
        guard id == generation else { return }
        guard pushed.0 == 0 else { failed("Не удалось подготовить устройство",id); return }
        let scid = String(format:"%08x",UInt32.random(in:1...0x7fffffff))
        let forwarded = await LocalProcess.run(adb,["-s",serial,"forward","tcp:0","localabstract:scrcpy_\(scid)"])
        guard let port = Int(forwarded.1.trimmingCharacters(in:.whitespacesAndNewlines)), forwarded.0 == 0 else { failed("Не удалось создать USB-соединение",id); return }
        guard id == generation else {
            _ = await LocalProcess.run(adb,["-s",serial,"forward","--remove","tcp:\(port)"]); return
        }
        tunnel = (adb,serial,port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s",serial,"shell","CLASSPATH=\(remote)","app_process","/","com.genymobile.scrcpy.Server","5.0.1","scid=\(scid)","tunnel_forward=true","audio=false","control=true","video_codec=h264","max_size=\(maxSize)","max_fps=\(fps)","video_bit_rate=6000000","send_device_meta=false","send_stream_meta=false","clipboard_autosync=false","log_level=error"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        server = process
        do {
            try process.run()
            var linked = false
            for _ in 0..<30 {
                guard id == generation else { return }
                guard process.isRunning else { failed("Компонент Android завершился. Подключите заново.",id);return }
                do {
                    let socket = try await openSocket(port:port)
                    guard id == generation else { socket.cancel();return }
                    video = socket
                    try await dummy(socket)
                    let commandSocket = try await openSocket(port:port)
                    guard id == generation else { socket.cancel();commandSocket.cancel();return }
                    control = commandSocket
                    linked = true; break
                } catch {
                    guard id == generation else { return }
                    video?.cancel(); video = nil
                    try await Task.sleep(nanoseconds:150_000_000)
                }
            }
            guard linked else { failed("Нет ответа от Android. Переподключите USB.",id); return }
            guard id == generation else { video?.cancel(); control?.cancel(); return }
            busy = false; state = "Ожидаю изображение…"
            receiveVideo(id)
            drainControl(id)
            DispatchQueue.main.asyncAfter(deadline:.now()+12) { [weak self] in
                guard let self, self.generation == id, !self.connected else { return }
                self.failed("Нет видеопотока. Попробуйте подключить заново.",id)
            }
        } catch { failed("Не удалось запустить поток Android",id) }
    }

    private func openSocket(port: Int) async throws -> NWConnection {
        let socket = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(port))!,using:.tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            @Sendable func finish(_ success:Bool) {
                guard once.claim() else { return }
                socket.stateUpdateHandler = nil
                if success { continuation.resume(returning:socket) }
                else { socket.cancel(); continuation.resume(throwing:LinkError.unavailable) }
            }
            socket.stateUpdateHandler = { state in
                switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
            }
            socket.start(queue:queue)
            queue.asyncAfter(deadline:.now()+2) { finish(false) }
        }
    }
    private func dummy(_ socket: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            let once = Once()
            @Sendable func finish(_ success:Bool) {
                guard once.claim() else { return }
                if success { continuation.resume() }
                else { socket.cancel(); continuation.resume(throwing:LinkError.unavailable) }
            }
            socket.receive(minimumIncompleteLength:1,maximumLength:1) { data,_,_,_ in finish(data?.first == 0) }
            queue.asyncAfter(deadline:.now()+1) { finish(false) }
        }
    }
    private func failed(_ message:String,_ id:UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.generation == id else { return }
            self.stop(); self.state = message
        }
    }
    func stop(synchronous:Bool=false) {
        generation = UUID()
        video?.cancel(); control?.cancel(); video = nil; control = nil
        if let server,server.isRunning { server.terminate() }; server = nil
        if let (adb,serial,port) = tunnel {
            let cleanup = {
                let command = Process()
                command.executableURL = URL(fileURLWithPath:adb)
                command.arguments = ["-s",serial,"forward","--remove","tcp:\(port)"]
                command.standardOutput = FileHandle.nullDevice;command.standardError = FileHandle.nullDevice
                guard (try? command.run()) != nil else { return }
                let deadline = DispatchWorkItem { if command.isRunning { command.terminate() } }
                DispatchQueue.global().asyncAfter(deadline:.now()+2,execute:deadline)
                command.waitUntilExit();deadline.cancel()
            }
            if synchronous { cleanup() } else { DispatchQueue.global(qos:.utility).async(execute:cleanup) }
        }
        tunnel = nil
        queue.async { [weak self] in
            if let decoder=self?.decoder{VTDecompressionSessionInvalidate(decoder)}
            self?.decoder=nil;self?.incoming.removeAll();self?.format=nil;self?.sps=nil;self?.pps=nil
        }
        connected = false; busy = false; sample = nil; pixelFrame=nil; state = "Не подключено"
    }
    private func receiveVideo(_ id: UUID) {
        guard let socket = video else { return }
        socket.receive(minimumIncompleteLength:1,maximumLength:1024*1024) { [weak self] data,_,complete,error in
            guard let self,self.generation == id else { return }
            if let data { self.incoming.append(data); self.parse(id) }
            if error != nil || complete { self.failed("Устройство отключено",id) }
            else { self.receiveVideo(id) }
        }
    }
    private func drainControl(_ id:UUID) {
        control?.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] _,_,complete,error in
            guard let self,self.generation == id else { return }
            if !complete && error == nil { self.drainControl(id) }
            else { self.failed("Соединение управления прервано",id) }
        }
    }
    private func parse(_ id:UUID) {
        while incoming.count >= 12 {
            let flags = AndroidWire.uint(incoming.prefix(8))
            let size = Int(AndroidWire.uint(incoming.dropFirst(8).prefix(4)))
            guard flags & (1 << 63) == 0, size > 0, size <= 16*1024*1024 else { failed("Неподдерживаемый видеопоток",id); return }
            guard incoming.count >= size+12 else { return }
            let packet = Data(incoming.dropFirst(12).prefix(size)); incoming.removeFirst(size+12)
            if flags & AndroidWire.configFlag != 0 { configure(packet); continue }
            guard let format else { continue }
            var avcc = Data()
            for unit in AndroidWire.nalUnits(packet) { avcc.append(AndroidWire.integer(UInt32(unit.count)));avcc.append(unit) }
            guard !avcc.isEmpty else { continue }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:avcc.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:avcc.count,flags:0,blockBufferOut:&block) == noErr, let block else { continue }
            let copied = avcc.withUnsafeBytes { raw in CMBlockBufferReplaceDataBytes(with:raw.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:avcc.count) }
            guard copied == noErr else { continue }
            var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:Int64(flags & ((1 << 61)-1)),timescale:1_000_000),decodeTimeStamp:.invalid)
            var length = avcc.count; var buffer:CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&length,sampleBufferOut:&buffer) == noErr, let buffer else { continue }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:true) as? [NSMutableDictionary],let item = attachments.first {
                item[kCMSampleAttachmentKey_DisplayImmediately] = true
                item[kCMSampleAttachmentKey_NotSync] = flags & AndroidWire.keyFlag == 0
            }
            decode(buffer,format:format,id:id)
        }
    }
    private func decode(_ buffer:CMSampleBuffer,format:CMVideoFormatDescription,id:UUID){
        if let decoder,!VTDecompressionSessionCanAcceptFormatDescription(decoder,formatDescription:format){VTDecompressionSessionInvalidate(decoder);self.decoder=nil}
        if decoder==nil {
            let attributes:[String:Any]=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
            let status=VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:format,decoderSpecification:nil,imageBufferAttributes:attributes as CFDictionary,outputCallback:nil,decompressionSessionOut:&decoder)
            guard status==noErr else{failed("Не удалось декодировать Android",id);return}
            if let decoder{VTSessionSetProperty(decoder,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)}
        }
        guard let decoder else{return}
        let status=VTDecompressionSessionDecodeFrame(decoder,sampleBuffer:buffer,flags:[._EnableAsynchronousDecompression],infoFlagsOut:nil){[weak self] status,_,pixel,pts,duration in
            guard status==noErr,let pixel,let self,self.generation==id else{return}
            var description:CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&description)==noErr,let description else{return}
            var timing=CMSampleTimingInfo(duration:duration,presentationTimeStamp:pts,decodeTimeStamp:.invalid)
            var displayed:CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&displayed)==noErr,let displayed else{return}
            if let attachments=CMSampleBufferGetSampleAttachmentsArray(displayed,createIfNecessary:true) as? [NSMutableDictionary]{attachments.first?[kCMSampleAttachmentKey_DisplayImmediately]=true}
            DispatchQueue.main.async{[weak self] in
                guard let self,self.generation==id else{return}
                self.videoSize=CGSize(width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel))
                self.pixelFrame=pixel;self.sample=displayed;self.connected=true;self.state="Подключено"
            }
        }
        if status != noErr{failed("Ошибка декодирования Android. Подключите заново.",id)}
    }
    private func configure(_ packet:Data) {
        for unit in AndroidWire.nalUnits(packet) {
            if unit.first.map({$0 & 31}) == 7 { sps = unit }
            if unit.first.map({$0 & 31}) == 8 { pps = unit }
        }
        guard let sps,let pps else { return }
        sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let pointers = [s.bindMemory(to:UInt8.self).baseAddress!,p.bindMemory(to:UInt8.self).baseAddress!]
            let sizes = [sps.count,pps.count]
            _ = pointers.withUnsafeBufferPointer { ptr in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,parameterSetPointers:ptr.baseAddress!,parameterSetSizes:sizes.baseAddress!,nalUnitHeaderLength:4,formatDescriptionOut:&format)
            }}
        }}
    }
    private func send(_ message:Data) { if connected { control?.send(content:message,completion:.contentProcessed({ _ in })) } }
    func touch(_ action:UInt8,_ point:CGPoint) { send(AndroidWire.touch(action:action,point:point,size:videoSize)) }
    func scroll(_ point:CGPoint,_ dx:Double,_ dy:Double) { send(AndroidWire.scroll(point:point,size:videoSize,dx:dx,dy:dy)) }
    func key(_ code:UInt32) { send(AndroidWire.key(code:code,action:0));send(AndroidWire.key(code:code,action:1)) }
    func text(_ text:String,paste:Bool=false) { send(AndroidWire.text(text,paste:paste || !text.unicodeScalars.allSatisfy({$0.isASCII}))) }
}

final class PhoneView: NSView {
    var session:EmbeddedAndroid?
    let videoLayer = AVSampleBufferDisplayLayer()
    private var lastSample:CMSampleBuffer?
    private var timebase:CMTimebase?
    private var down = false
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override var mouseDownCanMoveWindow:Bool { false }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect; layer?.addSublayer(videoLayer)
        if CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,sourceClock:CMClockGetHostTimeClock(),timebaseOut:&timebase) == noErr,let timebase {
            videoLayer.controlTimebase = timebase
            CMTimebaseSetRate(timebase,rate:1)
        }
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("Экран Android")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() { super.layout();CATransaction.begin();CATransaction.setDisableActions(true);videoLayer.frame = bounds;CATransaction.commit() }
    func update(_ buffer:CMSampleBuffer?) {
        guard let buffer else { if lastSample != nil { videoLayer.flushAndRemoveImage(); lastSample = nil };return }
        guard buffer !== lastSample else { return }
        if lastSample == nil,let timebase { CMTimebaseSetTime(timebase,time:CMSampleBufferGetPresentationTimeStamp(buffer)) }
        lastSample = buffer
        if videoLayer.status == .failed { videoLayer.flush() }
        videoLayer.enqueue(buffer)
    }
    private func point(_ event:NSEvent,clamp:Bool=false)->CGPoint? {
        guard let session else { return nil }
        let rect = AndroidWire.fittedRect(size:session.videoSize,bounds:bounds)
        let p = convert(event.locationInWindow,from:nil)
        guard rect.width>0,rect.height>0,clamp || rect.contains(p) else { return nil }
        return CGPoint(x:max(0,min(1,(p.x-rect.minX)/rect.width)),y:max(0,min(1,(p.y-rect.minY)/rect.height)))
    }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self);if let p = point(event) { down = true;session?.touch(0,p) } }
    override func mouseDragged(with event:NSEvent) { if down,let p=point(event,clamp:true) { session?.touch(2,p) } }
    override func mouseUp(with event:NSEvent) { if down,let p=point(event,clamp:true) { session?.touch(1,p) }; down = false }
    override func scrollWheel(with event:NSEvent) { if let p=point(event) { session?.scroll(p,Double(event.scrollingDeltaX)/25,Double(event.scrollingDeltaY)/25) } }
    override func keyDown(with event:NSEvent) {
        let keys:[UInt16:UInt32]=[51:67,117:112,36:66,76:66,48:61,53:4,123:21,124:22,125:20,126:19]
        if event.modifierFlags.contains(.command) { return }
        if let code=keys[event.keyCode] { session?.key(code) }
        else if let text=event.characters,!text.isEmpty { session?.text(text) }
    }
    @objc func paste(_ sender:Any?) { if let text=NSPasteboard.general.string(forType:.string) { session?.text(text,paste:true) } }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if window?.firstResponder === self,event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased()=="v" { paste(nil);return true }
        return super.performKeyEquivalent(with:event)
    }
}
struct AndroidCanvas:NSViewRepresentable {
    @ObservedObject var session:EmbeddedAndroid
    func makeNSView(context:Context)->PhoneView { let view=PhoneView();view.session=session;return view }
    func updateNSView(_ view:PhoneView,context:Context) { view.update(session.sample) }
}
