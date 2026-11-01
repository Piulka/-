import AppKit
import SwiftUI
import CoreText

enum MarkTool:String,CaseIterable,Identifiable {
    case arrow,line,ellipse,rectangle,pen,text
    var id:String{rawValue}
    var title:String{switch self{case .arrow:return "Стрелка";case .line:return "Линия";case .ellipse:return "Овал";case .rectangle:return "Рамка";case .pen:return "Перо";case .text:return "Текст"}}
    var symbol:String{switch self{case .arrow:return "arrow.up.right";case .line:return "line.diagonal";case .ellipse:return "oval";case .rectangle:return "rectangle";case .pen:return "pencil.tip";case .text:return "textformat"}}
}
struct ScreenshotMark {
    var tool:MarkTool
    var points:[CGPoint]
    var color:CGColor
    var width:CGFloat
    var text:String=""
}
@MainActor final class AnnotationDocument:ObservableObject {
    let image:CGImage
    let names:[String]
    @Published var tool:MarkTool = .arrow
    @Published var color:Color = .red
    @Published var width:Double=3
    @Published var text=""
    @Published var marks:[ScreenshotMark]=[]
    @Published var active:ScreenshotMark?
    private var history:[[ScreenshotMark]]=[]
    var canUndo:Bool{!history.isEmpty}
    init(image:CGImage,names:[String]){self.image=image;self.names=names}
    func begin(_ point:CGPoint){
        guard tool != .text || !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        let mark=ScreenshotMark(tool:tool,points:[point,point],color:NSColor(color).usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.red.cgColor,width:width,text:String(text.prefix(200)))
        if tool == .text{history.append(marks);marks.append(mark)}else{active=mark}
    }
    func move(_ point:CGPoint){
        guard var mark=active else{return}
        if mark.tool == .pen{mark.points.append(point)}else{mark.points[mark.points.count-1]=point}
        active=mark
    }
    func end(){
        guard let active else{return};self.active=nil
        let first=active.points.first!,last=active.points.last!
        if hypot(last.x-first.x,last.y-first.y)>0.002 || active.points.count>3{history.append(marks);marks.append(active)}
    }
    func undo(){guard let previous=history.popLast() else{return};marks=previous;active=nil}
    func clear(){guard !marks.isEmpty else{return};history.append(marks);marks=[];active=nil}
    func export()throws->CGImage {
        guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw MediaFailure("Не хватило памяти для разметки")}
        context.translateBy(x:0,y:CGFloat(image.height));context.scaleBy(x:1,y:-1)
        MarkRenderer.draw(image:image,marks:marks,in:context,rect:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let result=context.makeImage() else{throw MediaFailure("Не удалось сохранить разметку")};return result
    }
}

enum MarkRenderer {
    // The drawing coordinates have a top-left origin, both in the editor and in the exported PNG.
    static func draw(image:CGImage,marks:[ScreenshotMark],in context:CGContext,rect:CGRect){
        context.saveGState()
        context.translateBy(x:rect.minX,y:rect.maxY);context.scaleBy(x:1,y:-1)
        context.draw(image,in:CGRect(origin:.zero,size:rect.size));context.restoreGState()
        let unit=max(rect.width,rect.height)/1000
        for mark in marks {
            guard let origin=mark.points.first else{continue}
            func map(_ p:CGPoint)->CGPoint{CGPoint(x:rect.minX+p.x*rect.width,y:rect.minY+p.y*rect.height)}
            let a=map(origin),b=map(mark.points.last ?? origin),thickness=max(1,mark.width*unit)
            context.saveGState();context.setStrokeColor(mark.color);context.setFillColor(mark.color);context.setLineWidth(thickness);context.setLineCap(.round);context.setLineJoin(.round)
            let bounds=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
            switch mark.tool {
            case .arrow,.line:
                context.move(to:a);context.addLine(to:b);context.strokePath()
                if mark.tool == .arrow {
                    let angle=atan2(b.y-a.y,b.x-a.x),length=max(13*unit,thickness*4)
                    context.move(to:CGPoint(x:b.x-length*cos(angle-0.45),y:b.y-length*sin(angle-0.45)));context.addLine(to:b);context.addLine(to:CGPoint(x:b.x-length*cos(angle+0.45),y:b.y-length*sin(angle+0.45)));context.strokePath()
                }
            case .ellipse:context.strokeEllipse(in:bounds)
            case .rectangle:context.stroke(bounds)
            case .pen:
                context.move(to:a);for p in mark.points.dropFirst(){context.addLine(to:map(p))};context.strokePath()
            case .text:
                let font=NSFont.systemFont(ofSize:max(12,22*unit*(mark.width/3)),weight:.semibold)
                let line=CTLineCreateWithAttributedString(NSAttributedString(string:mark.text,attributes:[.font:font,.foregroundColor:NSColor(cgColor:mark.color) ?? .red]))
                context.translateBy(x:a.x,y:a.y+font.ascender);context.scaleBy(x:1,y:-1);context.textMatrix = .identity;context.textPosition = .zero;CTLineDraw(line,context)
            }
            context.restoreGState()
        }
    }
}

