import SwiftUI
import UIKit
import AVKit

private let roboAPIBase = URL(string: "https://shafaykeyauthadmin.lovable.app")!

struct RoboLicenseResponse: Codable {
    let success: Bool?
    let valid: Bool?
    let status: String?
    let key: String?
    let expires_at: String?
    let days_remaining: Int?
    let device_limit: Int?
    let devices_used: Int?
}

struct RoboPatchOption: Codable, Identifiable {
    let id: String
    let name: String
    let category: String
    let has_file: Bool
    let selectable: Bool
    let file_name: String?
    let download_url: String?
}

struct RoboPatchCategory: Codable {
    let category: String
    let name: String
    let options: [RoboPatchOption]
}

struct RoboPatchResponse: Codable {
    let success: Bool
    let download_url_expires_in: Int?
    let categories: [RoboPatchCategory]
}

@MainActor
final class RoboAPI: ObservableObject {
    @Published var license: RoboLicenseResponse?
    @Published var patches: [RoboPatchOption] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var patchDownloadState: [String: String] = [:]

    func verify(key: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var request = URLRequest(url: roboAPIBase.appendingPathComponent("api/public/v1/verify-license"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([
                "key": key.trimmingCharacters(in: .whitespacesAndNewlines),
                "device_id": RoboDevice.id,
                "product_identifier": "freefire"
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            let result = try JSONDecoder().decode(RoboLicenseResponse.self, from: data)
            license = result

            guard result.valid == true, result.status?.lowercased() == "active" else {
                let status = result.status?.lowercased() ?? ""
                if status == "expired" {
                    errorMessage = "License Expired"
                } else if status == "revoked" {
                    errorMessage = "License Revoked"
                } else {
                    errorMessage = "Invalid Key"
                }
                UserDefaults.standard.removeObject(forKey: "robo.license.key")
                UserDefaults.standard.removeObject(forKey: "robo.license.expiry")
                return
            }

            UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "robo.license.key")
            UserDefaults.standard.set(result.expires_at, forKey: "robo.license.expiry")
            errorMessage = nil
        } catch {
            license = nil
            errorMessage = "Unable to verify license. Please try again."
        }
    }

    func loadPatches(category: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var components = URLComponents(
                url: roboAPIBase.appendingPathComponent("api/public/v1/patch/options"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "category", value: category)]

            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let result = try JSONDecoder().decode(RoboPatchResponse.self, from: data)
            patches = result.categories.flatMap(\.options).filter { $0.selectable || $0.has_file }

            // The UI never opens the signed URL. Available patch files are
            // downloaded into the app's private patch library automatically.
            await downloadAvailablePatches()
        } catch {
            errorMessage = "Unable to load patches."
        }
    }

    func downloadAvailablePatches() async {
        for patch in patches where patch.has_file {
            await downloadPatch(patch)
        }
    }

    private func downloadPatch(_ patch: RoboPatchOption) async {
        guard let raw = patch.download_url, let url = URL(string: raw) else {
            patchDownloadState[patch.id] = "Unavailable"
            return
        }

        if patchDownloadState[patch.id] == "Downloaded" { return }
        patchDownloadState[patch.id] = "Downloading…"

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("ROBO iOS/Patches", isDirectory: true)

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let safeName = (patch.file_name?.isEmpty == false ? patch.file_name! : patch.id) + ".downloaded"
            let destination = root.appendingPathComponent(safeName)
            try data.write(to: destination, options: .atomic)

            patchDownloadState[patch.id] = "Downloaded"
        } catch {
            patchDownloadState[patch.id] = "Retrying…"
        }
    }

    func clearLicense() {
        license = nil
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: "robo.license.key")
        UserDefaults.standard.removeObject(forKey: "robo.license.expiry")
    }
}

enum RoboDevice {
    static var id: String {
        if let saved = UserDefaults.standard.string(forKey: "robo.device.id") { return saved }
        let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(value, forKey: "robo.device.id")
        return value
    }

    static var model: String { AppInfo.machineName }
    static var ios: String { UIDevice.current.systemVersion }
}

struct ContentView: View {
    @StateObject private var api = RoboAPI()
    @State private var tab = 0
    @State private var game = 0
    @State private var key = ""
    @State private var showKey = false
    @State private var accent = Color.white
        @State private var showChangeLicense = false

    private var storedKey: String {
        UserDefaults.standard.string(forKey: "robo.license.key") ?? ""
    }

