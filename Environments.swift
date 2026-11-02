import Foundation

struct QAEnvironment:Identifiable,Hashable {
    let id:String
    var title:String{id == "stage" ? "fridi" : "test"+id}
    var shortTitle:String{id == "stage" ? "fridi" : id}
    var host:String{id == "stage" ? "fridi.int.indels.dev" : "test\(id)-fridi.int.indels.dev"}
    static let all=(1...10).map{QAEnvironment(id:String(format:"%02d",$0))}+[QAEnvironment(id:"stage")]
    static func valid(_ id:String)->Bool{all.contains{$0.id==id}}
    static func matches(_ text:String,stand:String)->Bool {
        guard let environment=all.first(where:{$0.id==stand}) else{return false}
        return containsHost(environment.host,in:text)
    }
    // iOS DevNodes primary uses int/djem in current builds; older builds expose fridi.
    static func matchesIOSPrimary(_ text:String,stand:String)->Bool {
        guard let environment=all.first(where:{$0.id==stand}) else{return false}
        let primary=stand == "stage" ? "int.indels.dev" : "test\(stand)-djem.int.indels.dev"
        return [primary,environment.host].contains{containsHost($0,in:text)}
    }
    static func isIOSPrimaryHost(_ text:String)->Bool{all.contains{matchesIOSPrimary(text,stand:$0.id)}}
    private static func containsHost(_ host:String,in text:String)->Bool {
        // Exact host boundary prevents fridi from matching test08-fridi, or 01 from matching 010.
        let pattern="(?i)(?<![a-z0-9.-])"+NSRegularExpression.escapedPattern(for:host)+"(?![a-z0-9.-])"
        return text.range(of:pattern,options:.regularExpression) != nil
    }
}
