import Foundation

struct ServerConfig: Codable, Equatable {
    let host: String
    let port: Int
    let name: String?
    let password: String?
    
    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
    
    var displayName: String {
        name ?? "\(host):\(port)"
    }
    
    var requiresAuthentication: Bool {
        password != nil && !password!.isEmpty
    }
    
    var authorizationHeader: String? {
        guard let password = password, !password.isEmpty else { return nil }
        let credentials = "admin:\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        let base64 = data.base64EncodedString()
        return "Basic \(base64)"
    }
}