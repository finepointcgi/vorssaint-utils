// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// App routing and the mixer matrix, under the volume mixer's settings.
struct MixerMatrixSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var matrix = MixerMatrixService.shared
    @ObservedObject private var mixer = AppVolumeMixer.shared

    private var text: MixerMatrixStrings { FeatureStrings.mixerMatrix(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !MixerMatrixService.isSupported {
                SettingsCard(title: text.routingTitle) {
                    Text(text.problemNeedsMacOS).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                SettingsCard(title: text.routingTitle) { routing }
                SettingsCard(title: text.matrixTitle) { matrixContent }
            }
        }
        .onAppear {
            matrix.reconcile()
            matrix.beginWatchingMeters()
        }
        .onDisappear { matrix.endWatchingMeters() }
    }

    // MARK: - Routing

    private var playingApps: [MixerApp] {
        mixer.apps.filter { !$0.isBypassed && $0.persistenceID != nil }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    @ViewBuilder
    private var routing: some View {
        Text(text.routingCaption).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if mixer.needsPermission { permissionHint }
        ForEach(matrix.configuration.appRoutes.keys.sorted(), id: \.self) { bundleID in
            Divider()
            MixerRouteRow(bundleID: bundleID, text: text)
        }
        Menu(text.addApp) {
            ForEach(playingApps, id: \.id) { app in
                Button(app.name) {
                    guard let id = app.persistenceID else { return }
                    matrix.update { $0.appRoutes[id] = MixerAppRoute(name: app.name) }
                }
                .disabled(matrix.configuration.appRoutes[app.persistenceID ?? ""] != nil)
            }
        }
        .fixedSize()
    }

    private var permissionHint: some View {
        HStack {
            Label(text.permissionHint, systemImage: "waveform.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button(l10n.s.permissionOpenSettings) { Permissions.shared.openAudioCaptureSettings() }
            .controlSize(.small)
        }
    }

    // MARK: - Matrix

    @ViewBuilder
    private var matrixContent: some View {
        Toggle(text.matrixEnable, isOn: Binding(get: { matrix.configuration.enabled },
                                                set: { on in matrix.update { $0.enabled = on } }))
        Text(text.matrixCaption).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if matrix.configuration.enabled {
            status
            Text(text.sources).font(.headline).padding(.top, 6)
            ForEach(matrix.configuration.sources) { source in
                MixerStripRow(strip: .source(source.id), text: text)
            }
            addSourceMenu
            Text(text.outputs).font(.headline).padding(.top, 6)
            ForEach(matrix.configuration.outputs) { output in
                MixerStripRow(strip: .output(output.id), text: text)
            }
            addOutputMenu
            Text(text.sends).font(.headline).padding(.top, 6)
            MixerSendGrid(text: text)
        }
    }

    @ViewBuilder
    private var status: some View {
        let plan = matrix.plan
        HStack {
            if matrix.isRunning, let rate = plan.sampleRate, let clock = plan.clockName {
                Label(MixerMatrixText.fill(text.running, ["rate": MixerMatrixText.rate(rate), "name": clock]),
                      systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                Label(matrix.startFailed ? text.startFailed : text.notRunning, systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(text.resetClips) { matrix.resetClips() }
                .controlSize(.small)
        }
        .font(.caption)
        if (plan.sources + plan.outputs).contains(where: {
            if case .unavailable(.sampleRate) = $0.state { return true }
            return false
        }) {
            Button(text.openAudioMIDISetup) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            }
            .controlSize(.small)
        }
        if mixer.needsPermission, matrix.configuration.sources.contains(where: {
            if case .app = $0.kind { return true }
            return false
        }) { permissionHint }
    }

    private var addSourceMenu: some View {
        Menu(text.addSource) {
            Section(text.apps) {
                ForEach(playingApps, id: \.id) { app in
                    Button(app.name) {
                        guard let id = app.persistenceID else { return }
                        add(MixerMatrixSource(name: app.name, kind: .app(bundleID: id)))
                    }
                }
            }
            Section(text.inputs) {
                ForEach(matrix.inputDevices, id: \.uid) { device in
                    Button(device.name) {
                        add(MixerMatrixSource(name: device.name,
                                              kind: .input(MixerDeviceMatch(uid: device.uid, name: device.name)),
                                              mono: device.inputChannels == 1))
                    }
                }
            }
        }
        .fixedSize()
        .disabled(matrix.configuration.sources.count >= MixerMatrixConfiguration.maximumSources)
    }

    private func add(_ source: MixerMatrixSource) {
        matrix.update { configuration in
            configuration.sources.append(source)
            // The first output gets the new source, so it is heard at once.
            if let first = configuration.outputs.first {
                configuration.setSend(source.id, first.id, gainDB: 0)
            }
        }
    }

    private var addOutputMenu: some View {
        Menu(text.addOutput) {
            ForEach(matrix.outputDevices, id: \.uid) { device in
                Button(device.name) {
                    matrix.update { configuration in
                        let output = MixerMatrixOutput(name: device.name,
                                                       device: MixerDeviceMatch(uid: device.uid, name: device.name))
                        configuration.outputs.append(output)
                        if configuration.outputs.count == 1 {
                            for source in configuration.sources {
                                configuration.setSend(source.id, output.id, gainDB: 0)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(matrix.configuration.outputs.count >= MixerMatrixConfiguration.maximumOutputs)
    }
}

// MARK: - Text

enum MixerMatrixText {
    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    static func rate(_ rate: Double) -> String {
        rate.rounded() == rate ? String(Int(rate)) : String(format: "%.1f", locale: MetricFormat.locale, rate)
    }

    static func decibels(_ value: Float) -> String {
        value <= -60 ? "−∞ dB" : String(format: "%+.1f dB", locale: MetricFormat.locale, value).replacingOccurrences(of: "-", with: "−")
    }

    static func problem(_ problem: MixerStripProblem, _ text: MixerMatrixStrings) -> String {
        switch problem {
        case .noApp: return text.problemNoApp
        case .needsNewerMacOS: return text.problemNeedsMacOS
        case .needsPermission: return text.problemPermission
        case .appNotRunning: return text.problemNotRunning
        case .notConnected(let name): return fill(text.problemNotConnected, ["name": name])
        case .noOutputs(let name): return fill(text.problemNoOutputs, ["name": name])
        case .noInputs(let name): return fill(text.problemNoInputs, ["name": name])
        case .aggregate(let name): return fill(text.problemAggregate, ["name": name])
        case .tooFewChannels(let name, let count):
            return fill(text.problemChannels, ["name": name, "count": String(count)])
        case .sampleRate(let name, let rate, let mixerRate):
            return fill(text.problemSampleRate, ["name": name, "rate": self.rate(rate), "mixer": self.rate(mixerRate)])
        case .tooMany: return text.problemTooMany
        case .engineStopped: return text.problemStopped
        }
    }

    /// Nil while the strip plays.
    static func state(_ state: MixerStripState, _ text: MixerMatrixStrings) -> String? {
        switch state {
        case .off, .active: return nil
        case .waiting(let reason): return "\(text.waitingPrefix): \(problem(reason, text))"
        case .unavailable(let reason): return "\(text.unavailablePrefix): \(problem(reason, text))"
        }
    }
}

// MARK: - Route row

private struct MixerRouteRow: View {
    let bundleID: String
    let text: MixerMatrixStrings
    @ObservedObject private var matrix = MixerMatrixService.shared

    private var route: MixerAppRoute { matrix.configuration.appRoutes[bundleID] ?? MixerAppRoute() }

    private func edit(_ change: @escaping (inout MixerAppRoute) -> Void) {
        matrix.update { configuration in
            guard var route = configuration.appRoutes[bundleID] else { return }
            change(&route)
            configuration.appRoutes[bundleID] = route
        }
    }

    var body: some View {
        let status = matrix.plan.routes.first { $0.bundleID == bundleID }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { route.enabled }, set: { on in edit { $0.enabled = on } })) {
                    Text(route.name.isEmpty ? bundleID : route.name).font(.body.weight(.medium))
                }
                Spacer()
                Button(text.remove, role: .destructive) {
                    matrix.update { $0.appRoutes[bundleID] = nil }
                }
                .controlSize(.small)
            }
            LabeledContent(text.playsOn) {
                Menu(route.outputs.isEmpty ? "—" : route.outputs.map(\.name).joined(separator: ", ")) {
                    ForEach(matrix.outputDevices, id: \.uid) { device in
                        let match = MixerDeviceMatch(uid: device.uid, name: device.name)
                        let selected = route.outputs.contains { $0.uid == device.uid }
                        Button {
                            edit { route in
                                if selected { route.outputs.removeAll { $0.uid == device.uid } }
                                else { route.outputs.append(match) }
                            }
                        } label: {
                            if selected { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                        }
                    }
                }
                .fixedSize()
            }
            Toggle(text.keepDefault, isOn: Binding(get: { route.keepDefault }, set: { on in edit { $0.keepDefault = on } }))
            LabeledContent(text.level) {
                HStack {
                    Slider(value: Binding(get: { Double(route.gainDB) }, set: { value in edit { $0.gainDB = Float(value) } }),
                           in: -30...12)
                        .frame(maxWidth: 200)
                    Text(MixerMatrixText.decibels(route.gainDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            if let status {
                if status.state.isActive {
                    Label(text.routingNow, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                } else if let message = MixerMatrixText.state(status.state, text) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(zip(route.outputs, status.targetProblems).enumerated()), id: \.offset) { _, pair in
                    if let problem = pair.1, status.state.isActive {
                        Text("\(pair.0.name): \(MixerMatrixText.problem(problem, text))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Strips

enum MixerStripReference: Hashable {
    case source(String)
    case output(String)

    var id: String {
        switch self {
        case .source(let id), .output(let id): return id
        }
    }
}

private struct MixerStripRow: View {
    let strip: MixerStripReference
    let text: MixerMatrixStrings
    @ObservedObject private var matrix = MixerMatrixService.shared
    @State private var showsEffects = false

    private var source: MixerMatrixSource? {
        guard case .source(let id) = strip else { return nil }
        return matrix.configuration.sources.first { $0.id == id }
    }

    private var output: MixerMatrixOutput? {
        guard case .output(let id) = strip else { return nil }
        return matrix.configuration.outputs.first { $0.id == id }
    }

    private var status: MixerStripStatus? {
        switch strip {
        case .source(let id): return matrix.plan.sources.first { $0.id == id }
        case .output(let id): return matrix.plan.outputs.first { $0.id == id }
        }
    }

    private var gainDB: Float { source?.gainDB ?? output?.gainDB ?? 0 }
    private var muted: Bool { source?.muted ?? output?.muted ?? false }
    private var effects: MixerEffects { source?.effects ?? output?.effects ?? MixerEffects() }

    private func edit(source change: @escaping (inout MixerMatrixSource) -> Void = { _ in },
                      output outputChange: @escaping (inout MixerMatrixOutput) -> Void = { _ in }) {
        matrix.update { configuration in
            switch strip {
            case .source(let id):
                if let index = configuration.sources.firstIndex(where: { $0.id == id }) {
                    change(&configuration.sources[index])
                }
            case .output(let id):
                if let index = configuration.outputs.firstIndex(where: { $0.id == id }) {
                    outputChange(&configuration.outputs[index])
                }
            }
        }
    }

    private var name: String {
        if let status, !status.name.isEmpty { return status.name }
        return source?.name ?? output?.name ?? ""
    }

    private var symbol: String {
        if let source {
            if case .app = source.kind { return "app" }
            return "mic"
        }
        return "hifispeaker"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(name).lineLimit(1).frame(width: 130, alignment: .leading)
                Slider(value: Binding(get: { Double(gainDB) }, set: { value in
                    edit(source: { $0.gainDB = Float(value) }, output: { $0.gainDB = Float(value) })
                }), in: -60...12)
                .frame(minWidth: 120)
                .onTapGesture(count: 2) { edit(source: { $0.gainDB = 0 }, output: { $0.gainDB = 0 }) }
                Text(MixerMatrixText.decibels(gainDB)).monospacedDigit().font(.caption).frame(width: 58, alignment: .trailing)
                Toggle("M", isOn: Binding(get: { muted }, set: { on in
                    edit(source: { $0.muted = on }, output: { $0.muted = on })
                }))
                .toggleStyle(.button).help(text.mute)
                if let source {
                    Toggle("S", isOn: Binding(get: { source.solo }, set: { on in edit(source: { $0.solo = on }) }))
                        .toggleStyle(.button).help(text.solo)
                }
                Button(text.effects) { showsEffects = true }
                    .popover(isPresented: $showsEffects, arrowEdge: .trailing) {
                        MixerEffectsEditor(strip: strip, text: text)
                    }
                Button(role: .destructive) {
                    matrix.update { configuration in
                        switch strip {
                        case .source(let id): configuration.removeSource(id)
                        case .output(let id): configuration.removeOutput(id)
                        }
                    }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(text.remove)
            }
            MixerMeterBar(reading: matrix.meters[strip.id] ?? .silent, text: text)
                .frame(height: 6)
                .padding(.leading, 26)
            if let status, let message = MixerMatrixText.state(status.state, text) {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }
}

/// RMS as the bar, peak as a line, red once the strip clipped.
private struct MixerMeterBar: View {
    let reading: MixerMeterReading
    let text: MixerMatrixStrings

    private func position(_ level: Float) -> CGFloat {
        let db = MixerMatrixPlanner.decibels(level)
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * position(reading.rms))
                Rectangle().fill(reading.clipped ? Color.red : Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .offset(x: max(proxy.size.width * position(reading.peak) - 2, 0))
            }
        }
        // RMS, then peak; the limiter line only while it works.
        .help("\(MixerMatrixText.decibels(MixerMatrixPlanner.decibels(reading.rms))) / "
              + MixerMatrixText.decibels(MixerMatrixPlanner.decibels(reading.peak))
              + (reading.limiterReductionDB > 0.05
                  ? " · \(text.limiter) −\(MixerMatrixText.decibels(reading.limiterReductionDB).dropFirst())" : ""))
        .accessibilityHidden(true)
    }
}

// MARK: - Sends

private struct MixerSendGrid: View {
    let text: MixerMatrixStrings
    @ObservedObject private var matrix = MixerMatrixService.shared

    var body: some View {
        let configuration = matrix.configuration
        if configuration.sources.isEmpty || configuration.outputs.isEmpty {
            Text(text.noSends).font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        ForEach(configuration.outputs) { output in
                            Text(name(ofOutput: output)).font(.caption).lineLimit(1).frame(width: 96)
                        }
                    }
                    ForEach(configuration.sources) { source in
                        GridRow {
                            Text(name(ofSource: source)).font(.caption).lineLimit(1).frame(width: 120, alignment: .leading)
                            ForEach(configuration.outputs) { output in
                                MixerSendCell(source: source.id, output: output.id)
                                    .frame(width: 96)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func name(ofSource source: MixerMatrixSource) -> String {
        matrix.plan.sources.first { $0.id == source.id }?.name ?? source.name
    }

    private func name(ofOutput output: MixerMatrixOutput) -> String {
        output.name.isEmpty ? output.device.name : output.name
    }
}

/// A crosspoint: click to connect or disconnect, drag sideways to set the
/// level.
private struct MixerSendCell: View {
    let source: String
    let output: String
    @ObservedObject private var matrix = MixerMatrixService.shared
    @State private var dragStart: Float?

    var body: some View {
        let send = matrix.configuration.send(source, output)
        let connected = send != nil && send?.muted == false
        Text(send.map { MixerMatrixText.decibels($0.gainDB) } ?? "—")
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(connected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
            .onTapGesture {
                matrix.update { configuration in
                    if send == nil { configuration.setSend(source, output, gainDB: 0) }
                    else { configuration.removeSend(source, output) }
                }
            }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard let send else { return }
                let start = dragStart ?? send.gainDB
                if dragStart == nil { dragStart = start }
                let next = min(max(start + Float(value.translation.width / 4), -60), 12)
                matrix.update { $0.setSend(source, output, gainDB: (next * 2).rounded() / 2, muted: send.muted) }
            }.onEnded { _ in dragStart = nil })
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Effects

private struct MixerEffectsEditor: View {
    let strip: MixerStripReference
    let text: MixerMatrixStrings
    @ObservedObject private var matrix = MixerMatrixService.shared

    private var effects: MixerEffects {
        switch strip {
        case .source(let id): return matrix.configuration.sources.first { $0.id == id }?.effects ?? MixerEffects()
        case .output(let id): return matrix.configuration.outputs.first { $0.id == id }?.effects ?? MixerEffects()
        }
    }

    private func edit(_ change: @escaping (inout MixerEffects) -> Void) {
        matrix.update { configuration in
            switch strip {
            case .source(let id):
                if let index = configuration.sources.firstIndex(where: { $0.id == id }) {
                    change(&configuration.sources[index].effects)
                }
            case .output(let id):
                if let index = configuration.outputs.firstIndex(where: { $0.id == id }) {
                    change(&configuration.outputs[index].effects)
                }
            }
        }
    }

    private func floatBinding(_ get: @escaping (MixerEffects) -> Float,
                              _ set: @escaping (inout MixerEffects, Float) -> Void) -> Binding<Double> {
        Binding(get: { Double(get(effects)) }, set: { value in edit { set(&$0, Float(value)) } })
    }

    var body: some View {
        let effects = self.effects
        Form {
            if case .source(let id) = strip, let source = matrix.configuration.sources.first(where: { $0.id == id }) {
                sourceOptions(source)
            }
            LabeledContent(text.trim) {
                HStack {
                    Slider(value: floatBinding({ $0.trimDB }, { $0.trimDB = $1 }), in: -24...24).frame(width: 180)
                    Text(MixerMatrixText.decibels(effects.trimDB)).monospacedDigit().frame(width: 60)
                }
            }
            Section {
                Toggle(text.eq, isOn: Binding(get: { effects.eqEnabled }, set: { on in
                    edit { effects in
                        effects.eqEnabled = on
                        if on, effects.bands.isEmpty { effects.bands = MixerEffects.flatBands(5) }
                    }
                }))
                if effects.eqEnabled {
                    MixerEQCurve(bands: effects.bands)
                        .frame(height: 110)
                    ForEach(effects.bands) { band in
                        bandRow(band)
                    }
                    HStack {
                        Button(text.addBand) {
                            edit { $0.bands.append(MixerEQBand()) }
                        }
                        .disabled(effects.bands.count >= MixerEffects.maximumBands)
                        Button(text.flatEQ) { edit { $0.bands = MixerEffects.flatBands(max($0.bands.count, 3)) } }
                    }
                    .controlSize(.small)
                }
            }
            Section {
                Toggle(text.limiter, isOn: Binding(get: { effects.limiter.enabled },
                                                   set: { on in edit { $0.limiter.enabled = on } }))
                if effects.limiter.enabled {
                    labeledSlider(text.ceiling, floatBinding({ $0.limiter.ceilingDB }, { $0.limiter.ceilingDB = $1 }),
                                  -30...0, format: MixerMatrixText.decibels(effects.limiter.ceilingDB))
                    labeledSlider(text.release, floatBinding({ $0.limiter.releaseMS }, { $0.limiter.releaseMS = $1 }),
                                  5...1000, format: String(format: "%.0f ms", locale: MetricFormat.locale, effects.limiter.releaseMS))
                    labeledSlider(text.lookahead, floatBinding({ $0.limiter.lookaheadMS }, { $0.limiter.lookaheadMS = $1 }),
                                  0...Double(MixerLimiter.maximumLookaheadMS),
                                  format: String(format: "%.1f ms", locale: MetricFormat.locale, effects.limiter.lookaheadMS))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 260, maxHeight: 640)
    }

    @ViewBuilder
    private func sourceOptions(_ source: MixerMatrixSource) -> some View {
        let edit: (@escaping (inout MixerMatrixSource) -> Void) -> Void = { change in
            matrix.update { configuration in
                if let index = configuration.sources.firstIndex(where: { $0.id == source.id }) {
                    change(&configuration.sources[index])
                }
            }
        }
        switch source.kind {
        case .app:
            Toggle(text.keepOriginal, isOn: Binding(get: { source.keepOriginal }, set: { on in edit { $0.keepOriginal = on } }))
        case .input:
            Stepper("\(text.firstChannel): \(source.firstChannel + 1)",
                    value: Binding(get: { source.firstChannel }, set: { value in edit { $0.firstChannel = max(value, 0) } }),
                    in: 0...63)
            Toggle(text.mono, isOn: Binding(get: { source.mono }, set: { on in edit { $0.mono = on } }))
        }
    }

    private func labeledSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                               format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 180)
                Text(format).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
        }
    }

    private func bandName(_ kind: MixerEQBandKind) -> String {
        switch kind {
        case .peak: return text.bandPeak
        case .lowShelf: return text.bandLowShelf
        case .highShelf: return text.bandHighShelf
        case .lowPass: return text.bandLowPass
        case .highPass: return text.bandHighPass
        case .notch: return text.bandNotch
        }
    }

    private func bandRow(_ band: MixerEQBand) -> some View {
        let update: (@escaping (inout MixerEQBand) -> Void) -> Void = { change in
            edit { effects in
                if let index = effects.bands.firstIndex(where: { $0.id == band.id }) { change(&effects.bands[index]) }
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(get: { band.enabled }, set: { on in update { $0.enabled = on } }))
                    .labelsHidden()
                Picker("", selection: Binding(get: { band.kind }, set: { kind in update { $0.kind = kind } })) {
                    ForEach(MixerEQBandKind.allCases) { Text(bandName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Spacer()
                Button { edit { $0.bands.removeAll { $0.id == band.id } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            HStack {
                Text(text.frequency).font(.caption)
                // Logarithmic, 20 Hz to 20 kHz.
                Slider(value: Binding(get: { log10(Double(band.frequency)) },
                                      set: { value in update { $0.frequency = Float(pow(10, value)) } }),
                       in: log10(20.0)...log10(20_000.0))
                Text(band.frequency >= 1000 ? String(format: "%.1f kHz", locale: MetricFormat.locale, band.frequency / 1000)
                                            : String(format: "%.0f Hz", locale: MetricFormat.locale, band.frequency))
                    .font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
            }
            HStack {
                if band.kind.usesGain {
                    Text(text.gain).font(.caption)
                    Slider(value: Binding(get: { Double(band.gainDB) }, set: { value in update { $0.gainDB = Float(value) } }),
                           in: -18...18)
                    Text(MixerMatrixText.decibels(band.gainDB)).font(.caption.monospacedDigit()).frame(width: 62)
                }
                Text(text.q).font(.caption)
                Slider(value: Binding(get: { Double(band.q) }, set: { value in update { $0.q = Float(value) } }), in: 0.1...10)
                    .frame(width: 90)
                Text(String(format: "%.2f", locale: MetricFormat.locale, band.q)).font(.caption.monospacedDigit()).frame(width: 34)
            }
        }
        .opacity(band.enabled ? 1 : 0.5)
    }
}

/// The summed response of the enabled bands, 20 Hz to 20 kHz, ±18 dB.
private struct MixerEQCurve: View {
    let bands: [MixerEQBand]

    var body: some View {
        Canvas { context, size in
            let rate = 48_000.0
            let coefficients = bands.filter(\.enabled).map { MixerBiquadCoefficients.design($0, sampleRate: rate) }
            let zero = size.height / 2
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: zero))
            grid.addLine(to: CGPoint(x: size.width, y: zero))
            context.stroke(grid, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            var curve = Path()
            let steps = max(Int(size.width / 2), 2)
            for step in 0...steps {
                let position = Double(step) / Double(steps)
                let frequency = 20 * pow(1000, position)
                let db = coefficients.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: rate) }
                let y = zero - CGFloat(min(max(db, -18), 18) / 18) * zero
                let point = CGPoint(x: CGFloat(position) * size.width, y: y)
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        .accessibilityHidden(true)
    }
}
