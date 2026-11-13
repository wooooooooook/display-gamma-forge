// GammaForge.swift — Gamma Forge (display-gamma-forge)
// 실시간으로 그래픽 출력 감마 테이블(vcgt)을 조절하고, 결과를 ICC 프로파일로 저장하는 작은 macOS 앱.
//
// 빌드 & 실행 (Xcode Command Line Tools 필요: xcode-select --install)
//   swiftc -parse-as-library -O GammaForge.swift -o GammaForge && ./GammaForge
//
// 원리
//   - 미리보기: CGSetDisplayTransferByTable 로 디스플레이 감마 테이블(=vcgt가 로드되는 곳)을 직접 교체.
//     앱이 종료되면 macOS가 원래 프로파일의 설정으로 자동 복원함.
//   - 저장: macOS가 EDID로 만든 공장 프로파일(/Library/ColorSync/Profiles/Displays)을 기준으로
//     기존 vcgt 제거 → 새 vcgt + 새 이름(desc)만 넣어서 ~/Library/ColorSync/Profiles 에 저장.
//   - 이 앱은 ICC를 만드는 도구. 저장 후 종료하고, 시스템 설정에서 만든 프로파일을 선택해서 사용.
//
// 곡선 공식 (채널 c = R, G, B)
//   out(x) = gain_c * x ^ ( (모니터감마 / 목표감마) * shadow_c )
//   - 목표 감마: 낮출수록 중간톤이 진해짐(대비 ↑)
//   - 게인: 해당 채널의 최대 출력(밝은 영역)
//   - 채널 감마: 1보다 크면 그 채널이 중간·어두운 톤에서 더 많이 빠짐 (흰색·검정은 그대로)

import SwiftUI
import AppKit
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers

// MARK: - 다국어 (시스템 언어 자동 감지)

private let isKorean = Locale.current.language.languageCode?.identifier == "ko"
private func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

// MARK: - ICC 파일 읽기/쓰기

struct ICCProfile {
    var header: [UInt8]
    var tags: [(sig: String, data: [UInt8])]