@MainActor private final class MarkCanvasView:NSView {
    var document:AnnotationDocument?
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override var mouseDownCanMoveWindow:Bool{false}
    private var imageRect:CGRect {
        guard let image=document?.image else{return .zero}
        return AndroidWire.fittedRect(size:CGSize(width:image.width,height:image.height),bounds:bounds.insetBy(dx:12,dy:12))
    }
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("Разметка скриншота");setAccessibilityIdentifier("annotation.canvas")}
    required init?(coder:NSCoder){fatalError()}
    override func draw(_ dirtyRect:NSRect){
        NSColor(calibratedWhite:0.06,alpha:1).setFill();bounds.fill()
        guard let document,let context=NSGraphicsContext.current?.cgContext else{return}
        MarkRenderer.draw(image:document.image,marks:document.marks+(document.active.map{[$0]} ?? []),in:context,rect:imageRect)
    }
    private func point(_ event:NSEvent,clamp:Bool=false)->CGPoint? {
        let p=convert(event.locationInWindow,from:nil),r=imageRect
        guard r.width>0,r.height>0,clamp || r.contains(p) else{return nil}
        return CGPoint(x:max(0,min(1,(p.x-r.minX)/r.width)),y:max(0,min(1,(p.y-r.minY)/r.height)))
    }
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);if let p=point(event){document?.begin(p);needsDisplay=true}}
    override func mouseDragged(with event:NSEvent){if let p=point(event,clamp:true){document?.move(p);needsDisplay=true}}
    override func mouseUp(with event:NSEvent){document?.end();needsDisplay=true}
    override func keyDown(with event:NSEvent){if event.keyCode==53{document?.active=nil;needsDisplay=true}else{super.keyDown(with:event)}}
}
private struct MarkCanvas:NSViewRepresentable {
    @ObservedObject var document:AnnotationDocument
    func makeNSView(context:Context)->MarkCanvasView{let view=MarkCanvasView();view.document=document;return view}
    func updateNSView(_ view:MarkCanvasView,context:Context){view.document=document;view.needsDisplay=true}
}
struct ScreenshotEditor:View {
    @ObservedObject var document:AnnotationDocument
    @ObservedObject var media:MediaCoordinator
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{
                Text("Разметка").font(.title2.bold());Spacer()
                Button("Отмена"){media.editor=nil}.disabled(media.takingScreenshot).accessibilityIdentifier("annotation.cancel")
                Button("Сохранить"){Task{await media.saveEdited()}}.buttonStyle(.borderedProminent).disabled(media.takingScreenshot).accessibilityIdentifier("annotation.save")
            }
            HStack(spacing:6){
                ForEach(MarkTool.allCases){tool in
                    Button{document.tool=tool}label:{Image(systemName:tool.symbol).frame(width:25,height:23).background(document.tool==tool ? Color.white.opacity(0.17) : .clear,in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title).accessibilityIdentifier("annotation.\(tool.rawValue)")
                }
                Divider().frame(height:20)
                ColorPicker("Цвет",selection:$document.color,supportsOpacity:false).labelsHidden().frame(width:30).help("Цвет разметки")
                Picker("Толщина",selection:$document.width){Text("Тонко").tag(2.0);Text("Средне").tag(3.0);Text("Толсто").tag(5.0)}.labelsHidden().frame(width:90)
                Spacer(minLength:0)
                Button{document.undo()}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!document.canUndo).help("Отменить штрих").accessibilityIdentifier("annotation.undo")
                Button{document.clear()}label:{Image(systemName:"trash")}.disabled(document.marks.isEmpty).help("Очистить разметку").accessibilityIdentifier("annotation.clear")
            }.controlSize(.small)
            if document.tool == .text{TextField("Введите подпись и нажмите на изображение",text:$document.text).textFieldStyle(.roundedBorder).accessibilityIdentifier("annotation.text.input")}
            MarkCanvas(document:document).clipShape(RoundedRectangle(cornerRadius:10)).frame(maxWidth:.infinity,maxHeight:.infinity)
            Text(document.tool == .text ? "Введите текст сверху и нажмите, где поставить подпись." : "Потяните мышью по изображению. Сохранение — в выбранную папку.").font(.caption).foregroundStyle(.secondary)
            if media.failed{Text(media.notice).font(.caption).foregroundStyle(.orange)}
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).preferredColorScheme(.dark)
    }
}

struct MediaSettings:View {
    @ObservedObject var media:MediaCoordinator
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            HStack{Text("Скриншоты и видео").font(.headline);Spacer();Button("Выбрать папку…"){media.chooseFolder()}.accessibilityIdentifier("capture.folder.choose")}
            HStack{
                Image(systemName:"folder").foregroundStyle(.secondary)
                Text(media.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(media.folder.path).accessibilityIdentifier("capture.folder.path")
                Spacer(minLength:0)
                Button{media.showFolder()}label:{Image(systemName:"arrow.up.forward.square")}.help("Открыть папку").accessibilityIdentifier("capture.folder.open")
            }
            Text("PNG · MP4, 30 FPS, без звука. Два устройства — рядом в одном файле. Паузы вырезаются, остановка сохраняет видео автоматически.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}
