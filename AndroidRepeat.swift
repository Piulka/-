import Foundation
import SwiftUI
import Network
import CryptoKit

private enum RepeatFailure:Error {case connection,unmatched}

/// A private, session-only channel. Field values stay in memory and never reach status text/logs.
@MainActor private final class RepeatPeer {
    var onEvent:(([String:Any])->Void)?
    var onFailure:(()->Void)?
    private var socket:NWConnection?
    private var worker:Process?
    private var tunnel:(String,String,Int)?
    private var incoming=Data()
    private var waiting:[String:CheckedContinuation<Bool,Error>]=[:]
    private var ready=false,closed=false
    func start(adb:String,serial:String)async throws {
        guard let apk=Bundle.main.url(forResource:"qa-helper",withExtension:"apk") else{throw RepeatFailure.connection}
        let hash=SHA256.hash(data:try Data(contentsOf:apk)).map{String(format:"%02x",$0)}.joined()
        let present=await LocalProcess.run(adb,["-s",serial,"shell","pm","path","local.drivee.qahelper"])
        try check()
        if present.0 != 0 || !present.1.contains("package:") || UserDefaults.standard.string(forKey:"helperHash."+serial) != hash {
            let installed=await LocalProcess.run(adb,["-s",serial,"install","--no-incremental","-r","-t",apk.path],timeout:45)
            try check()
            guard installed.0==0,installed.1.contains("Success") else{throw AuthFailure("Разрешите обновление QA-компонента на Android")}
            UserDefaults.standard.set(hash,forKey:"helperHash."+serial)
        }
        let name="zhmakee_sync_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let secret=(UUID().uuidString+UUID().uuidString).replacingOccurrences(of:"-",with:"").lowercased()
        let config=try JSONSerialization.data(withJSONObject:["socket":name,"token":secret])
        let sent=await LocalProcess.input(adb,["-s",serial,"shell","run-as local.drivee.qahelper sh -c 'mkdir -p files; umask 077; cat > files/sync-request.json'"],data:config,timeout:4)
        try check();guard sent.0==0 else{throw RepeatFailure.connection}
        let forwarding=await LocalProcess.run(adb,["-s",serial,"forward","tcp:0","localabstract:"+name])
        guard forwarding.0==0,let port=Int(forwarding.1.trimmingCharacters(in:.whitespacesAndNewlines)),let endpoint=NWEndpoint.Port(rawValue:UInt16(exactly:port) ?? 0),port>0 else{throw RepeatFailure.connection}
        tunnel=(adb,serial,port);try check()
        let process=Process();process.executableURL=URL(fileURLWithPath:adb)
        process.arguments=["-s",serial,"shell","am","instrument","-w","local.drivee.qahelper/local.drivee.qahelper.SyncInstrumentation"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        worker=process;try process.run()
        // UiAutomation takes a little longer to start than the ADB tunnel.
        for _ in 0..<25 {
            try check();guard process.isRunning else{throw RepeatFailure.connection}
            let candidate=NWConnection(host:"127.0.0.1",port:endpoint,using:.tcp)
            socket=candidate;incoming.removeAll();ready=false
            candidate.stateUpdateHandler={ [weak self,weak candidate] state in
                Task{@MainActor in
                    guard let self,let candidate,self.socket === candidate,!self.closed else{return}
                    switch state {
                    case .ready:
                        candidate.send(content:Data((secret+"\n").utf8),completion:.contentProcessed{_ in})
                        self.receive(candidate)
                    case .failed,.cancelled: if self.ready{self.onFailure?()}
                    default:break
                    }
                }
            }
            candidate.start(queue:.main)
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds:100_000_000);try check()
                if ready{return}
            }
            candidate.stateUpdateHandler=nil;candidate.cancel();socket=nil
        }
        throw RepeatFailure.connection
    }
    private func check()throws{try Task.checkCancellation();if closed{throw CancellationError()}}
    private func receive(_ channel:NWConnection){
        channel.receive(minimumIncompleteLength:1,maximumLength:65536){[weak self,weak channel] data,_,complete,error in
            Task{@MainActor in
                guard let self,let channel,self.socket === channel,!self.closed else{return}
                if let data{self.incoming.append(data)}
                guard self.incoming.count<524288 else{self.onFailure?();return}
                while let end=self.incoming.firstIndex(of:10){
                    let line=self.incoming[..<end];self.incoming.removeSubrange(...end)
                    guard let packet=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else{self.onFailure?();return}
                    if packet["ready"] as? Bool == true{self.ready=true}
                    else if let request=packet["ack"] as? String{self.waiting.removeValue(forKey:request)?.resume(returning:packet["ok"] as? Bool == true)}
                    else if packet["event"] as? Bool == true{self.onEvent?(packet)}
                }
                if complete || error != nil{if self.ready{self.onFailure?()}}else{self.receive(channel)}
            }
        }
    }
    func apply(_ event:[String:Any])async throws {
        guard ready,!closed,let channel=socket else{throw RepeatFailure.connection}
        var command=event;command.removeValue(forKey:"event")
        let id=UUID().uuidString;command["request"]=id
        var data=try JSONSerialization.data(withJSONObject:command);data.append(10)
        let ok=try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Bool,Error>) in
            waiting[id]=continuation
            channel.send(content:data,completion:.contentProcessed{[weak self] error in
                if error != nil{Task{@MainActor in self?.waiting.removeValue(forKey:id)?.resume(throwing:RepeatFailure.connection)}}
            })
            Task{[weak self] in
                try? await Task.sleep(nanoseconds:2_500_000_000)
                self?.waiting.removeValue(forKey:id)?.resume(throwing:RepeatFailure.connection)
            }
        }
        guard ok else{throw RepeatFailure.unmatched}
    }
    func stop()async {
        closed=true;onEvent=nil;onFailure=nil;socket?.stateUpdateHandler=nil;socket?.cancel();socket=nil
        for continuation in waiting.values{continuation.resume(throwing:CancellationError())};waiting.removeAll()
        if let worker {
            for _ in 0..<10{if !worker.isRunning{break};try? await Task.sleep(nanoseconds:50_000_000)}
            if worker.isRunning,let (adb,serial,_)=tunnel{_=await LocalProcess.run(adb,["-s",serial,"shell","am","force-stop","local.drivee.qahelper"],timeout:3)}
            if worker.isRunning{worker.terminate()}
        }
        if let (adb,serial,port)=tunnel{
            _=await LocalProcess.run(adb,["-s",serial,"forward","--remove","tcp:\(port)"],timeout:3)
            _=await LocalProcess.run(adb,["-s",serial,"shell","run-as","local.drivee.qahelper","rm","-f","files/sync-request.json"],timeout:3)
        }
        worker=nil;tunnel=nil
    }
}