    init?(bytes b: [UInt8]) {
        guard b.count >= 132, String(bytes: b[36..<40], encoding: .ascii) == "acsp" else { return nil }
        header = Array(b[0..<128])
        let n = Int(ICCProfile.u32(b, 128))
        guard n > 0, b.count >= 132 + 12 * n else { return nil }
        var t: [(sig: String, data: [UInt8])] = []
        for i in 0..<n {
            let base = 132 + 12 * i
            let sig = String(bytes: b[base..<(base + 4)], encoding: .ascii) ?? "????"
            let off = Int(ICCProfile.u32(b, base + 4))
            let size = Int(ICCProfile.u32(b, base + 8))
            guard off + size <= b.count else { return nil }
            t.append((sig: sig, data: Array(b[off..<(off + size)])))
        }
        tags = t
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { (UInt16(b[o]) << 8) | UInt16(b[o + 1]) }
    static func s15(_ b: [UInt8], _ o: Int) -> Double { Double(Int32(bitPattern: u32(b, o))) / 65536.0 }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func ascii4(_ s: String) -> [UInt8] { Array(s.utf8.prefix(4)) }

    var version: Int { Int(header[8]) }

    func tag(_ s: String) -> [UInt8]? { tags.first(where: { $0.sig == s })?.data }

    mutating func set(_ s: String, _ d: [UInt8]) {
        if let i = tags.firstIndex(where: { $0.sig == s }) { tags[i].data = d } else { tags.append((sig: s, data: d)) }
    }

    mutating func remove(_ s: String) { tags.removeAll(where: { $0.sig == s }) }

    /// 프로파일의 TRC에서 모니터 고유 감마 추정
    var nativeGamma: Double? {
        guard let t = tag("gTRC") ?? tag("rTRC"), t.count >= 12 else { return nil }
        let type = String(bytes: t[0..<4], encoding: .ascii)
        if type == "para", t.count >= 16 { return ICCProfile.s15(t, 12) }
        if type == "curv" {
            let n = Int(ICCProfile.u32(t, 8))
            if n == 0 { return 1.0 }
            if n == 1, t.count >= 14 { return Double(ICCProfile.u16(t, 12)) / 256.0 }
            guard t.count >= 12 + 2 * n else { return nil }
            let mid = (n - 1) / 2
            let x = Double(mid) / Double(n - 1)
            let y = Double(ICCProfile.u16(t, 12 + 2 * mid)) / 65535.0
            if y > 0, y < 1, x > 0, x < 1 { return log(y) / log(x) }
        }
        return nil
    }

    var descText: String? {
        guard let t = tag("desc"), t.count >= 12 else { return nil }
        let type = String(bytes: t[0..<4], encoding: .ascii)
        if type == "mluc", t.count >= 28 {
            let len = Int(ICCProfile.u32(t, 20)), off = Int(ICCProfile.u32(t, 24))
            guard off + len <= t.count else { return nil }
            return String(bytes: t[off..<(off + len)], encoding: .utf16BigEndian)
        }
        if type == "desc" {
            let len = Int(ICCProfile.u32(t, 8))
            guard len > 0, 12 + len <= t.count else { return nil }
            return String(bytes: t[12..<(12 + len - 1)], encoding: .ascii)
        }
        return nil
    }

    func makeDesc(_ name: String) -> [UInt8] {
        if version >= 4 {
            let s: [UInt8] = name.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
            var d: [UInt8] = ICCProfile.ascii4("mluc")
            d += [0, 0, 0, 0]
            d += ICCProfile.be32(1)
            d += ICCProfile.be32(12)
            d += ICCProfile.ascii4("enUS")
            d += ICCProfile.be32(UInt32(s.count))
            d += ICCProfile.be32(28)
            d += s
            return d
        } else {
            let a = [UInt8](name.data(using: .ascii, allowLossyConversion: true) ?? Data())
            var d: [UInt8] = ICCProfile.ascii4("desc")
            d += [0, 0, 0, 0]
            d += ICCProfile.be32(UInt32(a.count + 1))
            d += a
            d += [0]
            d += ICCProfile.be32(0)
            d += ICCProfile.be32(0)
            d += ICCProfile.be16(0)
            d += [0]
            d += [UInt8](repeating: 0, count: 67)
            return d
        }
    }

    func serialize() -> [UInt8] {
        let n = tags.count
        let pos = (128 + 4 + 12 * n + 3) / 4 * 4
        var table = ICCProfile.be32(UInt32(n))
        var body: [UInt8] = []
        var placed: [[UInt8]: Int] = [:]
        for t in tags {
            let off: Int
            if let o = placed[t.data] {
                off = o
            } else {
                off = pos + body.count
                placed[t.data] = off
                body += t.data
                body += [UInt8](repeating: 0, count: (4 - t.data.count % 4) % 4)
            }
            table += ICCProfile.ascii4(t.sig)
            table += ICCProfile.be32(UInt32(off))
            table += ICCProfile.be32(UInt32(t.data.count))
        }
        var out: [UInt8] = header
        out += table
        out += [UInt8](repeating: 0, count: pos - out.count)
        out += body
        out.replaceSubrange(0..<4, with: ICCProfile.be32(UInt32(out.count)))
        for i in 84..<100 { out[i] = 0 }
        if version >= 4 {
            // v4 Profile ID = MD5 (flags, intent, ID 필드는 0으로 두고 계산)
            var tmp = out
            for i in 44..<48 { tmp[i] = 0 }
            for i in 64..<68 { tmp[i] = 0 }
            let digest = Insecure.MD5.hash(data: Data(tmp))
            out.replaceSubrange(84..<100, with: Array(digest))
        }
        return out
    }
}

// MARK: - 모델

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

final class Tuner: ObservableObject {
    static let N = 256
    static let charTags = ["rXYZ", "gXYZ", "bXYZ", "wtpt", "chad", "rTRC", "gTRC", "bTRC"]

