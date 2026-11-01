import Foundation

@main struct BuildModelsTests {
    static func main()throws {
        precondition(InstallResult.androidSucceeded(code:0,output:"Performing Streamed Install\nSuccess\n"))
        precondition(!InstallResult.androidSucceeded(code:1,output:"Success"))
        precondition(!InstallResult.androidSucceeded(code:0,output:"Success was not reported\nFailure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"))
        precondition(InstallResult.androidError("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]").contains("Подпись"))
        precondition(InstallResult.androidError("Failure [INSTALL_FAILED_USER_RESTRICTED]").contains("Подтвердите"))
        precondition(InstallResult.iosError("A valid provisioning profile for this executable was not found").contains("подпись"))
        let json=Data(#"{"platform":"android","package":"example.qa.client","name":"Sample","version":"2.3","build":"42","minimumOS":"26","flavor":"HMS"}"#.utf8)
        let metadata=try JSONDecoder().decode(BuildMetadata.self,from:json)
        precondition(metadata.platform == .android && metadata.build=="42" && metadata.flavor=="HMS")
        let a=LocalBuild(url:URL(fileURLWithPath:"/tmp/Sample.apk"),size:5,modified:Date(timeIntervalSince1970:10),metadata:metadata)
        let b=LocalBuild(url:a.url,size:6,modified:a.modified,metadata:metadata)
        precondition(a.fingerprint != b.fingerprint)
        print("Build metadata and install result verification: passed")
    }
}
