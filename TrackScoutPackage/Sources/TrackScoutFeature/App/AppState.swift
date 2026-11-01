import CoreLocation
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Top-level application state: owns the services, wires their callbacks
/// together, and publishes the derived data the views render (the places
/// list, the questions, the outbox, the sync status).
///
/// The shell (`TrackScoutApp`) creates exactly one and passes it to
/// `ContentView`; scene phase changes and app launch flow through here.
@MainActor
@Observable
public final class AppState {
    /// The screens the app can be on. Kept as a small value-type route so
    /// navigation is explicit and the `NotificationRouter` can deep-link
    /// into a place. `NavigationStack.path` holds these.
    public enum Route: Hashable {
        case main // the Nearby / All tabs (always the stack root)
        case place(key: String) // the question pager for one place
        case settings
        case onboarding
    }

    /// What the header and Settings show about the last sync.
    public struct SyncStatus: Equatable {
        public var lastSync: Date?
        public var outboxCount: Int = 0
        public var lastError: String? = nil
    }

    public let context: ModelContext
    public let settings: AppSettings
    public let location: LocationService
    public let placeMonitor: PlaceMonitor
    /// The shared camera (photo PRD 5.2), owned here so the Capture tab,
    /// the storefront set, and the question-page camera all drive the same
    /// session.
    public let camera: CameraController
    /// Device-frame gravity for the level indicator (photo PRD 5.2).
    public let attitude: DeviceAttitude
    public let syncEngine: SyncEngine
    public let notificationRouter: NotificationRouter
    public let alertScheduler: AlertScheduler

    /// Convenience for views: the image cache reader.
    public var imageStore: ImageStore { syncEngine.imageStore }

    /// Convenience for views: the photo outbox / file store (photo PRD 4.5).
    public var photoStore: PhotoStore { syncEngine.photoStore }

    /// A fresh client for UI-triggered downloads (owner-photo thumbnails).
    /// The sync engine builds its own per run; this one follows the current
    /// settings URL on demand. `nil` until a usable URL exists (§8.2: the
    /// app ships without one) — callers degrade, they do not crash.
    public var client: ReviewServerClient? {
        guard let raw = settings.resolvedServerURL, let baseURL = URL(string: raw) else {
            return nil
        }
        return LiveReviewServer(baseURL: baseURL)
    }

    /// Session cache of server-side photo JPEGs, keyed by `photoID` (photo
    /// PRD 4.1): the question-page strip and the fullscreen view must not
    /// re-download on every tap. `ImageStore` deliberately knows only the
    /// question-image paths, so the `/photo/` URLs come through here.
    @ObservationIgnored private var fetchedOwnerPhotoData: [String: Data] = [:]

    /// The JPEG for a server-side photo, fetched once per session
    /// (`GET /photo/<stored>`); `nil` when the record has no path, no server
    /// URL resolves, or the download fails (the thumbnail simply does not
    /// render).
    public func ownerPhotoData(for photo: OwnerPhoto) async -> Data? {
        guard let stored = photo.stored, let client else { return nil }
        if let cached = fetchedOwnerPhotoData[photo.photoID] { return cached }
        do {
            let data = try await client.downloadImage(from: client.photoURL(for: stored), timeout: 15)
            fetchedOwnerPhotoData[photo.photoID] = data
            return data
        } catch {
            return nil
        }
    }

    // MARK: Published state

    /// The navigation stack above the main screen; empty = main is on top.
    public var path: [Route] = []
    public private(set) var syncStatus = SyncStatus()
    public private(set) var isSyncing = false

