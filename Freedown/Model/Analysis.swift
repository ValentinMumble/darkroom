import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.valentinmumble.freedown", category: "analysis")

/// What the picture hashes and Vision find in the photos. Each analysis runs the first time its view opens,
/// then again after each reload. The answers are kept on disk by item and last change, so after the first
/// time only new and edited photos cost anything, across launches too.
@MainActor
@Observable
final class Analysis {
    private(set) var similarGroups: [ItemGroup]?
    private(set) var similarProgress = 0.0
    /// Live Photos where Vision found no person, face, cat or dog: nil until worked out
    private(set) var lifeless: Set<String>?
    private(set) var subjectsProgress = 0.0
    /// Photos that look taken by mistake (see Accidental): nil until worked out
    private(set) var accidental: Set<String>?
    private(set) var accidentalProgress = 0.0

    private struct Cache: Codable {
        var fingerprints: [String: Similar.Fingerprint] = [:]
        var subjects: [String: Bool] = [:]
    }

    private static let cacheFile = Settings.supportFolder.appending(path: "analysis.json")
    @ObservationIgnored private var cache: Cache = {
        guard let data = try? Data(contentsOf: cacheFile) else { return Cache() }
        return (try? JSONDecoder().decode(Cache.self, from: data)) ?? Cache()
    }()

    /// Keeps only the answers about items as they are now, so the file does not grow forever
    private func saveCache(_ items: [Item]) {
        let keys = Set(items.map(\.analysisKey))
        cache.fingerprints = cache.fingerprints.filter { keys.contains($0.key) }
        cache.subjects = cache.subjects.filter { keys.contains($0.key) }
        try? FileManager.default.createDirectory(at: Settings.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: Self.cacheFile)
    }

    /// Works out again, after the library changed, what was already asked for
    func refresh(_ items: [Item]) async {
        if similarGroups != nil { await computeSimilar(items) }
        if lifeless != nil { await computeSubjects(items) }
        if accidental != nil { await computeAccidental(items) }
    }

    func findSimilar(_ items: [Item]) async {
        guard similarGroups == nil else { return }
        await computeSimilar(items)
    }

    func findSubjects(_ items: [Item]) async {
        guard lifeless == nil else { return }
        await computeSubjects(items)
    }

    func findAccidental(_ items: [Item]) async {
        guard accidental == nil else { return }
        await computeAccidental(items)
    }

    /// Replaces the groups only once the new ones are ready, so the view keeps its place
    private func computeSimilar(_ items: [Item]) async {
        let started = Date.now
        let photos = items.filter { $0.kind == .photo && !$0.screenshot }
        let known = cache.fingerprints
        let (groups, computed) = await Task.detached(priority: .userInitiated) {
            Similar.groups(photos, known: known) { fraction in
                Task { @MainActor in self.similarProgress = fraction }
            }
        }.value
        cache.fingerprints.merge(computed) { _, new in new }
        saveCache(items)
        similarGroups = groups
        log.notice(
            "Similar: \(groups.count) groups of \(groups.reduce(0) { $0 + $1.itemIds.count }) photos in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
    }

    /// Checks each Live Photo once
    private func computeSubjects(_ items: [Item]) async {
        let started = Date.now
        let live = items.filter(\.live)
        let known = cache.subjects
        let answers = await Task.detached(priority: .userInitiated) {
            var answers = known
            for (index, item) in live.enumerated() where answers[item.analysisKey] == nil {
                if let living = Subjects.living(item.asset) { answers[item.analysisKey] = living }
                if index % 20 == 0 {
                    let fraction = Double(index) / Double(live.count)
                    Task { @MainActor in self.subjectsProgress = fraction }
                }
            }
            return answers
        }.value
        cache.subjects.merge(answers) { _, new in new }
        saveCache(items)
        let found = Set(live.filter { answers[$0.analysisKey] == false }.map(\.id))
        lifeless = found
        log.notice(
            "Subjects: \(found.count) of \(live.count) Live Photos without people or pets, in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
    }

    /// Scores every photo once (the similar shots reuse the scores), then looks for people in the few that
    /// score very low. Favorites and edited photos are left out: someone cared about them.
    private func computeAccidental(_ items: [Item]) async {
        let started = Date.now
        let photos = items.filter { $0.kind == .photo && !$0.screenshot && !$0.favorite && !$0.edited }
        let known = cache
        let (fingerprints, subjects) = await Task.detached(priority: .userInitiated) {
            var fingerprints = known.fingerprints
            var subjects = known.subjects
            for (index, item) in photos.enumerated() {
                let key = item.analysisKey
                // Taken again when it was scored before the utility flag was kept
                if fingerprints[key] == nil || (fingerprints[key]?.score != nil && fingerprints[key]?.utility == nil) {
                    fingerprints[key] = Similar.fingerprint(item.asset)
                }
                if Accidental.suspect(fingerprints[key]), subjects[key] == nil, let living = Subjects.living(item.asset) {
                    subjects[key] = living
                }
                if index % 20 == 0 {
                    let fraction = Double(index) / Double(photos.count)
                    Task { @MainActor in self.accidentalProgress = fraction }
                }
            }
            return (fingerprints, subjects)
        }.value
        cache.fingerprints.merge(fingerprints) { _, new in new }
        cache.subjects.merge(subjects) { _, new in new }
        saveCache(items)
        let found = Set(
            photos.filter { Accidental.suspect(fingerprints[$0.analysisKey]) && subjects[$0.analysisKey] == false }.map(\.id))
        accidental = found
        log.notice(
            "Accidental: \(found.count) of \(photos.count) photos, in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
    }
}
