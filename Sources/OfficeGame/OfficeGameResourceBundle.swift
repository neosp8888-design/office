// 이 파일은 앱과 SwiftPM 실행 환경에서 OfficeGame 리소스 번들을 안전하게 찾는다.

import Foundation

enum OfficeGameResourceBundle {
    static let bundle: Bundle = {
        if
            let resourcesURL = Bundle.main.resourceURL,
            let appBundle = Bundle(
                url: resourcesURL.appendingPathComponent(
                    "OfficeLLM_OfficeGame.bundle",
                    isDirectory: true
                )
            )
        {
            return appBundle
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            fatalError(
                "OFFICESTRA.app에 OfficeGame 리소스 번들이 없습니다."
            )
        }

        return Bundle.module
    }()
}
