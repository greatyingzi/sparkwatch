import Darwin
import Foundation
import Testing

@testable import SparkWatchCore

/// Ownership of a local forward, which is what the 2026-10-16 leak was about.
///
/// ssh connects first and binds afterwards, so a spawn that is going to fail is
/// alive for a second or two. Recording its pid at `run()` time therefore wrote
/// down a process that was about to die and buried the pid of the orphan that
/// really held the port: after that, every launch spawned a fresh ssh that died
/// on `ExitOnForwardFailure` while the orphan kept answering, and the port stayed
/// bound for hours with nobody owning it.
@Suite("隧道归属与 pid 记录")
struct TunnelForwardTests {
    @Test func theForwardSpecIsExactlyWhatSshGets() {
        #expect(
            SshTunnel.forwardSpec(localPort: 19100, remotePort: 11000)
                == "127.0.0.1:19100:localhost:11000"
        )
    }

    /// Reclaim kills what matches, so the matcher has to be boringly precise.
    @Test func onlyOurOwnForwardMatches() {
        let ours = "/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes "
            + "-L 127.0.0.1:19100:localhost:11000 leon@dgx-spark-00"
        #expect(SshTunnel.isOurForward(ours, localPort: 19100, remotePort: 11000))
        // Same command, different ports: not ours.
        #expect(!SshTunnel.isOurForward(ours, localPort: 19101, remotePort: 11000))
        #expect(!SshTunnel.isOurForward(ours, localPort: 19100, remotePort: 18000))
        // The spec alone, inside a non-ssh process, is not a forward.
        #expect(
            !SshTunnel.isOurForward(
                "scp -L 127.0.0.1:19100:localhost:11000 a b", localPort: 19100, remotePort: 11000
            )
        )
        // The unrelated forward this machine really runs (a memory-hub tunnel to
        // an explicit IP) must never match: matching it deletes someone else's
        // tunnel.
        let foreign = "/usr/bin/ssh -N -o BatchMode=yes -L 127.0.0.1:9298:192.168.1.6:9200 leon@box"
        #expect(!SshTunnel.isOurForward(foreign, localPort: 9298, remotePort: 9200))
        #expect(!SshTunnel.isOurForward(foreign, localPort: 19100, remotePort: 11000))
    }

    @Test func theProcessTableIsTheAuthorityOnOwnership() {
        // A port pair nobody forwards: the matcher must come back empty rather
        // than guessing, because reclaim acts on what it returns.
        #expect(SshTunnel.matchingForwards(localPort: 45997, remotePort: 45998).isEmpty)
    }

    @Test func theRecordPolicyNeedsBothHalves() {
        #expect(TunnelReadiness.shouldRecord(processAlive: true, portOpen: true))
        #expect(!TunnelReadiness.shouldRecord(processAlive: false, portOpen: true))
        #expect(!TunnelReadiness.shouldRecord(processAlive: true, portOpen: false))
        #expect(!TunnelReadiness.shouldRecord(processAlive: false, portOpen: false))
    }

    @Test func theTcpProbeSeesARealListener() throws {
        let port = 45996
        #expect(!TcpProbe.isOpen(port: port))
        let listener = try LoopbackListener(port: port)
        defer { listener.close() }
        #expect(TcpProbe.isOpen(port: port))
    }

    /// The leak, end to end: when the port is already owned by something that is
    /// not one of our forwards, `start()` fails fast and writes **no** pid record.
    /// Before the fix the record was written at spawn time regardless, which is
    /// what made the real orphan unreclaimable.
    @Test func aPortWeCannotOwnLeavesNoPidRecord() throws {
        let port = 45995
        let listener = try LoopbackListener(port: port)
        defer { listener.close() }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sparkwatch-tunnel-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let tunnel = SshTunnel(
            host: "127.0.0.1", user: "nobody", localPort: port, pidDirectory: directory
        )
        #expect(throws: TunnelError.self) { try tunnel.start() }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "tunnel-\(port).pid").path
        ))
        #expect(!tunnel.isRunning)
    }
}

/// A real loopback listener: the probe and the policy are both about a socket
/// that answers, so the test asks the same question production asks.
private final class LoopbackListener {
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ListenerError.socket }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw ListenerError.bind(port)
        }
    }

    func close() {
        Darwin.close(descriptor)
    }

    enum ListenerError: Error {
        case socket
        case bind(Int)
    }
}