    @Published var displays: [DisplayInfo] = []
    @Published var displayID: CGDirectDisplayID = 0 {
        didSet { if oldValue != displayID { CGDisplayRestoreColorSyncSettings(); loadProfiles() } }
    }
    @Published var target: Double = 2.2 { didSet { apply() } }
    @Published var gain: [Double] = [1, 1, 1] { didSet { apply() } }
    @Published var shadow: [Double] = [1, 1, 1] { didSet { apply() } }
    @Published var bypass = false { didSet { apply() } }
    @Published var nativeGamma: Double = 2.2
    @Published var baseName = "-"
    @Published var currentName = "-"
    /// nil = 확인 불가, true = 현재 선택 프로파일의 특성이 기준과 같음, false = 다름
    @Published var matchOK: Bool? = nil
    @Published var outName = "Custom"
    @Published var status = ""

    private var base: ICCProfile?
    private var initialized = false

    init() {
        refreshDisplays()
        if let d = displays.first(where: { CGDisplayIsBuiltin($0.id) == 0 }) ?? displays.first {
            displayID = d.id   // init 안에서는 didSet이 호출되지 않으므로 아래에서 직접 로드
        }
        loadProfiles()

        // 조절하는 동안 디스플레이가 재구성되면(덮개 열기 등) 미리보기를 다시 적용
        _ = CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard let info = info, !flags.contains(.beginConfigurationFlag) else { return }
            let t = Unmanaged<Tuner>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { t.apply() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: num.uint32Value, name: s.localizedName)
        }
    }

    var displayName: String { displays.first(where: { $0.id == displayID })?.name ?? "" }

    static func characterization(_ p: ICCProfile) -> [String: [UInt8]] {
        var d: [String: [UInt8]] = [:]
        for k in charTags { if let t = p.tag(k) { d[k] = t } }
        return d
    }

    /// 지금 시스템 설정에서 선택된 프로파일
    private func currentProfile() -> ICCProfile? {
        let cs = CGDisplayCopyColorSpace(displayID)
        guard let cf = cs.copyICCData() else { return nil }
        return ICCProfile(bytes: [UInt8](cf as Data))
    }

