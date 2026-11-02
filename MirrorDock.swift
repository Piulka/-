import AppKit
import SwiftUI
import ApplicationServices

/// Links two separate native windows. Apple Mirroring cannot be reparented into this app.
/// No captured-image input proxy, pointer warping, synthetic clicks or per-click repositioning.
@MainActor final class MirrorDock:ObservableObject {
    @Published private(set) var enabled=false
    @Published private(set) var message=""
    private weak var host:NSWindow?
    private var source:AXUIElement?
    private var originalPosition:CGPoint?
    private var lastPosition:CGPoint?
    private var oldHostFrame:NSRect?
    private var adjustedHostFrame:NSRect?
    private var oldMinimum:NSSize?
    private var hiddenByUs=false
    private var observers:[NSObjectProtocol]=[]
    private var generation=UUID()
    init(){
        for name in [NSWindow.didMoveNotification,NSWindow.didResizeNotification,NSWindow.didBecomeKeyNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]{
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] note in
                Task{@MainActor in
                    guard let self,self.enabled,let window=note.object as? NSWindow,window === self.host else{return}
                    switch note.name {
                    case NSWindow.willCloseNotification:self.disable()
                    case NSWindow.didMiniaturizeNotification:self.hide()
                    case NSWindow.didDeminiaturizeNotification:self.unhide();self.place(raise:true)
                    case NSWindow.didBecomeKeyNotification:self.place(raise:true)
                    default:self.place()
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didHideNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.hide()}})
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didUnhideNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.unhide();self?.place(raise:true)}})
    }
    private func point(_ window:AXUIElement)->CGPoint? {
        var raw:CFTypeRef?;guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&raw) == .success,let raw,CFGetTypeID(raw)==AXValueGetTypeID() else{return nil}
        var p=CGPoint.zero;guard AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cgPoint,&p) else{return nil};return p
    }
    private func size(_ window:AXUIElement)->CGSize? {
        var raw:CFTypeRef?;guard AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&raw) == .success,let raw,CFGetTypeID(raw)==AXValueGetTypeID() else{return nil}
        var p=CGSize.zero;guard AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cgSize,&p) else{return nil};return p
    }
    private func locate()->AXUIElement? {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.ScreenContinuity").first else{return nil}
        let target=AXUIElementCreateApplication(app.processIdentifier);var result:CFTypeRef?
        guard AXUIElementCopyAttributeValue(target,kAXWindowsAttribute as CFString,&result) == .success,let windows=result as? [AXUIElement] else{return nil}
        return windows.first{window in var id:CFTypeRef?;AXUIElementCopyAttributeValue(window,kAXIdentifierAttribute as CFString,&id);return id as? String == "iphone-mirroring-main"}
    }
    func setEnabled(_ value:Bool){
        if !value{disable();return}
        guard !enabled else{return}
        guard AXIsProcessTrusted() else{message="Нужен Универсальный доступ для Жмякее";return}
        guard let window=NSApp.windows.first(where:{$0.identifier?.rawValue=="main" && $0.isVisible}) ?? NSApp.keyWindow else{return}
        guard !window.styleMask.contains(.fullScreen) else{message="Выйдите из полноэкранного режима";return}
        host=window;message="Подключаю окно Apple…";let token=UUID();generation=token
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.ScreenContinuity") else{message="Видеоповтор не найден";return}
        let config=NSWorkspace.OpenConfiguration();config.activates=false
        NSWorkspace.shared.openApplication(at:url,configuration:config){_,_ in}
        Task{
            for _ in 0..<30{
                guard generation==token else{return}
                if let target=locate(),let phoneSize=size(target),phoneSize.width>100,phoneSize.height>300,let screen=window.screen {
                    guard screen.visibleFrame.width>=720+phoneSize.width+16,screen.visibleFrame.height>=phoneSize.height+65 else{message="На этом экране не помещаются три устройства";return}
                    source=target;originalPosition=point(target)
                    oldHostFrame=window.frame;oldMinimum=window.minSize
                    enabled=true;unhide();moveAlongside();return
                }
                try? await Task.sleep(nanoseconds:100_000_000)
            }
            if generation==token{message="Откройте видеоповтор и подключите iPhone"}
        }
    }
    func place(raise:Bool=false){
        guard enabled,let source,let window=host,!window.isMiniaturized,!NSApp.isHidden,let phoneSize=size(source),let top=NSScreen.screens.first?.frame.maxY else{return}
        let slot=CGRect(x:window.frame.maxX+6,y:window.frame.midY-phoneSize.height/2,width:phoneSize.width,height:phoneSize.height)
        var desired=CGPoint(x:slot.midX-phoneSize.width/2,y:top-slot.midY-phoneSize.height/2)
        let firstPlacement=lastPosition==nil
        if let now=point(source),abs(now.x-desired.x)>1 || abs(now.y-desired.y)>1 {
            if let position=AXValueCreate(.cgPoint,&desired),AXUIElementSetAttributeValue(source,kAXPositionAttribute as CFString,position) == .success{lastPosition=desired}
            else{if message != "macOS не разрешила переместить окно Apple"{message="macOS не разрешила переместить окно Apple"}}
        }
        if lastPosition==nil{lastPosition=point(source)}
        if raise || firstPlacement{
            AXUIElementPerformAction(source,kAXRaiseAction as CFString)
        }
    }
    func moveAlongside(){
        guard enabled,let host,let screen=host.screen,let source,let phoneSize=size(source) else{return}
        if let oldMinimum{host.minSize=oldMinimum}
        var frame=host.frame
        frame.size.width=min(max(720,oldHostFrame?.width ?? 955),screen.visibleFrame.width-phoneSize.width-12)
        frame.origin.x=min(max(screen.visibleFrame.minX,frame.minX),screen.visibleFrame.maxX-frame.width-phoneSize.width-12)
        host.setFrame(frame,display:true);adjustedHostFrame=frame
        message="Отдельное окно · связано с пультом";place(raise:true)
    }
    private func hide(){
        guard enabled,let source else{return}
        var current:CFTypeRef?;AXUIElementCopyAttributeValue(source,kAXMinimizedAttribute as CFString,&current)
        guard current as? Bool != true else{return}
        hiddenByUs=AXUIElementSetAttributeValue(source,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success
        if hiddenByUs{message="Окно Apple свёрнуто вместе с пультом"}
    }
    private func unhide(){
        guard let source else{return}
        if hiddenByUs{AXUIElementSetAttributeValue(source,kAXMinimizedAttribute as CFString,kCFBooleanFalse);hiddenByUs=false;message="Отдельное окно · связано с пультом"}
    }
    func disable(){
        generation=UUID();unhide()
        if let source,let lastPosition,let now=point(source),abs(now.x-lastPosition.x)<3,abs(now.y-lastPosition.y)<3,var originalPosition,let value=AXValueCreate(.cgPoint,&originalPosition){AXUIElementSetAttributeValue(source,kAXPositionAttribute as CFString,value)}
        enabled=false;source=nil;originalPosition=nil;lastPosition=nil
        if let host,let oldMinimum{host.minSize=oldMinimum}
        if let host,let oldHostFrame,let adjustedHostFrame,abs(host.frame.width-adjustedHostFrame.width)<4{
            var frame=host.frame;frame.size.width=oldHostFrame.width
            if let screen=host.screen{frame.origin.x=min(frame.minX,screen.visibleFrame.maxX-frame.width)}
            host.setFrame(frame,display:true)
        }
        host=nil;oldHostFrame=nil;adjustedHostFrame=nil;oldMinimum=nil;message=""
    }
}
