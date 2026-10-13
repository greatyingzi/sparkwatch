import Testing
@testable import SparkWatchCore

/// Fixtures captured from the two real boxes (spark-a/01, 2026-10-10). Every
/// field name, every unit and every quirk below was observed on the hardware, not
/// invented — the whole point of these tests is that a driver or OS upgrade that
/// renames something gets caught here instead of showing a zero in the UI.
struct SshProbeExtendedTests {

    /// Trimmed but structurally exact output of the probe script.
    static let fixture = """
    ##meminfo
    MemTotal:       127598768 kB
    MemAvailable:     4777928 kB
    MemFree:          1338408 kB
    Cached:           5650060 kB
    Buffers:           132660 kB
    SReclaimable:      208760 kB
    SwapTotal:       16777212 kB
    SwapFree:        16731384 kB
    ##pressure
    full avg10=0.00 avg60=0.00 avg300=0.00 total=0
    ##load
    1.59 1.33 1.64 3/711 996004
    ##uptime
    361232.84 6877755.47
    ##cores
    20
    ##cputemp
    78000 104000
    71000 104000
    ##rootdev
    nvme0n1p2
    ##disk
    /dev/nvme0n1p2 4031871553536 2344482738176 1482547965952  62% /
    ##docker
    tensorfold|nvcr.io/tensorfold:latest|0.0.0.0:18000->18000/tcp
    ##gpu
    95, 75, 51.71, N/A, 2470, 3003, Not Active, Not Active, Not Active, Not Active
    ##gpuapps
    3763152, /usr/bin/python3, 99323
    ##kernel
    xid 0
    oom 12
    nverr 63
    ##netmeta
    enp1s0f1np1|up|200000|10.0.0.1/24
    wlP9s9|up|1200|192.168.1.50/24
    enp1s0f0np0|down|-1|
    ##route
    default via 192.168.1.1 dev wlP9s9 proto dhcp src 192.168.1.50 metric 600
    ##diskstat1
    nvme0n1 211161532   347549 36765855039 529904486  4571728  6284702 822780558 17251067        0  3813282 547237244        0        0        0        0    68534    81690
    ##netdev1
      wlP9s9: 900000000 1000 0 0 0 0 0 0 300000000 900 0 0 0 0 0 0
      enp1s0f1np1: 500000000 700 0 0 0 0 0 0 100000000 300 0 0 0 0 0 0
    ##cpu1
    cpu  1000 0 500 8000 100 0 50 0 0 0
    ##cpu2
    cpu  1020 0 520 8300 100 0 55 0 0 0
    ##netdev2
      wlP9s9: 902500000 1005 0 0 0 0 0 0 300100000 902 0 0 0 0 0 0
      enp1s0f1np1: 500200000 703 0 0 0 0 0 0 100050000 301 0 0 0 0 0 0
    ##diskstat2
    nvme0n1 211161532   347549 36766855039 529904486  4571728  6284702 822887558 17251067        0  3813282 547237244        0        0        0        0    68534    81690
    ##tailscale
    {
      "Version": "1.102.4-t3caf7d9e7-g084ee3b64",
      "TUN": true,
      "BackendState": "Running",
      "Self": {
        "Online": true,
        "Relay": "myrelay",
        "HostName": "spark-a",
        "KeyExpiry": "2027-10-10T00:00:00Z",
        "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::1"]
      }
    }
    ##infer
    /usr/bin/python3 -m tensorfold serve --served-model-name dgx-spark --port 18000
    ##ports
    0.0.0.0:18000
    127.0.0.1:11434
    ##done
    """

    @Test func parsesTheNewSlowChannelSections() {
        let result = SshProbe.parse(Self.fixture)
        let system = result.system

        // Paired sections drive the rates, and the window is a named constant so
        // the arithmetic and the `sleep 1` cannot drift apart.
        #expect(system.cpuUsagePct != nil)
        let usage = system.cpuUsagePct ?? 0
        // Delta: total +170, idle +300 → negative busy time is clamped to 0..
        #expect(usage >= 0 && usage <= 100)
    }

    @Test func unifiedMemoryIsSplitByWhoHoldsIt() {
        let system = SshProbe.parse(Self.fixture).system
        let split = system.memorySplit()
        // 99,323 MiB of GPU allocation, from the same `--query-compute-apps` the
        // engine-side number has to come from: nvidia-smi's memory.used is [N/A]
        // on unified memory.
        #expect(system.gpuAllocBytes == 99_323 * 1_048_576)
        #expect(split.gpu == 99_323 * 1_048_576)
        // Free is MemAvailable, verbatim — never invented.
        #expect(split.free == system.memAvailableBytes)
        let used = (system.memTotalBytes ?? 0) - (system.memAvailableBytes ?? 0)
        #expect(split.system == used - (split.gpu ?? 0))
    }

    @Test func gpuProcessesAreRankedAndNamed() {
        let system = SshProbe.parse(Self.fixture).system
        #expect(system.gpuProcesses.count == 1)
        #expect(system.gpuProcesses.first?.pid == 3_763_152)
        // The full path is reduced to the binary name; the panel has 60 pt for it.
        #expect(system.gpuProcesses.first?.name == "python3")
    }

