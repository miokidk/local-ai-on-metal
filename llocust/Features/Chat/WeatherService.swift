import CoreLocation
import Foundation

private let weatherStaleAfterMinutes = 60

@MainActor
final class WeatherService: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let forecastToolName = "get_local_weather_forecast"

    private static let refreshInterval: TimeInterval = 60 * 60
    private static let locationFreshnessInterval: TimeInterval = 5 * 60

    private let session: URLSession
    private let persistence = WeatherPersistence()
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()

    private var cache = WeatherCacheState()
    private var didStart = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    deinit {
        refreshLoopTask?.cancel()
        refreshTask?.cancel()
    }

    var forecastTool: ResponseFunctionToolDefinition {
        ResponseFunctionToolDefinition(
            name: Self.forecastToolName,
            description: """
Returns the next ten days of cached local weather for the user's current location. The result includes when the forecast was fetched, how old it is, whether it is stale, and daily forecast values for the next ten days.
""",
            parameters: [
                "type": "object",
                "properties": [:],
                "required": [],
                "additionalProperties": false
            ],
            strict: true
        )
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        Task { [weak self] in
            await self?.restorePersistedState()
            self?.refreshIfNeeded(reason: "launch", force: false)
        }

        refreshLoopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                self.refreshIfNeeded(reason: "scheduled", force: false)
            }
        }
    }

    func fallbackForecastContext() -> String? {
        guard let snapshot = cache.snapshot else { return nil }

        let ageMinutes = snapshot.fetchedAt.ageInMinutes(referenceDate: Date())
        let freshnessLine = ageMinutes > weatherStaleAfterMinutes
            ? "This snapshot is a bit stale, so mention that briefly if you rely on it."
            : "This snapshot is fresh enough to use normally."

        let dayLines = snapshot.days.map { day in
            var parts = [
                "\(day.date): \(day.summary)",
                "high \(day.temperatureMaxF.roundedString)F/\(day.temperatureMaxC.roundedString)C",
                "low \(day.temperatureMinF.roundedString)F/\(day.temperatureMinC.roundedString)C"
            ]

            if let precipitationChance = day.precipitationProbabilityMax {
                parts.append("precip \(precipitationChance)%")
            }

            return "- " + parts.joined(separator: ", ")
        }

        return """
Cached local weather snapshot for the current location (\(snapshot.locationDescription)):
Fetched at: \(snapshot.fetchedAt.iso8601Timestamp)
Age: \(ageMinutes) minutes
\(freshnessLine)
Forecast:
\(dayLines.joined(separator: "\n"))
"""
    }

    func executeForecastTool(argumentsJSON _: String) async -> String {
        if shouldRefreshInBackground {
            refreshIfNeeded(reason: "tool", force: false)
        }

        let response = WeatherToolResponse.from(cache: cache)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(response),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"status":"unavailable","reason":"Weather data could not be encoded."}"#
        }

        return json
    }

    func refreshIfNeeded(reason: String, force: Bool) {
        let _ = reason
        guard refreshTask == nil else { return }
        guard force || shouldRefreshInBackground else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            await self.performRefresh()
        }
    }

    private var shouldRefreshInBackground: Bool {
        if let snapshot = cache.snapshot {
            return snapshot.fetchedAt.addingTimeInterval(Self.refreshInterval) <= Date()
        }

        guard let lastAttemptAt = cache.lastRefreshAttemptAt else {
            return true
        }

        return lastAttemptAt.addingTimeInterval(Self.refreshInterval) <= Date()
    }

    private func restorePersistedState() async {
        if let restored = await persistence.load() {
            cache = restored
        }

        cache.locationAuthorization = authorizationState(from: locationManager.authorizationStatus)
    }

    private func performRefresh() async {
        cache.lastRefreshAttemptAt = Date()
        cache.locationAuthorization = authorizationState(from: locationManager.authorizationStatus)

        do {
            let location = try await currentLocation()
            let snapshot = try await fetchForecast(for: location)
            cache.snapshot = snapshot
            cache.lastSuccessfulRefreshAt = snapshot.fetchedAt
            cache.lastErrorDescription = nil
        } catch is CancellationError {
            return
        } catch {
            cache.lastErrorDescription = friendlyDescription(for: error)
        }

        cache.locationAuthorization = authorizationState(from: locationManager.authorizationStatus)
        await persistence.save(cache)
    }

    private func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw WeatherServiceError.locationUnavailable("Location services are turned off.")
        }

        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            await waitForAuthorizationDecision()
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .denied:
            throw WeatherServiceError.locationUnavailable("Location access was denied.")
        case .restricted:
            throw WeatherServiceError.locationUnavailable("Location access is restricted.")
        case .notDetermined:
            throw WeatherServiceError.locationUnavailable("Location access is still pending.")
        @unknown default:
            throw WeatherServiceError.locationUnavailable("Location access is unavailable.")
        }

        if let location = locationManager.location,
           abs(location.timestamp.timeIntervalSinceNow) <= Self.locationFreshnessInterval {
            return location
        }

        return try await withCheckedThrowingContinuation { continuation in
            if let existingContinuation = locationContinuation {
                existingContinuation.resume(
                    throwing: WeatherServiceError.locationUnavailable("A newer location request replaced the previous one.")
                )
            }

            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    private func waitForAuthorizationDecision() async {
        if locationManager.authorizationStatus != .notDetermined {
            return
        }

        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
    }

    private func fetchForecast(for location: CLLocation) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: String(location.coordinate.latitude)),
            .init(name: "longitude", value: String(location.coordinate.longitude)),
            .init(name: "forecast_days", value: "10"),
            .init(name: "timezone", value: "auto"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max")
        ]

        guard let url = components?.url else {
            throw WeatherServiceError.forecastUnavailable("The weather request URL could not be created.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherServiceError.forecastUnavailable("The weather service returned an invalid response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.forecastUnavailable("The weather service returned \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
        let placeName = await reverseGeocodedName(for: location)
        return WeatherSnapshot(
            fetchedAt: Date(),
            latitude: decoded.latitude,
            longitude: decoded.longitude,
            timezoneIdentifier: decoded.timezone,
            placeName: placeName,
            days: decoded.daily.days
        )
    }

    private func reverseGeocodedName(for location: CLLocation) async -> String? {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }

        var parts: [String] = []
        if let locality = placemark.locality?.nonEmpty {
            parts.append(locality)
        }
        if let administrativeArea = placemark.administrativeArea?.nonEmpty,
           parts.contains(administrativeArea) == false {
            parts.append(administrativeArea)
        }
        if let country = placemark.country?.nonEmpty,
           parts.contains(country) == false {
            parts.append(country)
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func authorizationState(from status: CLAuthorizationStatus) -> WeatherLocationAuthorization {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private func friendlyDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return description
        }

        return error.localizedDescription
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        cache.locationAuthorization = authorizationState(from: manager.authorizationStatus)

        if manager.authorizationStatus != .notDetermined,
           let continuation = authorizationContinuation {
            authorizationContinuation = nil
            continuation.resume()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let _ = manager
        guard let location = locations.last else { return }

        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let _ = manager
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(throwing: error)
        }
    }
}

private struct WeatherCacheState: Codable {
    var snapshot: WeatherSnapshot?
    var lastRefreshAttemptAt: Date?
    var lastSuccessfulRefreshAt: Date?
    var lastErrorDescription: String?
    var locationAuthorization: WeatherLocationAuthorization = .notDetermined
}

private enum WeatherLocationAuthorization: String, Codable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

private struct WeatherSnapshot: Codable {
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double
    var timezoneIdentifier: String
    var placeName: String?
    var days: [WeatherForecastDay]

    var locationDescription: String {
        if let placeName, !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return placeName
        }

        return "\(latitude.formatted(.number.precision(.fractionLength(3)))), \(longitude.formatted(.number.precision(.fractionLength(3))))"
    }
}