    private var isLicensed: Bool {
        api.license?.valid == true && api.license?.status?.lowercased() == "active"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StarField()

            if isLicensed {
                mainInterface
            } else {
                licenseScreen
            }
        }
        .tint(accent)
        .onAppear {
            if key.isEmpty { key = storedKey }
            if !storedKey.isEmpty {
                Task { await api.verify(key: storedKey) }
            }
        }
    }

    private var mainInterface: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case 0:
                    FunctionsView(api: api, game: $game, accent: accent)
                case 1:
                    AccountView(api: api, showChangeLicense: $showChangeLicense, accent: accent)
                case 2:
                    RuntimeView(accent: accent)
                default:
                    SettingsViewRobo(accent: $accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                RoboTab(title: "Functions", icon: "square.grid.2x2.fill", selected: tab == 0, accent: accent) { tab = 0 }
                RoboTab(title: "Account", icon: "person.crop.circle.fill", selected: tab == 1, accent: accent) { tab = 1 }
                RoboTab(title: "Runtime", icon: "waveform.path.ecg", selected: tab == 2, accent: accent) { tab = 2 }
                RoboTab(title: "Settings", icon: "gearshape.fill", selected: tab == 3, accent: accent) { tab = 3 }
            }
            .padding(8)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
    }

    private var licenseScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 34)

                Text("ROBO iOS")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))

                Text("Play Beyond Limits")
                    .foregroundStyle(.white.opacity(0.65))

                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(accent)

                        Group {
                            if showKey {
                                TextField("License Key", text: $key)
                            } else {
                                SecureField("License Key", text: $key)
                            }
                        }

                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                        }
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.clear, lineWidth: 0)
                    }

                    Button {
                        Task { await api.verify(key: key) }
                    } label: {
                        HStack {
                            if api.isLoading { ProgressView().tint(.white) }
                            Text("Activate")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if let error = api.errorMessage {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Text("Supported: iOS 16 and newer")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))

                Spacer(minLength: 40)
            }
            .padding(22)
        }
    }
}

private struct FunctionsView: View {
    @ObservedObject var api: RoboAPI
    @Binding var game: Int
    let accent: Color

    // UI labels are intentionally independent from backend category names.
    private let games = [
        ("Free Fire", "free_fire_india"),
        ("Free Fire Max", "BGMI")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ROBO iOS")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("Functions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))

                VideoBanner()
                    .frame(height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                HStack(spacing: 10) {
                    ForEach(0..<games.count, id: \.self) { index in
                        Button {
                            game = index
                            Task { await api.loadPatches(category: games[index].1) }
                        } label: {
                            Text(games[index].0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(game == index ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    game == index
                                        ? accent.opacity(0.20)
                                        : Color.white.opacity(0.06)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }

                if api.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                if api.patches.isEmpty && !api.isLoading {
                    EmptyPatchCard()
                } else {
                    ForEach(api.patches) { patch in
                        PatchCard(
                            patch: patch,
                            accent: accent,
                            state: api.patchDownloadState[patch.id]
                        )
                    }
                }
            }
            .padding(18)
        }
        .refreshable {
            await api.loadPatches(category: games[game].1)
        }
        .onAppear {
            Task { await api.loadPatches(category: games[game].1) }
        }
    }
}

private struct PatchCard: View {
    let patch: RoboPatchOption
    let accent: Color
    let state: String?

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(accent.opacity(0.10))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "scope")
                        .foregroundStyle(accent)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(patch.name)
                    .font(.headline)

                Text(state ?? (patch.has_file ? "Preparing…" : "Unavailable"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            if state == "Downloaded" {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent)
            } else if state == "Downloading…" || state == "Retrying…" {
                ProgressView()
            } else {
                Image(systemName: patch.has_file ? "arrow.down.circle" : "circle.dashed")
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }
}

private struct EmptyPatchCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.65))

            Text("No patches available")
                .font(.headline)

            Text("New online patches will appear here automatically.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AccountView: View {
    @ObservedObject var api: RoboAPI
    @Binding var showChangeLicense: Bool
    let accent: Color
    @State private var reveal = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ROBO iOS")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("Play Beyond Limits")
                    .foregroundStyle(.white.opacity(0.65))

                accountSection("DEVICE") {
                    InfoRow(title: "Device supported", value: "Supported", icon: "checkmark.shield.fill", accent: accent)
                    InfoRow(title: "Model", value: RoboDevice.model, icon: "iphone", accent: accent)
                    InfoRow(title: "iOS Version", value: RoboDevice.ios, icon: "gear", accent: accent)
                    InfoRow(title: "Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-", icon: "number", accent: accent)
                }

                accountSection("LICENSE") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("License Key")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))

                            Text(reveal ? (api.license?.key ?? storedKey) : "••••••••••••••••")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button { reveal.toggle() } label: {
                            Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                        }

                        Button {
                            UIPasteboard.general.string = api.license?.key ?? storedKey
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                    }

                    if let days = api.license?.days_remaining {
                        Text(days == 1 ? "1 day remaining" : "\(days) days remaining")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    if let expiry = api.license?.expires_at {
                        Text("Expiry: \(expiry)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    Button("Change License") {
                        showChangeLicense = true
                    }
                    .foregroundStyle(accent)
                    .sheet(isPresented: $showChangeLicense) {
                        ChangeLicenseView(api: api)
                    }
                }

                accountSection("APP") {
                    InfoRow(title: "Name", value: "ROBO iOS", icon: "app.fill", accent: accent)
                    InfoRow(title: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-", icon: "info.circle.fill", accent: accent)
                }
            }
            .padding(18)
        }
    }

    private var storedKey: String {
        UserDefaults.standard.string(forKey: "robo.license.key") ?? "-"
    }

    private func accountSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))

            VStack(spacing: 0) {
                content()
            }
            .padding(4)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.01), lineWidth: 1)
            }
        }
    }
}

