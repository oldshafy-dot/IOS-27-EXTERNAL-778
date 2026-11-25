import SwiftUI
import UIKit

// ROBO iOS client UI. This client uses only the public license and patch-option APIs.
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

    func verify(key: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: roboAPIBase.appendingPathComponent("api/public/v1/verify-license"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: String] = [
                "key": key.trimmingCharacters(in: .whitespacesAndNewlines),
                "device_id": RoboDevice.id,
                "product_identifier": "freefire"
            ]
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let result = try JSONDecoder().decode(RoboLicenseResponse.self, from: data)
            license = result
            guard result.valid == true, result.status?.lowercased() == "active" else {
                throw RoboError.invalidLicense
            }
            UserDefaults.standard.set(key, forKey: "robo.license.key")
            UserDefaults.standard.set(result.expires_at, forKey: "robo.license.expiry")
        } catch {
            license = nil
            errorMessage = error.localizedDescription
        }
    }

    func loadPatches(category: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var components = URLComponents(url: roboAPIBase.appendingPathComponent("api/public/v1/patch/options"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "category", value: category)]
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let result = try JSONDecoder().decode(RoboPatchResponse.self, from: data)
            patches = result.categories.flatMap(\.options).filter { $0.selectable || $0.has_file }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearLicense() {
        license = nil
        UserDefaults.standard.removeObject(forKey: "robo.license.key")
        UserDefaults.standard.removeObject(forKey: "robo.license.expiry")
    }
}

