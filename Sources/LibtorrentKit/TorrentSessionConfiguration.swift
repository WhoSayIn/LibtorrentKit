import Foundation

public struct TorrentSessionConfiguration: Sendable, Equatable {
    public var userAgent: String
    public var listenPortRange: ClosedRange<UInt16>
    public var enableDHT: Bool
    public var enableLocalServiceDiscovery: Bool
    public var enableUPnP: Bool
    public var enableNATPMP: Bool
    public var caBundleURL: URL
    public var checkpointTimeout: Duration

    public init(
        userAgent: String = "LibtorrentKit/1",
        listenPortRange: ClosedRange<UInt16> = 6881...6891,
        enableDHT: Bool = true,
        enableLocalServiceDiscovery: Bool = true,
        enableUPnP: Bool = true,
        enableNATPMP: Bool = true,
        caBundleURL: URL,
        checkpointTimeout: Duration = .seconds(15)
    ) {
        self.userAgent = userAgent
        self.listenPortRange = listenPortRange
        self.enableDHT = enableDHT
        self.enableLocalServiceDiscovery = enableLocalServiceDiscovery
        self.enableUPnP = enableUPnP
        self.enableNATPMP = enableNATPMP
        self.caBundleURL = caBundleURL
        self.checkpointTimeout = checkpointTimeout
    }
}