private struct WeatherForecastDay: Codable {
    var date: String
    var weatherCode: Int
    var summary: String
    var temperatureMaxC: Double
    var temperatureMinC: Double
    var precipitationProbabilityMax: Int?
    var windSpeedMaxKmh: Double?

    var temperatureMaxF: Double {
        (temperatureMaxC * 9 / 5) + 32
    }

    var temperatureMinF: Double {
        (temperatureMinC * 9 / 5) + 32
    }
}

private struct WeatherToolResponse: Codable {
    var status: String
    var location: WeatherToolLocation?
    var fetchedAt: Date?
    var ageMinutes: Int?
    var staleAfterMinutes: Int
    var isStale: Bool
    var forecastDays: [WeatherToolDay]
    var lastRefreshAttemptAt: Date?
    var lastSuccessfulRefreshAt: Date?
    var lastErrorDescription: String?
    var locationAuthorization: String
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case status
        case location
        case fetchedAt = "fetched_at"
        case ageMinutes = "age_minutes"
        case staleAfterMinutes = "stale_after_minutes"
        case isStale = "is_stale"
        case forecastDays = "forecast_days"
        case lastRefreshAttemptAt = "last_refresh_attempt_at"
        case lastSuccessfulRefreshAt = "last_successful_refresh_at"
        case lastErrorDescription = "last_error"
        case locationAuthorization = "location_authorization"
        case reason
    }

    static func from(cache: WeatherCacheState) -> WeatherToolResponse {
        if let snapshot = cache.snapshot {
            let ageMinutes = snapshot.fetchedAt.ageInMinutes(referenceDate: Date())
            return WeatherToolResponse(
                status: "ok",
                location: WeatherToolLocation(
                    name: snapshot.placeName,
                    latitude: snapshot.latitude,
                    longitude: snapshot.longitude,
                    timezone: snapshot.timezoneIdentifier
                ),
                fetchedAt: snapshot.fetchedAt,
                ageMinutes: ageMinutes,
                staleAfterMinutes: weatherStaleAfterMinutes,
                isStale: ageMinutes > weatherStaleAfterMinutes,
                forecastDays: snapshot.days.map(WeatherToolDay.init),
                lastRefreshAttemptAt: cache.lastRefreshAttemptAt,
                lastSuccessfulRefreshAt: cache.lastSuccessfulRefreshAt,
                lastErrorDescription: cache.lastErrorDescription,
                locationAuthorization: cache.locationAuthorization.rawValue,
                reason: nil
            )
        }

        let reason: String
        switch cache.locationAuthorization {
        case .denied:
            reason = "Location permission is denied, so local weather data is unavailable."
        case .restricted:
            reason = "Location permission is restricted, so local weather data is unavailable."
        case .notDetermined:
            reason = "Local weather data has not been downloaded yet because location access is still pending."
        case .authorized:
            if let lastErrorDescription = cache.lastErrorDescription?.nonEmpty {
                reason = "The latest background weather refresh failed: \(lastErrorDescription)"
            } else {
                reason = "Local weather data has not been downloaded yet."
            }
        }

        return WeatherToolResponse(
            status: "unavailable",
            location: nil,
            fetchedAt: nil,
            ageMinutes: nil,
            staleAfterMinutes: weatherStaleAfterMinutes,
            isStale: true,
            forecastDays: [],
            lastRefreshAttemptAt: cache.lastRefreshAttemptAt,
            lastSuccessfulRefreshAt: cache.lastSuccessfulRefreshAt,
            lastErrorDescription: cache.lastErrorDescription,
            locationAuthorization: cache.locationAuthorization.rawValue,
            reason: reason
        )
    }
}

