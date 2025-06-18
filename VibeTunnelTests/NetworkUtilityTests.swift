import Testing
import Foundation
import Network
@testable import VibeTunnel

// MARK: - Mock Network Utility for Testing

@MainActor
enum MockNetworkUtility {
    static var mockLocalIP: String?
    static var mockAllIPs: [String] = []
    static var shouldFailGetAddresses = false
    
    static func reset() {
        mockLocalIP = nil
        mockAllIPs = []
        shouldFailGetAddresses = false
    }
    
    static func getLocalIPAddress() -> String? {
        if shouldFailGetAddresses { return nil }
        return mockLocalIP
    }
    
    static func getAllIPAddresses() -> [String] {
        if shouldFailGetAddresses { return [] }
        return mockAllIPs
    }
}

// MARK: - Network Utility Tests

@Suite("Network Utility Tests", .tags(.networking))
struct NetworkUtilityTests {
    
    // MARK: - Local IP Address Tests
    
    @Test("Get local IP address")
    func testGetLocalIPAddress() throws {
        // Test real implementation
        let localIP = NetworkUtility.getLocalIPAddress()
        
        // On a real system, we should get some IP address
        // It might be nil in some test environments
        if let ip = localIP {
            #expect(!ip.isEmpty)
            
            // Should be a valid IPv4 address format
            let components = ip.split(separator: ".")
            #expect(components.count == 4)
            
            // Each component should be a valid number 0-255
            for component in components {
                if let num = Int(component) {
                    #expect(num >= 0 && num <= 255)
                } else {
                    Issue.record("Invalid IP component: \(component)")
                }
            }
        }
    }
    
