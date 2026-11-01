import Foundation

struct TestAccount: Identifiable, Codable, Hashable {
    var id:String
    var name:String
    var role:String
    var stand:String = "08"
    enum CodingKeys:String,CodingKey {case id,name,role,stand}
    init(id:String,name:String,role:String,stand:String="08"){self.id=id;self.name=name;self.role=role;self.stand=stand}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name);role=try c.decode(String.self,forKey:.role)
        stand=try c.decodeIfPresent(String.self,forKey:.stand) ?? "08"
    }
    var label:String { role.isEmpty ? name : "\(name) · \(role)" }
}
