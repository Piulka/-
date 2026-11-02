import Foundation

enum ClientLinkMode:String,CaseIterable,Identifiable {
    case courier="appcity_courier",city="appcity"
    var id:String{rawValue}
    var title:String{self == .courier ? "Курьер" : "Город"}
}

struct CourierStop:Identifiable,Codable,Equatable {
    var id=UUID().uuidString
    var address:String
    var latitude:String
    var longitude:String
}
struct CourierPreset:Identifiable,Codable,Equatable {
    var id=UUID().uuidString
    var name:String
    var stops:[CourierStop]
    var price:String
    var paymentType=""
    var comment=""
    var entrance=""
    var recipientPhone=""
    var doorToDoor=""
    var senderAddress=""
    var recipientAddress=""
    static var defaults:[CourierPreset] {
        let route=[CourierStop(address:"A",latitude:"54.499721",longitude:"36.177034"),CourierStop(address:"B",latitude:"54.500425",longitude:"36.174327")]
        var full=CourierPreset(id:"full",name:"Все поля",stops:route,price:"350")
        full.paymentType="1";full.comment="Test";full.entrance="2";full.recipientPhone="+79990000000";full.doorToDoor="true";full.senderAddress="2/3/15";full.recipientAddress="1/4/20"
        return [full,CourierPreset(id:"route-price",name:"Адреса + цена",stops:route,price:"350")]
    }
    func url(forIPhone:Bool=false,mode:ClientLinkMode = .courier)throws->URL {
        func fail(_ text:String)throws->Never{throw DeepLinkFailure(text)}
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{try fail("Укажите название пресета")}
        guard (2...10).contains(stops.count) else{try fail("Нужно от 2 до 10 точек маршрута")}
        var route:[[String:Any]]=[]
        for (index,stop) in stops.enumerated(){
            guard !stop.address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let lat=Double(stop.latitude.replacingOccurrences(of:",",with:".")),let lon=Double(stop.longitude.replacingOccurrences(of:",",with:".")),lat.isFinite,lon.isFinite,(-90...90).contains(lat),(-180...180).contains(lon) else{try fail("Проверьте адрес и координаты точки \(index+1)")}
            route.append(["address":stop.address,"latitude":lat,"longitude":lon])
        }
        let normalized=price.trimmingCharacters(in:.whitespaces).replacingOccurrences(of:",",with:".")
        guard let amount=Double(normalized),amount.isFinite,amount>0 else{try fail("Укажите цену больше нуля")}
        guard paymentType.isEmpty || paymentType.range(of:"^[0-9]+$",options:.regularExpression) != nil else{try fail("ID оплаты должен состоять из цифр")}
        guard recipientPhone.isEmpty || recipientPhone.range(of:"^\\+?[0-9]{7,15}$",options:.regularExpression) != nil else{try fail("Проверьте телефон получателя: код страны и цифры")}
        guard ["","true","false"].contains(doorToDoor) else{try fail("Проверьте доставку до двери")}
        let data=try JSONSerialization.data(withJSONObject:route,options:[.sortedKeys])
        var query=[URLQueryItem(name:"route",value:String(decoding:data,as:UTF8.self)),URLQueryItem(name:"price",value:normalized)]
        if forIPhone || mode == .city {
            // City accepts the documented start/end coordinates on both platforms.
            // Older iOS courier builds use them too. Keep route and optional fields intact.
            guard stops.count==2 else{try fail(mode == .city ? "Для города пока доступны пресеты из двух точек" : "Для iPhone пока доступны пресеты из двух точек")}
            for (key,value) in [("start_latitude",route[0]["latitude"]!),("start_longitude",route[0]["longitude"]!),("end_latitude",route[1]["latitude"]!),("end_longitude",route[1]["longitude"]!)]{query.append(URLQueryItem(name:key,value:String(describing:value)))}
        }
        for (key,value) in [("payment_type_id",paymentType),("description",comment),("entrance",entrance),("recipient_phone",recipientPhone),("door_to_door",doorToDoor),("sender_specifying_address",senderAddress),("recipient_specifying_address",recipientAddress)] where !value.isEmpty {query.append(URLQueryItem(name:key,value:value))}
        var components=URLComponents(string:"drivee://open/client/"+mode.rawValue)!
        components.queryItems=query
        components.percentEncodedQuery=components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let url=components.url else{try fail("Не удалось собрать диплинк")};return url
    }
}
struct DeepLinkFailure:LocalizedError {var message:String;init(_ message:String){self.message=message};var errorDescription:String?{message}}
enum AndroidShell {
    // adb shell joins argv before invoking the device shell. Quote data at that boundary.
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func deepLinkCommand(_ url:URL)->String{"am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d \(quote(url.absoluteString)) -p com.drivee.taxi.rides"}
}
