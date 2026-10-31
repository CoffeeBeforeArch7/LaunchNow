import SwiftUI
import Foundation
import Combine

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
}

class Updater: ObservableObject {
    static let shared = Updater()
    
    private let owner = "ggkevinnnn"
    private let repo  = "LaunchNow"
    
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var alertURL: URL? = nil
    
    // 自用改版：不再从原作者仓库检查更新，免得下载原版把改版覆盖掉；
    // 上游有新版本时手动合并代码后重新编译。
    func checkForUpdate() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        alertTitle = "自用改版 v\(currentVersion)"
        alertMessage = "基于 \(owner)/\(repo) 修改，不从 GitHub 检查更新。"
        alertURL = nil
        showAlert = true
    }
    
    /// 从左到右比较版本号
    private func isVersion(_ versionA: String, greaterThan versionB: String) -> Bool {
        let vA = versionA.hasPrefix("v") ? String(versionA.dropFirst()) : versionA
        let vB = versionB.hasPrefix("v") ? String(versionB.dropFirst()) : versionB
        
        let componentsA = vA.split(separator: ".").compactMap { Int($0) }
        let componentsB = vB.split(separator: ".").compactMap { Int($0) }
        
        let count = max(componentsA.count, componentsB.count)
        
        for i in 0..<count {
            let a = i < componentsA.count ? componentsA[i] : 0
            let b = i < componentsB.count ? componentsB[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return false
    }
}
