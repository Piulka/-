import AppKit
import ScreenCaptureKit
import Vision
import ApplicationServices
import CoreImage
import CoreMedia

private struct ReadLine {var text:String;var box:CGRect}
private struct PhoneRead {
    var lines:[ReadLine]
    var window:SCWindow
    func find(_ value:String)->ReadLine? {lines.first{$0.text.localizedCaseInsensitiveContains(value)}}
    func point(_ line:ReadLine)->CGPoint {CGPoint(x:line.box.midX,y:line.box.midY)}
}

private final class CaptureResult<T>:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<T,Error>?
    init(_ value:CheckedContinuation<T,Error>){continuation=value}
    func finish(_ value:Result<T,Error>){let target=lock.withLock{let c=continuation;continuation=nil;return c};target?.resume(with:value)}
}
private func captureDeadline<T>(_ operation:@escaping ()async throws->T)async throws->T {
    try await withCheckedThrowingContinuation{continuation in
        let result=CaptureResult(continuation)
        Task{do{result.finish(.success(try await operation()))}catch{result.finish(.failure(error))}}
        Task{try? await Task.sleep(nanoseconds:10_000_000_000);result.finish(.failure(AuthFailure("Захват экрана не ответил. Перезапустите видеоповтор")))}
    }
}

private final class MirrorFrames:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    private let lock=NSLock()
    private var latest:CGImage?
    private let context=CIContext(options:[.cacheIntermediates:false])
    private let queue=DispatchQueue(label:"drivee.ios.action.frames")
    var stream:SCStream?
    var window:SCWindow?
    func image()->CGImage?{lock.lock();defer{lock.unlock()};return latest}
    func start()async throws {
        let content=try await captureDeadline{try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)}
        guard let target=content.windows.filter({$0.owningApplication?.bundleIdentifier=="com.apple.ScreenContinuity" && $0.frame.height>300 && $0.frame.width>150}).max(by:{$0.frame.height<$1.frame.height}) else{throw AuthFailure("Окно видеоповтора не найдено")}
        window=target
        let config=SCStreamConfiguration();config.width=Int(target.frame.width*2);config.height=Int(target.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.capturesAudio=false;config.scalesToFit=true;config.queueDepth=2;config.minimumFrameInterval=CMTime(value:1,timescale:8);config.pixelFormat=kCVPixelFormatType_32BGRA
        let source=SCStream(filter:SCContentFilter(desktopIndependentWindow:target),configuration:config,delegate:self)
        try source.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue);stream=source
        try await captureDeadline{try await source.startCapture()}
    }
    func stop()async{try? await stream?.stopCapture();stream=nil;lock.withLock{latest=nil}}
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType){
        guard type == .screen,sampleBuffer.isValid,let pixel=sampleBuffer.imageBuffer else{return}
        let frame=CIImage(cvPixelBuffer:pixel)
        guard let cg=context.createCGImage(frame,from:frame.extent) else{return}
        lock.lock();latest=cg;lock.unlock()
    }
    func stream(_ stream:SCStream,didStopWithError error:Error){lock.lock();latest=nil;lock.unlock()}
}

