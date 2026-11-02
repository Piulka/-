import AppKit
import SwiftUI
import Combine

enum DeviceShortcut:String,CaseIterable,Identifiable {
    case drivee,deeplink,geo
    var id:String{rawValue}
    var title:String{switch self{case .drivee:return "Drivee";case .deeplink:return "Deeplink";case .geo:return "GeoLab"}}
    var package:String{switch self{case .drivee:return "com.drivee.taxi.rides";case .deeplink:return "com.app.deeplinktester";case .geo:return "ru.driveelab.geo"}}
}

struct AndroidDevice: Identifiable {
    let id: String
    var name: String
    var state: String
    var build: String = ""
}

enum LocalProcess {
    static func run(_ path: String, _ arguments: [String], timeout: Double = 10, captureErrors:Bool=false) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = captureErrors ? pipe : FileHandle.nullDevice
            do { try process.run() } catch { return (-1, "") }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}

@MainActor final class DeskModel:ObservableObject {
    @Published var devices:[AndroidDevice]=[]
    @Published var selection:[String]=["",""]
    @Published var refreshing=false
    @Published var accounts=AccountVault.accounts()
    @Published var accountSelection=["",""]
    @Published var stands=["08","08"] {didSet{reconcileAccountSelection()}}
    @Published var iphoneAccount=""
    @Published var iphoneStand="08" {didSet{reconcileAccountSelection()}}
    @Published var closingSlots:Set<Int>=[]
    let authorizations=[AndroidAccountAction(),AndroidAccountAction()]
    let iosAuthorization=IOSAccountAction()
    let media=MediaCoordinator()
    let deepLinks=DeepLinkCoordinator()
    let builds=BuildLibrary()
    let androidRepeat=AndroidRepeat()
    let otp=OTPBridge()
    private var repeatObservation:AnyCancellable?
    private var otpObservation:AnyCancellable?
    private var connectionObservation:AnyCancellable?
    @Published var installingDevices:Set<String>=[]
    func isInstalling(_ slot:Int)->Bool{installingDevices.contains(selection[slot])}
    @Published var status="Подключите устройства по USB"
    @Published var adbPath:String { didSet { UserDefaults.standard.set(adbPath,forKey:"adbPath") } }
    @Published var autoConnect:Bool { didSet { UserDefaults.standard.set(autoConnect,forKey:"autoConnect") } }
    @Published var quality:Int { didSet { UserDefaults.standard.set(quality,forKey:"quality") } }
    @Published var fps:Int { didSet { UserDefaults.standard.set(fps,forKey:"fps") } }
    let sessions=[EmbeddedAndroid(),EmbeddedAndroid()]
    private var tasks:[Task<Void,Never>?]=[nil,nil]
    init() {
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        let paths=["\(home)/.local/bin/adb","/opt/homebrew/bin/adb","/usr/local/bin/adb",Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tools/scrcpy/adb").path]
        let saved=UserDefaults.standard.string(forKey:"adbPath") ?? ""
        adbPath = !saved.isEmpty && FileManager.default.isExecutableFile(atPath:saved) ? saved : (paths.first { FileManager.default.isExecutableFile(atPath:$0) } ?? "")
        autoConnect=UserDefaults.standard.object(forKey:"autoConnect") as? Bool ?? true
        quality=UserDefaults.standard.object(forKey:"quality") as? Int ?? 1280
        fps=UserDefaults.standard.object(forKey:"fps") as? Int ?? 30
        reconcileAccountSelection()
        media.model=self
        deepLinks.model=self
        builds.model=self
        androidRepeat.model=self
        repeatObservation=androidRepeat.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}
        otpObservation=otp.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}
        connectionObservation=Publishers.MergeMany(sessions.map{$0.$connected.removeDuplicates().map{_ in ()}.eraseToAnyPublisher()}).sink{[weak self] _ in
            Task{@MainActor in
                guard let self else{return};self.objectWillChange.send()
                if self.androidRepeat.engaged,!self.sessions.allSatisfy({$0.connected}){await self.androidRepeat.stop(message:"Поток отключён · повтор выключен")}
            }
        }
    }
    func refresh() async {
        reloadAccounts()
        guard !refreshing else { return };refreshing=true;defer { refreshing=false }
        guard FileManager.default.isExecutableFile(atPath:adbPath) else { status="Укажите путь ADB в настройках";return }
        let (code,output)=await LocalProcess.run(adbPath,["devices","-l"])
        guard code==0 else { status="Не удалось подключиться к ADB";return }
        var found:[AndroidDevice]=[]
        for line in output.split(separator:"\n") {
            let p=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard p.count>=2,["device","unauthorized","offline"].contains(p[1]) else { continue }
            var d=AndroidDevice(id:p[0],name:p.first(where:{$0.hasPrefix("model:")})?.dropFirst(6).replacingOccurrences(of:"_",with:" ") ?? "Android",state:p[1])
            if d.state=="device" {
                let (_,info)=await LocalProcess.run(adbPath,["-s",d.id,"shell","dumpsys","package","com.drivee.taxi.rides"])
                let lines=info.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespaces)}
                let version=lines.first(where:{$0.hasPrefix("versionName=")})?.replacingOccurrences(of:"versionName=",with:"") ?? "Drivee не установлен"
                let build=lines.first(where:{$0.hasPrefix("versionCode=")})?.split(separator:" ").first?.replacingOccurrences(of:"versionCode=",with:"") ?? ""
                d.build=build.isEmpty ? version : "\(version) · \(build)"
                if version.contains("hms") { d.name="Huawei · HMS" };if version.contains("gms") { d.name="POCO · GMS" }
            }
            found.append(d)
        }
        devices=found.sorted{$0.name<$1.name}
        let ready=devices.filter{$0.state=="device"}
        if androidRepeat.engaged,!selection.allSatisfy({serial in ready.contains{$0.id==serial}}){await androidRepeat.stop(message:"Устройство отключено · повтор выключен")}
        for i in 0..<2 {
            if selection[i].isEmpty,let d=ready.first(where:{!selection.contains($0.id)}) { selection[i]=d.id }
            if !selection[i].isEmpty,!ready.contains(where:{$0.id==selection[i]}) { sessions[i].stop() }
            if autoConnect,!sessions[i].connected,!sessions[i].busy,!selection[i].isEmpty,ready.contains(where:{$0.id==selection[i]}) { connect(i) }
        }
        status=ready.isEmpty ? "Подключите Android по USB и разрешите отладку" : "Устройств доступно: \(ready.count)"
    }
    func poll() async {
        guard !refreshing,!Task.isCancelled else { return }
        let (code,text)=await LocalProcess.run(adbPath,["devices","-l"])
        guard code==0,!Task.isCancelled else { return }
        let state=Set(text.split(separator:"\n").compactMap { line -> String? in
            let p=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard p.count>=2,["device","unauthorized","offline"].contains(p[1]) else { return nil }
            return p[0]+":"+p[1]
        })
        if state != Set(devices.map{$0.id+":"+$0.state}) { await refresh() }
    }
    func stopAll() {
        Task{await androidRepeat.stop()}
        for i in 0..<2 { tasks[i]?.cancel();sessions[i].stop();authorizations[i].cancel() };iosAuthorization.cancel()
    }
    func choose(_ id:String,slot:Int) {
        guard !androidRepeat.engaged else{status="Сначала выключите повтор нажатий";return}
        guard selection[slot] != id,!authorizations[slot].running,!authorizations[1-slot].running,closingSlots.isEmpty,installingDevices.isEmpty else { return }
        let other=1-slot,previous=selection[slot]
        if selection[other]==id,!id.isEmpty {
            tasks[other]?.cancel();sessions[other].stop();selection[other]=previous
            if autoConnect,!previous.isEmpty { connect(other) }
        }
        tasks[slot]?.cancel();sessions[slot].stop();selection[slot]=id
        if autoConnect,!id.isEmpty { connect(slot) }
    }
    func connect(_ slot:Int) {
        guard let d=devices.first(where:{$0.id==selection[slot] && $0.state=="device"}) else { return }
        tasks[slot]?.cancel()
        tasks[slot]=Task { await sessions[slot].start(serial:d.id,adb:adbPath,maxSize:quality,fps:fps) }
    }
    func toggle(_ slot:Int) {
        guard !androidRepeat.engaged else{status="Сначала выключите повтор нажатий";return}
        if sessions[slot].connected || sessions[slot].busy { tasks[slot]?.cancel();sessions[slot].stop() } else { connect(slot) }
    }
    func openShortcut(_ shortcut:DeviceShortcut,slot:Int) {
        guard !androidRepeat.engaged else{status="Сначала выключите повтор нажатий";return}
        let serial=selection[slot]
        guard !serial.isEmpty,sessions[slot].connected,!closingSlots.contains(slot),!isInstalling(slot) else{return}
        let adb=adbPath
        Task {
            let resolved=await LocalProcess.run(adb,["-s",serial,"shell","cmd","package","resolve-activity","--brief","-a","android.intent.action.MAIN","-c","android.intent.category.LAUNCHER","-p",shortcut.package])
            guard selection[slot]==serial,sessions[slot].connected else{return}
            guard resolved.0==0,let component=resolved.1.split(separator:"\n").map({$0.trimmingCharacters(in:.whitespacesAndNewlines)}).first(where:{$0.hasPrefix(shortcut.package+"/")}) else{status="\(shortcut.title) не найден на выбранном устройстве";return}
            let result=await LocalProcess.run(adb,["-s",serial,"shell","am","start","-W","-a","android.intent.action.MAIN","-c","android.intent.category.LAUNCHER","-n",component])
            let success=result.0==0 && result.1.contains("Status: ok") && !result.1.localizedCaseInsensitiveContains("error") && !result.1.contains("Exception")
            status=success ? "\(shortcut.title) открыт на выбранном устройстве" : "Не удалось открыть \(shortcut.title)"
        }
    }
    func forceCloseCurrentApp(_ slot:Int){
        guard !androidRepeat.engaged else{status="Сначала выключите повтор нажатий";return}
        let serial=selection[slot],adb=adbPath
        guard !serial.isEmpty,sessions[slot].connected,!authorizations[slot].running,!closingSlots.contains(slot),!isInstalling(slot) else{return}
        closingSlots.insert(slot)
        status="Закрываю текущее приложение…"
        Task {
            defer{closingSlots.remove(slot)}
            let current=await LocalProcess.run(adb,["-s",serial,"shell","dumpsys","activity","activities"],timeout:4)
            guard current.0==0,let package=AndroidForeground.package(in:current.1) else{status="Не найдено текущее приложение";return}
            let launcher=await LocalProcess.run(adb,["-s",serial,"shell","cmd","package","resolve-activity","--brief","-a","android.intent.action.MAIN","-c","android.intent.category.HOME"],timeout:3)
            let home=launcher.1.split(separator:"\n").last(where:{$0.contains("/")})?.split(separator:"/").first.map(String.init)
            guard launcher.0==0,home != nil else{status="Не удалось проверить системный интерфейс";return}
            guard !AndroidForeground.isProtected(package,home:home) else{status="На экране системный интерфейс — закрывать нечего";return}
            guard selection[slot]==serial,sessions[slot].connected else{return}
            let result=await LocalProcess.run(adb,["-s",serial,"shell","am","force-stop","--user","current",package],timeout:4)
            guard result.0==0 else{status="Не удалось закрыть приложение";return}
            try? await Task.sleep(nanoseconds:200_000_000)
            let after=await LocalProcess.run(adb,["-s",serial,"shell","dumpsys","activity","activities"],timeout:4)
            guard after.0==0 else{status="Команда закрытия отправлена; проверьте экран";return}
            let name=DeviceShortcut.allCases.first(where:{$0.package==package})?.title ?? package
            status=AndroidForeground.package(in:after.1)==package ? "Приложение осталось открытым" : "\(name) закрыт принудительно"
        }
    }
    func showMirror() {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.ScreenContinuity") else { status="Видеоповтор iPhone не найден";return }
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
    func accounts(on stand:String)->[TestAccount]{accounts.filter{$0.stand==stand}}
    var environmentLabel:String {
        let chosen=QAEnvironment.all.filter{stands.contains($0.id) || iphoneStand==$0.id}
        return chosen.map(\.title).joined(separator:" · ")
    }
    func reconcileAccountSelection(){
        for i in 0..<2 {let available=accounts(on:stands[i]);if !available.contains(where:{$0.id==accountSelection[i]}){accountSelection[i]=available.first?.id ?? ""}}
        let available=accounts(on:iphoneStand)
        if !available.contains(where:{$0.id==iphoneAccount}){iphoneAccount=available.first?.id ?? ""}
    }
    func reloadAccounts(){accounts=AccountVault.accounts();reconcileAccountSelection()}
    func login(_ slot:Int){
        guard !otp.working else{status="Дождитесь завершения сброса OTP";return}
        guard !androidRepeat.engaged else{status="Сначала выключите повтор нажатий";return}
        guard !selection[slot].isEmpty,!isInstalling(slot) else{return}
        guard accounts(on:stands[slot]).contains(where:{$0.id==accountSelection[slot]}),let phone=AccountVault.read(accountSelection[slot]),let otp=AccountVault.read("otp") else{authorizations[slot].message="Добавьте аккаунт на вкладке «Аккаунты»";return}
        authorizations[slot].start(adb:adbPath,serial:selection[slot],phone:phone,otp:otp,stand:stands[slot])
    }
    func loginIPhone(){
        guard !otp.working else{status="Дождитесь завершения сброса OTP";return}
        guard !installingDevices.contains("iphone") else{return}
        guard accounts(on:iphoneStand).contains(where:{$0.id==iphoneAccount}),let phone=AccountVault.read(iphoneAccount),let otp=AccountVault.read("otp") else{iosAuthorization.message="Добавьте аккаунт на вкладке «Аккаунты»";return}
        iosAuthorization.start(phone:phone,otp:otp,stand:iphoneStand)
    }
    func resetOTP(accountID:String,stand:String){
        guard stand == "08",accounts(on:"08").contains(where:{$0.id==accountID}),let phone=AccountVault.read(accountID),OTPRules.valid(phone:phone,stand:stand) else{status="Выберите тестовый аккаунт test08 для сброса OTP";return}
        guard !authorizations.contains(where:{$0.running}),!iosAuthorization.running else{status="Дождитесь завершения авторизации перед сбросом OTP";return}
        otp.reset(phone:phone,id:accountID)
    }
    func navigation(_ code:UInt32,slot:Int){
        sessions[slot].key(code)
        if androidRepeat.enabled{sessions[1-slot].key(code)}
    }
    func chooseADB() {
        let picker=NSOpenPanel();picker.canChooseDirectories=false;picker.canChooseFiles=true;picker.message="Выберите исполняемый файл adb"
        picker.begin { response in
            guard response == .OK,let path=picker.url?.path,FileManager.default.isExecutableFile(atPath:path) else { return }
            Task { @MainActor in self.adbPath=path }
        }
    }
}

