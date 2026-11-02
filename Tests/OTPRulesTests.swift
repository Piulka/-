import Foundation
@main struct OTPRulesTests {
    static func main(){
        let phone="258"+"12345678"
        precondition(OTPRules.valid(phone:phone,stand:"08"))
        for stand in ["09","stage",""]{precondition(!OTPRules.valid(phone:phone,stand:stand))}
        for bad in ["*",phone+"*",String(phone.dropFirst()),phone+"0",phone+"\n"]{precondition(!OTPRules.valid(phone:bad,stand:"08"))}
        precondition(OTPRules.message("reset_unverified").contains("не подтверждён"))
        precondition(OTPRules.successMessage(["ok":true,"code":"connected"],action:"ping") != nil)
        precondition(OTPRules.successMessage(["ok":true,"code":"reset","found":3,"deleted":3,"remaining":0],action:"reset") != nil)
        for invalid:[String:Any] in [["ok":true],["ok":true,"code":"reset","found":3,"deleted":4,"remaining":0],["ok":true,"code":"reset","found":3,"deleted":3,"remaining":1]] {
            precondition(OTPRules.successMessage(invalid,action:"reset")==nil)
        }
        print("OTP test08 phone validation and failure reporting: passed")
    }
}
