import Foundation

@main struct AndroidForegroundTests {
    static func main(){
        let huawei="    mResumedActivity: ActivityRecord{abc u0 app.example.client/.ClientActivity t325}"
        let poco="    topResumedActivity=ActivityRecord{def u0 app.example.courier/.CourierActivity t219}"
        precondition(AndroidForeground.package(in:huawei)=="app.example.client")
        precondition(AndroidForeground.package(in:poco)=="app.example.courier")
        precondition(AndroidForeground.package(in:huawei+"\n"+poco)=="app.example.courier")
        precondition(AndroidForeground.package(in:"topResumedActivity=null\n"+huawei)=="app.example.client")
        precondition(AndroidForeground.package(in:"topResumedActivity=null")==nil)
        precondition(AndroidForeground.package(in:"mLastPausedActivity: ActivityRecord{abc u0 app.example.old/.Activity}")==nil)
        precondition(AndroidForeground.package(in:"mResumedActivity: not-a-component")==nil)
        precondition(AndroidForeground.isProtected("com.huawei.android.launcher",home:nil))
        precondition(AndroidForeground.isProtected("com.mi.android.globallauncher",home:nil))
        precondition(AndroidForeground.isProtected("app.example.launcher",home:"app.example.launcher"))
        precondition(AndroidForeground.isProtected("com.android.systemui",home:nil))
        precondition(!AndroidForeground.isProtected("app.example.client",home:"app.example.launcher"))
        print("Android foreground parsing and launcher protection: 12 checks passed")
    }
}