enum RoboError: LocalizedError {
    case invalidLicense
    var errorDescription: String? {
        switch self {
        case .invalidLicense: return "License is not active or is not valid for this device."
        }
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
    @State private var accent = Color(red: 0.25, green: 0.65, blue: 1.0)
    @State private var appearance = 0
    @State private var showChangeLicense = false
    @State private var copied = false

    private var storedKey: String { UserDefaults.standard.string(forKey: "robo.license.key") ?? "" }
    private var isLicensed: Bool { api.license?.valid == true && api.license?.status?.lowercased() == "active" }

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
        .preferredColorScheme(.dark)
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
                case 0: FunctionsView(api: api, game: $game, accent: accent)
                case 1: AccountView(api: api, showChangeLicense: $showChangeLicense, accent: accent)
                case 2: RuntimeView(accent: accent)
                default: SettingsViewRobo(accent: $accent, appearance: $appearance)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                RoboTab(title: "Functions", icon: "square.grid.2x2.fill", selected: tab == 0, accent: accent) { tab = 0 }
                RoboTab(title: "Account", icon: "person.crop.circle.fill", selected: tab == 1, accent: accent) { tab = 1 }
                RoboTab(title: "Runtime", icon: "waveform.path.ecg", selected: tab == 2, accent: accent) { tab = 2 }
                RoboTab(title: "Settings", icon: "gearshape.fill", selected: tab == 3, accent: accent) { tab = 3 }
            }
            .padding(8)
            .background(Color(white: 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var licenseScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("ROBO iOS")
                .font(.system(size: 38, weight: .bold, design: .rounded))
            Text("Play Beyond Limits")
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(accent)
                    Group {
                        if showKey { TextField("License Key", text: $key) }
                        else { SecureField("License Key", text: $key) }
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                    }
                }
                .padding(16)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    Task { await api.verify(key: key) }
                } label: {
                    HStack {
                        if api.isLoading { ProgressView().tint(.white) }
                        Text("Continue")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(18)
            if let error = api.errorMessage { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Text("Supported: iOS 16 and newer")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(22)
    }
}

private struct FunctionsView: View {
    @ObservedObject var api: RoboAPI
    @Binding var game: Int
    let accent: Color
    private let games = [("Free Fire", "free_fire_india"), ("Free Fire Max", "BGMI")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(spacing: 10) {
                    ForEach(0..<games.count, id: \.self) { index in
                        Button { game = index; Task { await api.loadPatches(category: games[index].1) } } label: {
                            Text(games[index].0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(game == index ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(game == index ? accent.opacity(0.22) : Color(white: 0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                if api.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                if api.patches.isEmpty && !api.isLoading {
                    EmptyPatchCard()
                } else {
                    ForEach(api.patches) { patch in
                        PatchCard(patch: patch, accent: accent)
                    }
                }
            }
            .padding(18)
        }
        .refreshable { await api.loadPatches(category: games[game].1) }
        .onAppear { Task { await api.loadPatches(category: games[game].1) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ROBO iOS").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Functions").foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 155)
                .overlay {
                    VStack(alignment: .leading) {
                        Spacer()
                        Text("Play Beyond Limits").font(.title3.bold())
                        Text("Online patch options").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
        }
    }
}

private struct PatchCard: View {
    let patch: RoboPatchOption
    let accent: Color
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(patch.name).font(.headline)
                    Text(patch.category.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: patch.has_file ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(patch.has_file ? accent : .secondary)
            }
            Button {
                guard let raw = patch.download_url, let url = URL(string: raw) else { message = "Patch file is not available."; return }
                UIApplication.shared.open(url)
            } label: {
                Text("Download")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(Color(white: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct EmptyPatchCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash").font(.title2).foregroundStyle(.secondary)
            Text("No patches available").font(.headline)
            Text("New online patches will appear here automatically.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(32)
        .background(Color(white: 0.07))
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
                Text("ROBO iOS").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Play Beyond Limits").foregroundStyle(.secondary)
                section("DEVICE") {
                    InfoRow(title: "Device supported", value: "Supported", icon: "checkmark.shield.fill", accent: accent)
                    InfoRow(title: "Model", value: RoboDevice.model, icon: "iphone", accent: accent)
                    InfoRow(title: "iOS Version", value: RoboDevice.ios, icon: "gear", accent: accent)
                    InfoRow(title: "Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-", icon: "number", accent: accent)
                }
                section("LICENSE") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("License Key").font(.caption).foregroundStyle(.secondary)
                            Text(reveal ? (api.license?.key ?? "-") : "••••••••••••••••")
                                .font(.system(.body, design: .monospaced)).lineLimit(1)
                        }
                        Spacer()
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash.fill" : "eye.fill") }
                        Button {
                            UIPasteboard.general.string = api.license?.key
                            copied = true
                        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    }
                    if let expiry = api.license?.expires_at { Text("Expiry: \(expiry)").font(.caption).foregroundStyle(.secondary) }
                    Button("Change License") { showChangeLicense = true }
                        .buttonStyle(.bordered)
                        .sheet(isPresented: $showChangeLicense) { ChangeLicenseView(api: api) }
                }
                section("APP") {
                    InfoRow(title: "Name", value: "ROBO iOS", icon: "app.fill", accent: accent)
                    InfoRow(title: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-", icon: "info.circle.fill", accent: accent)
                }
            }.padding(18)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .padding(4).background(Color(white: 0.07)).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct ChangeLicenseView: View {
    @ObservedObject var api: RoboAPI
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("ROBO license key", text: $key).textInputAutocapitalization(.characters).padding(14).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
                Button("Verify") { Task { await api.verify(key: key); if api.license != nil { dismiss() } } }.buttonStyle(.borderedProminent)
                Spacer()
            }.padding(20).navigationTitle("Change License").navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private struct RuntimeView: View {
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runtime").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Runtime logs are ready for the next module.").foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.07)).frame(maxWidth: .infinity, minHeight: 220).overlay {
                VStack(spacing: 8) { Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(accent); Text("No runtime events yet").foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(18)
    }
}

private struct SettingsViewRobo: View {
    @Binding var accent: Color
    @Binding var appearance: Int
    @AppStorage("robo.language") private var language = "English"
    @AppStorage("robo.streamer") private var streamer = false
    @AppStorage("robo.calculator") private var calculator = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) { Text("Dark").tag(0); Text("System").tag(1) }
                ColorPicker("Accent Color", selection: $accent, supportsOpacity: false)
                Text("Default accent: light blue with glow").font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Language", selection: $language) { Text("English").tag("English"); Text("Chinese").tag("Chinese"); Text("Vietnamese").tag("Vietnamese"); Text("Korean").tag("Korean") }
            }
            Section("Modes") {
                Toggle("Streamer Mode", isOn: $streamer)
                Toggle("Calculator Mode", isOn: $calculator)
            }
            Section("Compatibility") {
                LabeledContent("Device", value: RoboDevice.model)
                LabeledContent("iOS", value: RoboDevice.ios)
                LabeledContent("Support", value: "iOS 16+")
            }
            Section("About") { Text("ROBO iOS").font(.headline); Text("Public client: license verification + online patch options").font(.caption).foregroundStyle(.secondary) }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Settings")
    }
}

private struct InfoRow: View {
    let title: String; let value: String; let icon: String; let accent: Color
    var body: some View {
        HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(accent).frame(width: 22); VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline) }; Spacer() }.padding(12)
    }
}

private struct RoboTab: View {
    let title: String; let icon: String; let selected: Bool; let accent: Color; let action: () -> Void
    var body: some View {
        Button(action: action) { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption2.weight(.semibold)) }.foregroundStyle(selected ? accent : .secondary).frame(maxWidth: .infinity).padding(.vertical, 7) }
    }
}

private struct StarField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            Canvas { ctx, size in
                let seed = Int(context.date.timeIntervalSince1970 * 3)
                var rng = SeededRandom(seed: seed)
                for _ in 0..<70 {
                    let x = CGFloat(rng.next()) * size.width
                    let y = CGFloat(rng.next()) * size.height
                    let r = CGFloat(rng.next()) * 1.4 + 0.3
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.22)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct SeededRandom {
    var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> Double { state = state &* 2862933555777941757 &+ 3037000493; return Double(state % 10000) / 10000.0 }
}
