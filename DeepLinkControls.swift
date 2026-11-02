import AppKit
import SwiftUI

@MainActor final class DeepLinkCoordinator:ObservableObject {
    weak var model:DeskModel?
    @Published var presets:[CourierPreset] {didSet{if let data=try? JSONEncoder().encode(presets){UserDefaults.standard.set(data,forKey:"courierPresets")};if !presets.contains(where:{$0.id==selected}){selected=presets.first?.id ?? ""}}}
    @Published var selected="full"
    @Published var target=0
    @Published var mode:ClientLinkMode {didSet{UserDefaults.standard.set(mode.rawValue,forKey:"clientLinkMode")}}
    @Published var running=false
    @Published var message=""
    @Published var failed=false
    init(){
        mode=ClientLinkMode(rawValue:UserDefaults.standard.string(forKey:"clientLinkMode") ?? "") ?? .courier
        if let data=UserDefaults.standard.data(forKey:"courierPresets"),let saved=try? JSONDecoder().decode([CourierPreset].self,from:data){presets=saved}else{presets=CourierPreset.defaults}
        selected=presets.first?.id ?? ""
    }
    func save(_ preset:CourierPreset)throws {
        _=try preset.url()
        if let index=presets.firstIndex(where:{$0.id==preset.id}){presets[index]=preset}else{presets.append(preset)}
        selected=preset.id
    }
    func open(){
        guard !running,let model,let preset=presets.first(where:{$0.id==selected}) else{return}
        let destination=target
        if destination<2,model.androidRepeat.engaged{message="Сначала выключите повтор нажатий";failed=true;return}
        if destination<2 ? model.isInstalling(destination) : model.installingDevices.contains("iphone"){message="Дождитесь установки сборки";failed=true;return}
        if destination<2,model.authorizations[destination].running || model.closingSlots.contains(destination){message="Дождитесь завершения действия на телефоне";failed=true;return}
        if destination==2,model.iosAuthorization.running{message="Дождитесь завершения входа iPhone";failed=true;return}
        do {
            let url=try preset.url(forIPhone:destination==2,mode:mode)
            let serial=destination<2 ? model.selection[destination] : ""
            guard destination==2 || !serial.isEmpty else{throw DeepLinkFailure("Выберите Android на вкладке устройств")}
            running=true;failed=false;message="Открываю форму…"
            let adb=model.adbPath
            Task {
                defer{running=false}
                do {
                    if destination<2 {
                        let result=await LocalProcess.run(adb,["-s",serial,"shell",AndroidShell.deepLinkCommand(url)],timeout:12)
                        guard result.0==0,result.1.contains("Status: ok"),!result.1.contains("Error:"),!result.1.contains("Exception") else{throw DeepLinkFailure("Диплинк не открылся. Проверьте подключение и сборку Drivee")}
                    }else{try await openIPhone(url)}
                    message=""
                }catch{message=error.localizedDescription;failed=true}
            }
        }catch{message=error.localizedDescription;failed=true}
    }
    private func command(_ args:[String])async throws->[String:Any] {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("zhmakee-link-\(UUID().uuidString).json")
        defer{try? FileManager.default.removeItem(at:file)}
        let result=await LocalProcess.run("/usr/bin/xcrun",["devicectl","--timeout","12"]+args+["--json-output",file.path],timeout:15)
        guard result.0==0,let data=try? Data(contentsOf:file),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let payload=object["result"] as? [String:Any] else{throw DeepLinkFailure("Подключите iPhone к Xcode по USB и разблокируйте для подключения")}
        return payload
    }
    private func openIPhone(_ url:URL)async throws {
        let result=try await command(["list","devices"])
        let devices=(result["devices"] as? [[String:Any]] ?? []).filter{device in
            let properties=device["properties"] as? [String:Any]
            let hardware=properties?["hardware"] as? [String:Any] ?? device["hardwareProperties"] as? [String:Any] ?? [:]
            let connection=properties?["connection"] as? [String:Any] ?? device["connectionProperties"] as? [String:Any] ?? [:]
            return hardware["deviceType"] as? String == "iPhone" && connection["pairingState"] as? String == "paired"
        }
        guard devices.count==1,let identifier=devices.first?["identifier"] as? String else{throw DeepLinkFailure(devices.isEmpty ? "Подключите iPhone к Xcode по USB" : "Подключите один iPhone для открытия диплинка")}
        _=try await command(["device","process","launch","--device",identifier,"--payload-url",url.absoluteString,"com.drivee.taxi.rides"])
    }
}

