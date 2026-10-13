import Testing
@testable import SparkWatchCore

/// The action layer is the only part of this app that can break something, so the
/// command it issues and the capability probe around it are pinned by tests.
struct NodeControlTests {
    /// Verbatim probe output from spark-a / -01 (2026-10-10): passwordless
    /// sudo works, systemd is present, and every physical interface reports
    /// `disabled`, i.e. **no Wake-on-LAN**. The last point is why no wake button
    /// exists in the UI.
    static let probeWithSudoNoWake = """
    ##sudo
    ok
    ##systemd
    ok
    ##wake
    disabled
    disabled
    ##done
    """

    static let probeWithoutSudo = """
    ##sudo
    no
    ##systemd
    ok
    ##wake
    disabled
    ##done
    """

    static let probeWithoutSystemd = """
    ##sudo
    ok
    ##systemd
    no
    ##wake
    ##done
    """

    @Test func dgxBoxesCanShutDownButNotWake() {
        let support = NodeControl.parseSupport(Self.probeWithSudoNoWake)
        #expect(support.canShutDown)
        #expect(support.wakeAvailable == false)
        // The note has to say why there is no wake button, or the absence reads as
        // an unfinished feature.
        #expect(support.note.contains("不支持网络唤醒"))
    }

    @Test func missingSudoDisablesShutdownWithAReason() {
        let support = NodeControl.parseSupport(Self.probeWithoutSudo)
        #expect(support.canShutDown == false)
        #expect(support.note.contains("免密 sudo"))
    }

    @Test func missingSystemdDisablesShutdown() {
        let support = NodeControl.parseSupport(Self.probeWithoutSystemd)
        #expect(support.canShutDown == false)
        #expect(support.note.contains("systemd"))
    }

    @Test func wakeIsAvailableWhenAnInterfaceEnablesIt() {
        let support = NodeControl.parseSupport("##sudo\nok\n##systemd\nok\n##wake\nenabled\n")
        #expect(support.wakeAvailable)
        #expect(support.canShutDown)
    }

    /// The command itself: `sync` first (a 100 GB model has been writing into the
    /// unified pool), then the vendor script if present, else systemd.
    @Test func shutdownCommandIsGracefulAndNonInteractive() {
        let script = NodeControl.shutdownScript()
        #expect(script.hasPrefix("sync"))
        #expect(script.contains("sudo -n"))
        // `-n` matters: without it sudo blocks on a password prompt that no one
        // can answer over a monitoring channel, and the sheet would hang forever.
        #expect(script.contains("sudo -n spark-shutdown"))
        #expect(script.contains("sudo -n systemctl poweroff"))
        #expect(script.contains("##accepted"))
    }

    @Test func magicPacketHasTheStandardShape() {
        let packet = NodeControl.magicPacket(mac: "aa:bb:cc:dd:ee:ff")
        #expect(packet?.count == 102)
        #expect(packet?.prefix(6).allSatisfy { $0 == 0xFF } == true)
        #expect(packet?[6] == 0xAA)
        #expect(packet?[11] == 0xFF)
        // A MAC that cannot be parsed yields nothing rather than a half packet.
        #expect(NodeControl.magicPacket(mac: "not-a-mac") == nil)
        #expect(NodeControl.magicPacket(mac: "aa:bb:cc:dd:ee") == nil)
        // Dash-separated MACs are accepted (some tools print them that way).
        #expect(NodeControl.magicPacket(mac: "AA-BB-CC-DD-EE-FF")?.count == 102)
    }
}
