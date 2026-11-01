import AppKit
import SwiftUI

@MainActor final class BuildLibrary:ObservableObject {
    weak var model:DeskModel?
    @Published var files:[LocalBuild]=[]
    @Published var selectedID=""
    @Published var targetID=""
    @Published var refreshing=false
    @Published var installing=false
    @Published var message=""
    @Published var failed=false
    @Published var query=""
    @Published var filter="all"
    @Published var iPhones:[InstallationTarget]=[]
    @Published var openAfter:Bool {didSet{UserDefaults.standard.set(openAfter,forKey:"buildOpenAfter")}}
    @Published var folder:URL {didSet{UserDefaults.standard.set(folder.path,forKey:"buildFolder")}}
    private var folderPanel:NSOpenPanel?
    private var cache:[String:(String,BuildMetadata?,String)]=[:]
    var selected:LocalBuild?{files.first{$0.id==selectedID}}
    var targets:[InstallationTarget] {
        let androids=(model?.devices ?? []).filter{$0.state=="device"}.map{InstallationTarget(id:$0.id,title:$0.name,platform:.android)}
        return androids+iPhones
    }
    var compatibleTargets:[InstallationTarget]{targets.filter{$0.platform==selected?.platform}}
    var visible:[LocalBuild]{files.filter{file in
        let platform=filter=="all" || filter==file.platform.rawValue
        let text=[file.url.lastPathComponent,file.metadata?.version ?? "",file.metadata?.build ?? "",file.metadata?.flavor ?? "",file.metadata?.package ?? ""].joined(separator:" ")
        return platform && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
    }}
    var canInstall:Bool{!installing && !refreshing && selected?.metadata != nil && compatibleTargets.contains{$0.id==targetID}}
    init(){
        folder=UserDefaults.standard.string(forKey:"buildFolder").map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0]
        openAfter=UserDefaults.standard.object(forKey:"buildOpenAfter") as? Bool ?? true
    }
    private var inspector:URL?{Bundle.main.url(forResource:"BuildInspector",withExtension:"py")}
    private var aapt:String {
        let home=FileManager.default.homeDirectoryForCurrentUser
        for root in [home.appendingPathComponent("Library/Android/sdk"),URL(fileURLWithPath:ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] ?? "/nonexistent")] {
            let folder=root.appendingPathComponent("build-tools")
            let versions=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []
            if let tool=versions.sorted(by:{$0.lastPathComponent.compare($1.lastPathComponent,options:.numeric) == .orderedDescending}).map({$0.appendingPathComponent("aapt2").path}).first(where:{FileManager.default.isExecutableFile(atPath:$0)}){return tool}
        };return ""
    }
    private func inspect(_ url:URL)async throws->BuildMetadata {
        guard let inspector else{throw BuildFailure("Не найден компонент чтения сборок")}
        let result=await LocalProcess.run("/usr/bin/python3",[inspector.path,"inspect",url.path,aapt],timeout:25)
        guard let data=result.1.data(using:.utf8) else{throw BuildFailure("Не удалось прочитать сборку")}
        if result.0 != 0 {
            let error=(try? JSONSerialization.jsonObject(with:data) as? [String:String])?["error"]
            throw BuildFailure(error ?? "Не удалось прочитать сборку")
        }
        guard let metadata=try? JSONDecoder().decode(BuildMetadata.self,from:data) else{throw BuildFailure("Не удалось прочитать версию приложения")};return metadata
    }
    func select(_ id:String){
        guard !installing else{return};selectedID=id;message="";failed=false
        if let flavor=selected?.metadata?.flavor,!flavor.isEmpty,let matching=compatibleTargets.first(where:{$0.title.localizedCaseInsensitiveContains(flavor)}){targetID=matching.id}
        else if !compatibleTargets.contains(where:{$0.id==targetID}){targetID=compatibleTargets.first?.id ?? ""}
    }
    func refresh(quiet:Bool=false)async {
        guard !refreshing,!installing else{return};refreshing=true;defer{refreshing=false}
        if !quiet{failed=false;message="";cache=cache.filter{$0.value.2.isEmpty}}
        let directory=folder
        do {
            let found=try await Task.detached(priority:.utility){
                try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey],options:[.skipsHiddenFiles]).compactMap{url->LocalBuild? in
                    guard ["apk","ipa"].contains(url.pathExtension.lowercased()) else{return nil}
                    let v=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])
                    guard v.isRegularFile==true else{return nil}
                    return LocalBuild(url:url,size:Int64(v.fileSize ?? 0),modified:v.contentModificationDate ?? .distantPast)
                }.sorted{$0.modified==$1.modified ? $0.url.lastPathComponent<$1.url.lastPathComponent : $0.modified>$1.modified}
            }.value
            files=found.map{var item=$0;if let saved=cache[item.id],saved.0==item.fingerprint{item.metadata=saved.1;item.error=saved.2};return item}
            if !files.contains(where:{$0.id==selectedID}){selectedID=files.first?.id ?? ""}
            for index in files.indices where files[index].metadata==nil && files[index].error.isEmpty {
                do{files[index].metadata=try await inspect(files[index].url)}catch{files[index].error=error.localizedDescription}
                cache[files[index].id]=(files[index].fingerprint,files[index].metadata,files[index].error)
            }
            cache=cache.filter{key,_ in files.contains{$0.id==key}}
            await refreshIPhones()
            if !compatibleTargets.contains(where:{$0.id==targetID}){select(selectedID)}
            if files.isEmpty && !quiet{message="В папке пока нет файлов APK и IPA"}
        }catch{files=[];message="Не удалось открыть папку сборок. Выберите её кнопкой «Папка»";failed=true}
    }
    private func coreDevice(_ args:[String],timeout:Double=15,installation:Bool=false)async throws->[String:Any] {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("zhmakee-build-device-\(UUID().uuidString).json")
        defer{try? FileManager.default.removeItem(at:file)}
        let command=await LocalProcess.run("/usr/bin/xcrun",["devicectl","--timeout",String(Int(timeout))]+args+["--json-output",file.path],timeout:timeout+5)
        let object=(try? Data(contentsOf:file)).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        guard command.0==0,let result=object?["result"] as? [String:Any] else {
            let details=(object?["error"]).flatMap{try? JSONSerialization.data(withJSONObject:$0)}.map{String(decoding:$0,as:UTF8.self)} ?? ""
            throw BuildFailure(installation ? InstallResult.iosError(details) : "Подключите iPhone по USB и проверьте его доступность в Xcode")
        };return result
    }
    private func refreshIPhones()async {
        do {
            let result=try await coreDevice(["list","devices"],timeout:8)
            iPhones=(result["devices"] as? [[String:Any]] ?? []).compactMap{device in
                let properties=device["properties"] as? [String:Any] ?? [:]
                let hardware=properties["hardware"] as? [String:Any] ?? device["hardwareProperties"] as? [String:Any] ?? [:]
                let connection=properties["connection"] as? [String:Any] ?? device["connectionProperties"] as? [String:Any] ?? [:]
                guard hardware["deviceType"] as? String=="iPhone",connection["pairingState"] as? String=="paired",let id=device["identifier"] as? String else{return nil}
                return InstallationTarget(id:id,title:hardware["marketingName"] as? String ?? "iPhone",platform:.ios)
            }
        }catch{iPhones=[]}
    }
    func chooseFolder(){
        guard !installing else{return}
        if let folderPanel{folderPanel.makeKeyAndOrderFront(nil);return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.directoryURL=folder;panel.prompt="Выбрать";panel.message="Папка со сборками APK и IPA";folderPanel=panel
        let complete:(NSApplication.ModalResponse)->Void={[weak self,weak panel] response in
            guard let self else{return};let chosen=panel?.url;self.folderPanel=nil
            if response == .OK,let chosen{self.folder=chosen;self.cache=[:];Task{await self.refresh()}}
        }
        if let window=NSApp.keyWindow{panel.beginSheetModal(for:window,completionHandler:complete)}else{panel.begin(completionHandler:complete)}
    }
    func reveal(){if let selected{NSWorkspace.shared.activateFileViewerSelecting([selected.url])}else{NSWorkspace.shared.open(folder)}}
    func install(){
        guard canInstall,let file=selected,let metadata=file.metadata,let target=compatibleTargets.first(where:{$0.id==targetID}),let model else{return}
        let key=target.platform == .ios ? "iphone" : target.id
        if target.platform == .android,model.androidRepeat.engaged{message="Сначала выключите повтор нажатий";failed=true;return}
        if target.platform == .ios ? model.iosAuthorization.running : model.authorizations.enumerated().contains(where:{model.selection[$0.offset]==target.id && $0.element.running}) || model.closingSlots.contains(where:{model.selection[$0]==target.id}){message="Дождитесь завершения действия на телефоне";failed=true;return}
        guard !model.installingDevices.contains(key) else{return}
        installing=true;model.installingDevices.insert(key);message="Подготавливаю \(file.url.lastPathComponent)…";failed=false
        let adb=model.adbPath,launch=openAfter
        Task {
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("zhmakee-install-\(UUID().uuidString)",isDirectory:true)
            defer{try? FileManager.default.removeItem(at:temporary);model.installingDevices.remove(key);installing=false}
            do {
                try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let snapshot=temporary.appendingPathComponent("build."+file.url.pathExtension.lowercased())
                let values=try file.url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
                guard Int64(values.fileSize ?? -1)==file.size,values.contentModificationDate==file.modified else{throw BuildFailure("Файл изменился. Обновите список и выберите сборку снова")}
                try await Task.detached(priority:.utility){try FileManager.default.copyItem(at:file.url,to:snapshot)}.value
                guard try await inspect(snapshot)==metadata else{throw BuildFailure("Содержимое файла изменилось. Обновите список сборок")}
                message="Устанавливаю на \(target.title)…"
                if target.platform == .android {
                    let result=await LocalProcess.run(adb,["-s",target.id,"install","-r","-d",snapshot.path],timeout:180,captureErrors:true)
                    guard InstallResult.androidSucceeded(code:result.0,output:result.1) else{throw BuildFailure(InstallResult.androidError(result.1))}
                    message="Проверяю установленную версию…"
                    let info=await LocalProcess.run(adb,["-s",target.id,"shell","dumpsys","package",metadata.package])
                    let version=info.1.split(separator:"\n").first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("versionName=")})?.trimmingCharacters(in:.whitespaces).dropFirst(12)
                    let expected=info.1.range(of:"versionCode="+metadata.build+"(?:\\s|$)",options:.regularExpression) != nil
                    guard info.0==0,version.map(String.init)==metadata.version,expected else{throw BuildFailure("Команда установки завершена, но версия на телефоне не подтвердилась")}
                }else{
                    guard let inspector else{throw BuildFailure("Не найден компонент распаковки IPA")}
                    message="Распаковываю подписанную IPA…"
                    let unpacked=await LocalProcess.run("/usr/bin/python3",[inspector.path,"extract",snapshot.path,temporary.appendingPathComponent("Payload").path],timeout:120)
                    let payload=unpacked.1.data(using:.utf8).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:String]}
                    guard unpacked.0==0,let path=payload?["app"] else{throw BuildFailure(payload?["error"] ?? "Не удалось распаковать IPA")}
                    message="Устанавливаю на \(target.title)…"
                    _=try await coreDevice(["device","install","app","--device",target.id,path],timeout:180,installation:true)
                    message="Проверяю установленную версию…"
                    let info=try await coreDevice(["device","info","apps","--device",target.id,"--bundle-id",metadata.package,"--include-all-apps"])
                    guard let app=(info["apps"] as? [[String:Any]])?.first(where:{$0["bundleIdentifier"] as? String==metadata.package}),app["version"] as? String==metadata.version,app["bundleVersion"] as? String==metadata.build else{throw BuildFailure("IPA установлена, но версия не подтвердилась через Xcode")}
                }
                var launchFailed=false
                if launch {
                    message="Открываю приложение…"
                    do{try await openInstalled(metadata,target:target,adb:adb)}catch{launchFailed=true}
                }
                message="Установлено: \(metadata.version) · \(metadata.build) → \(target.title)"+(launchFailed ? ". Открыть приложение не удалось" : "")
                failed=false
                await model.refresh()
            }catch{message=error.localizedDescription;failed=true}
        }
    }
    private func openInstalled(_ metadata:BuildMetadata,target:InstallationTarget,adb:String)async throws {
        if target.platform == .ios{_=try await coreDevice(["device","process","launch","--device",target.id,metadata.package]);return}
        let resolved=await LocalProcess.run(adb,["-s",target.id,"shell","cmd","package","resolve-activity","--brief","-a","android.intent.action.MAIN","-c","android.intent.category.LAUNCHER","-p",metadata.package])
        guard resolved.0==0,let component=resolved.1.split(separator:"\n").map(String.init).first(where:{$0.hasPrefix(metadata.package+"/")}) else{throw BuildFailure("Не найден запуск приложения")}
        let launched=await LocalProcess.run(adb,["-s",target.id,"shell","am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "+AndroidShell.quote(component)])
        guard launched.0==0,launched.1.contains("Status: ok") else{throw BuildFailure("Не удалось открыть приложение")}
    }
}
