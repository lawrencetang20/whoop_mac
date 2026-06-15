// WhoopAPI.swift  (host app target only)
// Fetches data from the local Python dashboard API (http://localhost:8756/api/*)
// so the native app reuses the same backend the menu-bar app already serves.
// Requires the `com.apple.security.network.client` entitlement.

import Foundation

// Numeric loopback (not "localhost") so App Transport Security doesn't block the HTTP call.
let kAPIBase = "http://127.0.0.1:8756"

// MARK: - Models (snake_case keys match the API; fields may be null)

struct RecoveryPoint: Codable, Identifiable {
    var day: String
    var recovery_score: Int?
    var hrv_rmssd_milli: Double?
    var resting_heart_rate: Int?
    var id: String { day }
}

struct SleepPoint: Codable, Identifiable {
    var day: String
    var hours: Double?
    var need_hours: Double?
    var rem_hours: Double?
    var deep_hours: Double?
    var light_hours: Double?
    var awake_hours: Double?
    var performance: Double?
    var efficiency: Double?
    var respiratory_rate: Double?
    var id: String { day }
}

struct StrainPoint: Codable, Identifiable {
    var day: String
    var strain: Double?
    var average_heart_rate: Int?
    var max_heart_rate: Int?
    var calories: Double?
    var id: String { day }
}

struct WorkoutRow: Codable, Identifiable {
    var id: String
    var day: String?
    var sport_name: String?
    var strain: Double?
    var average_heart_rate: Int?
    var max_heart_rate: Int?
    var calories: Double?
    var distance_meter: Double?
}

struct SportRollup: Codable, Identifiable {
    var sport_name: String
    var count: Int
    var total_strain: Double?
    var avg_strain: Double?
    var avg_hr: Double?
    var calories: Double?
    var id: String { sport_name }
}

struct Summary: Codable {
    var avg_recovery: Double?
    var max_recovery: Int?
    var avg_hrv: Double?
    var avg_rhr: Double?
    var avg_sleep_hours: Double?
    var avg_sleep_performance: Double?
    var avg_strain: Double?
    var workout_count: Int?
    var total_calories: Double?
}

// Nutrition: numeric fields are Double? so they decode whether the API emits 950 or 950.0.
struct NutritionSummary: Codable {
    var calories: Double?
    var protein_g: Double?
    var carbs_g: Double?
    var fat_g: Double?
    var burned: Double?
    var net: Double?
    var goal: Double?
    var remaining: Double?
    var items: Int?
    var day: String?
}

struct NutritionPoint: Codable, Identifiable {
    var day: String
    var calories: Double?
    var id: String { day }
}

struct NutritionResponse: Codable {
    var summary: NutritionSummary?
    var series: [NutritionPoint]?
    var nutritionix: Bool?
}

struct EnergyPoint: Codable, Identifiable {
    var day: String
    var intake: Double?
    var burned: Double?
    var net: Double?
    var id: String { day }
}

struct LatestStats: Codable {
    struct Rec: Codable {
        var recovery_score: Int?; var hrv_rmssd_milli: Double?
        var resting_heart_rate: Int?; var spo2_percentage: Double?; var skin_temp_celsius: Double?
    }
    struct Slp: Codable {
        var hours: Double?; var need_hours: Double?; var performance: Double?
        var efficiency: Double?; var respiratory_rate: Double?
    }
    struct Str: Codable {
        var strain: Double?; var average_heart_rate: Int?; var max_heart_rate: Int?; var calories: Double?
    }
    var day: String?
    var recovery: Rec?
    var recovery_prev: Rec?
    var sleep: Slp?
    var sleep_prev: Slp?
    var strain: Str?
    var strain_prev: Str?
}

struct AppStatus: Codable {
    struct Profile: Codable { var first_name: String? }
    struct Counts: Codable { var days: Int?; var sleeps: Int?; var workouts: Int? }
    var authorized: Bool?
    var last_sync: String?
    var profile: Profile?
    var counts: Counts?
}

// MARK: - Data store

@MainActor
final class WhoopData: ObservableObject {
    @Published var latest: LatestStats?
    @Published var summary: Summary?
    @Published var recovery: [RecoveryPoint] = []
    @Published var sleep: [SleepPoint] = []
    @Published var strain: [StrainPoint] = []
    @Published var workouts: [WorkoutRow] = []
    @Published var sports: [SportRollup] = []
    @Published var nutrition: NutritionResponse?
    @Published var energy: [EnergyPoint] = []
    @Published var status: AppStatus?
    @Published var error: String?
    @Published var loading = false

    private func get<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        guard let url = URL(string: kAPIBase + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func load(days: Int) async {
        loading = true
        error = nil
        do {
            async let st = get("/api/status", AppStatus.self)
            async let la = get("/api/latest", LatestStats.self)
            async let su = get("/api/summary?days=\(days)", Summary.self)
            async let rc = get("/api/recovery?days=\(days)", [RecoveryPoint].self)
            async let sl = get("/api/sleep?days=\(days)", [SleepPoint].self)
            async let sn = get("/api/strain?days=\(days)", [StrainPoint].self)
            async let wk = get("/api/workouts?days=\(days)", [WorkoutRow].self)
            async let sp = get("/api/sports?days=\(days)", [SportRollup].self)
            async let nu = get("/api/nutrition?days=\(days)", NutritionResponse.self)
            async let en = get("/api/energy?days=\(days)", [EnergyPoint].self)
            status = try await st
            latest = try await la
            summary = try await su
            recovery = try await rc
            sleep = try await sl
            strain = try await sn
            workouts = try await wk
            sports = try await sp
            // Nutrition routes are newer; tolerate an older backend that lacks them
            // (best-effort) rather than failing the whole dashboard load.
            nutrition = try? await nu
            energy = (try? await en) ?? []
        } catch {
            self.error = "Can't reach the WHOOP service on localhost:8756. Make sure the menu-bar app (WHOOP) is running, then hit refresh."
        }
        loading = false
    }
}

// MARK: - Helpers

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}()

func parseDay(_ s: String?) -> Date {
    guard let s, let d = dayFormatter.date(from: s) else { return Date() }
    return d
}
