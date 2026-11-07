import Foundation
import Darwin

extension Viewer {
    func startDiscovery() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes,
                       socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(5002).bigEndian
            addr.sin_addr.s_addr = 0

            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bound == 0 else {
                print("beacon bind failed")
                return
            }

            var buf = [UInt8](repeating: 0, count: 64)

            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)

                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buf, buf.count, 0, $0, &len)
                    }
                }

                guard n > 0,
                      String(decoding: buf[0..<n], as: UTF8.self)
                        .hasPrefix("MACDISPLAY1") else {
                    continue
                }

                let ip = String(cString: inet_ntoa(from.sin_addr))

                guard ip.hasPrefix("169.254.") ||
                      ip.hasPrefix("192.168.50.") else {
                    continue
                }

                self?.netQueue.async {
                    guard let self = self, self.host != ip else { return }

                    print("found host:", ip)
                    self.host = ip

                    self.videoGen += 1
                    self.conn?.cancel()

                    self.inputGen += 1
                    self.inputConn?.cancel()

                    self.connect()
                    self.connectInput()
                }
            }
        }
    }
}
