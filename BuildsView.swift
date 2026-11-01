import SwiftUI

struct BuildsView:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var library:BuildLibrary
    var active:Bool
    private let accent=Color(red:0.64,green:0.94,blue:0.18)
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{
                Text("Сборки").font(.title2.bold())
                Spacer()
                if library.refreshing{ProgressView().controlSize(.small)}
                Button{library.chooseFolder()}label:{Label("Папка",systemImage:"folder")}.disabled(library.installing).accessibilityIdentifier("builds.folder")
                Button{Task{await library.refresh()}}label:{Image(systemName:"arrow.clockwise")}.help("Обновить сборки и устройства").disabled(library.installing || library.refreshing).accessibilityIdentifier("builds.refresh")
            }
            Button{library.reveal()}label:{Text(library.folder.path.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")).font(.caption).foregroundStyle(.secondary).lineLimit(1)}.buttonStyle(.plain).help(library.folder.path)
            HStack(spacing:8){
                TextField("Имя, версия, номер сборки…",text:$library.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("builds.search")
                ForEach([("all","Все"),("android","APK"),("ios","IPA")],id:\.0){key,title in
                    Button{library.filter=key}label:{Text(title).font(.caption.weight(.semibold)).padding(.horizontal,9).padding(.vertical,6).background(library.filter==key ? accent : Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:6)).foregroundStyle(library.filter==key ? Color.black : Color.primary)}.buttonStyle(.plain).accessibilityIdentifier("builds.filter.\(key)")
                }
            }.disabled(library.installing)
            Text("\(library.visible.count) файлов · новые сверху").font(.caption).foregroundStyle(.secondary)
            ScrollView{
                LazyVStack(spacing:7){
                    ForEach(library.visible){file in
                        Button{library.select(file.id)}label:{BuildRow(file:file,selected:library.selectedID==file.id)}.buttonStyle(.plain).disabled(library.installing).accessibilityIdentifier("builds.file.\(file.url.lastPathComponent)")
                    }
                    if library.visible.isEmpty && !library.refreshing{Text(library.files.isEmpty ? "Скачайте APK или IPA в эту папку" : "Сборки не найдены по вашему запросу").font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(28)}
                }
            }.frame(minHeight:140,maxHeight:.infinity)
            Divider()
            if let file=library.selected {
                VStack(alignment:.leading,spacing:10){
                    Text(file.url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(2).accessibilityIdentifier("builds.selected")
                    if let meta=file.metadata{Text("\(meta.package) · \(meta.version) · \(meta.build)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)}
                    Text("Установить на").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:135),spacing:7)],spacing:7){
                        ForEach(library.targets){target in
                            Button{library.targetID=target.id}label:{Label(target.title,systemImage:target.platform == .ios ? "iphone" : "smartphone").font(.system(size:11,weight:.medium)).lineLimit(1).frame(maxWidth:.infinity,minHeight:32).padding(.horizontal,6).background(library.targetID==target.id ? accent : Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:8)).foregroundStyle(library.targetID==target.id ? Color.black : Color.primary)}.buttonStyle(.plain).disabled(library.installing || target.platform != file.platform).help(target.platform != file.platform ? "Выберите \(target.platform == .ios ? "IPA" : "APK") для этого устройства" : target.title).accessibilityIdentifier("builds.target.\(target.id)")
                        }
                    }
                    if library.compatibleTargets.isEmpty{Text(file.platform == .ios ? "Подключите iPhone по USB и нажмите обновление" : "Подключите Android по USB").font(.caption).foregroundStyle(.orange)}
                    HStack{
                        Toggle("Открыть после установки",isOn:$library.openAfter).toggleStyle(.checkbox).font(.caption).disabled(library.installing).accessibilityIdentifier("builds.open-after")
                        Spacer()
                        Button{library.install()}label:{Text(library.installing ? "Устанавливаю…" : "Установить").font(.system(size:12,weight:.semibold)).padding(.horizontal,18).frame(height:32).background(library.canInstall ? accent : Color.white.opacity(0.08),in:RoundedRectangle(cornerRadius:8)).foregroundStyle(library.canInstall ? Color.black : Color.secondary)}.buttonStyle(.plain).disabled(!library.canInstall).accessibilityIdentifier("builds.install")
                    }
                }
            }
            if !library.message.isEmpty{
                HStack(alignment:.top,spacing:8){
                    if library.installing{ProgressView().controlSize(.small)}
                    Text(library.message).font(.caption).foregroundStyle(library.failed ? .orange : .secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityIdentifier("builds.status")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            }
        }.padding(24).frame(maxWidth:900,maxHeight:.infinity,alignment:.topLeading)
            .task(id:active){
                guard active else{return};await library.refresh(quiet:!library.files.isEmpty)
                while !Task.isCancelled{do{try await Task.sleep(nanoseconds:5_000_000_000)}catch{return};await library.refresh(quiet:true)}
            }
    }
}
private struct BuildRow:View {
    var file:LocalBuild
    var selected:Bool
    private let accent=Color(red:0.64,green:0.94,blue:0.18)
    var body:some View {
        HStack(alignment:.top,spacing:10){
            Image(systemName:file.platform == .ios ? "apple.logo" : "shippingbox").font(.system(size:19)).foregroundStyle(selected ? accent : .secondary).frame(width:25).padding(.top,2)
            VStack(alignment:.leading,spacing:5){
                HStack(alignment:.top){Text(file.url.lastPathComponent).font(.system(size:12,weight:.semibold)).lineLimit(2).multilineTextAlignment(.leading);Spacer(minLength:8);if let flavor=file.metadata?.flavor,!flavor.isEmpty{Text(flavor).font(.system(size:9,weight:.bold)).padding(.horizontal,5).padding(.vertical,3).background(Color.white.opacity(0.08),in:Capsule())}}
                Text(file.versionLabel).font(.system(size:11)).foregroundStyle(file.error.isEmpty ? Color.secondary : Color.orange).lineLimit(2).multilineTextAlignment(.leading)
                Text(file.modified.formatted(date:.abbreviated,time:.shortened)+" · "+ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file)).font(.system(size:10)).foregroundStyle(.tertiary)
            }
        }.padding(11).frame(maxWidth:.infinity,alignment:.leading).background(selected ? accent.opacity(0.09) : Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(selected ? accent.opacity(0.6) : Color.white.opacity(0.05),lineWidth:1)).contentShape(Rectangle())
    }
}
