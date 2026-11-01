import Foundation
import Observation

/// User-adjustable settings (PRD 4.5), persisted in UserDefaults.
///
/// The server URL has no shipped default: the app asks for it on first launch
/// (or runs on the bundled demo data instead). It can be overridden for
/// development without touching the app: set the `TRACKSCOUT_SERVER_URL`
/// environment variable or pass the `-TrackScoutServerURL <url>` launch
/// argument to point the app at the reference server (`server/`).
@Observable
public final class AppSettings {
    public enum MapStyle: String, CaseIterable, Identifiable, Sendable {
        case imagery = "imagery"
        case hybrid = "hybrid"
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }
    public var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled) }
    }
    public var alertsPerDay: Int {
        didSet { defaults.set(alertsPerDay, forKey: Keys.alertsPerDay) }
    }
    public var quietStartHour: Int {
        didSet { defaults.set(quietStartHour, forKey: Keys.quietStartHour) }
    }
    public var quietEndHour: Int {
        didSet { defaults.set(quietEndHour, forKey: Keys.quietEndHour) }
    }
    public var monitorRadiusMeters: Double {
        didSet { defaults.set(monitorRadiusMeters, forKey: Keys.radius) }
    }
    public var mapStyle: MapStyle {
        didSet { defaults.set(mapStyle.rawValue, forKey: Keys.mapStyle) }
    }
    public var showAnswered: Bool {
        didSet { defaults.set(showAnswered, forKey: Keys.showAnswered) }
    }
    /// Photo uploads only over Wi-Fi (photo PRD 4.5: on by default, the
    /// server is on the home LAN). Off = upload over any network.
    public var photosWiFiOnly: Bool {
        didSet { defaults.set(photosWiFiOnly, forKey: Keys.photosWiFiOnly) }
    }
    /// Copy taken photos to the Camera Roll (photo PRD 4.5: off by default).
    public var saveToPhotos: Bool {
        didSet { defaults.set(saveToPhotos, forKey: Keys.saveToPhotos) }
    }
    /// Night-photo nudges for places whose wanted photo is night/both
    /// (photo PRD 4.4: on by default).
    public var nightAlertsEnabled: Bool {
        didSet { defaults.set(nightAlertsEnabled, forKey: Keys.nightAlertsEnabled) }
    }
    /// The "photo wanted" badge in the Nearby list and the map layer (photo
    /// PRD 4.2: a Settings toggle, on by default).
    public var showPhotoWanted: Bool {
        didSet { defaults.set(showPhotoWanted, forKey: Keys.showPhotoWanted) }
    }
    /// When true the app runs on the bundled demo data and never talks to a
    /// server (§8.2 "Use demo data"): no sync, no uploads, no image prefetch.
    public var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Keys.demoMode) }
    }
    /// The project name served by `GET /data/trackscout.json` (§8.2), shown in
    /// the header. Display-only; it is never part of the app's identity.
    public var projectName: String? {
        didSet {
            if let projectName {
                defaults.set(projectName, forKey: Keys.projectName)
            } else {
                defaults.removeObject(forKey: Keys.projectName)
            }
        }
    }
    /// Night-nudge window (photo PRD 4.4): minutes after sunset until the
    /// window opens. The server may override this via `trackscout.json`
    /// (§8.2); the defaults match the shipped 30 min / 23:30.
    public var nightWindowStartOffsetMinutes: Double {
        didSet { defaults.set(nightWindowStartOffsetMinutes, forKey: Keys.nightWindowStartOffset) }
    }
    /// Night-nudge window (photo PRD 4.4): fractional local hours (23.5 =
    /// 23:30) at which the window closes.
    public var nightWindowEndHour: Double {
        didSet { defaults.set(nightWindowEndHour, forKey: Keys.nightWindowEndHour) }
    }
    public var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: Keys.onboarded) }
    }

    private enum Keys {
        static let serverURL = "serverURL"
        static let demoMode = "demoMode"
        static let projectName = "projectName"
        static let nightWindowStartOffset = "nightWindowStartOffsetMinutes"
        static let nightWindowEndHour = "nightWindowEndHour"
        static let alertsEnabled = "alertsEnabled"
        static let alertsPerDay = "alertsPerDay"
        static let quietStartHour = "quietStartHour"
        static let quietEndHour = "quietEndHour"
        static let radius = "monitorRadiusMeters"
        static let mapStyle = "mapStyle"
        static let showAnswered = "showAnswered"
        static let photosWiFiOnly = "photosWiFiOnly"
        static let saveToPhotos = "saveToPhotos"
        static let nightAlertsEnabled = "nightAlertsEnabled"
        static let showPhotoWanted = "showPhotoWanted"
        static let onboarded = "onboarded"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        self.demoMode = defaults.object(forKey: Keys.demoMode) as? Bool ?? false
        self.projectName = defaults.string(forKey: Keys.projectName)
        self.nightWindowStartOffsetMinutes = defaults.object(forKey: Keys.nightWindowStartOffset) as? Double ?? 30
        self.nightWindowEndHour = defaults.object(forKey: Keys.nightWindowEndHour) as? Double ?? 23.5
        self.alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        self.alertsPerDay = defaults.object(forKey: Keys.alertsPerDay) as? Int ?? 3
        self.quietStartHour = defaults.object(forKey: Keys.quietStartHour) as? Int ?? 22
        self.quietEndHour = defaults.object(forKey: Keys.quietEndHour) as? Int ?? 8
        self.monitorRadiusMeters = defaults.object(forKey: Keys.radius) as? Double ?? 40
        self.mapStyle = MapStyle(rawValue: defaults.string(forKey: Keys.mapStyle) ?? "") ?? .imagery
        self.showAnswered = defaults.object(forKey: Keys.showAnswered) as? Bool ?? false
        self.photosWiFiOnly = defaults.object(forKey: Keys.photosWiFiOnly) as? Bool ?? true
        self.saveToPhotos = defaults.object(forKey: Keys.saveToPhotos) as? Bool ?? false
        self.nightAlertsEnabled = defaults.object(forKey: Keys.nightAlertsEnabled) as? Bool ?? true
        self.showPhotoWanted = defaults.object(forKey: Keys.showPhotoWanted) as? Bool ?? true
        self.onboarded = defaults.object(forKey: Keys.onboarded) as? Bool ?? false
    }

    /// The server URL actually used, or `nil` when there is none to use.
    ///
    /// Precedence (§8.2): the `TRACKSCOUT_SERVER_URL` environment variable,
    /// then the `-TrackScoutServerURL <url>` launch argument, then the
    /// persisted setting. A blank or unparseable value yields `nil`; callers
    /// treat that as "demo or not-ready" rather than crashing on a force
    /// unwrap, so a device without a URL degrades instead of building
    /// `URL(string: nil)`.
    public var resolvedServerURL: String? {
        let info = ProcessInfo.processInfo
        if let env = info.environment["TRACKSCOUT_SERVER_URL"], !env.isEmpty {
            return Self.sanitizedServerURL(env)
        }
        let args = info.arguments
        if let i = args.firstIndex(of: "-TrackScoutServerURL"), i + 1 < args.count,
           !args[i + 1].isEmpty {
            return Self.sanitizedServerURL(args[i + 1])
        }
        return Self.sanitizedServerURL(serverURL)
    }

    /// Trims and validates a URL string; returns it only when it is a
    /// non-empty `http(s)` URL with a host, else `nil`.
    private static func sanitizedServerURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host() != nil
        else { return nil }
        return trimmed
    }

    /// Applies optional project settings served by `GET /data/trackscout.json`
    /// (§8.2) to the persisted settings. A `nil` argument (the server has no
    /// `trackscout.json`) leaves every value untouched. The project name is
    /// always applied when present; the alert radius is applied only when the
    /// user has not already chosen one; the night window is applied per field
    /// when present.
    public func applyServerSettings(_ settings: TrackScoutSettingsDTO?) {
        guard let settings else { return }
        if let name = settings.name, !name.isEmpty {
            self.projectName = name
        }
        if let radius = settings.alertRadiusMeters,
           self.defaults.object(forKey: Keys.radius) == nil {
            self.monitorRadiusMeters = radius
        }
        if let window = settings.nightWindow {
            if let offset = window.startOffsetMinutes {
                self.nightWindowStartOffsetMinutes = offset
            }
            if let end = window.endHour {
                self.nightWindowEndHour = end
            }
        }
    }
}
