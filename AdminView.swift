import SwiftUI

struct AdminView:View {
    @ObservedObject var bridge:OTPBridge
    @State private var draft=""
    var body:some View {
        VStack(alignment:.leading,spacing:22){
            HStack{Text("Админка").font(.title2.bold());Spacer();Text("test08 · Калуга · 590").font(.caption).foregroundStyle(.secondary)}
            Text("Настройки курьерского типа Courier").foregroundStyle(.secondary)
            HStack{
                Button("Открыть в Chrome"){bridge.showAdmin()}.accessibilityIdentifier("admin.open")
                Button("Обновить") {bridge.readAdmin()}.disabled(bridge.working).accessibilityIdentifier("admin.refresh")
                Spacer()
                Label(bridge.connected ? "Мост подключён" : "Нет связи с Chrome",systemImage:bridge.connected ? "checkmark.circle" : "link").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:16){
                Text("Door to Door").font(.headline)
                if bridge.adminDoor != nil{
                    Picker("Door to Door",selection:$draft){Text("Включен").tag("enabled");Text("Отключен").tag("disabled")}.pickerStyle(.segmented).labelsHidden().frame(maxWidth:300).disabled(bridge.working).accessibilityIdentifier("admin.door")
                    Button("Сохранить и сбросить кэш"){
                        if let current=bridge.adminDoor{bridge.saveDoor(draft,expected:current)}
                    }.disabled(bridge.working || !AdminRules.states.contains(draft) || draft == bridge.adminDoor).accessibilityIdentifier("admin.save")
                }else{Text("Нажмите «Обновить», чтобы прочитать текущее значение.").font(.callout).foregroundStyle(.secondary)}
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
            VStack(alignment:.leading,spacing:10){
                Text("Кэш test08").font(.headline)
                Button("Сбросить GO + PHP"){bridge.clearAdminCache()}.disabled(bridge.working).accessibilityIdentifier("admin.cache")
                Text("PHP очищается сразу. GO принимает запрос и применяет сброс примерно через 10 секунд.").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
            if bridge.working{ProgressView().controlSize(.small)}
            if !bridge.adminMessage.isEmpty{Text(bridge.adminMessage).font(.callout).foregroundStyle(bridge.adminFailed ? .orange : .secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("admin.status")}
            Text("Используется текущий вход в Chrome. Если сессия закончилась, войдите в админку в браузере и нажмите «Обновить».").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength:0)
        }.padding(26).frame(maxWidth:650,alignment:.topLeading)
            .onChange(of:bridge.adminRevision){_,_ in draft=bridge.adminDoor ?? ""}
    }
}