@MainActor final class AndroidRepeat:ObservableObject {
    @Published private(set) var enabled=false
    @Published private(set) var busy=false
    @Published private(set) var stopping=false
    @Published private(set) var message=""
    @Published private(set) var repeated=0
    weak var model:DeskModel?
    private var peers:[RepeatPeer]=[]
    private var generation=UUID()
    private var task:Task<Void,Never>?
    private var relayTask:Task<Void,Never>?
    private var queue:[(Int,[String:Any])]=[]
    var engaged:Bool{enabled || busy}
    var canStart:Bool {
        guard let model else{return false}
        return model.selection.allSatisfy{!$0.isEmpty} && Set(model.selection).count==2 && model.sessions.allSatisfy{$0.connected} && !model.authorizations.contains{$0.running} && model.installingDevices.isEmpty && model.closingSlots.isEmpty && !model.deepLinks.running
    }
    func setEnabled(_ value:Bool){
        if !value{Task{await stop()};return}
        guard !engaged,canStart,let model else{return}
        let token=UUID();generation=token;busy=true;message="Подключаю повтор…";repeated=0
        let newPeers=[RepeatPeer(),RepeatPeer()];peers=newPeers
        let adb=model.adbPath,serials=model.selection
        task=Task{[self] in
            do {
                for index in 0..<2{
                    try await newPeers[index].start(adb:adb,serial:serials[index]);try Task.checkCancellation()
                    guard generation==token else{throw CancellationError()}
                }
                for index in 0..<2{
                    newPeers[index].onEvent={ [weak self] event in guard let self,self.generation==token,self.enabled else{return};self.enqueue(index,event)}
                    newPeers[index].onFailure={ [weak self] in guard let self,self.generation==token else{return};Task{await self.stop(message:"Связь потеряна · повтор выключен")}}
                }
                busy=false;enabled=true;message="В обе стороны · по элементам"
            }catch{if generation==token{let text=(error as? AuthFailure)?.message ?? "Не удалось включить повтор";Task{await self.stop(message:text)}}}
        }
    }
    private func enqueue(_ source:Int,_ event:[String:Any]){
        // Coalesce successive field edits, but preserve ordering before a click.
        if event["action"] as? String == "text",let last=queue.last,last.0==source,last.1["action"] as? String == "text",
           let a=last.1["element"] as? NSDictionary,let b=event["element"] as? NSDictionary,a==b{queue[queue.count-1]=(source,event)}
        else{queue.append((source,event))}
        guard queue.count<=64 else{Task{await stop(message:"Слишком много событий · повтор выключен")};return}
        guard relayTask==nil else{return}
        let token=generation
        relayTask=Task{
            defer{if generation==token{relayTask=nil}}
            while enabled,generation==token,!queue.isEmpty{
                let (source,event)=queue.removeFirst()
                do{try await peers[1-source].apply(event);guard generation==token else{return};repeated+=1;message="Повторено: \(repeated) · ↔"}
                catch{if generation==token{
                    let text:String
                    switch error{case RepeatFailure.unmatched:text="Нет однозначного элемента · повтор выключен";case is CancellationError:text="Повтор выключен";default:text="Android не ответил · повтор выключен"}
                    await stop(message:text)
                };return}
            }
        }
    }
    func stop(message:String="Повтор выключен")async {
        if stopping{while stopping{try? await Task.sleep(nanoseconds:50_000_000)};return};stopping=true
        let token=UUID();generation=token;enabled=false;busy=true;self.message=message
        let startup=task;task=nil;startup?.cancel();relayTask?.cancel();queue.removeAll();relayTask=nil
        // Wait for any in-flight ADB preparation before tearing down its tunnel/process.
        await startup?.value
        let old=peers;peers=[]
        for peer in old{await peer.stop()}
        if generation==token{busy=false;stopping=false}
    }
}

struct RepeatSidebar:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var sync:AndroidRepeat
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            Toggle(isOn:Binding(get:{sync.enabled || (sync.busy && !sync.stopping)},set:{sync.setEnabled($0)})){
                Label("Повтор ↔",systemImage:"hand.tap").font(.system(size:11,weight:.medium))
            }.toggleStyle(.switch).controlSize(.mini).disabled(sync.stopping || (!sync.engaged && !sync.canStart)).accessibilityIdentifier("repeat.toggle")
            if !sync.message.isEmpty{Text(sync.message).font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.help("Нажатия и ввод текста между двумя Android. Нужны одинаковые экраны; неоднозначный элемент отключает повтор. Свайпы и элементы без accessibility-разметки не повторяются.")
    }
}
