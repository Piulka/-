import Foundation
import Darwin
import CryptoKit

enum AccountVault {
    private static var directory:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Drivee QA Desk/Accounts",isDirectory:true)}
    private static func access<T>(write:Bool,_ operation:(inout [String:String])throws->T)throws->T {
        let manager=FileManager.default,folder=directory
        try manager.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        let descriptor=Darwin.open(folder.appendingPathComponent("store.lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor>=0 else{throw AuthFailure("Не удалось открыть хранилище тестовых аккаунтов")}
        defer{Darwin.close(descriptor)}
        guard flock(descriptor,write ? LOCK_EX : LOCK_SH)==0 else{throw AuthFailure("Хранилище аккаунтов занято")}
        defer{flock(descriptor,LOCK_UN)}
        let file=folder.appendingPathComponent("credentials.json")
        var values:[String:String]=[:]
        if manager.fileExists(atPath:file.path){values=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))}
        let result=try operation(&values)
        if write {
            try JSONEncoder().encode(values).write(to:file,options:.atomic)
            try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        return result
    }
    static func read(_ key:String)->String? {try? access(write:false){$0[key]}}
    static func save(_ value:String,key:String)throws {
        do{try access(write:true){$0[key]=value}}catch{throw AuthFailure("Не удалось сохранить тестовый аккаунт")}
    }
    static func remove(_ key:String){_ = try? access(write:true){$0.removeValue(forKey:key)}}
    static func accounts()->[TestAccount] {
        guard let data=UserDefaults.standard.data(forKey:"accounts"),let a=try? JSONDecoder().decode([TestAccount].self,from:data) else{return []};return a
    }
    static func saveAccounts(_ accounts:[TestAccount]){if let data=try? JSONEncoder().encode(accounts){UserDefaults.standard.set(data,forKey:"accounts")}}
    // Runtime seed only: credentials arrive over stdin and never appear in source, argv or logs.
    static func seed()throws {
        guard let job=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as? [String:String],let phone=job["phone"],let name=job["name"] else{throw AuthFailure("invalid_seed")}
        guard phone.range(of:"^258[0-9]{8}$",options:.regularExpression) != nil else{throw AuthFailure("invalid_seed")}
        if let otp=job["otp"]{try validate(phone:phone,otp:otp)}
        var all=accounts();let id=job["id"] ?? UUID().uuidString
        let stand=job["stand"] ?? "08"
        guard QAEnvironment.valid(stand) else{throw AuthFailure("invalid_seed")}
        let entry=TestAccount(id:id,name:name,role:job["role"] ?? "",stand:stand)
        if let index=all.firstIndex(where:{$0.id==id}){all[index]=entry}else{all.append(entry)}
        try save(phone,key:id)
        if let otp=job["otp"]{try save(otp,key:"otp")}
        saveAccounts(all)
    }

    static func validatePhone(_ phone:String)throws {
        guard phone.range(of:"^258[0-9]{8}$",options:.regularExpression) != nil else{throw AuthFailure("Введите ровно 8 цифр после +258")}
    }
    static func validate(phone:String,otp:String)throws {
        guard phone.range(of:"^258[0-9]{8}$",options:.regularExpression) != nil,otp.range(of:"^[0-9]{4}$",options:.regularExpression) != nil else{throw AuthFailure("Нужен номер 258 + 8 цифр и код из 4 цифр")}
    }
}
struct AuthFailure:Error,LocalizedError {let message:String;init(_ s:String){message=s};var errorDescription:String?{message}}

extension LocalProcess {
    static func input(_ path:String,_ arguments:[String],data:Data,timeout:Double=60)async->(Int32,String) {
        await Task.detached {
            let p=Process(),input=Pipe(),output=Pipe();p.executableURL=URL(fileURLWithPath:path);p.arguments=arguments;p.standardInput=input;p.standardOutput=output;p.standardError=FileHandle.nullDevice
            do{try p.run()}catch{return(-1,"")}
            let stop=DispatchWorkItem{if p.isRunning{p.terminate()}}
            DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:stop)
            try? input.fileHandleForWriting.write(contentsOf:data);try? input.fileHandleForWriting.close()
            let result=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();stop.cancel()
            return(p.terminationStatus,String(data:result,encoding:.utf8) ?? "")
        }.value
    }
}

private struct AndroidUIRow:Decodable {
    var id:String,text:String,desc:String,bounds:String
    var center:(String,String)? {
        let regex=try! NSRegularExpression(pattern:"-?[0-9]+")
        let n=regex.matches(in:bounds,range:NSRange(bounds.startIndex...,in:bounds)).compactMap{Range($0.range,in:bounds).flatMap{Int(bounds[$0])}}
        guard n.count==4,n[0]>=0,n[1]>=0,n[2]>n[0],n[3]>n[1],n[2]<20000,n[3]<20000 else{return nil}
        return(String((n[0]+n[2])/2),String((n[1]+n[3])/2))
    }
}