struct DeepLinkSidebar:View {
    @ObservedObject var model:DeskModel
    @ObservedObject var coordinator:DeepLinkCoordinator
    @AppStorage("deepLinksExpanded") private var expanded=true
    var body:some View {
        VStack(alignment:.leading,spacing:8){
            Button{withAnimation(.easeInOut(duration:0.16)){expanded.toggle()}}label:{HStack{Text("ДИПЛИНКИ").font(.system(size:9,weight:.semibold));Spacer();Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:9))}.foregroundStyle(.secondary).contentShape(Rectangle())}.buttonStyle(.plain).accessibilityIdentifier("deeplink.header")
            if expanded {
                Picker("Форма",selection:$coordinator.mode){ForEach(ClientLinkMode.allCases){mode in Text(mode.title).tag(mode)}}
                    .pickerStyle(.segmented).labelsHidden().disabled(coordinator.running).accessibilityIdentifier("deeplink.mode")
                    .help("drivee://open/client/"+coordinator.mode.rawValue)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:4),count:3),spacing:4){
                    ForEach(0..<3,id:\.self){target in
                        let name=target==2 ? "iPhone" : (model.devices.first(where:{$0.id==model.selection[target]})?.name.components(separatedBy:" · ").first ?? "A\(target+1)")
                        SidebarChoice(title:name,selected:coordinator.target==target){coordinator.target=target}
                            .help(name).accessibilityIdentifier("deeplink.device.\(target)")
                    }
                }.disabled(coordinator.running)
                VStack(spacing:4){
                    ForEach(coordinator.presets){preset in
                        SidebarChoice(title:preset.name,selected:coordinator.selected==preset.id){coordinator.selected=preset.id}
                            .help(preset.name).accessibilityIdentifier("deeplink.preset.\(preset.id)")
                    }
                    if coordinator.presets.isEmpty{Text("Добавьте пресет в настройках").font(.caption).foregroundStyle(.secondary)}
                }.disabled(coordinator.running)
                Button{coordinator.open()}label:{Label(coordinator.running ? "Открываю…" : "Заполнить",systemImage:"link").frame(maxWidth:.infinity)}.disabled(coordinator.running || coordinator.presets.isEmpty).help("Открыть форму в клиентском аккаунте. Поддержка полей зависит от сборки Drivee").accessibilityIdentifier("deeplink.open")
            }
            if coordinator.failed && !coordinator.message.isEmpty{Text(coordinator.message).font(.system(size:10)).foregroundStyle(coordinator.failed ? .orange : .secondary).fixedSize(horizontal:false,vertical:true).lineLimit(3).help(coordinator.message).accessibilityIdentifier("deeplink.status")}
        }.controlSize(.small).frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct SidebarChoice:View {
    var title:String
    var selected:Bool
    var action:()->Void
    var body:some View {
        Button(action:action){Text(title).font(.system(size:10,weight:.semibold)).lineLimit(2).minimumScaleFactor(0.75).frame(maxWidth:.infinity,minHeight:28).padding(.horizontal,2).background(selected ? Color(red:0.64,green:0.94,blue:0.18) : Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:6)).foregroundStyle(selected ? Color.black : Color.primary)}.buttonStyle(.plain)
    }
}