    /// macOS가 EDID로 자동 생성한 공장 프로파일 찾기
    /// (/Library/ColorSync/Profiles/Displays/<모델명>-<UUID>.icc)
    private func findFactoryProfile(matching current: ICCProfile?) -> (ICCProfile, String)? {
        let dir = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let name = displayName
        var candidates: [(ICCProfile, URL, Date)] = []
        for url in files where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: url), let p = ICCProfile(bytes: [UInt8](data)) else { continue }
            let byFile = !name.isEmpty && url.lastPathComponent.hasPrefix(name + "-")
            let byDesc = !name.isEmpty && p.descText == name
            guard byFile || byDesc else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((p, url, date))
        }
        guard !candidates.isEmpty else { return nil }
        // 같은 모델이 여러 대면: 현재 선택 프로파일과 특성이 같은 것 우선, 없으면 최신 파일
        if let cur = current {
            let c = Tuner.characterization(cur)
            if let hit = candidates.first(where: { Tuner.characterization($0.0) == c }) {
                return (hit.0, hit.1.lastPathComponent)
            }
        }
        let newest = candidates.max(by: { $0.2 < $1.2 })!
        return (newest.0, newest.1.lastPathComponent)
    }

    func loadProfiles() {
        guard displayID != 0 else { return }
        let current = currentProfile()
        currentName = current?.descText ?? L("(읽을 수 없음)", "(unreadable)")
        if let found = findFactoryProfile(matching: current) {
            let (factory, file) = found
            setBase(factory, label: "\(factory.descText ?? file)  (\(L("공장 프로파일", "factory profile")): \(file))")
        } else if let cur = current {
            setBase(cur, label: "\(cur.descText ?? "?")  \(L("(공장 프로파일을 못 찾아 현재 선택된 프로파일 사용)", "(factory profile not found, using current profile)"))")
        } else {
            status = L("프로파일을 읽지 못했어요. '기준 ICC 직접 선택…'으로 지정해 주세요.",
                       "Couldn't read a profile. Use 'Choose Base ICC…' to pick one.")
        }
        checkMatch(current)
    }

    /// 미리보기가 저장 결과와 같으려면, 현재 선택된 프로파일의 특성(원색·화이트·TRC)이 기준과 같아야 함
    func checkMatch(_ current: ICCProfile? = nil) {
        guard let b = base, let cur = current ?? currentProfile() else { matchOK = nil; return }
        currentName = cur.descText ?? "?"
        matchOK = Tuner.characterization(cur) == Tuner.characterization(b)
    }

    func loadBaseFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }
        panel.directoryURL = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let p = ICCProfile(bytes: [UInt8](data)) else { return }
        setBase(p, label: "\(p.descText ?? url.lastPathComponent)  (\(L("직접 선택", "manually selected")): \(url.lastPathComponent))")
        checkMatch()
    }

    private func setBase(_ p: ICCProfile, label: String) {
        base = p
        nativeGamma = p.nativeGamma ?? 2.2
        baseName = label
        if !initialized {
            initialized = true
            target = (nativeGamma * 100).rounded() / 100
            outName = "\(p.descText ?? "Display") Custom"
        }
        apply()
    }

    func curve(_ c: Int) -> [Double] {
        let e = nativeGamma / target * shadow[c]
        return (0..<Tuner.N).map { i in
            min(1.0, max(0.0, gain[c] * pow(Double(i) / Double(Tuner.N - 1), e)))
        }
    }

    func apply() {
        guard displayID != 0 else { return }
        var r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue]
        if bypass {
            let id = (0..<Tuner.N).map { CGGammaValue(Double($0) / Double(Tuner.N - 1)) }
            r = id; g = id; b = id
        } else {
            r = curve(0).map { CGGammaValue($0) }
            g = curve(1).map { CGGammaValue($0) }
            b = curve(2).map { CGGammaValue($0) }
        }
        let err = CGSetDisplayTransferByTable(displayID, UInt32(Tuner.N), &r, &g, &b)
        if err != .success {
            status = L("감마 테이블 적용 실패 (CGError \(err.rawValue)). '밝기 자동 조절'이 켜져 있다면 꺼 보세요.",
                       "Failed to apply gamma table (CGError \(err.rawValue)). If 'Automatically adjust brightness' is on, try turning it off.")
        }
    }

    func reset() {
        target = (nativeGamma * 100).rounded() / 100
        gain = [1, 1, 1]
        shadow = [1, 1, 1]
    }

    func presetCustomG18() {
        target = 1.8
        gain = [0.98, 1, 1]
        shadow = [1.10, 1, 1]
    }

    var summary: String {
        String(format: L("감마 %.2f | 게인 R%.3f G%.3f B%.3f | 채널 감마 R%.2f G%.2f B%.2f",
                          "Gamma %.2f | Gain R%.3f G%.3f B%.3f | Channel Gamma R%.2f G%.2f B%.2f"),
               target, gain[0], gain[1], gain[2], shadow[0], shadow[1], shadow[2])
    }

    @discardableResult
    func save() -> Bool {
        guard var p = base else { status = L("기준 프로파일이 없어요.", "No base profile set."); return false }
        let name = outName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { status = L("프로파일 이름을 입력해 주세요.", "Enter a profile name."); return false }

        var vcgt: [UInt8] = ICCProfile.ascii4("vcgt")
        vcgt += [0, 0, 0, 0]
        vcgt += ICCProfile.be32(0)          // 0 = table
        vcgt += ICCProfile.be16(3)          // 채널 수
        vcgt += ICCProfile.be16(UInt16(Tuner.N))
        vcgt += ICCProfile.be16(2)          // 16-bit
        for c in 0..<3 {
            for v in curve(c) { vcgt += ICCProfile.be16(UInt16((v * 65535).rounded())) }
        }
        // 기준(공장) 프로파일은 그대로 두고 vcgt와 이름만 교체
        p.remove("vcgt")
        p.set("desc", p.makeDesc(name))
        p.set("vcgt", vcgt)
        let bytes = p.serialize()

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles")
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(safe).icc")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
            status = L("저장 완료: \(url.path)", "Saved: \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        } catch {
            status = L("저장 실패: \(error.localizedDescription)", "Save failed: \(error.localizedDescription)")
            return false
        }
    }

    func saveAndQuit() {
        guard save() else { return }
        let name = outName.trimmingCharacters(in: .whitespaces)
        let alert = NSAlert()
        alert.messageText = L("저장했어요", "Saved")
        alert.informativeText = L(
            "앱을 종료하면 화면이 원래 설정으로 돌아가요.\n시스템 설정 › 디스플레이 › 색상 프로필에서 '\(name)'을 선택하면 지금 본 결과가 적용돼요.\n(같은 이름을 덮어썼다면 다른 프로파일을 한 번 선택했다가 다시 선택하세요.)",
            "The screen returns to its original setting when the app quits.\nSelect '\(name)' in System Settings › Displays › Color Profile to apply what you just saw.\n(If you overwrote the same name, pick a different profile once, then select it again.)")
        alert.addButton(withTitle: L("종료하고 디스플레이 설정 열기", "Quit and Open Display Settings"))
        alert.runModal()
        if let u = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
        NSApp.terminate(nil)
    }
}

