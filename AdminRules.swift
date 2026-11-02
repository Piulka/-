import Foundation

enum AdminRules {
    static let url="https://test08-podval.int.indels.dev/podval/city/update?id=590#tab-custom-order-settings"
    static let states=["enabled","disabled"]
    static func success(_ result:[String:Any],action:String,value:String?)->String? {
        guard result["ok"] as? Bool == true else{return nil}
        let code=result["code"] as? String
        if action == "admin_read"{
            guard code == "admin_loaded",let door=result["door"] as? String,states.contains(door) else{return nil}
            return "Настройки загружены из админки"
        }
        guard result["go"] as? Bool == true,result["php"] as? Bool == true else{return nil}
        if action == "admin_door"{
            guard code == "admin_saved",result["saved"] as? Bool == true,result["door"] as? String == value,let value,states.contains(value) else{return nil}
            return "Door to Door сохранён · PHP очищен · GO применит сброс примерно через 10 с"
        }
        return action == "admin_cache" && code == "admin_cache_done" ? "PHP очищен · запрос сброса GO принят (примерно 10 с)" : nil
    }
    static func message(_ code:String,saved:Bool=false,go:Bool=false,php:Bool=false)->String {
        switch code {
        case "admin_tab_missing","tab_missing":return "Откройте админку Калуги в Chrome"
        case "admin_auth_required":return "Войдите в админку test08 в Chrome и обновите настройки"
        case "admin_conflict":return "Значение в админке изменилось · обновите перед сохранением"
        case "admin_page_changed":return "Форма админки изменилась · операция остановлена"
        case "admin_partial":return (saved ? "Настройка сохранена. " : "")+(go ? "Сброс GO запрошен. " : "")+(php ? "PHP очищен. " : "PHP не подтверждён. ")+"Проверьте админку перед повтором"
        case "admin_unverified":return "Результат не подтверждён · обновите настройки и проверьте админку перед повтором"
        case "busy":return "Дождитесь завершения операции"
        case "timeout":return "Chrome не ответил · проверьте админку перед повтором"
        case "invalid_request":return "Доступны только test08 · Калуга · Courier"
        default:return "Нет связи с админкой · проверьте вкладку Chrome и VPN"
        }
    }
}