struct DeepLinkSettings:View {
    @ObservedObject var coordinator:DeepLinkCoordinator
    @State private var selected=""
    @State private var draft=CourierPreset.defaults[0]
    @State private var loaded=false
    @State private var notice=""
    @State private var failed=false
    @State private var drafts:[String:CourierPreset]=[:]
    private func load(_ id:String){
        if loaded{drafts[selected]=draft};selected=id
        draft=drafts[id] ?? coordinator.presets.first(where:{$0.id==id}) ?? CourierPreset(name:"",stops:CourierPreset.defaults[1].stops,price:"350")
        loaded=true;notice=""
    }
    private func field(_ title:String,_ placeholder:String,_ binding:Binding<String>,id:String?=nil)->some View {
        VStack(alignment:.leading,spacing:4){Text(title).font(.caption).foregroundStyle(.secondary);TextField(placeholder,text:binding).textFieldStyle(.roundedBorder).accessibilityLabel(title).accessibilityIdentifier(id ?? "deeplink.field."+title)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text("Диплинки · пресеты").font(.headline);Spacer();Button{load("")}label:{Label("Добавить",systemImage:"plus")}.accessibilityIdentifier("deeplink.settings.add")}
            if !coordinator.presets.isEmpty {
                Picker("Пресет",selection:Binding(get:{selected},set:{load($0)})){
                    if selected.isEmpty{Text("Новый пресет").tag("")};ForEach(coordinator.presets){Text($0.name).tag($0.id)}
                }.accessibilityIdentifier("deeplink.settings.preset")
            }
            field("Название","Название заполнения",$draft.name,id:"deeplink.settings.name")
            Text("Маршрут").font(.subheadline.weight(.medium))
            ForEach($draft.stops){$stop in
                VStack(alignment:.leading,spacing:6){
                    HStack{TextField("Адрес",text:$stop.address).textFieldStyle(.roundedBorder).accessibilityIdentifier("deeplink.stop.\(stop.id).address");if draft.stops.count>2{Button{draft.stops.removeAll{$0.id==stop.id}}label:{Image(systemName:"minus.circle")}.help("Удалить точку")}}
                    HStack{field("Широта","54.499721",$stop.latitude,id:"deeplink.stop.\(stop.id).latitude");field("Долгота","36.177034",$stop.longitude,id:"deeplink.stop.\(stop.id).longitude")}
                }.padding(10).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            }
            Button("Добавить точку"){draft.stops.append(CourierStop(address:"",latitude:"",longitude:""))}.disabled(draft.stops.count>=10)
            HStack{field("Цена","350",$draft.price);field("ID оплаты","Не передавать",$draft.paymentType)}
            field("Комментарий курьеру","Не передавать",$draft.comment)
            HStack{field("Подъезд отправителя","Не передавать",$draft.entrance);field("Телефон получателя","+код страны и номер",$draft.recipientPhone)}
            Picker("От двери до двери",selection:$draft.doorToDoor){Text("Не передавать").tag("");Text("Да").tag("true");Text("Нет").tag("false")}
            field("Подъезд / этаж / квартира отправителя","Не передавать",$draft.senderAddress)
            field("Подъезд / этаж / квартира получателя","Не передавать",$draft.recipientAddress)
            Text("Пустые необязательные поля не передаются. Примеры A / B взяты из документации. Для iPhone — две точки; Android поддерживает промежуточные адреса.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack{
                if !selected.isEmpty{Button("Удалить",role:.destructive){coordinator.presets.removeAll{$0.id==selected};drafts.removeValue(forKey:selected);loaded=false;load(coordinator.presets.first?.id ?? "")}.accessibilityIdentifier("deeplink.settings.delete")}
                Spacer()
                Button("Сохранить пресет"){
                    do{try coordinator.save(draft);drafts.removeValue(forKey:"");selected=draft.id;drafts[selected]=draft;notice="Пресет сохранён";failed=false}catch{notice=error.localizedDescription;failed=true}
                }.accessibilityIdentifier("deeplink.settings.save")
            }
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(failed ? Color.orange : Color.green).accessibilityIdentifier("deeplink.settings.status")}
            Link("Документация диплинков",destination:URL(string:"https://docs.drivee.tech/Couriers/tech/kurerskie-deeplink")!).font(.caption)
        }.onAppear{if !loaded{load(coordinator.presets.first?.id ?? "")}}
    }
}
