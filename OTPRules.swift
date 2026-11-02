import Foundation

enum OTPRules {
    static let browserURL="https://redis-insight.dev.indels.tech/89b36460-e2f2-4245-a741-cdb7c13e7e1d/browser"
    static func valid(phone:String,stand:String)->Bool{stand == "08" && phone.utf8.count==11 && phone.range(of:"^258[0-9]{8}$",options:.regularExpression) != nil}
    static func successMessage(_ result:[String:Any],action:String)->String? {
        guard result["ok"] as? Bool == true,let code=result["code"] as? String else{return nil}
        if action == "ping"{return code == "connected" ? "Chrome и RedisInsight test08 подключены" : nil}
        guard let found=result["found"] as? Int,(0...3).contains(found) else{return nil}
        if action == "inspect"{return code == "checked" ? "OTP test08 · найдено ключей: \(found) из 3" : nil}
        guard action == "reset",let deleted=result["deleted"] as? Int,(0...found).contains(deleted),result["remaining"] as? Int == 0 else{return nil}
        if found==0{return code == "checked" ? "OTP test08 · ключей блокировки нет" : nil}
        return code == "reset" ? "OTP test08 сброшен · удалено: \(deleted)" : nil
    }
    static func message(_ code:String)->String {
        switch code {
        case "tab_missing","wrong_tab":return "Откройте test08 в RedisInsight через Chrome"
        case "auth_required":return "Войдите в RedisInsight в Chrome"
        case "wrong_database":return "Подключение Redis не соответствует test08"
        case "api_not_found","unexpected_response","unexpected_keys":return "Версия RedisInsight не распознана · сброс остановлен"
        case "reset_unverified":return "Результат сброса не подтверждён · проверьте ключи перед повтором"
        case "keys_remain":return "После сброса остались OTP-ключи · проверьте RedisInsight"
        case "busy":return "Дождитесь завершения предыдущего сброса"
        case "timeout":return "Chrome не ответил · проверьте RedisInsight перед повтором"
        case "invalid_phone","invalid_request":return "Сброс доступен только тестовому аккаунту на test08"
        default:return "Нет связи с RedisInsight · проверьте VPN и вкладку Chrome"
        }
    }
}
