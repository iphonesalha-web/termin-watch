import SwiftUI

struct LogView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationView {
            Group {
                if model.logLines.isEmpty {
                    VStack(spacing: 12) {
                        if let e = model.errorText {
                            Text(e).foregroundColor(.red).multilineTextAlignment(.center)
                        } else {
                            Text("لا توجد أسطر بعد").foregroundColor(.secondary)
                        }
                    }
                    .padding()
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .environment(\.layoutDirection, .leftToRight)
                                    .id(i)
                            }
                        }
                        .listStyle(.plain)
                        .onAppear { scrollToEnd(proxy) }
                        .onChange(of: model.logLines.count) { _ in scrollToEnd(proxy) }
                    }
                }
            }
            .navigationTitle("السجل")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { Task { await model.loadLog() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await model.loadLog() }
        }
        .navigationViewStyle(.stack)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let last = model.logLines.count - 1
        if last >= 0 { proxy.scrollTo(last, anchor: .bottom) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @AppStorage("host") private var host = "http://pi.local:8787"
    @AppStorage("token") private var token = ""
    @State private var result: String?
    @State private var resultOK = false
    @State private var testing = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("عنوان الـ Pi"),
                        footer: Text("في البيت: http://pi.local:8787 أو عنوان IP من الـ FRITZ!Box. من الخارج: عنوان Tailscale (100.x.x.x) مع المنفذ 8787.")) {
                    TextField("http://pi.local:8787", text: $host)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section(header: Text("كلمة السر"),
                        footer: Text("تظهر في نهاية التنصيب على الـ Pi، أو بالأمر: grep API_TOKEN ~/termin-watch/api.env")) {
                    SecureField("API_TOKEN", text: $token)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    Button {
                        Task {
                            testing = true
                            await model.refresh()
                            testing = false
                            if let e = model.errorText { result = e; resultOK = false }
                            else { result = "الاتصال ناجح ✅"; resultOK = true }
                        }
                    } label: {
                        HStack {
                            Text("اختبار الاتصال")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let r = result {
                        Text(r).foregroundColor(resultOK ? .green : .red)
                    }
                }
            }
            .navigationTitle("الإعدادات")
        }
        .navigationViewStyle(.stack)
    }
}