private let accent=Color(red:0.64,green:0.94,blue:0.18)
private let toolName="Жмякее"

struct PhonePanel:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var session:EmbeddedAndroid
    @ObservedObject var auth:AndroidAccountAction
    let slot:Int
    @State private var expanded=false
    private var deviceName:String {model.devices.first(where:{$0.id==model.selection[slot]})?.name ?? "Android \(slot+1)"}
    var body:some View {
        VStack(spacing:0) {
            Button {withAnimation(.easeInOut(duration:0.16)){expanded.toggle()}} label:{
                HStack(spacing:8){
                    Circle().fill(session.connected ? accent : Color.gray).frame(width:6,height:6)
                    Text(deviceName).font(.system(size:12,weight:.semibold)).lineLimit(1)
                    Spacer(minLength:4)
                    if session.busy{ProgressView().controlSize(.mini)}
                    Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal,12).frame(height:36).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("device.\(slot).header").help(expanded ? "Свернуть управление" : "Выбрать устройство и аккаунт")
            if expanded {
                VStack(alignment:.leading,spacing:8){
                    HStack(spacing:6){
                        Picker("Устройство",selection:Binding(get:{model.selection[slot]},set:{model.choose($0,slot:slot)})) {
                            Text("Выберите Android").tag("")
                            ForEach(model.devices){d in Text(d.name+(d.state=="device" ? "" : " · \(d.state)")).tag(d.id)}
                        }.labelsHidden().disabled(session.busy || model.authorizations.contains(where:{$0.running}) || !model.closingSlots.isEmpty || !model.installingDevices.isEmpty)
                        Button {model.toggle(slot)} label:{Image(systemName:session.busy ? "xmark" : session.connected ? "power" : "cable.connector")}
                            .help(session.busy ? "Отменить подключение" : session.connected ? "Отключить" : "Подключить").disabled(model.selection[slot].isEmpty || model.closingSlots.contains(slot))
                    }
                    Text(model.devices.first(where:{$0.id==model.selection[slot]})?.build ?? "USB · Android").font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing:6){
                        Picker("Аккаунт",selection:$model.accountSelection[slot]) {
                            Text("Выберите аккаунт").tag("")
                            ForEach(model.accounts(on:model.stands[slot])){Text($0.label).tag($0.id)}
                        }.labelsHidden().frame(maxWidth:.infinity).disabled(auth.running || model.isInstalling(slot))
                        Picker("Стенд",selection:$model.stands[slot]){ForEach(QAEnvironment.all){Text($0.shortTitle).tag($0.id)}}.labelsHidden().frame(width:66).help("Стенд").disabled(auth.running || model.isInstalling(slot))
                        if auth.running{Button{auth.cancel()}label:{Image(systemName:"stop.fill")}.help("Остановить")}
                        else{Button("Войти"){model.login(slot)}.accessibilityIdentifier("auth.android.\(slot).login").disabled(model.otp.working || model.accountSelection[slot].isEmpty || model.selection[slot].isEmpty || model.isInstalling(slot))}
                        if model.stands[slot] == "08"{
                            Button{model.resetOTP(accountID:model.accountSelection[slot],stand:model.stands[slot])}label:{Image(systemName:"clock.arrow.circlepath")}
                                .help("Сбросить блокировку OTP выбранного аккаунта test08").accessibilityLabel("Сброс OTP").accessibilityIdentifier("otp.android.\(slot).reset")
                                .disabled(model.otp.working || model.accountSelection[slot].isEmpty || model.authorizations.contains(where:{$0.running}) || model.iosAuthorization.running)
                        }
                    }
                }.controlSize(.small).padding(.horizontal,10).padding(.bottom,10)
            }
            if !auth.message.isEmpty {
                HStack(spacing:6){
                    if auth.running{ProgressView().controlSize(.mini)}
                    if !auth.warning.isEmpty{Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange).help(auth.warning)}
                    Text(auth.message).lineLimit(1).help(auth.message)
                    Spacer(minLength:0)
                    if auth.running && !expanded{Button{auth.cancel()}label:{Image(systemName:"stop.fill")}.buttonStyle(.plain).help("Остановить вход")}
                }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.bottom,7)
            }
            if model.stands[slot] == "08",!model.otp.accountID.isEmpty,model.otp.accountID==model.accountSelection[slot],!model.otp.message.isEmpty{
                Text(model.otp.message).font(.system(size:10)).foregroundStyle(model.otp.failed ? .orange : .secondary).padding(.horizontal,10).padding(.bottom,7).accessibilityIdentifier("otp.android.\(slot).status")
            }
            ZStack {
                Color.black
                AndroidCanvas(session:session)
                if !session.connected {
                    VStack(spacing:12){
                        if session.busy{ProgressView().controlSize(.small)}else{Image(systemName:"iphone.gen3").font(.system(size:34,weight:.ultraLight))}
                        Text(session.state).font(.callout).multilineTextAlignment(.center)
                        if !session.busy{Button("Подключить"){model.connect(slot)}.disabled(model.selection[slot].isEmpty)}
                    }.foregroundStyle(.secondary).padding(20)
                }
            }.clipShape(RoundedRectangle(cornerRadius:11)).padding(.horizontal,6)
            HStack(spacing:8){
                HStack(spacing:12){
                    Button{model.navigation(4,slot:slot)}label:{Image(systemName:"chevron.left")}.help("Назад")
                    Button{model.navigation(3,slot:slot)}label:{Image(systemName:"house")}.help("Домой")
                    Button{model.navigation(187,slot:slot)}label:{Image(systemName:"square.on.square")}.help("Недавние приложения")
                    Button{model.forceCloseCurrentApp(slot)}label:{Image(systemName:"xmark.app").foregroundStyle(.red)}
                        .help("Принудительно закрыть текущее приложение")
                        .accessibilityLabel("Закрыть текущее приложение")
                        .accessibilityIdentifier("device.\(slot).force-close")
                        .disabled(auth.running || model.closingSlots.contains(slot))
                }
                Spacer(minLength:6)
                HStack(spacing:9){
                    ForEach(DeviceShortcut.allCases){shortcut in
                        Button(shortcut.title){model.openShortcut(shortcut,slot:slot)}
                            .fixedSize().help("Открыть \(shortcut.title) на этом устройстве")
                            .accessibilityIdentifier("launch.\(slot).\(shortcut.rawValue)")
                    }
                }
            }.buttonStyle(.plain).font(.system(size:11)).disabled(!session.connected || model.isInstalling(slot)).padding(.horizontal,12).frame(height:36)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.white.opacity(0.06),lineWidth:1))
            .onChange(of:model.accountSelection[slot]){_,_ in if !auth.running{auth.message=""}}
            .onChange(of:model.stands[slot]){_,_ in if !auth.running{auth.message=""}}
    }
}