// Operates the genuine, separate iPhone Mirroring window during an explicit action only.
// Frames and OCR stay in memory; no screenshots, phone numbers or codes are logged.
@MainActor final class IOSAccountAction:ObservableObject {
    @Published var running=false
    @Published var message="" {didSet{if UserDefaults.standard.bool(forKey:"iosPrepareOnly"){UserDefaults.standard.set(message,forKey:"iosLastStatus")}}}
    private var task:Task<Void,Never>?
    private var began=Date()
    private var mirror:NSRunningApplication?
    private var token=UUID()
    private var savedPointer:CGPoint?
    private var frames:MirrorFrames?
    func cancel(){guard running else{return};task?.cancel();message="Останавливаю…"}
    func start(phone:String,otp:String,stand:String){
        guard !running else{return}
        guard AXIsProcessTrusted() else {
            message="Разрешите Универсальный доступ для Жмякее"
            _=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary);return
        }
        guard CGPreflightScreenCaptureAccess() else {message="Разрешите запись экрана для Жмякее";_ = CGRequestScreenCaptureAccess();return}
        running=true;message="Открываю Drivee…";began=Date();let current=UUID();token=current
        task=Task {
            savedPointer=CGEvent(source:nil)?.location
            defer {
                if token==current{running=false}
                if NSWorkspace.shared.frontmostApplication?.processIdentifier==mirror?.processIdentifier {
                    if let p=savedPointer{CGWarpMouseCursorPosition(p)}
                    NSApp.activate();NSApp.windows.first(where:{$0.isVisible})?.makeKeyAndOrderFront(nil)
                }
                savedPointer=nil;if let source=frames{Task{await source.stop()}};frames=nil
            }
            do {
                try AccountVault.validate(phone:phone,otp:otp)
                guard ["08","09"].contains(stand) else{throw AuthFailure("Неизвестный стенд")}
                guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.ScreenContinuity").first else{throw AuthFailure("Откройте видеоповтор iPhone и подключитесь")}
                mirror=app
                try await activateMirror(app)
                message="Читаю экран iPhone…"
                let source=MirrorFrames();frames=source;try await source.start()
                var initial=try await screen(checkErrors:false)
                if initial.find("Превышено количество") != nil || initial.find("30 минут") != nil {
                    guard let close=initial.find("Закрыть") else{throw AuthFailure("Закройте прежнее сообщение о лимите на iPhone")}
                    try await tap(close,in:initial);try await pause(0.3);initial=try await screen()
                }
                if !isDrivee(initial) {
                    message="Запускаю Drivee…"
                    do{try await launchFromSpotlight()}catch{try await launchDrivee();try await activateMirror(app)}
                    initial=try await wait({self.isDrivee($0)},seconds:8)
                }
                try await authenticate(phone:phone,otp:otp,stand:stand)
                if !UserDefaults.standard.bool(forKey:"iosPrepareOnly"){message=String(format:"Вход выполнен · %.1f с",Date().timeIntervalSince(began))}
            }catch is CancellationError{if token==current{message="Остановлено"}}
            catch{if token==current{message=(error as? AuthFailure)?.message ?? "Не удалось прочитать окно видеоповтора"}}
        }
    }
    private func authenticated(_ r:PhoneRead)->Bool {
        guard r.find("Введите код")==nil,r.find("Укажите телефон")==nil else{return false}
        return r.find("Куда") != nil || r.find("Поездки по городу") != nil || r.find("Мои заказы") != nil || r.find("Курьер") != nil || (r.find("Заказы") != nil && (r.find("Доход") != nil || r.find("Приоритет") != nil))
    }
    private func isDrivee(_ s:PhoneRead)->Bool {
        authenticated(s) || ["Укажите телефон","Введите код","Current Host","Изменить номер","Выход из аккаунта","Module primary","DevNodes","История заказов","Стать водителем"].contains{s.find($0) != nil}
    }
    private func launchFromSpotlight()async throws {
        try key(20,flags:.maskCommand)
        _=try await wait({$0.find("Поиск") != nil || $0.find("Search") != nil},seconds:3)
        try await type("Drivee")
        let result=try await wait({r in r.lines.contains{$0.text.caseInsensitiveCompare("Drivee") == .orderedSame && $0.box.midY<0.7}},seconds:4)
        guard let icon=result.lines.first(where:{$0.text.caseInsensitiveCompare("Drivee") == .orderedSame && $0.box.midY<0.7}) else{throw AuthFailure("Drivee не найден на iPhone")}
        try await tap(icon,in:result)
    }
    private func axNodes(_ app:NSRunningApplication)->[AXUIElement] {
        var queue=[AXUIElementCreateApplication(app.processIdentifier)],result:[AXUIElement]=[]
        while !queue.isEmpty && result.count<350 {
            let next=queue.removeFirst();result.append(next);var children:CFTypeRef?
            if AXUIElementCopyAttributeValue(next,kAXChildrenAttribute as CFString,&children) == .success,let list=children as? [AXUIElement]{queue.append(contentsOf:list)}
        };return result
    }
    private func resumeButton(_ app:NSRunningApplication)->AXUIElement? {
        for node in axNodes(app) {
            var role:CFTypeRef?;AXUIElementCopyAttributeValue(node,kAXRoleAttribute as CFString,&role)
            var labels:[String]=[]
            for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute] {var value:CFTypeRef?;AXUIElementCopyAttributeValue(node,key as CFString,&value);if let text=value as? String{labels.append(text)}}
            guard labels.contains(where:{["Возобновить","Resume"].contains($0)}) else{continue}
            if role as? String == kAXButtonRole{return node}
            var parent:CFTypeRef?;AXUIElementCopyAttributeValue(node,kAXParentAttribute as CFString,&parent)
            if let parent,CFGetTypeID(parent)==AXUIElementGetTypeID(){return (parent as! AXUIElement)}
        };return nil
    }
    private func phoneReady(_ app:NSRunningApplication)->Bool {
        axNodes(app).contains{node in var value:CFTypeRef?;AXUIElementCopyAttributeValue(node,kAXIdentifierAttribute as CFString,&value);return value as? String == "app.grid.3x3"}
    }
    private func activateMirror(_ app:NSRunningApplication)async throws {
        app.activate(options:[])
        let ax=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        var windows:CFTypeRef?;AXUIElementCopyAttributeValue(ax,kAXWindowsAttribute as CFString,&windows)
        if let first=(windows as? [AXUIElement])?.first{AXUIElementPerformAction(first,kAXRaiseAction as CFString)}
        for _ in 0..<30 {if NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier{break};try await pause(0.05)}
        if let button=resumeButton(app){
            message="Подключаю видеоповтор…";AXUIElementPerformAction(button,kAXPressAction as CFString)
            for _ in 0..<50 {try await pause(0.15);if phoneReady(app){break}}
            guard phoneReady(app) else{throw AuthFailure("Не удалось возобновить видеоповтор. Проверьте подключение iPhone")}
            try await pause(0.2)
        }
    }
    private func pause(_ seconds:Double=0.18)async throws {try Task.checkCancellation();if Date().timeIntervalSince(began)>65{throw AuthFailure("Превышено время ожидания")};try await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
    private func jsonCommand(_ args:[String])async throws->[String:Any] {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("drivee-device-\(UUID().uuidString).json")
        defer{try? FileManager.default.removeItem(at:file)}
        let r=await LocalProcess.run("/usr/bin/xcrun",["devicectl","--timeout","8"]+args+["--json-output",file.path],timeout:10)
        try Task.checkCancellation()
        let data=try? Data(contentsOf:file)
        let object=data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        if UserDefaults.standard.bool(forKey:"iosPrepareOnly") {
            let error=object?["error"] as? [String:Any] ?? [:]
            UserDefaults.standard.set(["exit":Int(r.0),"command":args.prefix(3).joined(separator:" "),"json":data != nil,"errorCode":error["code"] as? Int ?? 0,"domain":error["domain"] as? String ?? ""],forKey:"iosDeviceDiagnostic")
        }
        guard r.0==0,let result=object?["result"] as? [String:Any] else{throw AuthFailure("iPhone недоступен через Xcode")};return result
    }
    private func launchDrivee()async throws {
        let result=try await jsonCommand(["list","devices"])
        let all=(result["devices"] as? [[String:Any]] ?? []).filter {d in
            guard let p=d["properties"] as? [String:Any],let h=p["hardware"] as? [String:Any],let c=p["connection"] as? [String:Any] else{return false}
            return h["deviceType"] as? String == "iPhone" && c["state"] as? String == "connected"
        }
        guard all.count==1,let id=all.first?["identifier"] as? String else{throw AuthFailure("Подключите один физический iPhone в Xcode")}
        // Launching an already-running app brings it to the phone foreground without restarting it.
        _=try await jsonCommand(["device","process","launch","--device",id,"com.drivee.taxi.rides"])
    }
    private func screen(checkErrors:Bool=true)async throws->PhoneRead {
        try Task.checkCancellation()
        guard let app=mirror,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{
            if UserDefaults.standard.bool(forKey:"iosPrepareOnly"){UserDefaults.standard.set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",forKey:"iosFocusDiagnostic")}
            throw AuthFailure("Вход остановлен: фокус ушёл с видеоповтора")
        }
        guard let source=frames,let window=source.window else{throw AuthFailure("Нет потока iPhone")}
        for _ in 0..<30 {if source.image() != nil{break};try await pause(0.1)}
        guard let image=source.image() else{throw AuthFailure("Нет изображения iPhone")}
        let observations:[VNRecognizedTextObservation]=try await Task.detached {
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["ru-RU","en-US"];request.usesLanguageCorrection=false
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);return request.results ?? []
        }.value
        let lines=observations.compactMap {o->ReadLine? in
            guard let t=o.topCandidates(1).first?.string else{return nil};let b=o.boundingBox
            return ReadLine(text:t,box:CGRect(x:b.minX,y:1-b.maxY,width:b.width,height:b.height))
        }
        let r=PhoneRead(lines:lines,window:window)
        if UserDefaults.standard.bool(forKey:"iosPrepareOnly") {
            let allowed=["Мозамбик","Россия","Далее","Укажите телефон","Current Host","Введите код","Module primary"]
            let known=lines.filter{line in allowed.contains{line.text.hasPrefix($0)} || line.text.contains("indels.dev")}.map{["text":$0.text,"box":NSStringFromRect($0.box)]}
            UserDefaults.standard.set(["frame":NSStringFromRect(window.frame),"width":image.width,"height":image.height,"known":known],forKey:"iosGeometryDiagnostic")
        }
        if checkErrors && (r.find("Превышено количество") != nil || r.find("30 минут") != nil) {throw AuthFailure("Лимит попыток на сервере. Повторите через 30 минут")}
        if r.find("геопозици") != nil && r.find("Разрешать всегда") != nil{throw AuthFailure("Ответьте на системный запрос геолокации iPhone")}
        if r.find("Соединение потеряно") != nil || r.find("Возобновить") != nil {throw AuthFailure("Возобновите видеоповтор iPhone")}
        return r
    }
    private func click(_ point:CGPoint,in screen:PhoneRead)async throws {
        try Task.checkCancellation()
        guard let app=mirror,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{
            if UserDefaults.standard.bool(forKey:"iosPrepareOnly"){UserDefaults.standard.set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",forKey:"iosFocusDiagnostic")}
            throw AuthFailure("Вход остановлен: фокус ушёл с видеоповтора")
        }
        // Refuse stale geometry if the user moved/resized the genuine window.
        guard let list=CGWindowListCopyWindowInfo(.optionIncludingWindow,screen.window.windowID) as? [[String:Any]],let b=list.first?[kCGWindowBounds as String] as? [String:Any],let rect=CGRect(dictionaryRepresentation:b as CFDictionary),abs(rect.minX-screen.window.frame.minX)<2,abs(rect.minY-screen.window.frame.minY)<2,abs(rect.width-screen.window.frame.width)<2 else{throw AuthFailure("Окно переместилось. Запустите вход ещё раз")}
        let p=CGPoint(x:rect.minX+point.x*rect.width,y:rect.minY+point.y*rect.height)
        for type in [CGEventType.leftMouseDown,.leftMouseUp]{let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:p,mouseButton:.left);e?.setIntegerValueField(.mouseEventClickState,value:1);e?.post(tap:.cghidEventTap);if type == .leftMouseDown{try await pause(0.055)}}
        try await pause()
    }
    private func tap(_ line:ReadLine,in screen:PhoneRead)async throws{try await click(screen.point(line),in:screen)}
    private func key(_ code:CGKeyCode,flags:CGEventFlags=[])throws {
        try Task.checkCancellation();guard let app=mirror,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{throw AuthFailure("Фокус ушёл с видеоповтора")}
        for down in [true,false]{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down);e?.flags=flags;e?.post(tap:.cghidEventTap)}
    }
    private func type(_ text:String)async throws {
        let digits:[Character:CGKeyCode]=["0":29,"1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25]
        for char in text {try Task.checkCancellation();if let code=digits[char]{try key(code);try await pause(0.045);continue};let values=Array(String(char).utf16)
            for down in [true,false]{let e=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down);values.withUnsafeBufferPointer{e?.keyboardSetUnicodeString(stringLength:values.count,unicodeString:$0.baseAddress!)};e?.post(tap:.cghidEventTap)}
            try await pause(0.03)
        }
    }
    private func wait(_ predicate:(PhoneRead)->Bool,seconds:Double=5)async throws->PhoneRead {
        let until=Date().addingTimeInterval(seconds)
        repeat{let s=try await screen();if predicate(s){try await pause(0.25);let settled=try await screen();if predicate(settled){return settled}};try await pause(0.15)}while Date()<until
        throw AuthFailure("Неожиданный экран iPhone. Проверьте видеоповтор")
    }
    private func authenticate(phone:String,otp:String,stand:String)async throws {
        var s=try await screen()
        if s.find("Module primary") != nil,let close=s.find("Закрыть"){try await tap(close,in:s);s=try await wait{$0.find("Укажите телефон") != nil || $0.find("Выход из аккаунта") != nil}}
        // The back arrow is used only on a positively recognised OTP page.
        if s.find("Введите код") != nil{try await click(CGPoint(x:0.12,y:0.143),in:s);s=try await wait{$0.find("Укажите телефон") != nil}}
        if s.find("Укажите телефон")==nil {
            message="Выхожу из аккаунта…"
            if let settings=s.find("Настройки"),s.find("Изменить номер")==nil{try await tap(settings,in:s);s=try await wait{$0.find("Выход из аккаунта") != nil}}
            else if s.find("Выход из аккаунта")==nil {
                // Main map/menu placement is used only after recognising the order page.
                guard authenticated(s) else{throw AuthFailure("Откройте главный экран Drivee на iPhone")}
                try await click(CGPoint(x:0.095,y:0.154),in:s);s=try await wait{$0.find("Настройки") != nil}
                guard let settings=s.find("Настройки") else{throw AuthFailure("Не найдены настройки")};try await tap(settings,in:s);s=try await wait{$0.find("Выход из аккаунта") != nil}
            }
            guard let logout=s.find("Выход из аккаунта") else{throw AuthFailure("Не найдена кнопка выхода")}
            try await tap(logout,in:s);s=try await wait{$0.find("Укажите телефон") != nil}
        }
        message="Проверяю стенд…"
        if !s.lines.contains(where:{$0.text.contains("test"+stand+"-")}) {
            guard let label=s.find("Current Host") else{throw AuthFailure("Не найден выбор стенда")}
            if let host=s.lines.first(where:{$0.text.lowercased().contains("test") && $0.box.midY>label.box.midY && $0.box.midY<label.box.midY+0.08}){try await tap(host,in:s)}
            else{try await click(CGPoint(x:label.box.midX,y:label.box.midY+0.024),in:s)}
            s=try await wait{$0.find("Module primary") != nil}
            if let primary=s.find("Module primary"){try await tap(primary,in:s)}
            s=try await wait{$0.lines.contains(where:{$0.text.contains("test"+stand+"-")})}
            guard let target=s.lines.first(where:{$0.text.contains("test"+stand+"-")}) else{throw AuthFailure("Стенд не найден")};try await tap(target,in:s)
            s=try await screen();guard let close=s.find("Закрыть") else{throw AuthFailure("Не найдена кнопка закрытия стендов")};try await tap(close,in:s)
            s=try await wait{$0.find("Укажите телефон") != nil}
            guard s.lines.contains(where:{$0.text.contains("test"+stand+"-")}) else{throw AuthFailure("Стенд не переключился")}
        }
        guard var next=s.find("Далее") else{throw AuthFailure("Кнопка Далее не найдена")}
        if !s.lines.contains(where:{$0.text.contains("+258")}) {
            try await click(CGPoint(x:0.15,y:next.box.midY-0.092),in:s)
            s=try await wait{$0.find("Мозамбик") != nil}
            guard let country=s.find("Мозамбик") else{throw AuthFailure("Страна не найдена")};try await tap(country,in:s)
            s=try await wait{$0.find("Укажите телефон") != nil};guard let button=s.find("Далее") else{throw AuthFailure("Кнопка Далее не найдена")};next=button
        }
        message="Ввожу номер…"
        let field=CGPoint(x:0.87,y:next.box.midY-0.092)
        // Cmd+A is handled by the Mac mirroring view. Delete only the existing national digits.
        for attempt in 0..<3 {
            guard let value=s.lines.first(where:{$0.text.contains("+258") && abs($0.box.midY-field.y)<0.05}) else{throw AuthFailure("Не удалось прочитать поле номера")}
            let existing=value.text.filter(\.isNumber)
            guard existing.hasPrefix("258"),existing.count<=35 else{throw AuthFailure("Не удалось проверить префикс номера")}
            if existing.count==3{break}
            try await click(field,in:s);try key(124)
            for _ in 0..<(existing.count-3){try key(51);try await pause(0.03)}
            try await pause(0.15);s=try await screen()
            if attempt==2, !s.lines.contains(where:{$0.text.filter(\.isNumber)=="258"}){throw AuthFailure("Не удалось очистить прежний номер")}
        }
        try await click(field,in:s);try key(124);try await type(String(phone.dropFirst(3)))
        let wanted=phone
        s=try await wait({$0.lines.contains(where:{$0.text.filter(\.isNumber)==wanted})},seconds:2)
        if UserDefaults.standard.bool(forKey:"iosPrepareOnly"){message="Номер и стенд проверены";return}
        guard let submit=s.find("Далее") else{throw AuthFailure("Кнопка Далее не найдена")};try await tap(submit,in:s)
        message="Ввожу код…";s=try await wait({$0.find("Введите код") != nil},seconds:10)
        try await click(CGPoint(x:0.5,y:0.367),in:s);try await type(otp)
        message="Проверяю вход…"
        for _ in 0..<4 {
            s=try await wait({r in self.authenticated(r) || r.find("Пропустить") != nil || r.find("Понятно") != nil},seconds:14)
            if let skip=s.find("Пропустить"){try await tap(skip,in:s);continue}
            if let tooltip=s.find("Понятно"){try await tap(tooltip,in:s);continue}
            if authenticated(s){return}
        }
        throw AuthFailure("Не удалось подтвердить главный экран iPhone")
    }
}
