import AppKit
import SwiftUI

@MainActor final class OTPBridge:ObservableObject {
    @Published private(set) var working=false
    @Published private(set) var connected=false
    @Published private(set) var message=""
    @Published private(set) var failed=false
    @Published private(set) var adminDoor:String?
    @Published private(set) var adminMessage=""
    @Published private(set) var adminFailed=false
    @Published private(set) var adminRevision=0
    private(set) var accountID=""
    private var monitoring:Task<Void,Never>?
    private var operation:Task<Void,Never>?
    private let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Жмякее/OTPBridge",isDirectory:true)
    init(){
        monitoring=Task{[weak self] in
            while !Task.isCancelled{
                self?.updateConnection()
                try? await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }
    private func updateConnection(){
        let value=(try? Data(contentsOf:root.appendingPathComponent("state.json"))).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let time=value?["time"] as? Double ?? 0
        let active=(0..<8).contains(Date().timeIntervalSince1970-time)
        if active != connected{connected=active}
    }
    func prepare(){
        guard !working,let script=Bundle.main.url(forResource:"install",withExtension:"py",subdirectory:"ChromeOTPBridge") else{return}
        working=true;accountID="";message="Готовлю расширение…";failed=false
        Task{
            defer{working=false}
            let result=await LocalProcess.run("/usr/bin/python3",[script.path],timeout:8)
            guard result.0==0 else{failed=true;message="Не удалось подготовить расширение Chrome";return}
            message="Загрузите папку extension в Chrome → Расширения → Загрузить распакованное"
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("extension",isDirectory:true)])
        }
    }
    func showFolder(){NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("extension",isDirectory:true)])}
    func showRedis(){
        guard let chrome=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome"),let url=URL(string:OTPRules.browserURL) else{return}
        NSWorkspace.shared.open([url],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration())
    }
    func check(){perform(action:"ping",phone:nil,id:"")}
    func inspect(phone:String,id:String){perform(action:"inspect",phone:phone,id:id)}
    func reset(phone:String,id:String){perform(action:"reset",phone:phone,id:id)}
    func readAdmin(){perform(action:"admin_read",phone:nil,id:"")}
    func saveDoor(_ value:String,expected:String){perform(action:"admin_door",phone:nil,id:"",value:value,expected:expected)}
    func clearAdminCache(){perform(action:"admin_cache",phone:nil,id:"")}
    func showAdmin(){
        guard let chrome=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome"),let url=URL(string:AdminRules.url) else{return}
        NSWorkspace.shared.open([url],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration())
    }
    private func perform(action:String,phone:String?,id:String,value:String?=nil,expected:String?=nil){
        guard !working else{return}
        let admin=["admin_read","admin_door","admin_cache"].contains(action)
        func report(_ text:String,error:Bool=false){
            if admin{adminMessage=text;adminFailed=error}else{message=text;failed=error}
        }
        updateConnection()
        guard connected else{report("Подключите расширение Chrome в настройках OTP",error:true);return}
        guard admin || action == "ping" || phone.map({OTPRules.valid(phone:$0,stand:"08")}) == true else{failed=true;message=OTPRules.message("invalid_phone");return}
        if action == "admin_door",!(AdminRules.states.contains(value ?? "") && AdminRules.states.contains(expected ?? "")){report(AdminRules.message("invalid_request"),error:true);return}
        working=true;accountID=id
        report(admin ? (action == "admin_read" ? "Загружаю настройки…" : action == "admin_cache" ? "Сбрасываю GO + PHP…" : "Сохраняю Door to Door и сбрасываю кэш…") : action == "reset" ? "Сбрасываю OTP test08…" : "Проверяю RedisInsight…")
        operation=Task{[self] in
            defer{working=false;operation=nil}
            let queue=root.appendingPathComponent("queue",isDirectory:true),requestID=UUID().uuidString
            let request=queue.appendingPathComponent("request-\(requestID).json"),response=queue.appendingPathComponent("response-\(requestID).json")
            defer{try? FileManager.default.removeItem(at:request);try? FileManager.default.removeItem(at:response)}
            do {
                try FileManager.default.createDirectory(at:queue,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                // Payloads are transient IPC, never logs or account storage.
                for file in (try? FileManager.default.contentsOfDirectory(at:queue,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] {
                    if let date=(try? file.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,Date().timeIntervalSince(date)>90{try? FileManager.default.removeItem(at:file)}
                }
                var task:[String:Any]=["id":requestID,"stand":"08","operation":action,"created":Date().timeIntervalSince1970]
                if let phone{task["phone"]=phone}
                if admin{task["city"]=590}
                if let value{task["value"]=value}
                if let expected{task["expected"]=expected}
                let data=try JSONSerialization.data(withJSONObject:task)
                // umask cannot be assumed for a GUI process. Use a protected temporary file then rename.
                let temporary=queue.appendingPathComponent("\(requestID).tmp")
                guard FileManager.default.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw AuthFailure("Не удалось связаться с Chrome")}
                try FileManager.default.moveItem(at:temporary,to:request)
                let until=Date().addingTimeInterval(36)
                repeat {
                    if let bytes=try? Data(contentsOf:response),bytes.count<16384,let result=try JSONSerialization.jsonObject(with:bytes) as? [String:Any]{
                        if admin{
                            guard result["ok"] as? Bool == true else{throw AuthFailure(AdminRules.message(result["code"] as? String ?? "admin_connection_error",saved:result["saved"] as? Bool == true,go:result["go"] as? Bool == true,php:result["php"] as? Bool == true))}
                            guard let success=AdminRules.success(result,action:action,value:value) else{throw AuthFailure(AdminRules.message("admin_unverified"))}
                            if let door=result["door"] as? String{adminDoor=door;adminRevision+=1}
                            report(success)
                        }else{
                            guard result["ok"] as? Bool == true else{throw AuthFailure(OTPRules.message(result["code"] as? String ?? "connection_error"))}
                            guard let success=OTPRules.successMessage(result,action:action) else{throw AuthFailure(OTPRules.message(action == "reset" ? "reset_unverified" : "unexpected_response"))}
                            report(success)
                        }
                        return
                    }
                    try await Task.sleep(nanoseconds:150_000_000)
                }while Date()<until
                throw AuthFailure(admin ? AdminRules.message("timeout") : OTPRules.message("timeout"))
            }catch{
                if admin && action != "admin_cache"{adminDoor=nil}
                report((error as? AuthFailure)?.message ?? "Не удалось связаться с Chrome",error:true)
            }
        }
    }
    func finishBeforeQuit()async{while working{try? await Task.sleep(nanoseconds:100_000_000)}}
}

struct OTPBridgeSettings:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var bridge:OTPBridge
    @State private var selected=""
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Label(bridge.connected ? "Расширение Chrome подключено" : "Расширение Chrome не подключено",systemImage:bridge.connected ? "checkmark.circle" : "link")
            Text("Мост test08: RedisInsight для OTP и админка Калуги. Учётные данные остаются в Chrome.").font(.caption).foregroundStyle(.secondary)
            HStack{Button("Подготовить расширение"){bridge.prepare()}.accessibilityIdentifier("otp.prepare");Button("Показать папку"){bridge.showFolder()}.accessibilityIdentifier("otp.folder")}.disabled(bridge.working)
            Text("В Chrome откройте chrome://extensions, включите «Режим разработчика» и выберите «Загрузить распакованное» → папка extension.").font(.caption).foregroundStyle(.secondary)
            HStack{Button("Открыть RedisInsight"){bridge.showRedis()};Button("Проверить подключение"){bridge.check()}.disabled(bridge.working).accessibilityIdentifier("otp.check")}
            HStack{
                Picker("Аккаунт test08",selection:$selected){Text("Выберите аккаунт").tag("");ForEach(model.accounts(on:"08")){Text($0.label).tag($0.id)}}.disabled(bridge.working)
                Button("Найти ключи"){
                    if let phone=AccountVault.read(selected){bridge.inspect(phone:phone,id:selected)}
                }.disabled(bridge.working || selected.isEmpty).accessibilityIdentifier("otp.inspect")
            }
            if !bridge.message.isEmpty{Text(bridge.message).font(.caption).foregroundStyle(bridge.failed ? .orange : .secondary).accessibilityIdentifier("otp.status")}
        }
    }
}