private struct WeatherToolLocation: Codable {
    var name: String?
    var latitude: Double
    var longitude: Double
    var timezone: String
}

private struct WeatherToolDay: Codable {
    var date: String
    var summary: String
    var weatherCode: Int
    var temperatureMaxC: Double
    var temperatureMinC: Double
    var temperatureMaxF: Double
    var temperatureMinF: Double
    var precipitationProbabilityMax: Int?
    var windSpeedMaxKmh: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case summary
        case weatherCode = "weather_code"
        case temperatureMaxC = "temperature_max_c"
        case temperatureMinC = "temperature_min_c"
        case temperatureMaxF = "temperature_max_f"
        case temperatureMinF = "temperature_min_f"
        case precipitationProbabilityMax = "precipitation_probability_max"
        case windSpeedMaxKmh = "wind_speed_max_kmh"
    }

    init(day: WeatherForecastDay) {
        date = day.date
        summary = day.summary
        weatherCode = day.weatherCode
        temperatureMaxC = day.temperatureMaxC
        temperatureMinC = day.temperatureMinC
        temperatureMaxF = day.temperatureMaxF
        temperatureMinF = day.temperatureMinF
        precipitationProbabilityMax = day.precipitationProbabilityMax
        windSpeedMaxKmh = day.windSpeedMaxKmh
    }
}

