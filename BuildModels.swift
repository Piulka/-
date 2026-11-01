import Foundation

enum BuildPlatform:String,Codable {case android,ios}
struct BuildMetadata:Codable,Equatable {
    var platform:BuildPlatform
    var package:String
    var name:String
    var version:String
    var build:String
    var minimumOS:String
    var flavor:String
}
struct LocalBuild:Identifiable {
    var url:URL
    var size:Int64
    var modified:Date
    var metadata:BuildMetadata?
    var error=""
    var id:String{url.path}
    var fingerprint:String{"\(size):\(modified.timeIntervalSince1970)"}
    var platform:BuildPlatform{url.pathExtension.lowercased()=="ipa" ? .ios : .android}
    var versionLabel:String{metadata.map{"\($0.version) · \($0.build)"} ?? (error.isEmpty ? "Читаю версию…" : error)}
}
struct InstallationTarget:Identifiable {
    var id:String
    var title:String
    var platform:BuildPlatform
}
struct BuildFailure:LocalizedError {var message:String;init(_ message:String){self.message=message};var errorDescription:String?{message}}
enum InstallResult {
    static func androidSucceeded(code:Int32,output:String)->Bool{code==0 && output.split(whereSeparator:{$0.isNewline}).contains{$0.trimmingCharacters(in:.whitespaces)=="Success"}}
    static func androidError(_ output:String)->String {
        let errors=[("INSTALL_FAILED_UPDATE_INCOMPATIBLE","Подпись APK отличается от установленной. Приложение не удалялось"),("INSTALL_PARSE_FAILED_NO_CERTIFICATES","APK не подписан или повреждён"),("INSTALL_FAILED_VERSION_DOWNGRADE","Android запретил установку более старой версии"),("INSTALL_FAILED_INSUFFICIENT_STORAGE","На телефоне недостаточно свободного места"),("INSTALL_FAILED_NO_MATCHING_ABIS","APK не подходит архитектуре телефона"),("INSTALL_FAILED_USER_RESTRICTED","Подтвердите установку по USB на телефоне и повторите"),("INSTALL_FAILED_ABORTED","Установка отменена на телефоне"),("INSTALL_CANCELED_BY_USER","Установка отменена на телефоне"),("INSTALL_FAILED_OLDER_SDK","Для APK нужна более новая версия Android")]
        return errors.first(where:{output.contains($0.0)})?.1 ?? "Не удалось установить APK. Проверьте USB и подтверждение на телефоне"
    }
    static func iosError(_ output:String)->String {
        if ["provisioning profile","0xe8008015","0xe8008018","ApplicationVerificationFailed","application could not be verified"].contains(where:{output.localizedCaseInsensitiveContains($0)}){return "iPhone отклонил подпись или provisioning profile этой IPA. Нужна подходящая подписанная сборка"}
        if output.localizedCaseInsensitiveContains("expired"){return "Срок подписи IPA истёк. Скачайте актуальную сборку"}
        if output.contains("MismatchedApplicationIdentifierEntitlement"){return "Подпись IPA несовместима с установленным приложением. Оно не удалялось"}
        if ["No space left","insufficient storage","insufficient space"].contains(where:{output.localizedCaseInsensitiveContains($0)}){return "На iPhone недостаточно свободного места"}
        return "Не удалось установить IPA. Проверьте USB, доверие Mac и доступность iPhone в Xcode"
    }
}