private struct AccountDraft {var name="";var role="";var digits=""}
private struct PhoneDigitsField:NSViewRepresentable {
    @Binding var digits:String
    static func clean(_ value:String)->String {
        let numbers=value.filter{"0123456789".contains($0)}
        return String((numbers.count==11 && numbers.hasPrefix("258") ? String(numbers.dropFirst(3)) : numbers).prefix(8))
    }
    final class Coordinator:NSObject,NSTextFieldDelegate {
        var parent:PhoneDigitsField
        init(_ parent:PhoneDigitsField){self.parent=parent}
        func controlTextDidChange(_ notification:Notification){
            guard let field=notification.object as? NSTextField else{return}
            let cleaned=PhoneDigitsField.clean(field.stringValue)
            if field.stringValue != cleaned {
                let selection=field.currentEditor()?.selectedRange.location ?? cleaned.count
                field.stringValue=cleaned
                if let editor=field.currentEditor(){editor.string=cleaned;editor.selectedRange=NSRange(location:min(selection,cleaned.count),length:0)}
            }
            parent.digits=cleaned
        }
    }
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->NSTextField {
        let field=NSTextField(string:digits)
        field.placeholderString="8 цифр";field.bezelStyle = .roundedBezel
        field.font = .monospacedSystemFont(ofSize:NSFont.systemFontSize,weight:.regular)
        field.delegate=context.coordinator
        field.setAccessibilityIdentifier("accounts.phone")
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return field
    }
    func updateNSView(_ field:NSTextField,context:Context){
        context.coordinator.parent=self
        if field.stringValue != digits{field.stringValue=digits}
    }
}
struct AccountsView:View {
    @ObservedObject var model:DeskModel
    @State private var stand="08"
    private var stageAccounts:[TestAccount]{model.accounts(on:stand)}
    @State private var selected=""
    @State private var draft=AccountDraft()
    @State private var drafts:[String:AccountDraft]=[:]
    @State private var notice=""
    @State private var isError=false
    @State private var loaded=false
    private var currentIndex:Int? {stageAccounts.firstIndex(where:{$0.id==selected})}
    private var currentPage:Int {currentIndex.map{$0+1} ?? 0}
    private var pages:[Int] {
        let count=stageAccounts.count
        let first=max(0,min((currentIndex ?? 0)-4,max(0,count-10)))
        return Array(first..<min(count,first+10))
    }
    private func load(_ id:String){
        if loaded{drafts[stand+":"+selected]=draft}
        selected=id;notice="";isError=false;loaded=true
        if let cached=drafts[stand+":"+id]{draft=cached;return}
        guard let account=stageAccounts.first(where:{$0.id==id}) else{draft=AccountDraft();return}
        let full=AccountVault.read(id) ?? ""
        draft=AccountDraft(name:account.name,role:account.role,digits:full.hasPrefix("258") ? String(full.dropFirst(3)) : full)
    }
    private func save(){
        do {
            let full="258"+draft.digits
            try AccountVault.validatePhone(full)
            let name=draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty else{throw AuthFailure("Укажите имя аккаунта")}
            let id=selected.isEmpty ? UUID().uuidString : selected
            try AccountVault.save(full,key:id)
            let entry=TestAccount(id:id,name:name,role:draft.role.trimmingCharacters(in:.whitespacesAndNewlines),stand:stand)
            var all=model.accounts
            if let index=all.firstIndex(where:{$0.id==id}){all[index]=entry}else{all.append(entry)}
            AccountVault.saveAccounts(all);model.reloadAccounts()
            if selected.isEmpty{drafts.removeValue(forKey:stand+":")}
            selected=id;draft.name=name;drafts[stand+":"+id]=draft;notice="Сохранено";isError=false
        }catch{notice=error.localizedDescription;isError=true}
    }
    private func remove(){
        let index=currentIndex ?? 0
        AccountVault.remove(selected);drafts.removeValue(forKey:stand+":"+selected)
        AccountVault.saveAccounts(model.accounts.filter{$0.id != selected});model.reloadAccounts()
        loaded=false
        load(stageAccounts.isEmpty ? "" : stageAccounts[min(index,stageAccounts.count-1)].id)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:22){
            HStack(alignment:.top){
                VStack(alignment:.leading,spacing:5){Text("Аккаунты").font(.title2.bold());Text(selected.isEmpty ? "Новый тестовый аккаунт" : "Аккаунт \(currentPage) из \(stageAccounts.count)").font(.callout).foregroundStyle(.secondary)}
                Spacer()
                Button{load("")}label:{Label("Добавить",systemImage:"plus")}.accessibilityIdentifier("accounts.add")
            }
            HStack(spacing:3){
                ForEach(QAEnvironment.all){environment in
                    Button{
                        drafts[stand+":"+selected]=draft;stand=environment.id;loaded=false
                        load(stageAccounts.first?.id ?? "")
                    }label:{Text(environment.shortTitle).font(.system(size:11,weight:.semibold)).frame(maxWidth:.infinity,minHeight:28).background(stand==environment.id ? accent : Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:6)).foregroundStyle(stand==environment.id ? Color.black : Color.primary)}
                    .buttonStyle(.plain).help(environment.title).accessibilityIdentifier("accounts.stand.\(environment.id)")
                }
            }
            if stageAccounts.isEmpty && selected.isEmpty {Text("На этом стенде пока нет аккаунтов").font(.caption).foregroundStyle(.secondary)}
            if !stageAccounts.isEmpty {
                HStack(spacing:4){
                    Button{if let index=currentIndex,index>0{load(stageAccounts[index-1].id)}}label:{Image(systemName:"chevron.left")}
                        .disabled(currentIndex==nil || currentIndex==0).help("Предыдущий аккаунт").accessibilityIdentifier("accounts.previous")
                    Spacer(minLength:0)
                    ForEach(pages,id:\.self){index in
                        Button{load(stageAccounts[index].id)}label:{Text("\(index+1)").font(.system(size:12,weight:.semibold)).frame(width:25,height:28).background(currentIndex==index ? accent : Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:7)).foregroundStyle(currentIndex==index ? Color.black : Color.primary)}
                            .buttonStyle(.plain).help(stageAccounts[index].label).accessibilityIdentifier("accounts.page.\(index+1)")
                    }
                    Spacer(minLength:0)
                    Button{if let index=currentIndex,index+1<stageAccounts.count{load(stageAccounts[index+1].id)}}label:{Image(systemName:"chevron.right")}
                        .disabled(currentIndex==nil || currentIndex==stageAccounts.count-1).help("Следующий аккаунт").accessibilityIdentifier("accounts.next")
                }.controlSize(.small).padding(10).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            }
            VStack(alignment:.leading,spacing:18){
                VStack(alignment:.leading,spacing:7){Text("Имя").font(.callout.weight(.medium));TextField("Например, Заказимир",text:$draft.name).accessibilityIdentifier("accounts.name").textFieldStyle(.roundedBorder)}
                VStack(alignment:.leading,spacing:7){Text("Роль").font(.callout.weight(.medium));TextField("Клиент, автокурьер, пеший курьер…",text:$draft.role).accessibilityIdentifier("accounts.role").textFieldStyle(.roundedBorder)}
                VStack(alignment:.leading,spacing:7){
                    Text("Номер телефона").font(.callout.weight(.medium))
                    HStack(spacing:8){
                        TextField("Код страны",text:.constant("+258")).disabled(true).frame(width:66).textFieldStyle(.roundedBorder).accessibilityIdentifier("accounts.country")
                        PhoneDigitsField(digits:$draft.digits).frame(height:24)
                    }.font(.system(.body,design:.monospaced))
                }
            }
            Text("Только тестовые аккаунты. Данные хранятся локально на этом Mac.").font(.caption).foregroundStyle(.secondary)
            HStack{
                if !selected.isEmpty{Button("Удалить",role:.destructive){remove()}.accessibilityIdentifier("accounts.delete")}
                if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(isError ? Color.orange : accent).lineLimit(2)}
                Spacer()
                Button("Сохранить"){save()}.keyboardShortcut(.defaultAction).accessibilityIdentifier("accounts.save")
            }
        }.padding(26).frame(minWidth:480,maxWidth:.infinity,minHeight:450,alignment:.topLeading).preferredColorScheme(.dark)
            .onAppear{model.reloadAccounts();if !loaded{load(stageAccounts.first?.id ?? "")}}
    }
}