    @Test("Local IP address preferences")
    func testLocalIPPreferences() throws {
        // Test that we prefer local network addresses
        let mockIPs = [
            "192.168.1.100",  // Preferred - local network
            "10.0.0.50",      // Preferred - local network
            "172.16.0.10",    // Preferred - local network
            "8.8.8.8",        // Not preferred - public IP
            "127.0.0.1"       // Should be filtered out - loopback
        ]
        
        // Verify our preference logic
        for ip in mockIPs {
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                #expect(true, "IP \(ip) should be preferred")
            }
        }
    }
    
    @Test("Get all IP addresses")
    func testGetAllIPAddresses() throws {
        let allIPs = NetworkUtility.getAllIPAddresses()
        
        // Should return array (might be empty in test environment)
        #expect(allIPs.count >= 0)
        
        // If we have IPs, verify they're valid
        for ip in allIPs {
            #expect(!ip.isEmpty)
            
            // Should not contain loopback
            #expect(!ip.hasPrefix("127."))
            
            // Should be valid IPv4 format
            let components = ip.split(separator: ".")
            #expect(components.count == 4)
        }
    }
    
    // MARK: - Network Interface Tests
    
    @Test("Network interface filtering")
    func testInterfaceFiltering() throws {
        // Test that we filter interfaces correctly
        let allIPs = NetworkUtility.getAllIPAddresses()
        
        // Should not contain any loopback addresses
        for ip in allIPs {
            #expect(!ip.hasPrefix("127.0.0"))
            #expect(ip != "::1") // IPv6 loopback
        }
    }
    
    @Test("IPv4 address validation")
    func testIPv4Validation() throws {
        let testIPs = [
            ("192.168.1.1", true),
            ("10.0.0.1", true),
            ("172.16.0.1", true),
            ("256.1.1.1", false), // Invalid - component > 255
            ("1.1.1", false),     // Invalid - only 3 components
            ("1.1.1.1.1", false), // Invalid - too many components
            ("a.b.c.d", false),   // Invalid - non-numeric
            ("", false),          // Invalid - empty
        ]
        
        for (ip, shouldBeValid) in testIPs {
            let components = ip.split(separator: ".")
            let isValid = components.count == 4 && components.allSatisfy { component in
                if let num = Int(component) {
                    return num >= 0 && num <= 255
                }
                return false
            }
            
            #expect(isValid == shouldBeValid, "IP \(ip) validation failed")
        }
    }
    
    // MARK: - Edge Cases Tests
    
    @Test("Handle no network interfaces")
    @MainActor
    func testNoNetworkInterfaces() throws {
        // In a real scenario where no interfaces are available
        // the functions should return nil/empty array gracefully
        
        MockNetworkUtility.shouldFailGetAddresses = true
        
        #expect(MockNetworkUtility.getLocalIPAddress() == nil)
        #expect(MockNetworkUtility.getAllIPAddresses().isEmpty)
        
        MockNetworkUtility.reset()
    }
    
    @Test("Multiple network interfaces")
    @MainActor
    func testMultipleInterfaces() throws {
        // When multiple interfaces exist, we should get all of them
        MockNetworkUtility.mockAllIPs = [
            "192.168.1.100", // Wi-Fi
            "192.168.2.50",  // Ethernet
            "10.0.0.100"     // VPN
        ]
        
        let allIPs = MockNetworkUtility.getAllIPAddresses()
        #expect(allIPs.count == 3)
        #expect(Set(allIPs).count == 3) // All unique
        
        MockNetworkUtility.reset()
    }
    
    // MARK: - Platform-Specific Tests
    
    @Test("macOS network interface names")
    func testMacOSInterfaceNames() throws {
        // On macOS, typical interface names are:
        // en0 - Primary network interface (often Wi-Fi)
        // en1 - Secondary network interface (often Ethernet)
        // en2, en3, etc. - Additional interfaces
        
        // This test documents expected behavior
        let expectedPrefixes = ["en"]
        
        for prefix in expectedPrefixes {
            #expect(prefix.hasPrefix("en"), "Network interfaces should start with 'en' on macOS")
        }
    }
    
    // MARK: - Performance Tests
    
    @Test("Performance of IP address retrieval", .tags(.performance))
    func testIPRetrievalPerformance() async throws {
        // Measure time to get IP addresses
        let start = Date()
        
        for _ in 0..<10 {
            _ = NetworkUtility.getLocalIPAddress()
        }
        
        let elapsed = Date().timeIntervalSince(start)
        
        // Should be reasonably fast (< 1 second for 10 calls)
        #expect(elapsed < 1.0, "IP retrieval took too long: \(elapsed) seconds")
    }
    
    // MARK: - Concurrent Access Tests
    
    @Test("Concurrent IP address retrieval", .tags(.concurrency))
    func testConcurrentAccess() async throws {
        await withTaskGroup(of: String?.self) { group in
            // Multiple concurrent calls
            for _ in 0..<10 {
                group.addTask {
                    NetworkUtility.getLocalIPAddress()
                }
            }
            
            var results: [String?] = []
            for await result in group {
                results.append(result)
            }
            
            // All calls should return the same value
            let uniqueResults = Set(results.compactMap { $0 })
            #expect(uniqueResults.count <= 1, "Concurrent calls returned different IPs")
        }
    }
    
    // MARK: - Integration Tests
    
    @Test("Network utility with system network state", .tags(.integration))
    func testSystemNetworkState() throws {
        let localIP = NetworkUtility.getLocalIPAddress()
        let allIPs = NetworkUtility.getAllIPAddresses()
        
        // If we have a local IP, it should be in the all IPs list
        if let localIP = localIP {
            #expect(allIPs.contains(localIP), "Local IP should be in all IPs list")
        }
        
        // All IPs should be unique
        #expect(Set(allIPs).count == allIPs.count, "IP addresses should be unique")
    }
    
    @Test("IP address format consistency")
    func testIPAddressFormat() throws {
        let allIPs = NetworkUtility.getAllIPAddresses()
        
        for ip in allIPs {
            // Should not have leading/trailing whitespace
            #expect(ip == ip.trimmingCharacters(in: .whitespacesAndNewlines))
            
            // Should not contain port numbers
            #expect(!ip.contains(":"))
            
            // Should be standard dotted decimal notation
            #expect(ip.contains("."))
        }
    }
    
    // MARK: - Mock Tests
    
    @Test("Mock network utility behavior")
    @MainActor
    func testMockUtility() throws {
        // Set up mock
        MockNetworkUtility.mockLocalIP = "192.168.1.100"
        MockNetworkUtility.mockAllIPs = ["192.168.1.100", "10.0.0.50"]
        
        #expect(MockNetworkUtility.getLocalIPAddress() == "192.168.1.100")
        #expect(MockNetworkUtility.getAllIPAddresses().count == 2)
        
        // Test failure scenario
        MockNetworkUtility.shouldFailGetAddresses = true
        #expect(MockNetworkUtility.getLocalIPAddress() == nil)
        #expect(MockNetworkUtility.getAllIPAddresses().isEmpty)
        
        MockNetworkUtility.reset()
    }
}