@MainActor final class AndroidAccountAction:ObservableObject {
    @Published var running=false
    @Published var message=""
    @Published var warning=""
    private var task:Task<Void,Never>?
    private var serial="",adb=""
    private var generation=UUID()
    static let stages=["open":"Открываю Drivee…","logout":"Выхожу из аккаунта…","server":"Проверяю стенд…","phone":"Ввожу номер…","otp":"Ввожу код…","verify":"Проверяю вход…"]
    static let errors=["rate_limited":"Лимит попыток на сервере. Повторите через 30 минут","app_missing":"Drivee не установлен","login_screen_unavailable":"Не найден экран входа","server_selector_missing":"Не найден выбор стенда","server_not_found":"Стенд не найден в сборке","country_selector_missing":"Не найден выбор страны","invalid_request":"Проверьте номер, код и стенд","unexpected_screen":"Экран изменился или сервер не ответил","element_missing":"Элемент интерфейса не найден","text_input_failed":"Не удалось заполнить поле","timeout":"Превышено время ожидания","automation_failed":"Не удалось завершить вход"]
    func start(adb:String,serial:String,phone:String,otp:String,stand:String){
        guard !running else{return};self.adb=adb;self.serial=serial;running=true;warning="";message="Подготавливаю устройство…"
        let token=UUID();generation=token;let began=Date()
        task=Task {
            defer{if generation==token{running=false}}
            do {
                guard let apk=Bundle.main.url(forResource:"qa-helper",withExtension:"apk") else{throw AuthFailure("Нет компонента Android-авторизации")}
                let hash=SHA256.hash(data:try Data(contentsOf:apk)).map{String(format:"%02x",$0)}.joined()
                let package=await LocalProcess.run(adb,["-s",serial,"shell","pm","path","local.drivee.qahelper"])
                try Task.checkCancellation()
                if package.0 != 0 || !package.1.contains("package:") || UserDefaults.standard.string(forKey:"helperHash."+serial) != hash {
                    let install=await LocalProcess.run(adb,["-s",serial,"install","--no-incremental","-r","-t",apk.path],timeout:45)
                    guard install.0==0,install.1.contains("Success") else{throw AuthFailure("Разрешите установку QA-компонента на телефоне")}
                    UserDefaults.standard.set(hash,forKey:"helperHash."+serial)
                }
                try Task.checkCancellation()
                try await prepareDriverUI(adb:adb,serial:serial)
                let request=try JSONSerialization.data(withJSONObject:["mode":"auth","phone":phone,"otp":otp,"stand":stand])
                let prepare=await LocalProcess.run(adb,["-s",serial,"shell","run-as local.drivee.qahelper sh -c 'mkdir -p files; rm -f files/status.json files/request.json files/inspection.json'"])
                guard prepare.0==0 else{throw AuthFailure("QA-компонент недоступен")}
                let send=await LocalProcess.input(adb,["-s",serial,"shell","run-as local.drivee.qahelper sh -c 'umask 077; cat > files/request.json'"],data:request)
                guard send.0==0 else{throw AuthFailure("Не удалось передать задание устройству")}
                try Task.checkCancellation()
                let worker=Task{await LocalProcess.run(adb,["-s",serial,"shell","am","instrument","-w","local.drivee.qahelper/local.drivee.qahelper.FlowInstrumentation"],timeout:50)}
                var result:[String:Any]=[:];var lastStage=""
                for _ in 0..<160 {
                    try Task.checkCancellation()
                    let read=await LocalProcess.run(adb,["-s",serial,"exec-out","run-as","local.drivee.qahelper","cat","files/status.json"],timeout:3)
                    if let data=read.1.data(using:.utf8),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                        result=value
                        if let stage=value["stage"] as? String{lastStage=stage;message=Self.stages[stage] ?? "Переключаю аккаунт…"}
                        if ["success","error"].contains(value["state"] as? String ?? ""){break}
                    }
                    try await Task.sleep(nanoseconds:250_000_000)
                }
                _=await worker.value;try Task.checkCancellation()
                var success=result["state"] as? String == "success"
                if !success,lastStage=="verify"{success=try await recoverPostLogin(adb:adb,serial:serial)}
                guard success else{
                    if !warning.isEmpty{throw AuthFailure("Сервер сообщил о проблеме со связью")}
                    throw AuthFailure(Self.errors[result["error"] as? String ?? ""] ?? "Не удалось завершить вход")
                }
                let seconds=Date().timeIntervalSince(began)
                message=String(format:"Вход выполнен · %.1f с",seconds)
            }catch is CancellationError {if generation==token{message="Остановлено"}}
            catch{if generation==token{message=(error as? AuthFailure)?.message ?? "Не удалось выполнить вход"}}
        }
    }
    private func inspect(adb:String,serial:String)async throws->[AndroidUIRow] {
        try Task.checkCancellation()
        _=await LocalProcess.run(adb,["-s",serial,"shell","run-as local.drivee.qahelper mkdir -p files"])
        let sent=await LocalProcess.input(adb,["-s",serial,"shell","run-as local.drivee.qahelper sh -c 'umask 077; cat > files/request.json'"],data:Data("{\"mode\":\"inspect\"}".utf8))
        guard sent.0==0 else{throw AuthFailure("QA-компонент недоступен")}
        _=await LocalProcess.run(adb,["-s",serial,"shell","am","instrument","-w","local.drivee.qahelper/local.drivee.qahelper.FlowInstrumentation"],timeout:8)
        try Task.checkCancellation()
        let read=await LocalProcess.run(adb,["-s",serial,"exec-out","run-as","local.drivee.qahelper","cat","files/inspection.json"])
        guard read.0==0,let data=read.1.data(using:.utf8),let rows=try? JSONDecoder().decode([AndroidUIRow].self,from:data) else{throw AuthFailure("Не удалось прочитать интерфейс Android")};return rows
    }
    private func tap(_ row:AndroidUIRow,adb:String,serial:String)async throws {
        try Task.checkCancellation();guard let (x,y)=row.center else{throw AuthFailure("Элемент Android не виден")}
        let result=await LocalProcess.run(adb,["-s",serial,"shell","input","tap",x,y],timeout:3)
        guard result.0==0 else{throw AuthFailure("Не удалось нажать кнопку Android")}
        try await Task.sleep(nanoseconds:180_000_000)
    }
    private func recoverPostLogin(adb:String,serial:String)async throws->Bool {
        for _ in 0..<6 {
            let rows=try await inspect(adb:adb,serial:serial)
            if rows.contains(where:{$0.id.hasSuffix("/main_floatingactionbutton_menu") || $0.id.hasSuffix("/driver_city_tab_orders")}){return true}
            if rows.contains(where:{$0.text.contains("Проблемы со связью")}) {
                warning="Во время входа стенд сообщил о проблеме со связью. Авторизация проверена отдельно после закрытия сообщения."
                if let close=rows.first(where:{$0.text=="Закрыть" && $0.center != nil}){try await tap(close,adb:adb,serial:serial);continue}
            }
            if let close=rows.first(where:{$0.id.hasSuffix("/close") && $0.desc=="Закрыть сервис?" && $0.center != nil}){try await tap(close,adb:adb,serial:serial);continue}
            if let extra=rows.first(where:{$0.id.hasSuffix("/onboarding_btn_skip") || $0.id.hasSuffix("/ui_tooltip_content_button")}){try await tap(extra,adb:adb,serial:serial);continue}
            if rows.isEmpty{try await Task.sleep(nanoseconds:250_000_000);continue}
            return false
        };return false
    }
    private func prepareDriverUI(adb:String,serial:String)async throws {
        var rows=try await inspect(adb:adb,serial:serial)
        if !rows.contains(where:{$0.id.hasPrefix("com.drivee.taxi.rides:id/")}) {
            _=await LocalProcess.run(adb,["-s",serial,"shell","monkey","-p","com.drivee.taxi.rides","-c","android.intent.category.LAUNCHER","1"])
            for _ in 0..<8 {try await Task.sleep(nanoseconds:200_000_000);rows=try await inspect(adb:adb,serial:serial);if rows.contains(where:{$0.id.hasPrefix("com.drivee.taxi.rides:id/")}){break}}
        }
        if rows.contains(where:{$0.text=="Опции заказов"}) {
            _=await LocalProcess.run(adb,["-s",serial,"shell","input","keyevent","4"]);try await Task.sleep(nanoseconds:180_000_000);rows=try await inspect(adb:adb,serial:serial)
        }
        if let skip=rows.first(where:{$0.id.hasSuffix("/onboarding_btn_skip")}){try await tap(skip,adb:adb,serial:serial);rows=try await inspect(adb:adb,serial:serial)}
        if let settings=rows.first(where:{$0.text=="Настройки" && $0.id.contains("navigation_drawer") && $0.center != nil}) {
            message="Открываю настройки аккаунта…";try await tap(settings,adb:adb,serial:serial);return
        }
        guard rows.contains(where:{$0.id.hasSuffix("/driver_city_tab_orders")}),let menu=rows.first(where:{$0.desc=="Меню" && $0.center != nil}) else{return}
        message="Открываю настройки аккаунта…";try await tap(menu,adb:adb,serial:serial)
        for _ in 0..<6 {
            rows=try await inspect(adb:adb,serial:serial)
            if let settings=rows.first(where:{$0.text=="Настройки" && $0.center != nil}) {
                try await tap(settings,adb:adb,serial:serial)
                return
            }
            try await Task.sleep(nanoseconds:150_000_000)
        }
        throw AuthFailure("Не найдено меню аккаунта Android")
    }
    func cancel(){
        guard running else{return};generation=UUID();task?.cancel();message="Останавливаю…"
        let a=adb,s=serial
        Task{_ = await LocalProcess.run(a,["-s",s,"shell","am","force-stop","local.drivee.qahelper"]);_ = await LocalProcess.run(a,["-s",s,"shell","run-as local.drivee.qahelper rm -f files/request.json"]);running=false;message="Остановлено"}
    }
}