struct IPhoneControls:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var auth:IOSAccountAction
    @State private var expanded=false
    var body:some View {
        VStack(alignment:.leading,spacing:0){
            Button{withAnimation(.easeInOut(duration:0.16)){expanded.toggle()}}label:{
                HStack{Label("iPhone Air",systemImage:"iphone").font(.system(size:12,weight:.semibold));Spacer(minLength:0);Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:9)).foregroundStyle(.secondary)}.contentShape(Rectangle()).padding(.vertical,10)
            }.buttonStyle(.plain).accessibilityIdentifier("device.iphone.header")
            if expanded {
                VStack(alignment:.leading,spacing:8){
                    Picker("Аккаунт",selection:$model.iphoneAccount){Text("Аккаунт").tag("");ForEach(model.accounts(on:model.iphoneStand)){Text($0.label).tag($0.id)}}.labelsHidden().disabled(auth.running)
                    HStack{
                        Picker("Стенд",selection:$model.iphoneStand){ForEach(QAEnvironment.all){Text($0.shortTitle).tag($0.id)}}.labelsHidden().disabled(auth.running)
                        if auth.running{Button{auth.cancel()}label:{Image(systemName:"stop.fill")}}
                        else{Button("Войти"){model.loginIPhone()}.accessibilityIdentifier("auth.iphone.login").disabled(model.otp.working || model.iphoneAccount.isEmpty || model.installingDevices.contains("iphone"))}
                    }
                    Button("Видеоповтор ↗"){model.showMirror()}
                    if model.iphoneStand == "08"{
                        Button("Сброс OTP"){model.resetOTP(accountID:model.iphoneAccount,stand:model.iphoneStand)}
                            .disabled(model.otp.working || model.iphoneAccount.isEmpty || auth.running || model.authorizations.contains(where:{$0.running})).accessibilityIdentifier("otp.iphone.reset")
                    }
                }.controlSize(.small).padding(.bottom,10)
            }
            if !auth.message.isEmpty{
                HStack(alignment:.top,spacing:4){
                    Text(auth.message).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    if auth.running && !expanded{Button{auth.cancel()}label:{Image(systemName:"stop.fill")}.buttonStyle(.plain)}
                }.padding(.bottom,9)
            }
            if model.iphoneStand == "08",!model.otp.accountID.isEmpty,model.otp.accountID==model.iphoneAccount,!model.otp.message.isEmpty{
                Text(model.otp.message).font(.system(size:10)).foregroundStyle(model.otp.failed ? .orange : .secondary).padding(.bottom,9).accessibilityIdentifier("otp.iphone.status")
            }
        }.padding(.horizontal,10).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
            .onChange(of:model.iphoneAccount){_,_ in if !auth.running{auth.message=""}}
            .onChange(of:model.iphoneStand){_,_ in if !auth.running{auth.message=""}}
    }
}