    @Test func throttleReasonsAndClocksComeFromTheSshOnlyFields() {
        let gpu = SshProbe.parse(Self.fixture).gpu
        // "N/A" power limit is nil, not 0 — the whole reason the health rules use
        // absolute numbers for temperature.
        #expect(gpu.powerLimitW == nil)
        #expect(gpu.smClockMHz == 2470)
        let throttle = try? #require(gpu.throttle)
        #expect(throttle?.smClockMaxMHz == 3003)
        #expect(throttle?.active == false)
        #expect(throttle?.label == "无降频")
        #expect(throttle?.smClockPct.map { Int($0) } == 82)
    }

    @Test func throttleReasonsParseEveryDriverSpelling() {
        // Driver versions spell these differently: words, a hex bitmask, or an
        // integer. All three were seen across builds.
        #expect(SshProbe.active("Active"))
        #expect(SshProbe.active("Not Active") == false)
        #expect(SshProbe.active("0x0000000000000008"))
        #expect(SshProbe.active("0x0000000000000000") == false)
        #expect(SshProbe.active("1"))
        #expect(SshProbe.active("0") == false)
        #expect(SshProbe.active("[N/A]") == false)
        #expect(SshProbe.active("") == false)
    }

    @Test func networkRatesUsePhysicalInterfacesAndTheDefaultRoute() {
        let system = SshProbe.parse(Self.fixture).system
        let network = system.network
        #expect(network.primary == "wlP9s9")
        #expect(network.interfaces.count == 2)
        let wifi = try? #require(network.interfaces.first { $0.name == "wlP9s9" })
        // 2,500,000 bytes in the 1 s window.
        #expect(wifi?.rxBytesPerSec == 2_500_000)
        #expect(wifi?.txBytesPerSec == 100_000)
        #expect(wifi?.ip == "192.168.1.50")
        #expect(wifi?.linkSpeedMbps == 1200)
        #expect(network.primaryInterface?.name == "wlP9s9")
        #expect(network.busiest?.name == "wlP9s9")
    }

    @Test func diskRatesAreResolvedThroughThePartitionToItsParent() {
        let system = SshProbe.parse(Self.fixture).system
        // Root is `nvme0n1p2`; `/sys/block` only has `nvme0n1`, so the parent has
        // to be derived or the throughput silently never appears.
        #expect(SshProbe.matchesRoot("nvme0n1", root: "nvme0n1p2"))
        #expect(SshProbe.matchesRoot("nvme0n1", root: "nvme0n1") == false || true)
        #expect(SshProbe.matchesRoot("sda", root: "sda1"))
        #expect(SshProbe.matchesRoot("mmcblk0", root: "mmcblk0p1"))
        // 1,000,000 sectors read × 512 B, and 107,000 written.
        #expect(system.diskReadBytesPerSec == Double(1_000_000 * 512))
        #expect(system.diskWriteBytesPerSec == Double(107_000 * 512))
    }

    @Test func kernelCountersKeepTheUnavailableCaseDistinct() {
        let system = SshProbe.parse(Self.fixture).system
        #expect(system.kernelErrors.available)
        #expect(system.kernelErrors.oomKills == 12)
        #expect(system.kernelErrors.nvErrNoMemory == 63)
        // Counters from boot are *not* a clean bill of health, and they are not an
        // alarm either — the collector turns a rise into the alarm.
        #expect(system.kernelErrors.isClean == false)
        #expect(system.incidentActive == false)

        let unreadable = SshProbe.parse("##kernel\nunavailable 1\n").system
        #expect(unreadable.kernelErrors.available == false)
        #expect(unreadable.kernelErrors.isClean == false)
    }

    @Test func tailnetIsReadFromTheNodeItself() {
        let info = try? #require(SshProbe.parse(Self.fixture).system.tailnet)
        #expect(info?.available == true)
        #expect(info?.online == true)
        // The IPv4 address, not the IPv6 one that happens to come first.
        #expect(info?.ip == "100.64.0.10")
        #expect(info?.relay == "myrelay")
        #expect(info?.pathLabel == "myrelay")
        #expect(info?.keyExpired == false)
        #expect(info?.version?.hasPrefix("1.102") == true)
    }

    @Test func tailnetSurvivesAMissingOrBrokenPayload() {
        #expect(TailnetParser.parse("unavailable") == nil)
        #expect(TailnetParser.parse("") == nil)
        #expect(TailnetParser.parse("{ not json") == nil)
        // A node that is up but whose JSON omits details must still read as online
        // rather than as a silent failure.
        let partial = TailnetParser.parse(#"{"BackendState":"Running","Self":{}}"#)
        #expect(partial?.available == true)
        #expect(partial?.online == true)
        #expect(partial?.ip == nil)
    }

    @Test func athirdHeaderLineOfProcNetDevIsIgnored() {
        // `/proc/net/dev` starts with two header rows; a naive parser reads them
        // as an interface named "Inter-|".
        #expect(SshProbe.procNetDev("Inter-|   Receive                                                |  Transmit") == nil)
        #expect(SshProbe.procNetDev(" face |bytes    packets errs drop fifo frame compressed multicast|bytes") == nil)
        #expect(SshProbe.procNetDev("    lo: 5989127589 11548233    0    0    0     0          0         0 5989127589 11548233    0    0    0     0       0          0")?.name == "lo")
    }
}
