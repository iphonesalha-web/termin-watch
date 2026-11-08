import SwiftUI

struct StatusView: View {
    @EnvironmentObject var model: Model
    @State private var showCutoff = false
    @State private var confirmStop = false
    @State private var cutoffDate = Date()

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    var body: some View {
        NavigationView {
            List {
                if let e = model.errorText {
                    Section {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }

                if let s = model.status {
                    serviceSection(s)
                    slotsSection(s)
                    actionsSection()
                    if let d = s.device { deviceSection(d) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("مراقب المواعيد")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if model.busy { ProgressView() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            // تحديث تلقائي كل 15 ثانية طالما الشاشة ظاهرة
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .alert(model.notice?.isError == true ? "خطأ" : "تم",
               isPresented: noticeBinding,
               actions: { Button("حسناً", role: .cancel) {} },
               message: { Text(model.notice?.text ?? "") })
        .sheet(isPresented: $showCutoff) { cutoffSheet }
        .confirmationDialog("إيقاف المراقبة؟ لن تصلك تنبيهات حتى تشغّلها من جديد.",
                            isPresented: $confirmStop, titleVisibility: .visible) {
            Button("إيقاف", role: .destructive) { Task { await model.serviceAction("stop") } }
            Button("إلغاء", role: .cancel) {}
        }
    }

    // MARK: أقسام

    private func serviceSection(_ s: StatusResponse) -> some View {
        Section("الخدمة") {
            HStack {
                Text("الحالة")
                Spacer()
                stateBadge(s.service)
            }
            HStack {
                Text("آخر فحص")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.stamp(s.last_check))
                    Text(Fmt.ago(from: s.last_check, now: s.now))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if s.ok == false, let err = s.error {
                Text("آخر خطأ: \(err)").font(.caption).foregroundColor(.red)
            }
            HStack {
                Text("إشعارات Telegram")
                Spacer()
                Image(systemName: s.telegram == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(s.telegram == true ? .green : .red)
            }
        }
    }

    private func slotsSection(_ s: StatusResponse) -> some View {
        Section("المواعيد") {
            HStack {
                Text("أنبّهك قبل")
                Spacer()
                Text(Fmt.day(s.cutoff)).bold()
                Button("تغيير") {
                    cutoffDate = Self.parse(s.cutoff) ?? Date()
                    showCutoff = true
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text("أقرب موعد متاح")
                Spacer()
                Text(Fmt.day(s.earliest))
            }
            HStack {
                Text("عدد المواعيد المتاحة")
                Spacer()
                Text(s.total.map(String.init) ?? "—")
            }
            if let up = s.upcoming, !up.isEmpty {
                ForEach(up.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.day(day)).font(.subheadline).bold()
                        Text((up[day] ?? []).joined(separator: "  ·  "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func actionsSection() -> some View {
        Section("تحكم") {
            Button { Task { await model.serviceAction("restart") } } label: {
                Label("إعادة التشغيل", systemImage: "arrow.clockwise")
            }
            Button { Task { await model.serviceAction("start") } } label: {
                Label("تشغيل", systemImage: "play.fill")
            }
            Button(role: .destructive) { confirmStop = true } label: {
                Label("إيقاف", systemImage: "stop.fill")
            }
            Button { Task { await model.testTelegram() } } label: {
                Label("إرسال رسالة اختبار إلى Telegram", systemImage: "paperplane")
            }
        }
        .disabled(model.busy)
    }

    private func deviceSection(_ d: DeviceInfo) -> some View {
        Section("الجهاز") {
            if let t = d.temp_c { row("الحرارة", String(format: "%.1f °C", t)) }
            if let m = d.mem_used_pct { row("الذاكرة", "\(m)%") }
            if let k = d.disk_used_pct { row("التخزين", "\(k)%") }
            row("مدة التشغيل", Fmt.uptime(d.uptime_s))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) }
    }

    @ViewBuilder
    private func stateBadge(_ state: String) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case "active": return ("يعمل", .green)
            case "inactive": return ("متوقف", .red)
            case "failed": return ("فشل", .red)
            case "activating": return ("يبدأ…", .orange)
            default: return ("غير معروف", .orange)
            }
        }()
        Text(text)
            .font(.subheadline).bold()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: تغيير التاريخ

    private var cutoffSheet: some View {
        NavigationView {
            VStack {
                DatePicker("", selection: $cutoffDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                Text("سأرسل تنبيهاً لأي موعد قبل هذا التاريخ.")
                    .font(.footnote).foregroundColor(.secondary)
                Spacer()
            }
            .navigationTitle("تاريخ التنبيه")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        showCutoff = false
                        Task { await model.setCutoff(cutoffDate) }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { showCutoff = false }
                }
            }
        }
    }

    private static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