struct SettingsSection<Content:View>:View {
    let title:String
    let id:String
    let content:Content
    @AppStorage private var expanded:Bool
    init(title:String,id:String,@ViewBuilder content:()->Content){
        self.title=title;self.id=id;self.content=content()
        _expanded=AppStorage(wrappedValue:false,"settings.expanded."+id)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:expanded ? 14 : 0){
            Button{withAnimation(.easeInOut(duration:0.16)){expanded.toggle()}}label:{
                HStack{Text(title).font(.headline);Spacer();Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.caption)}.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("settings."+id+".header")
            // Keep editors alive so collapsing a section preserves its unsaved draft.
            VStack(alignment:.leading,spacing:14){content}
                .frame(height:expanded ? nil : 0,alignment:.top).clipped().opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded).disabled(!expanded).accessibilityHidden(!expanded)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
    }
}

struct SettingsView:View {
    @ObservedObject var model:DeskModel
    var body:some View {
        VStack(alignment:.leading,spacing:22){
            Text("Настройки").font(.title2.bold())
            SettingsSection(title:"Устройства и экран",id:"devices"){
                Toggle("Подключать доступные устройства автоматически",isOn:$model.autoConnect)
                HStack{Text("Разрешение потока");Spacer();Picker("Разрешение",selection:$model.quality){Text("960 px").tag(960);Text("1280 px").tag(1280);Text("1600 px").tag(1600)}.labelsHidden().frame(width:140)}
                HStack{Text("Частота кадров");Spacer();Picker("Частота",selection:$model.fps){Text("30 FPS").tag(30);Text("60 FPS").tag(60)}.labelsHidden().frame(width:140)}
                Text("Параметры потока применяются при следующем подключении. Экраны подстраиваются под размер окна.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack{Text("ADB").font(.headline);Spacer();Button("Выбрать…"){model.chooseADB()}}
                TextField("Путь к adb",text:$model.adbPath).textFieldStyle(.roundedBorder).font(.caption.monospaced())
            }
            SettingsSection(title:"Скриншоты и видео",id:"capture"){MediaSettings(media:model.media)}
            SettingsSection(title:"Диплинки и пресеты",id:"deeplinks"){DeepLinkSettings(coordinator:model.deepLinks)}
            SettingsSection(title:"Сброс OTP · test08",id:"otp"){OTPBridgeSettings(model:model,bridge:model.otp)}
            Spacer(minLength:0)
        }.padding(26).frame(minWidth:460,minHeight:460,alignment:.topLeading).preferredColorScheme(.dark)
    }
}

struct DeskView:View {
    @ObservedObject var model:DeskModel
    private enum Tab {case devices,builds,settings,accounts,admin,annotation}
    @State private var tab:Tab = .devices
    @ObservedObject var media:MediaCoordinator
    var body:some View {
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:22){
                ScrollView{VStack(alignment:.leading,spacing:22){
                VStack(alignment:.leading,spacing:10){
                if let url=Bundle.main.url(forResource:"BrandMark",withExtension:"png"),let logo=NSImage(contentsOf:url){
                    Button{tab = .devices}label:{
                        Image(nsImage:logo).resizable().interpolation(.high).scaledToFit().frame(width:52,height:52)
                            .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Устройства").accessibilityIdentifier("brand.logo").help("Открыть устройства")
                }
                VStack(alignment:.leading,spacing:18){
                Button{tab = .devices}label:{Label("Устройства",systemImage:"rectangle.split.2x1").font(.system(size:12,weight:.medium))}.buttonStyle(.plain).foregroundStyle(tab == .devices ? accent : Color.secondary).accessibilityIdentifier("navigation.devices")
                Button{tab = .builds}label:{Label("Сборки",systemImage:"shippingbox").font(.system(size:12))}.buttonStyle(.plain).foregroundStyle(tab == .builds ? accent : Color.secondary).accessibilityIdentifier("navigation.builds")
                Button{tab = .settings}label:{Label("Настройки",systemImage:"slider.horizontal.3").font(.system(size:12))}.buttonStyle(.plain).foregroundStyle(tab == .settings ? accent : Color.secondary).accessibilityIdentifier("navigation.settings")
                Button{tab = .accounts}label:{Label("Аккаунты",systemImage:"person.crop.circle").font(.system(size:12))}.buttonStyle(.plain).foregroundStyle(tab == .accounts ? accent : Color.secondary).accessibilityIdentifier("navigation.accounts")
                Button{tab = .admin}label:{Label("Админка",systemImage:"switch.2").font(.system(size:12))}.buttonStyle(.plain).foregroundStyle(tab == .admin ? accent : Color.secondary).accessibilityIdentifier("navigation.admin")
                }
                }
                RepeatSidebar(model:model,sync:model.androidRepeat)
                DeepLinkSidebar(model:model,coordinator:model.deepLinks)
                MediaSidebar(model:model,media:media){tab = .annotation}
                }.frame(maxWidth:.infinity,alignment:.leading)}.scrollIndicators(.hidden)
                Spacer(minLength:4)
                IPhoneControls(model:model,auth:model.iosAuthorization)
                Label(model.environmentLabel,systemImage:"network").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).help(model.environmentLabel)
            }.padding(.horizontal,16).padding(.top,6).padding(.bottom,14).frame(width:154).background(Color.white.opacity(0.025))
            Divider()
            ZStack(alignment:.topLeading){
            VStack(spacing:6){
                HStack(spacing:12){ForEach(0..<2,id:\.self){i in PhonePanel(model:model,session:model.sessions[i],auth:model.authorizations[i],slot:i)}}
                HStack(spacing:6){
                    if model.refreshing{ProgressView().controlSize(.mini)}else{Circle().fill(accent).frame(width:5,height:5)}
                    Text(model.status).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("USB").font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)
                }.frame(height:14)
            }.padding(12)
                .opacity(tab == .devices ? 1 : 0).allowsHitTesting(tab == .devices).disabled(tab != .devices).accessibilityHidden(tab != .devices)
            ScrollView{AccountsView(model:model).frame(maxWidth:600)}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .opacity(tab == .accounts ? 1 : 0).allowsHitTesting(tab == .accounts).disabled(tab != .accounts).accessibilityHidden(tab != .accounts)
            ScrollView{SettingsView(model:model).frame(maxWidth:600)}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .opacity(tab == .settings ? 1 : 0).allowsHitTesting(tab == .settings).disabled(tab != .settings).accessibilityHidden(tab != .settings)
            ScrollView{AdminView(bridge:model.otp)}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .opacity(tab == .admin ? 1 : 0).allowsHitTesting(tab == .admin).disabled(tab != .admin).accessibilityHidden(tab != .admin)
            BuildsView(model:model,library:model.builds,active:tab == .builds).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .opacity(tab == .builds ? 1 : 0).allowsHitTesting(tab == .builds).disabled(tab != .builds).accessibilityHidden(tab != .builds)
            if let editor=media.editor{ScreenshotEditor(document:editor,media:media).opacity(tab == .annotation ? 1 : 0).allowsHitTesting(tab == .annotation).disabled(tab != .annotation).accessibilityHidden(tab != .annotation)}
            }
        }.frame(minWidth:720,minHeight:580).preferredColorScheme(.dark)
            .task{
                await model.refresh()
                while !Task.isCancelled{do{try await Task.sleep(nanoseconds:3_000_000_000)}catch{break};await model.poll()}
            }
            .onChange(of:tab){_,value in NSApp.keyWindow?.makeFirstResponder(nil);if value == .admin && !model.otp.working{model.otp.readAdmin()}}
            .onChange(of:media.editor == nil){_,empty in if empty && tab == .annotation{tab = .devices}}
            .onDisappear{model.stopAll()}
    }
}

@main struct DeskApp:App {
    @NSApplicationDelegateAdaptor(DeskApplicationDelegate.self) private var delegate
    @StateObject private var model=DeskModel()
    init(){if CommandLine.arguments.contains("--seed"){do{try AccountVault.seed();exit(0)}catch{exit(1)}}}
    private var initial:CGSize {
        let screen=NSScreen.main?.visibleFrame.size ?? CGSize(width:1440,height:900)
        return CGSize(width:max(760,min(1100,screen.width-360)),height:max(620,min(940,screen.height-36)))
    }
    var body:some Scene {
        Window(toolName,id:"main"){DeskView(model:model,media:model.media).onAppear{delegate.media=model.media;delegate.builds=model.builds;delegate.androidRepeat=model.androidRepeat;delegate.otp=model.otp;if let url=Bundle.main.url(forResource:"AppIcon",withExtension:"icns"),let icon=NSImage(contentsOf:url){NSApp.applicationIconImage=icon}}}.defaultSize(width:initial.width,height:initial.height).defaultPosition(.topLeading)
    }
}