    /// All questions, in display order (the project's order of group labels —
    /// alphabetical before the first sync — then page, then order). Views
    /// filter and slice this.
    public private(set) var questions: [Question] = []
    /// The project's intended display order of group labels, from the last
    /// sync's questions file (`groups` array). `nil` before the first sync:
    /// the question order falls back to alphabetical.
    @ObservationIgnored public private(set) var groupOrder: [String]?
    /// All places, unsorted — views sort by distance with animation.
    public private(set) var places: [Place] = []
    /// Outbox items, newest first (for the Settings list).
    public private(set) var outbox: [OutboxItem] = []
    /// Photo outbox records (photo PRD 4.5), oldest first. `PhotoStore` is
    /// not observable, so views (the Settings photo list, the Capture tab's
    /// "waiting to upload" state) read this snapshot instead of the store.
    public private(set) var photoOutbox: [PhotoOutboxItem] = []
    /// The server's photo records (`owner_photos.json`), rebuilt wholesale
    /// per sync. Drives the question-page thumbnails and the
    /// "has a day / night photo" state.
    public private(set) var ownerPhotos: [OwnerPhoto] = []

    @ObservationIgnored private var questionsByID: [String: Question] = [:]
    @ObservationIgnored private var lastMonitorRefresh = Date.distantPast
    @ObservationIgnored private var lastMonitorRefreshLocation: CLLocation?

    public init(context: ModelContext, settings: AppSettings = AppSettings()) {
        self.context = context
        self.settings = settings
        self.location = LocationService()
        self.placeMonitor = PlaceMonitor()
        // The client is built per sync so a URL change in Settings applies
        // to the very next one. No URL is a reported state, not a crash:
        // the factory throws `NoServerURLError` and the sync surfaces it.
        self.syncEngine = SyncEngine(context: context) {
            guard let raw = settings.resolvedServerURL,
                  let baseURL = URL(string: raw)
            else {
                throw NoServerURLError()
            }
            return LiveReviewServer(baseURL: baseURL)
        }
        self.notificationRouter = NotificationRouter()
        self.alertScheduler = AlertScheduler(context: context, settings: settings)
        self.camera = CameraController()
        self.attitude = DeviceAttitude()

        // Photo PRD 4.5: uploads are Wi-Fi-only by default; the gate re-reads
        // both the setting and the current path on every sync.
        self.syncEngine.shouldUploadPhotos = { [weak self] in
            guard let self else { return false }
            return !self.settings.photosWiFiOnly || self.syncEngine.isWiFi
        }

        // PRD 4.2: the first screen on a fresh install is the onboarding
        // that asks for Always (with an explanation).
        if !settings.onboarded {
            self.path = [.onboarding]
        }

        wireCallbacks()
    }

    /// Question ids with a pending (unconfirmed) outbox item — a question
    /// with one counts as answered until the server confirms or rejects it
    /// (PRD 4.1). Views use this to badge questions and count progress.
    public var pendingOutboxQuestionIDs: Set<String> {
        Set(outbox.filter { $0.state == .pending }.map(\.questionID))
    }

    /// A question by id (the denormalised lookup the views need).
    public func question(_ id: String) -> Question? {
        questionsByID[id]
    }

    /// This question's local photos (pending or sent), for the question-page
    /// thumbnail strip (photo PRD 4.1).
    public func localPhotos(forQuestion questionID: String) -> [PhotoOutboxItem] {
        photoOutbox.filter { $0.questionID == questionID }
    }

    /// This question's server-side photos, for the thumbnail strip (photo
    /// PRD 4.1).
    public func serverPhotos(forQuestion questionID: String) -> [OwnerPhoto] {
        ownerPhotos.filter { $0.questionID == questionID }
    }

    /// The next open question of the question's place, in display order,
    /// after `id` (PRD 4.4: submit moves to the next open question of the
    /// place). Call this *before* recording the answer — once the answer is
    /// in, the pager reorders its pages and the caller just needs the id.
    public func nextOpenQuestionID(after id: String) -> String? {
        guard let question = questionsByID[id], let placeKey = question.placeKey,
              let place = places.first(where: { $0.key == placeKey }) else {
            return nil
        }
        let displayOrder = Dictionary(uniqueKeysWithValues: questions.enumerated().map { ($0.element.id, $0.offset) })
        let open = place.questionIDs
            .compactMap { questionsByID[$0] }
            .filter { !$0.isAnswered(outboxQuestionIDs: pendingOutboxQuestionIDs) }
            .sorted { displayOrder[$0.id, default: 0] < displayOrder[$1.id, default: 0] }
        guard let index = open.firstIndex(where: { $0.id == id }) else { return nil }
        return open.dropFirst(index + 1).first?.id
    }