// MARK: - UI

struct ParamRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 110, alignment: .leading)
            Button("−") { value = snap(value - step) }.frame(width: 28)
            Slider(value: $value, in: range)
            Button("+") { value = snap(value + step) }.frame(width: 28)
            Text(String(format: "%.\(digits)f", value))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func snap(_ v: Double) -> Double {
        let r = (v / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, r))
    }
}

struct PatternView: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height / 4
            let rows: [(y: CGFloat, values: [Int])] = [
                (0, Array(stride(from: 0, through: 255, by: 16)) + [255]),   // 전체 계단
                (h * 2, Array(stride(from: 0, through: 48, by: 4))),         // 어두운 영역 계단
                (h * 3, Array(stride(from: 207, through: 255, by: 4)))       // 밝은 영역 계단
            ]
            for r in rows {
                let pw = w / CGFloat(r.values.count)
                for (i, v) in r.values.enumerated() {
                    let rect = CGRect(x: pw * CGFloat(i), y: r.y, width: pw + 1, height: h)
                    ctx.fill(Path(rect), with: .color(Color(.sRGB, white: Double(v) / 255, opacity: 1)))
                }
            }
            ctx.fill(Path(CGRect(x: 0, y: h, width: w, height: h)),
                     with: .linearGradient(Gradient(colors: [Color(.sRGB, white: 0, opacity: 1), Color(.sRGB, white: 1, opacity: 1)]),
                                           startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: w, y: h)))  // 그라데이션
        }
        .frame(height: 200)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }
}

struct ContentView: View {
    @EnvironmentObject var t: Tuner
    @State private var coarse = false

