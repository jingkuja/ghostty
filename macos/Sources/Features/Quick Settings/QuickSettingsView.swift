import AppKit
import SwiftUI

/// The popover behind the titlebar's gear: the common settings that otherwise mean
/// editing Ghostty's config file, applied as soon as they change.
struct QuickSettingsView: View {
    @ObservedObject var store = QuickSettingsStore.shared
    @AppStorage("QuickSettingsSection") private var section: Section = .appearance

    enum Section: String, CaseIterable, Identifiable {
        case appearance, font, colors, behavior

        var id: Self { self }

        var title: String {
            switch self {
            case .appearance: "外观"
            case .font: "字体"
            case .colors: "颜色"
            case .behavior: "行为"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .font: "textformat"
            case .colors: "drop"
            case .behavior: "cursorarrow.rays"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .appearance: AppearanceSettings(store: store)
                    case .font: FontSettings(store: store)
                    case .colors: ColorSettings(store: store)
                    case .behavior: BehaviorSettings(store: store)
                    }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 380, height: 470)
        .onAppear(perform: store.load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("修改即时生效")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            QuickSettingsTabs(selection: $section)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else {
                Text(store.path.abbreviatingHome)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.path)
            }
            Spacer()
            Button("编辑配置文件…", action: store.openFile)
                .controlSize(.small)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The sections as a segmented control whose selection slides between them.
private struct QuickSettingsTabs: View {
    @Binding var selection: QuickSettingsView.Section
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(QuickSettingsView.Section.allCases) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    HStack(spacing: 4) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11, weight: .medium))
                        Text(section.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundColor(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.11))
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelStyle.fieldFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PanelStyle.hairline, lineWidth: 1))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selection)
    }
}

// MARK: Sections

private struct AppearanceSettings: View {
    @ObservedObject var store: QuickSettingsStore
    @AppStorage(QuickSettingsStore.alwaysShowTabBarKey) private var alwaysShowTabBar = true

