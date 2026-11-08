import CoreLocation
import MapKit

/// 单次定位 + 反向地理编码，用于字幕记录标题。
/// 无权限或失败时返回 nil，不阻塞录制。
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// 当前地点名：优先 POI 名称，其次简短地址，最后完整地址。
    func currentPlaceName() async -> String? {
        let status = await authorizationStatus()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        guard let location = await requestLocation() else { return nil }
        return await reverseGeocode(location)
    }

    // MARK: - 授权与定位

    private func authorizationStatus() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    // MARK: - 反向地理编码（iOS 26 MapKit，替代已弃用的 CLGeocoder）

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let items = try? await request.mapItems,
              let item = items.first else { return nil }

        if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let short = item.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !short.isEmpty {
            return short
        }
        if let full = item.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty {
            return full
        }
        return nil
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let continuation = self?.authorizationContinuation else { return }
            self?.authorizationContinuation = nil
            continuation.resume(returning: status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor [weak self] in
            guard let continuation = self?.locationContinuation else { return }
            self?.locationContinuation = nil
            continuation.resume(returning: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let continuation = self?.locationContinuation else { return }
            self?.locationContinuation = nil
            continuation.resume(returning: nil)
        }
    }
}
