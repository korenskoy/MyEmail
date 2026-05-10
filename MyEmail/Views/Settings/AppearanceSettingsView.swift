//
//  AppearanceSettingsView.swift
//  MyEmail
//
//  Theme, density, layout preferences.
//

import SwiftUI

// MARK: - AppTheme

enum AppTheme: String, CaseIterable, Sendable {
    case system, light, dark

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("messageDensity") private var density: String = "compact"
    @AppStorage("dateFormatRelative") private var relativeDates = true
    @AppStorage("previewLineCount") private var previewLines: Int = 1
    @AppStorage("appTheme") private var theme: AppTheme = .system
    @AppStorage("plainTextFontSize") private var plainFontSize: Int = 13
    @AppStorage("plainTextMonospace") private var plainMonospace: Bool = false
    @AppStorage("plainTextQuoteColor1") private var quoteHex1: String = "#7B5EA7"
    @AppStorage("plainTextQuoteColor2") private var quoteHex2: String = "#1A9D7A"
    @AppStorage("plainTextQuoteColor3") private var quoteHex3: String = "#28A745"
    @AppStorage("showMailUserAgent") private var showMUA: Bool = false

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $theme) {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
            }

            Section("Message List") {
                Picker("Row density", selection: $density) {
                    Text("Compact (22pt)").tag("compact")
                    Text("Normal (26pt)").tag("normal")
                    Text("Wide (34pt)").tag("wide")
                }

                Picker("Preview lines", selection: $previewLines) {
                    Text("None").tag(0)
                    Text("1 line").tag(1)
                    Text("2 lines").tag(2)
                }
            }

            Section("Dates") {
                Toggle("Use relative dates (Today, Yesterday)", isOn: $relativeDates)
            }

            Section("Icons") {
                Toggle("Display Mail User Agent", isOn: $showMUA)
            }

            Section("Plain text") {
                LabeledContent("Font size") {
                    Stepper("\(plainFontSize) pt", value: $plainFontSize, in: 11...18)
                }
                Toggle("Use monospace font", isOn: $plainMonospace)
                LabeledContent("Quoted text colors") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            ColorPicker("Level 1", selection: quoteColor(0))
                            ColorPicker("Level 2", selection: quoteColor(1))
                            ColorPicker("Level 3", selection: quoteColor(2))
                        }
                        PlainTextQuotePreview(colors: [
                            Color(hex: quoteHex1),
                            Color(hex: quoteHex2),
                            Color(hex: quoteHex3)
                        ])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: theme) { _, newValue in
            newValue.apply()
        }
    }

    private func quoteColor(_ index: Int) -> Binding<Color> {
        switch index {
        case 0: return Binding(get: { Color(hex: quoteHex1) }, set: { quoteHex1 = $0.hexString })
        case 1: return Binding(get: { Color(hex: quoteHex2) }, set: { quoteHex2 = $0.hexString })
        default: return Binding(get: { Color(hex: quoteHex3) }, set: { quoteHex3 = $0.hexString })
        }
    }
}

private struct PlainTextQuotePreview: View {
    let colors: [Color]
    private let labels = ["Level 1", "Level 2", "Level 3"]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: 14)
                        .foregroundStyle(colors[i])
                    Text(labels[i])
                        .font(.system(size: 12))
                        .foregroundStyle(colors[i])
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}

private extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 { h = h.flatMap { [$0, $0] }.map(String.init).joined() }
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