    var body: some View {
        let k = coarse ? 5.0 : 1.0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L("모니터", "Monitor"), selection: $t.displayID) {
                    ForEach(t.displays) { d in Text(d.name).tag(d.id) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Button(L("다시 확인", "Recheck")) { t.loadProfiles() }
                Button(L("기준 ICC 직접 선택…", "Choose Base ICC…")) { t.loadBaseFromFile() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("저장 기준: \(t.baseName)", "Base for saving: \(t.baseName)"))
                Text(L("모니터 고유 감마(TRC): \(String(format: "%.3f", t.nativeGamma))   ·   현재 선택된 프로파일: \(t.currentName)",
                       "Native gamma (TRC): \(String(format: "%.3f", t.nativeGamma))   ·   Current profile: \(t.currentName)"))
                switch t.matchOK {
                case .some(true):
                    Text(L("✅ 현재 선택된 프로파일과 기준의 모니터 특성이 같아요. 미리보기 = 저장 결과",
                           "✅ The current profile's monitor characteristics match the base. Preview = saved result"))
                        .foregroundColor(.green)
                case .some(false):
                    Text(L("⚠️ 현재 선택된 프로파일의 특성(원색·화이트·TRC)이 기준과 달라요. 색 관리 앱의 미리보기가 저장 결과와 다르게 보일 수 있어요. 시스템 설정에서 공장 프로파일(또는 이 앱으로 만든 Custom)을 선택한 뒤 '다시 확인'을 누르세요.",
                           "⚠️ The current profile's characteristics (primaries/white/TRC) differ from the base. A color-managed app's preview may not match the saved result. Select the factory profile (or a Custom one made by this app) in System Settings, then press 'Recheck'."))
                        .foregroundColor(.orange)
                case .none:
                    Text(L("현재 선택된 프로파일을 확인할 수 없어요.", "Can't verify the current profile.")).foregroundColor(.secondary)
                }
            }
            .font(.callout)
            .foregroundColor(.secondary)

            GroupBox(L("전체", "Overall")) {
                ParamRow(title: L("목표 감마", "Target Gamma"), value: $t.target, range: 1.2...2.8, step: 0.01 * k, digits: 2)
            }
            GroupBox(L("게인 (밝은 영역 · 최대 출력)", "Gain (highlights · max output)")) {
                VStack {
                    ParamRow(title: L("R 게인", "R Gain"), value: $t.gain[0], range: 0.70...1.0, step: 0.002 * k, digits: 3)
                    ParamRow(title: L("G 게인", "G Gain"), value: $t.gain[1], range: 0.70...1.0, step: 0.002 * k, digits: 3)
                    ParamRow(title: L("B 게인", "B Gain"), value: $t.gain[2], range: 0.70...1.0, step: 0.002 * k, digits: 3)
                }
            }
            GroupBox(L("채널 감마 보정 (1보다 크면 그 채널이 중간·어두운 톤에서 더 빠짐, 흰색·검정은 그대로)",
                       "Channel Gamma (above 1 pulls that channel down more in mids/shadows; white/black stay fixed)")) {
                VStack {
                    ParamRow(title: L("R 채널 감마", "R Channel Gamma"), value: $t.shadow[0], range: 0.80...1.40, step: 0.01 * k, digits: 2)
                    ParamRow(title: L("G 채널 감마", "G Channel Gamma"), value: $t.shadow[1], range: 0.80...1.40, step: 0.01 * k, digits: 2)
                    ParamRow(title: L("B 채널 감마", "B Channel Gamma"), value: $t.shadow[2], range: 0.80...1.40, step: 0.01 * k, digits: 2)
                }
            }

            HStack {
                Toggle(L("큰 단위로 조절 (×5)", "Coarse step (×5)"), isOn: $coarse)
                Spacer()
                Toggle(L("원본 보기 (비교)", "Show original (compare)"), isOn: $t.bypass)
                Button(L("초기화", "Reset")) { t.reset() }
                Button(L("Custom G1.8 값 불러오기", "Load Custom G1.8 preset")) { t.presetCustomG18() }
            }

            PatternView()

            Text(t.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)

            HStack {
                Text(L("저장 이름", "Save as"))
                TextField(L("프로파일 이름", "Profile name"), text: $t.outName).frame(maxWidth: 320)
                Button(L("저장만", "Save Only")) { t.save() }
                Button(L("저장하고 종료", "Save & Quit")) { t.saveAndQuit() }.keyboardShortcut("s")
                Spacer()
                Link(L("☕ 후원하기", "☕ Support"), destination: URL(string: "https://buymeacoffee.com/wooooooooook")!)
                    .font(.callout)
            }
            Text(t.status).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
        }
        .padding(16)
        .frame(minWidth: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        signal(SIGINT) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { CGDisplayRestoreColorSyncSettings() }
}

@main
struct GammaForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var tuner = Tuner()

    var body: some Scene {
        WindowGroup("Gamma Forge") {
            ContentView().environmentObject(tuner)
        }
    }
}