    // MARK: Lifecycle

    /// Called once at launch (before the first `.active`).
    public func appDidLaunch() async {
        // Taps on notifications while the app was suspended never fire
        // `didReceive`; collect them now so they can be flushed when the
        // scene becomes active.
        await notificationRouter.collectPendingNotifications()
        // The first launch opens onboarding (see init); if it was already
        // popped and not finished, bring it back.
        if !settings.onboarded, path.first != .onboarding {
            path = [.onboarding]
        }
        // Demo mode (§8.2): load the bundled sample questions at launch so
        // the app is fully usable without a server.
        if settings.demoMode {
            await loadDemoData()
        }
        // The named monitor must not be created while the keychain/protected
        // data is sealed; PlaceMonitor handles the deferral itself.
        placeMonitor.start()
    }

    /// Called from the shell's `onChange(of: scenePhase)`.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            location.setForeground(true)
            location.applyAuthorization()
            placeMonitor.start()
            Task {
                await notificationRouter.flushPendingOpenPlaces()
                await sync(auto: true) // PRD 4.1: auto-sync on foreground
            }
        case .inactive:
            // The app is still visible (Control Center, app switcher
            // transition) — keep live updates running.
            break
        case .background:
            location.setForeground(false)
        @unknown default:
            break
        }
    }

    private func wireCallbacks() {
        location.onAuthorizationChange = { [weak self] _ in
            guard let self else { return }
            // Re-assert the update loop: the authorization may have changed
            // (granted via onboarding, or changed in Settings) while the
            // scene phase stayed the same.
            self.location.applyAuthorization()
        }

        location.onSignificantChange = { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshMonitoredPlaces(throttled: true) }
        }

        placeMonitor.onEntry = { [weak self] key in
            guard let self else { return }
            // The entry itself is the trigger for a re-selection (the PRD
            // wants the monitored set recomputed on every entry/exit) and
            // for the nudge.
            await self.refreshMonitoredPlaces(throttled: false)
            guard self.settings.alertsEnabled, self.location.allowsBackgroundAlerts else { return }
            await self.alertScheduler.handleEntry(placeKey: key)
            // Photo PRD 4.4: the night nudge is a separate gate — its own
            // night window (sunset + offset → the project's end hour) instead
            // of quiet hours, so it is a separate call. In practice at most
            // one of the two passes: entry alerts die in quiet hours, night
            // nudges die in daylight.
            await self.alertScheduler.handleNightNudge(placeKey: key)
        }

        notificationRouter.onOpenPlace = { [weak self] key in
            self?.openPlace(key)
        }
    }

    // MARK: Sync

    /// One sync in the PRD order (outbox → questions → answers → image
    /// prefetch). `auto` uses the short 3 s request timeout of the
    /// launch/foreground syncs; manual "Sync now" gets 15 s.
    ///
    /// In demo mode (§8.2) there is no server: the sync confirms the outbox
    /// locally, uploads nothing, and prefetches nothing.
    public func sync(auto: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let outcome: SyncOutcome
        if settings.demoMode {
            outcome = syncEngine.demoSync()
        } else {
            outcome = await syncEngine.sync(timeout: auto ? 3 : 15)
        }
        if let error = outcome.error {
            syncStatus.lastError = error
        } else {
            syncStatus.lastError = nil
            syncStatus.lastSync = .now
        }
        if let groupOrder = outcome.groupOrder {
            self.groupOrder = groupOrder
        }
        if let projectSettings = outcome.projectSettings {
            settings.applyServerSettings(projectSettings)
        }

        await refreshDerived()
        await refreshMonitoredPlaces(throttled: false)
        // Step 4 of the sync: Wi-Fi-only, best-effort, never blocking — and
        // pointless in demo mode (the sample has no images to fetch).
        if !settings.demoMode {
            Task { await syncEngine.prefetchImages() }
        }
    }

    /// Loads the bundled demo questions into the store (§8.2 "Use demo
    /// data"). Idempotent: the questions are matched by id, so loading over
    /// an existing set is a plain refresh.
    public func loadDemoData() async {
        guard let doc = DemoData.questionsDoc() else { return }
        if let groups = doc.groups {
            groupOrder = groups
        }
        try? syncEngine.applyQuestions(doc, groupOrder: doc.groups)
        await refreshDerived()
    }

    // MARK: Derived data

    /// Re-reads the store into the published arrays after any change that
    /// affects what the screens show.
    public func refreshDerived() async {
        let allQuestions = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        let allPlaces = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let allOutbox = (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
        let allPhotoItems = (try? context.fetch(FetchDescriptor<PhotoOutboxItem>())) ?? []
        let allOwnerPhotos = (try? context.fetch(FetchDescriptor<OwnerPhoto>())) ?? []

        let byID = Dictionary(uniqueKeysWithValues: allQuestions.map { ($0.id, $0) })
        let order = PlaceBuilder.groupOrder(groupOrder)
        questions = allQuestions.sorted { a, b in
            let left = order(a.group, b.group)
            let right = order(b.group, a.group)
            if left && !right { return true }
            if right && !left { return false }
            if a.page != b.page { return a.page < b.page }
            return a.order < b.order
        }
        places = allPlaces
        outbox = allOutbox.sorted { $0.createdAt > $1.createdAt }
        photoOutbox = allPhotoItems.sorted { $0.createdAt < $1.createdAt }
        ownerPhotos = allOwnerPhotos
        questionsByID = byID
        syncStatus.outboxCount = allOutbox.filter { $0.state == .pending }.count

        // Denormalise which light kinds a question has a photo of (photo
        // PRD 4.1: the "wanted" chip and the open/answered state). Rejected
        // photos do not count — they never made it to the server.
        var lightsByQuestion: [String: Set<String>] = [:]
        for item in allPhotoItems where item.state != .rejected {
            if let questionID = item.questionID {
                lightsByQuestion[questionID, default: []].insert(item.lightRaw)
            }
        }
        for photo in allOwnerPhotos where photo.questionID != nil {
            if let questionID = photo.questionID, let light = photo.light {
                lightsByQuestion[questionID, default: []].insert(light.rawValue)
            }
        }
        for question in allQuestions {
            question.photoLights = lightsByQuestion[question.id]?.sorted() ?? []
        }
        try? context.save()
    }

    // MARK: Monitored places

    /// Recomputes the 20-nearest-open-places selection and hands it to the
    /// monitor. `throttled` adds the 15 s / 25 m guard for the
    /// significant-change trigger; entries, syncs, and answers refresh
    /// immediately.
    public func refreshMonitoredPlaces(throttled: Bool) async {
        guard let center = location.lastLocation?.coordinate else { return }
        if throttled {
            let now = Date()
            // 15 s and 25 m since the last refresh — the significant-change
            // trigger fires every ~500 m, this keeps the selection from
            // churning on each hop.
            if let last = lastMonitorRefreshLocation,
               now.timeIntervalSince(lastMonitorRefresh) < 15,
               Geo.distance(from: center, to: last.coordinate) < 25 {
                return
            }
            lastMonitorRefresh = now
            lastMonitorRefreshLocation = location.lastLocation
        }

        let pending = pendingOutboxQuestionIDs
        let monitored = places.map { place in
            let isOpen = place.questionIDs.contains { id in
                guard let question = questionsByID[id] else { return false }
                return !question.isAnswered(outboxQuestionIDs: pending)
            }
            return MonitoredPlace(key: place.key, lat: place.lat, lon: place.lon, isOpen: isOpen)
        }
        let selected = MonitoredPlaceSelector.select(monitored, center: center)
        await placeMonitor.update(places: selected, radius: settings.monitorRadiusMeters)
    }

    // MARK: Answers

    /// Records an answer in the outbox and syncs immediately (PRD 4.1: the
    /// outbox is the source of truth for "answered"; the sync confirms it).
    public func submitAnswer(question: Question, answer: String, comment: String?) async {
        // Photo PRD 4.1: a photo for the question that is still in the
        // outbox is mentioned in the answer's comment, so the server's view
        // says a photo is coming with it.
        var comment = comment
        if photoStore.localPhotos(forQuestion: question.id).contains(where: { $0.state == .pending }) {
            comment = comment.map { $0 + " [photo]" } ?? "[photo]"
        }
        let item = OutboxItem(questionID: question.id, answer: answer, comment: comment)
        context.insert(item)
        try? context.save()
        await refreshDerived()
        // A deliberate user action gets the generous 15 s request timeout,
        // not the 3 s one of the launch/foreground syncs: the questions file
        // is large, and a 3 s timeout would abort this sync before the
        // confirmation of the answer we just POSTed applied.
        await sync(auto: false)
    }

    /// Removes a rejected (or stale) outbox item (PRD 4.1: the user can
    /// delete rejected answers from Settings).
    public func deleteOutboxItem(_ item: OutboxItem) {
        context.delete(item)
        try? context.save()
        Task { await refreshDerived() }
    }

    // MARK: Photos

    /// Captures one photo with the shared camera (photo PRD 5.2): the JPEG
    /// and one precise location sample at the shutter moment run in
    /// parallel; the light kind is the sun at the capture time (or the
    /// user's override) and the heading/pitch come from the device.
    @discardableResult
    public func capturePhoto(
        questionID: String? = nil,
        placeKey: String? = nil,
        building: String,
        kind: PhotoKind,
        lightOverride: LightKind? = nil,
        note: String? = nil,
        setID: String? = nil,
        setStep: String? = nil
    ) async throws -> PhotoOutboxItem {
        async let jpeg = camera.capturePhoto()
        async let fix = location.samplePreciseLocation(timeout: 10)
        let (imageData, location) = try await (jpeg, fix)

        let taken = Date()
        let light = lightOverride ?? {
            guard let coordinate = location?.coordinate else { return LightKind.day }
            return Sun.kind(time: taken, lat: coordinate.latitude, lon: coordinate.longitude)
        }()
        let meta = PhotoMeta(
            photoID: UUID().uuidString,
            questionID: questionID,
            placeKey: placeKey,
            building: building,
            kind: kind,
            light: light,
            taken: taken,
            lat: location?.coordinate.latitude,
            lon: location?.coordinate.longitude,
            accuracyMeters: location?.horizontalAccuracy,
            headingDegrees: self.location.heading,
            pitchDegrees: attitude.pitchDegrees,
            source: .camera,
            note: note,
            setID: setID,
            setStep: setStep
        )
        let item = try photoStore.add(meta: meta, jpeg: imageData)
        // Photo PRD 4.5: copy to the Camera Roll only when the setting is on.
        // The survey photo is already stored locally, so a library failure
        // here is silently dropped.
        if settings.saveToPhotos {
            _ = await PhotoLibrary.save(jpeg: imageData, taken: taken)
        }
        await refreshDerived()
        return item
    }

    /// Whether an imported photo must be confirmed with "Taken here?" before
    /// it is attached (photo PRD 5.3: the EXIF location is more than 150 m
    /// from the chosen place). No place, no EXIF location, or close enough
    /// all attach without a prompt.
    public func needsTakenHereConfirmation(exifCoordinate: CLLocationCoordinate2D?, placeKey: String?) -> Bool {
        guard
            let exifCoordinate,
            let placeKey,
            let placeCoordinate = Geo.coordinate(forKey: placeKey)
        else {
            return false
        }
        return Geo.distance(from: exifCoordinate, to: placeCoordinate) > 150
    }

    /// Attaches an imported photo (photo PRD 5.3): the EXIF date and
    /// location win when present; without a location, the chosen place's
    /// coordinates are used, and the light kind is computed at *that*
    /// position (photo PRD 5.1). `takenHereConfirmed` is the answer to the
    /// "Taken here?" prompt when the EXIF point was more than 150 m away.
    @discardableResult
    public func importPhoto(
        data: Data,
        questionID: String? = nil,
        placeKey: String? = nil,
        building: String,
        kind: PhotoKind = .other,
        lightOverride: LightKind? = nil,
        takenHereConfirmed: Bool = false
    ) async throws -> PhotoOutboxItem {
        let jpeg = try PhotoEncoder.jpeg(from: data)
        let taken = PhotoEncoder.exifDate(from: data) ?? Date()
        let exifCoordinate = PhotoEncoder.exifCoordinate(from: data)
        let placeCoordinate = placeKey.flatMap { Geo.coordinate(forKey: $0) }

        let coordinate: CLLocationCoordinate2D?
        if let exifCoordinate {
            // Far from the place and the user did *not* confirm "Taken
            // here?": keep the EXIF point. Otherwise the EXIF point when it
            // is close, else the place.
            let far = placeCoordinate.map { Geo.distance(from: exifCoordinate, to: $0) > 150 } ?? false
            coordinate = (far && !takenHereConfirmed) ? placeCoordinate : exifCoordinate
        } else {
            coordinate = placeCoordinate
        }

        let light = lightOverride ?? {
            guard let coordinate else { return LightKind.day }
            return Sun.kind(time: taken, lat: coordinate.latitude, lon: coordinate.longitude)
        }()
        let meta = PhotoMeta(
            photoID: UUID().uuidString,
            questionID: questionID,
            placeKey: placeKey,
            building: building,
            kind: kind,
            light: light,
            taken: taken,
            lat: coordinate?.latitude,
            lon: coordinate?.longitude,
            source: .photoImport
        )
        let item = try photoStore.add(meta: meta, jpeg: jpeg)
        await refreshDerived()
        return item
    }

    /// Deletes a photo from the outbox (file and record) — the Settings
    /// photo list's swipe action (photo PRD 4.5).
    public func deletePhoto(_ item: PhotoOutboxItem) {
        photoStore.delete(item)
        fetchedOwnerPhotoData[item.photoID] = nil
        Task { await refreshDerived() }
    }

    /// The "photo wanted" badge state for the Nearby list (photo PRD 4.2):
    /// true when the place has at least one open question whose photo is
    /// still wanted.
    public func hasPhotoWanted(place: Place) -> Bool {
        let pending = pendingOutboxQuestionIDs
        return place.questionIDs.contains { id in
            guard let question = questionsByID[id] else { return false }
            guard question.photoWanted != nil else { return false }
            return !question.isAnswered(outboxQuestionIDs: pending)
        }
    }

    // MARK: Navigation

    /// Deep-link target of the notification router and of row taps.
    /// Replaces the stack: exactly one page on top of the main screen.
    public func openPlace(_ key: String) {
        path = [.place(key: key)]
    }

    /// Pops back to the main screen (Nearby).
    public func popToMain() {
        path = []
    }

    public var placesWithOpenState: [(place: Place, openCount: Int, total: Int)] {
        let pending = pendingOutboxQuestionIDs
        return places.map { place in
            let total = place.questionIDs.count
            let open = place.questionIDs
                .compactMap { questionsByID[$0] }
                .filter { !$0.isAnswered(outboxQuestionIDs: pending) }
                .count
            return (place, open, total)
        }
    }
}

