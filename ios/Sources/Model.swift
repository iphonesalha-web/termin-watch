import Foundation
import SwiftUI

struct Notice {
    let text: String
    let isError: Bool
}

@MainActor
final class Model: ObservableObject {
    @Published var status: StatusResponse?
    @Published var logLines: [String] = []
    @Published var errorText: String?
    @Published var notice: Notice?
    @Published var busy = false

    // MARK: قراءة

    func refresh() async {
        guard let api = PiAPI.fromDefaults() else {
            status = nil
            errorText = PiError.notConfigured.localizedDescription
            return
        }
        do {
            status = try await api.call(StatusResponse.self, path: "/status")
            errorText = nil
        } catch let e {
            errorText = e.localizedDescription
        }
    }

    func loadLog() async {
        guard let api = PiAPI.fromDefaults() else {
            errorText = PiError.notConfigured.localizedDescription
            return
        }
        do {
            let r = try await api.call(LogResponse.self, path: "/log?n=150")
            logLines = r.lines
            errorText = nil
        } catch let e {
            errorText = e.localizedDescription
        }
    }

    // MARK: أوامر

    private func act(_ method: String, _ path: String, body: [String: String]? = nil,
                     success: String) async {
        guard let api = PiAPI.fromDefaults() else {
            notice = Notice(text: PiError.notConfigured.localizedDescription, isError: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await api.call(ActionResponse.self, method: method, path: path, body: body)
            if r.ok == false {
                notice = Notice(text: r.message ?? r.error ?? "فشل التنفيذ", isError: true)
            } else {
                notice = Notice(text: success, isError: false)
            }
        } catch let e {
            notice = Notice(text: e.localizedDescription, isError: true)
        }
        // الخدمة تحتاج لحظة لتستقر قبل قراءة حالتها
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
    }

    func serviceAction(_ action: String) async {
        let names = ["start": "تم التشغيل", "stop": "تم الإيقاف", "restart": "تمت إعادة التشغيل"]
        await act("POST", "/service/\(action)", success: names[action] ?? "تم")
    }

    func setCutoff(_ date: Date) async {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let s = f.string(from: date)
        await act("POST", "/cutoff", body: ["date": s], success: "التاريخ الجديد: \(s) (أُعيد تشغيل المراقب)")
    }

    func testTelegram() async {
        await act("POST", "/test", success: "أُرسلت رسالة الاختبار إلى Telegram")
    }
}

// MARK: - مساعدات العرض

enum Fmt {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let shown: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    /// "2026-11-08T11:00:00" -> "08.11 11:00"
    static func stamp(_ s: String?) -> String {
        guard let s = s, let d = iso.date(from: s) else { return "—" }
        return shown.string(from: d)
    }

    /// الفرق بين لحظتين نصيتين (بتوقيت الـ Pi نفسه)
    static func ago(from s: String?, now: String?) -> String {
        guard let s = s, let n = now, let a = iso.date(from: s), let b = iso.date(from: n) else { return "" }
        let sec = Int(b.timeIntervalSince(a))
        if sec < 60 { return "قبل لحظات" }
        if sec < 3600 { return "قبل \(sec / 60) دقيقة" }
        if sec < 86400 { return "قبل \(sec / 3600) ساعة" }
        return "قبل \(sec / 86400) يوم"
    }

    /// "2027-02-16" -> "16.02.2027"
    static func day(_ s: String?) -> String {
        guard let s = s else { return "—" }
        let p = s.split(separator: "-")
        guard p.count == 3 else { return s }
        return "\(p[2]).\(p[1]).\(p[0])"
    }

    static func uptime(_ s: Int?) -> String {
        guard let s = s else { return "—" }
        if s >= 86400 { return "\(s / 86400) يوم \((s % 86400) / 3600) ساعة" }
        if s >= 3600 { return "\(s / 3600) ساعة \((s % 3600) / 60) دقيقة" }
        return "\(s / 60) دقيقة"
    }
}
