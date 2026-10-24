import Foundation

/// Build identity and a policy boundary, never a persisted preference.
enum PipEditionPolicy {
    #if PIP_EDITION
        static let isPip = true
        static let allowsAutomaticDetection = false
        static let allowsRemoteProviders = false
        static let allowsUpdates = false
        static let allowsAutomation = false
    #else
        static let isPip = false
        static let allowsAutomaticDetection = true
        static let allowsRemoteProviders = true
        static let allowsUpdates = true
        static let allowsAutomation = true
    #endif
}

/// The local product core is shared by neutral and Pip skins. The immutable
/// upstream reference remains a separate provenance build.
enum MeetingsBuildIdentity {
    #if PIP_NEUTRAL && !MEETINGS_REPLICA
    static let name = "Meetings Baseline"
    static let dataFolder = "MeetingsNeutral"
    static let bundleID = "uk.pipreps.meetings.neutral"
    #elseif PIP_NEUTRAL
    static let name = "Meetings Replica"
    static let dataFolder = "MeetingsReplica"
    static let bundleID = "uk.pipreps.meetings.replica"
    #else
    static let name = "Pip Meetings"
    static let dataFolder = "PipMeetings"
    static let bundleID = "uk.pipreps.meetings"
    #endif
    #if MEETINGS_ENHANCEMENTS
    static let enhanced = true
    static let suffix = " Enhanced"
    #else
    static let enhanced = false
    static let suffix = ""
    #endif
    static var displayName: String { name + suffix }
    static var storageName: String { dataFolder + (enhanced ? "Enhanced" : "") }
    static var subsystem: String { bundleID + (enhanced ? ".enhanced" : "") }
}