private struct ChangeLicenseView: View {
    @ObservedObject var api: RoboAPI
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Change License")
                    .font(.title2.bold())

                TextField("ROBO license key", text: $key)
                    .textInputAutocapitalization(.characters)
                    .padding(14)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button("Verify") {
                    Task {
                        await api.verify(key: key)
                        if api.license?.valid == true && api.license?.status?.lowercased() == "active" {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                if let error = api.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(20)
        }
    }
}

private struct RuntimeView: View {
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runtime")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("Runtime logs")
                .foregroundStyle(.white.opacity(0.65))

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.clear)
                .frame(maxWidth: .infinity, minHeight: 220)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.largeTitle)
                            .foregroundStyle(accent)

                        Text("No runtime events yet")
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

            Spacer()
        }
        .padding(18)
    }
}

private struct SettingsViewRobo: View {
    @Binding var accent: Color
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue

    private var language: String {
        languageCode
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                settingsSection("APPEARANCE") {
                    ColorPicker("Accent Color", selection: $accent, supportsOpacity: false)
                    Text("ROBO uses its custom dark appearance and ignores the system Light/Dark setting.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }

                settingsSection("LANGUAGE") {
                    Picker("Language", selection: $languageCode) {
                        Text("English").tag("English")
                        Text("Chinese").tag("Chinese")
                        Text("Vietnamese").tag("Vietnamese")
                        Text("Korean").tag("Korean")
                    }
                }

                settingsSection("COMPATIBILITY") {
                    InfoRow(title: "Device", value: RoboDevice.model, icon: "iphone", accent: accent)
                    InfoRow(title: "iOS", value: RoboDevice.ios, icon: "gear", accent: accent)
                    InfoRow(title: "Support", value: "iOS 16+", icon: "checkmark.shield.fill", accent: accent)
                }
            }
            .padding(18)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))

            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    let icon: String
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))

                Text(value)
                    .font(.subheadline)
            }

            Spacer()
        }
        .padding(12)
    }
}

private struct RoboTab: View {
    let title: String
    let icon: String
    let selected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? accent : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
    }
}

private struct VideoBanner: View {
    @State private var player: AVPlayer?

    private let candidates = [
        "Functionscreen",
        "banner-red",
        "banner-blue",
        "banner-gold",
        "banner-green",
        "banner-orange"
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.12, blue: 0.20),
                            Color(red: 0.025, green: 0.025, blue: 0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let player {
                VideoPlayer(player: player)
                    .disabled(true)
                    .onAppear {
                        player.play()
                        player.actionAtItemEnd = .none
                        NotificationCenter.default.addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: player.currentItem,
                            queue: .main
                        ) { _ in
                            player.seek(to: .zero)
                            player.play()
                        }
                    }
                    .onDisappear {
                        player.pause()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    Text("ROBO iOS")
                        .font(.title.bold())
                    Text("Play Beyond Limits")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .onAppear {
            guard player == nil else { return }

            for name in candidates {
                if let url = Bundle.main.url(forResource: name, withExtension: "mov") {
                    player = AVPlayer(url: url)
                    break
                }
            }
        }
    }
}

private struct StarField: View {
    private let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.08,0.12,1.1,0.30),(0.21,0.22,0.7,0.20),(0.34,0.08,0.9,0.24),(0.48,0.18,0.6,0.18),
        (0.63,0.10,1.0,0.28),(0.78,0.24,0.7,0.19),(0.91,0.13,1.0,0.25),(0.14,0.42,0.6,0.16),
        (0.29,0.53,1.0,0.22),(0.57,0.44,0.7,0.18),(0.74,0.57,0.9,0.21),(0.88,0.47,0.6,0.17),
        (0.06,0.73,0.8,0.20),(0.22,0.84,0.6,0.16),(0.43,0.72,1.0,0.23),(0.67,0.80,0.7,0.18),
        (0.84,0.72,0.9,0.22),(0.94,0.88,0.6,0.17)
    ]

    var body: some View {
        GeometryReader { _ in
            Canvas { ctx, size in
                for (xRatio,yRatio,r,opacity) in stars {
                    let x=xRatio*size.width, y=yRatio*size.height
                    let rect=CGRect(x:x-r/2,y:y-r/2,width:r,height:r)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct SeededRandom {
    var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
            &* 2862933555777941757
            &+ 3037000493
    }

    mutating func next() -> Double {
        state = state &* 2862933555777941757 &+ 3037000493
        return Double(state % 10000) / 10000.0
    }
}
