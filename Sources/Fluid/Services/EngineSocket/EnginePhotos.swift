import Foundation
import Photos

/// Your Photos library, for myOS, through Apple's own permission. Only dates and locations are ever read: never an image, never a file name,
/// and nothing here is logged. `summary` returns counts only; it is the feasibility check for using photo locations as evidence of where you were.
nonisolated protocol EnginePhotosProviding: Sendable {
    /// {authorization: "authorized"|"limited"|"denied"|"restricted"|"not_determined"}
    func status() async -> [String: Any]
    /// Shows macOS's Photos prompt if it hasn't been answered; returns the same shape as `status`.
    func request() async -> [String: Any]
    /// {total, located, first_day?, last_day?, located_days, by_year: {"2024": n}} for photos and videos that are not hidden.
    func summary() async throws -> [String: Any]
    /// Where photos were taken, as small clusters: {clusters: [{t0, t1, lat, lon, n}], scanned, used, screenshots, shared}. Only photos the camera
    /// took are used (screenshots and shared-album items are left out). `since` (epoch seconds) limits it to newer photos.
    func locations(since: TimeInterval?) async throws -> [String: Any]
}

nonisolated enum EnginePhotosError: LocalizedError, Equatable {
    case notAllowed
    var errorDescription: String? { "Allow Photos for the myOS engine first (macOS asks once)." }
}

nonisolated enum PhotosRules {
    static func name(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "not_determined"
        }
    }

    /// A location is usable when it has a real accuracy reading and sits on the Earth.
    static func usable(latitude: Double, longitude: Double, accuracy: Double) -> Bool {
        accuracy >= 0 && (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude) && !(latitude == 0 && longitude == 0)
    }
}

nonisolated struct PhotoPoint: Equatable {
    var time: TimeInterval
    var lat: Double
    var lon: Double
}

nonisolated enum PhotoClusters {
    /// Groups points by UTC day and a grid cell about 5 km across (0.05 degrees). A cluster keeps its first and last time, the mean position
    /// (4 decimals, about 10 m) and how many photos are in it, so no single photo's position leaves the engine.
    static func aggregate(_ points: [PhotoPoint], cell: Double = 0.05) -> [[String: Any]] {
        struct Key: Hashable { var day: Int; var la: Int; var lo: Int }
        struct Acc { var t0: TimeInterval; var t1: TimeInterval; var sumLat = 0.0; var sumLon = 0.0; var n = 0 }
        var buckets: [Key: Acc] = [:]
        for p in points {
            let key = Key(day: Int((p.time / 86400).rounded(.down)), la: Int((p.lat / cell).rounded(.down)), lo: Int((p.lon / cell).rounded(.down)))
            var a = buckets[key] ?? Acc(t0: p.time, t1: p.time)
            a.t0 = min(a.t0, p.time)
            a.t1 = max(a.t1, p.time)
            a.sumLat += p.lat
            a.sumLon += p.lon
            a.n += 1
            buckets[key] = a
        }
        let r4 = { (x: Double) in (x * 10_000).rounded() / 10_000 }
        return buckets.values.sorted { $0.t0 < $1.t0 }.map { a in
            ["t0": Int(a.t0), "t1": Int(a.t1), "lat": r4(a.sumLat / Double(a.n)), "lon": r4(a.sumLon / Double(a.n)), "n": a.n]
        }
    }
}

nonisolated struct LiveEnginePhotos: EnginePhotosProviding {
    func status() async -> [String: Any] { ["authorization": PhotosRules.name(PHPhotoLibrary.authorizationStatus(for: .readWrite))] }

    func request() async -> [String: Any] {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return ["authorization": PhotosRules.name(s)]
    }

    func locations(since: TimeInterval?) async throws -> [String: Any] {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard s == .authorized || s == .limited else { throw EnginePhotosError.notAllowed }
        return await Task.detached(priority: .utility) { () -> [String: Any] in
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            var format = "(mediaType == %d OR mediaType == %d)"
            var args: [Any] = [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
            if let since { format += " AND creationDate > %@"; args.append(Date(timeIntervalSince1970: since) as NSDate) }
            options.predicate = NSPredicate(format: format, argumentArray: args)
            let assets = PHAsset.fetchAssets(with: options)
            var points: [PhotoPoint] = []
            var scanned = 0, screenshots = 0, shared = 0
            let now = Date().timeIntervalSince1970 + 86400
            assets.enumerateObjects { asset, _, _ in
                scanned += 1
                guard let loc = asset.location, let date = asset.creationDate,
                      PhotosRules.usable(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy),
                      date.timeIntervalSince1970 <= now else { return }
                // A screenshot's place is wherever you were looking at it; a shared album's photos are other people's.
                if asset.mediaSubtypes.contains(.photoScreenshot) { screenshots += 1; return }
                if asset.sourceType.contains(.typeCloudShared) { shared += 1; return }
                points.append(PhotoPoint(time: date.timeIntervalSince1970, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
            }
            return ["clusters": PhotoClusters.aggregate(points), "scanned": scanned, "used": points.count, "screenshots": screenshots, "shared": shared]
        }.value
    }

    func summary() async throws -> [String: Any] {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard s == .authorized || s == .limited else { throw EnginePhotosError.notAllowed }
        return await Task.detached(priority: .utility) { () -> [String: Any] in
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let assets = PHAsset.fetchAssets(with: options)
            var total = 0, located = 0
            var first: Date?, last: Date?
            var days = Set<Int>()
            var byYear: [String: Int] = [:]
            let cal = Calendar.current
            assets.enumerateObjects { asset, _, _ in
                total += 1
                guard let loc = asset.location, let date = asset.creationDate,
                      PhotosRules.usable(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy) else { return }
                located += 1
                if first == nil || date < first! { first = date }
                if last == nil || date > last! { last = date }
                days.insert(Int(date.timeIntervalSince1970 / 86400))
                byYear[String(cal.component(.year, from: date)), default: 0] += 1
            }
            var out: [String: Any] = ["total": total, "located": located, "located_days": days.count, "by_year": byYear]
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            if let first { out["first_day"] = f.string(from: first) }
            if let last { out["last_day"] = f.string(from: last) }
            return out
        }.value
    }
}
