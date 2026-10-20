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

nonisolated struct LiveEnginePhotos: EnginePhotosProviding {
    func status() async -> [String: Any] { ["authorization": PhotosRules.name(PHPhotoLibrary.authorizationStatus(for: .readWrite))] }

    func request() async -> [String: Any] {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return ["authorization": PhotosRules.name(s)]
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
