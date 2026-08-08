// 이 파일은 앱과 SwiftPM 실행 환경에서 OfficeCore 리소스 번들을 안전하게 찾는다.

import Foundation

enum OfficeCoreResourceBundle {
    static let bundle: Bundle = {
        if
            let resourcesURL = Bundle.main.resourceURL,
            let appBundle = Bundle(
                url: resourcesURL.appendingPathComponent(
                    "OfficeLLM_OfficeCore.bundle",
                    isDirectory: true
                )
            )
        {
            return appBundle
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            fatalError(
                "OFFICESTRA.app에 OfficeCore 리소스 번들이 없습니다."
            )
        }

        let bundleName = "OfficeLLM_OfficeCore.bundle"
        let executableDirectory = URL(
            fileURLWithPath: CommandLine.arguments[0]
        )
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let argumentDirectories = CommandLine.arguments
            .filter { $0.hasPrefix("/") }
            .map {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
            }
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            executableDirectory,
            executableDirectory.deletingLastPathComponent(),
        ] + argumentDirectories + Bundle.allBundles.map {
            $0.bundleURL.deletingLastPathComponent()
        }
        for directory in candidates {
            if let bundle = Bundle(
                url: directory.appendingPathComponent(
                    bundleName,
                    isDirectory: true
                )
            ) {
                return bundle
            }
        }
        fatalError("SwiftPM OfficeCore 리소스 번들이 없습니다.")
    }()
}