    var body: some View {
        SettingsGroup("主题") {
            SettingsRow("配色主题", key: "theme", store: store) {
                Picker("", selection: store.text("theme", default: "")) {
                    Text("默认").tag("")
                    // Keep a value the list doesn't have, e.g. "light:A,dark:B".
                    if let theme = store.value("theme"), !QuickSettingsStore.themes.contains(theme) {
                        Text(theme).tag(theme)
                    }
                    Divider()
                    ForEach(QuickSettingsStore.themes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }
            SettingsNote("主题会设置全部颜色，“颜色”中单独设置的会覆盖它。")
        }

        SettingsGroup("窗口") {
            SettingsRow("背景不透明度", key: "background-opacity", store: store) {
                let opacity = store.number("background-opacity", default: 1)
                HStack(spacing: 8) {
                    Slider(value: opacity, in: 0.3...1, step: 0.05)
                        .frame(width: 120)
                    Text("\(Int((opacity.wrappedValue * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            SettingsRow("背景模糊", key: "background-blur", store: store) {
                Toggle("", isOn: store.flag("background-blur", default: false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsRow("水平内边距", key: "window-padding-x", store: store) {
                NumberStepper(value: store.number("window-padding-x", default: 2), range: 0...40, unit: "pt")
            }
            SettingsRow("垂直内边距", key: "window-padding-y", store: store) {
                NumberStepper(value: store.number("window-padding-y", default: 2), range: 0...40, unit: "pt")
            }
            SettingsRow("标题栏样式", key: "macos-titlebar-style", store: store) {
                Picker("", selection: store.text("macos-titlebar-style", default: "transparent")) {
                    Text("透明").tag("transparent")
                    Text("原生").tag("native")
                    Text("标签页").tag("tabs")
                    Text("隐藏").tag("hidden")
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
            SettingsNote("标题栏样式在新窗口中生效。")
        }

        SettingsGroup("标签栏") {
            SettingsRow("只有一个标签页时也显示") {
                Toggle("", isOn: $alwaysShowTabBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: alwaysShowTabBar) { _ in TerminalWindow.syncAllTabBars() }
            }
        }
    }
}

private struct FontSettings: View {
    @ObservedObject var store: QuickSettingsStore

    var body: some View {
        let family = store.value("font-family")
        let size = store.number("font-size", default: 13)

        SettingsGroup("字体") {
            SettingsRow("字体", key: "font-family", store: store) {
                Picker("", selection: store.text("font-family", default: "")) {
                    Text("默认（JetBrains Mono）").tag("")
                    if let family, !QuickSettingsStore.monospacedFamilies.contains(family) {
                        Text(family).tag(family)
                    }
                    Divider()
                    ForEach(QuickSettingsStore.monospacedFamilies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }
            SettingsRow("字号", key: "font-size", store: store) {
                NumberStepper(value: size, range: 8...36, step: 0.5, unit: "pt")
            }
            SettingsRow("加粗渲染", key: "font-thicken", store: store) {
                Toggle("", isOn: store.flag("font-thicken", default: false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsRow("行高", key: "adjust-cell-height", store: store) {
                NumberStepper(value: store.percent("adjust-cell-height"), range: -20...100, step: 5, unit: "%")
            }
        }

        SettingsGroup("预览") {
            let font = family.flatMap { NSFont(name: $0, size: size.wrappedValue) }
                ?? NSFont(name: "JetBrains Mono", size: size.wrappedValue)
                ?? .monospacedSystemFont(ofSize: size.wrappedValue, weight: .regular)
            VStack(alignment: .leading, spacing: 4) {
                Text("~/project $ git status")
                Text("0O 1lI {}[] => != -> 你好，世界")
            }
            .font(Font(font))
            .lineLimit(1)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(store.effectiveColor("foreground") ?? .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(store.effectiveColor("background") ?? Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PanelStyle.hairline, lineWidth: 1))
        }
    }
}

private struct ColorSettings: View {
    @ObservedObject var store: QuickSettingsStore

    var body: some View {
        SettingsGroup("终端") {
            ColorRow(title: "背景", key: "background", store: store)
            ColorRow(title: "前景（文字）", key: "foreground", store: store)
        }
        SettingsGroup("光标与选区") {
            ColorRow(title: "光标", key: "cursor-color", store: store)
            ColorRow(title: "光标处文字", key: "cursor-text", store: store)
            ColorRow(title: "选区背景", key: "selection-background", store: store)
            ColorRow(title: "选区文字", key: "selection-foreground", store: store)
        }
        SettingsNote("未单独设置的颜色跟随主题，点 ↺ 可恢复。")
    }
}

private struct BehaviorSettings: View {
    @ObservedObject var store: QuickSettingsStore

    var body: some View {
        SettingsGroup("光标") {
            SettingsRow("样式", key: "cursor-style", store: store) {
                Picker("", selection: store.text("cursor-style", default: "block")) {
                    Text("方块").tag("block")
                    Text("竖线").tag("bar")
                    Text("下划线").tag("underline")
                    Text("空心方块").tag("block_hollow")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 120)
            }
            SettingsRow("闪烁", key: "cursor-style-blink", store: store) {
                Toggle("", isOn: store.flag("cursor-style-blink", default: true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }

        SettingsGroup("鼠标与剪贴板") {
            SettingsRow("打字时隐藏鼠标", key: "mouse-hide-while-typing", store: store) {
                Toggle("", isOn: store.flag("mouse-hide-while-typing", default: false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsRow("选中即复制", key: "copy-on-select", store: store) {
                Picker("", selection: store.text("copy-on-select", default: "none")) {
                    Text("关闭").tag("none")
                    Text("系统剪贴板").tag("clipboard")
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
        }

        SettingsGroup("键盘") {
            SettingsRow("Option 作为 Alt", key: "macos-option-as-alt", store: store) {
                Picker("", selection: store.text("macos-option-as-alt", default: "")) {
                    Text("默认").tag("")
                    Text("关闭").tag("false")
                    Text("两侧").tag("true")
                    Text("左侧").tag("left")
                    Text("右侧").tag("right")
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
            SettingsNote("开启后 Option 组合键发送 Alt，而不是输入特殊字符。")
        }
    }
}

// MARK: Building blocks

/// A titled card of rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(PanelStyle.hairline, lineWidth: 1))
        }
    }
}

/// A setting's label, its control, and a button that removes it from the config file.
private struct SettingsRow<Control: View>: View {
    let title: String
    var key: String?
    var store: QuickSettingsStore?
    @ViewBuilder let control: Control

    init(_ title: String, key: String? = nil, store: QuickSettingsStore? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.key = key
        self.store = store
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            control
                .controlSize(.small)
            ResetButton(key: key, store: store)
        }
        .frame(minHeight: 30)
    }
}

private struct ResetButton: View {
    let key: String?
    let store: QuickSettingsStore?

    var body: some View {
        let isSet = key.flatMap { store?.value($0) } != nil
        Button {
            if let key { store?.set(key, nil) }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSet ? 1 : 0)
        .disabled(!isSet)
        .help("恢复默认")
    }
}

private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

/// A color setting: a swatch to pick it, showing what applies while the file doesn't set it.
private struct ColorRow: View {
    let title: String
    let key: String
    @ObservedObject var store: QuickSettingsStore

    var body: some View {
        let explicit = store.value(key).flatMap { Color(configHex: $0) }
        SettingsRow(title, key: key, store: store) {
            HStack(spacing: 8) {
                Text(store.value(key) ?? "主题")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                ColorPicker("", selection: Binding(
                    get: { explicit ?? store.effectiveColor(key) ?? .gray },
                    set: { store.set(key, $0.configHex) }),
                    supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

/// A number with − and + buttons.
private struct NumberStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", by: -step)
            Text(formatted)
                .font(.system(size: 12).monospacedDigit())
                .frame(minWidth: 52)
            stepButton("plus", by: step)
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PanelStyle.fieldFill))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(PanelStyle.hairline, lineWidth: 1))
    }

    private var formatted: String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return number + " " + unit
    }

    private func stepButton(_ symbol: String, by delta: Double) -> some View {
        Button {
            value = (value + delta).clamped(to: range)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }
}

// MARK: Bindings

private extension QuickSettingsStore {
    /// A value as text; choosing `default` writes it like any other value.
    func text(_ key: String, default fallback: String) -> Binding<String> {
        Binding(
            get: { self.value(key) ?? fallback },
            set: { self.set(key, $0.isEmpty ? nil : $0) })
    }

    func number(_ key: String, default fallback: Double) -> Binding<Double> {
        Binding(
            get: { self.value(key).flatMap(Double.init) ?? fallback },
            set: { value in
                let rounded = (value * 100).rounded() / 100
                self.set(key, rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded))
            })
    }

    func flag(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { self.value(key).map { $0 == "true" } ?? fallback },
            set: { self.set(key, $0 ? "true" : "false") })
    }

    /// A percentage such as `adjust-cell-height = 10%`; 0 removes it.
    func percent(_ key: String) -> Binding<Double> {
        Binding(
            get: {
                guard let value = self.value(key), value.hasSuffix("%") else { return 0 }
                return Double(value.dropLast()) ?? 0
            },
            set: { self.set(key, $0 == 0 ? nil : "\(Int($0))%") })
    }
}