private struct OpenMeteoForecastResponse: Decodable {
    let latitude: Double
    let longitude: Double
    let timezone: String
    let daily: DailyPayload

    struct DailyPayload: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]
        let precipitationProbabilityMax: [Double]?
        let windSpeedMax: [Double]?

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case windSpeedMax = "wind_speed_10m_max"
        }

        var days: [WeatherForecastDay] {
            let count = min(time.count, weatherCode.count, temperatureMax.count, temperatureMin.count)
            guard count > 0 else { return [] }

            return (0..<count).map { index in
                WeatherForecastDay(
                    date: time[index],
                    weatherCode: weatherCode[index],
                    summary: Self.summary(for: weatherCode[index]),
                    temperatureMaxC: temperatureMax[index],
                    temperatureMinC: temperatureMin[index],
                    precipitationProbabilityMax: precipitationProbabilityMax.flatMap { values in
                        guard values.indices.contains(index) else { return nil }
                        return Int(values[index].rounded())
                    },
                    windSpeedMaxKmh: windSpeedMax.flatMap { values in
                        guard values.indices.contains(index) else { return nil }
                        return values[index]
                    }
                )
            }
        }

        private static func summary(for weatherCode: Int) -> String {
            switch weatherCode {
            case 0:
                return "Clear"
            case 1:
                return "Mostly clear"
            case 2:
                return "Partly cloudy"
            case 3:
                return "Overcast"
            case 45, 48:
                return "Fog"
            case 51, 53, 55:
                return "Drizzle"
            case 56, 57:
                return "Freezing drizzle"
            case 61, 63, 65:
                return "Rain"
            case 66, 67:
                return "Freezing rain"
            case 71, 73, 75:
                return "Snow"
            case 77:
                return "Snow grains"
            case 80, 81, 82:
                return "Rain showers"
            case 85, 86:
                return "Snow showers"
            case 95:
                return "Thunderstorm"
            case 96, 99:
                return "Thunderstorm with hail"
            default:
                return "Unknown"
            }
        }
    }
}

private actor WeatherPersistence {
    private let fileManager = FileManager.default
    private let directoryName = "llocust"
    private let fileName = "Weather.json"

    private var fileURL: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL.appendingPathComponent(fileName)
    }

    func load() -> WeatherCacheState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WeatherCacheState.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ state: WeatherCacheState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save weather cache: \(error)")
        }
    }
}

private enum WeatherServiceError: LocalizedError {
    case locationUnavailable(String)
    case forecastUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .locationUnavailable(let message), .forecastUnavailable(let message):
            return message
        }
    }
}

private extension Date {
    var iso8601Timestamp: String {
        ISO8601DateFormatter().string(from: self)
    }

    func ageInMinutes(referenceDate: Date) -> Int {
        max(Int(referenceDate.timeIntervalSince(self) / 60), 0)
    }
}

private extension Double {
    var roundedString: String {
        String(Int(rounded()))
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
