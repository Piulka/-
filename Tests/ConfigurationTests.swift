import Foundation

@main struct ConfigurationTests {
    static func main()throws {
        let legacy=Data(#"[{"id":"legacy","name":"Sample","role":"Client"}]"#.utf8)
        let migrated=try JSONDecoder().decode([TestAccount].self,from:legacy)
        precondition(migrated[0].stand=="08" && migrated[0].id=="legacy")
        let catalog=migrated+[TestAccount(id:"other",name:"Sample",role:"Courier",stand:"10"),TestAccount(id:"base",name:"Base",role:"Client",stand:"stage")]
        let roundTrip=try JSONDecoder().decode([TestAccount].self,from:JSONEncoder().encode(catalog))
        precondition(roundTrip==catalog && roundTrip.filter{$0.stand=="08"}.count==1 && roundTrip.filter{$0.stand=="10"}.count==1)
        precondition(QAEnvironment.all.count==11 && QAEnvironment.valid("10") && QAEnvironment.valid("stage") && !QAEnvironment.valid("00"))
        for environment in QAEnvironment.all {
            precondition(QAEnvironment.matches("Сервер API https://\(environment.host)/",stand:environment.id))
            precondition(!QAEnvironment.matches("https://evil-\(environment.host)",stand:environment.id))
            for other in QAEnvironment.all where other != environment {precondition(!QAEnvironment.matches(other.host,stand:environment.id))}
        }
        precondition(!QAEnvironment.matches("test010-fridi.int.indels.dev",stand:"01"))
        precondition(QAEnvironment.matchesIOSPrimary("Current Host: https://int.indels.dev",stand:"stage"))
        precondition(QAEnvironment.matchesIOSPrimary("https://fridi.int.indels.dev/",stand:"stage"))
        precondition(!QAEnvironment.matchesIOSPrimary("https://test08-djem.int.indels.dev",stand:"stage"))
        precondition(!QAEnvironment.matchesIOSPrimary("https://test08-fridi.int.indels.dev",stand:"stage"))
        for number in 1...10 {
            let id=String(format:"%02d",number),host="test\(id)-djem.int.indels.dev"
            precondition(QAEnvironment.matchesIOSPrimary("https://\(host)",stand:id))
            precondition(!QAEnvironment.matches("https://\(host)",stand:id))
            precondition(!QAEnvironment.matchesIOSPrimary("https://evil-\(host)",stand:id))
            precondition(!QAEnvironment.matchesIOSPrimary("https://test\(id)0-djem.int.indels.dev",stand:id))
            for other in QAEnvironment.all where other.id != id {precondition(!QAEnvironment.matchesIOSPrimary(host,stand:other.id))}
        }
        precondition(!QAEnvironment.matchesIOSPrimary("https://indels.app",stand:"stage"))
        let full=CourierPreset.defaults[0],minimal=CourierPreset.defaults[1]
        let fullQuery=try items(full),minimalQuery=try items(minimal)
        precondition(fullQuery.count==9 && minimalQuery.count==2)
        precondition(fullQuery["door_to_door"]=="true" && fullQuery["recipient_phone"]?.hasPrefix("+")==true)
        let stops=try JSONSerialization.jsonObject(with:Data(fullQuery["route"]!.utf8)) as! [[String:Any]]
        precondition(stops.count==2 && stops[0]["latitude"] as? Double==54.499721)
        let iosQuery=URLComponents(url:try full.url(forIPhone:true),resolvingAgainstBaseURL:false)!.queryItems!
        precondition(iosQuery.count==13 && iosQuery.first(where:{$0.name=="start_latitude"})?.value=="54.499721")
        var multi=full;multi.stops.append(CourierStop(address:"C",latitude:"54.500468",longitude:"36.174441"))
        _=try multi.url()
        do{_=try multi.url(forIPhone:true);preconditionFailure("Intermediate point lost")}catch is DeepLinkFailure{}
        var custom=minimal
        custom.name="Cyrillic & encoding";custom.stops[0].address="улица А & Б, 2/3 + вход 'С'";custom.comment="тест &price=1 + ? # %";custom.price="420,50";custom.doorToDoor="false"
        let query=try items(custom),url=try custom.url()
        precondition(query["price"]=="420.50" && query["description"]==custom.comment && query["door_to_door"]=="false")
        let customRoute=try JSONSerialization.jsonObject(with:Data(query["route"]!.utf8)) as! [[String:Any]]
        precondition(customRoute[0]["address"] as? String==custom.stops[0].address)
        precondition(!url.absoluteString.contains(" ") && url.absoluteString.contains("%2B"))
        precondition(AndroidShell.quote("a'b & c")=="'a'\\''b & c'")
        precondition(AndroidShell.deepLinkCommand(url).contains("-d 'drivee://"))
        for invalid in ["latitude","price","phone","route","name","door"] {
            var bad=full
            switch invalid {case "latitude":bad.stops[0].latitude="91";case "price":bad.price="-2";case "phone":bad.recipientPhone="x";case "route":bad.stops=[];case "name":bad.name=" ";default:bad.doorToDoor="maybe"}
            do{_=try bad.url();preconditionFailure("Invalid \(invalid) accepted")}catch is DeepLinkFailure{}
        }
        print("Accounts migration, 11 environments, deep-link encoding and validation: passed")
    }
    static func items(_ preset:CourierPreset)throws->[String:String]{Dictionary(uniqueKeysWithValues:URLComponents(url:try preset.url(),resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value!)})}
}
