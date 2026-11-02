import Foundation
@main struct AdminRulesTests {
    static func main(){
        precondition(AdminRules.success(["ok":true,"code":"admin_loaded","door":"enabled"],action:"admin_read",value:nil) != nil)
        precondition(AdminRules.success(["ok":true,"code":"admin_loaded","door":"unexpected"],action:"admin_read",value:nil) == nil)
        let saved:[String:Any]=["ok":true,"code":"admin_saved","door":"disabled","saved":true,"go":true,"php":true]
        precondition(AdminRules.success(saved,action:"admin_door",value:"disabled") != nil)
        precondition(AdminRules.success(saved,action:"admin_door",value:"enabled") == nil)
        var partial=saved;partial["php"]=false
        precondition(AdminRules.success(partial,action:"admin_door",value:"disabled") == nil)
        precondition(AdminRules.message("admin_conflict").contains("обновите"))
        precondition(AdminRules.message("admin_partial",saved:true,go:true).contains("Настройка сохранена"))
        print("Admin status validation and partial failure messages: passed")
    }
}
