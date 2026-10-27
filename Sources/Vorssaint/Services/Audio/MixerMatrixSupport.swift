// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// App routing and the mixer matrix, the parts that need no audio device:
/// the saved configuration, the planner that turns it and what is connected
/// into one topology, and the signal processing the IO callback runs.
///
/// Routes and the matrix compile into ONE topology: a process tap per app
/// (muting the app's own output when it should only be heard through the
/// mix) and one private aggregate device whose clock is the first output,
/// every other device joining it drift-compensated. One IO callback mixes
/// every source into every output, so nothing here buffers across clocks.

// MARK: - Configuration

/// A device as the configuration names it: by UID, falling back to the name
/// when the UID changed (some USB devices pick a new one per port).
struct MixerDeviceMatch: Codable, Hashable {
    var uid: String
    var name: String
}

/// One app sent to other outputs, keyed by bundle id.
struct MixerAppRoute: Codable, Equatable {
    var enabled = true
    var name = ""
    var outputs: [MixerDeviceMatch] = []
    /// Keep playing on the app's own output too. Off: it is heard only on
    /// `outputs`.
    var keepDefault = false
    var gainDB: Float = 0

    init(enabled: Bool = true, name: String = "", outputs: [MixerDeviceMatch] = [],
         keepDefault: Bool = false, gainDB: Float = 0) {
        self.enabled = enabled
        self.name = name
        self.outputs = outputs
        self.keepDefault = keepDefault
        self.gainDB = gainDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        outputs = try c.decodeIfPresent([MixerDeviceMatch].self, forKey: .outputs) ?? []
        keepDefault = try c.decodeIfPresent(Bool.self, forKey: .keepDefault) ?? false
        gainDB = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
    }
}

enum MixerEQBandKind: String, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch
    var id: String { rawValue }
    var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

struct MixerEQBand: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var kind: MixerEQBandKind = .peak
    var frequency: Float = 1000
    var gainDB: Float = 0
    var q: Float = 0.707
}

struct MixerLimiterSettings: Codable, Equatable {
    var enabled = false
    /// dBFS, −60…0.
    var ceilingDB: Float = -1
    var releaseMS: Float = 100
    /// 0…20 ms, which the strip is delayed by.
    var lookaheadMS: Float = 5
}

/// Inserts on a strip, in order: trim, EQ, then the limiter.
struct MixerEffects: Codable, Equatable {
    static let maximumBands = 10

    var trimDB: Float = 0
    var eqEnabled = false
    var bands: [MixerEQBand] = []
    var limiter = MixerLimiterSettings()

    /// `count` flat bands from 60 Hz to 12 kHz: a low shelf, bells and a
    /// high shelf.
    static func flatBands(_ count: Int) -> [MixerEQBand] {
        let count = min(max(count, 3), maximumBands)
        return (0..<count).map { index in
            let position = Float(index) / Float(count - 1)
            let kind: MixerEQBandKind = index == 0 ? .lowShelf : index == count - 1 ? .highShelf : .peak
            return MixerEQBand(kind: kind, frequency: 60 * powf(12_000 / 60, position), gainDB: 0,
                               q: kind == .peak ? 1 : 0.707)
        }
    }
}

enum MixerSourceKind: Codable, Equatable {
    /// An app's audio, through a process tap.
    case app(bundleID: String)
    /// A microphone, an interface, or what plays into a virtual device such
    /// as BlackHole, read from its input side.
    case input(MixerDeviceMatch)
}

struct MixerMatrixSource: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var kind: MixerSourceKind
    var gainDB: Float = 0
    var muted = false
    /// While any source is soloed, only soloed sources are heard.
    var solo = false
    /// Apps: keep the app on its own output as well.
    var keepOriginal = false
    /// Devices: the first channel of the stereo pair read.
    var firstChannel = 0
    /// Devices: read one channel and feed it to both sides.
    var mono = false
    var effects = MixerEffects()
}

struct MixerMatrixOutput: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var device: MixerDeviceMatch
    var gainDB: Float = 0
    var muted = false
    /// The first device channel of the stereo pair written.
    var firstChannel = 0
    var effects = MixerEffects()
}

/// A crosspoint. A source and an output without one are not connected.
struct MixerMatrixSend: Codable, Equatable {
    var source: String
    var output: String
    var gainDB: Float = 0
    var muted = false
}

struct MixerMatrixConfiguration: Codable, Equatable {
    static let maximumSources = 32
    static let maximumOutputs = 16

    var enabled = false
    var sources: [MixerMatrixSource] = []
    var outputs: [MixerMatrixOutput] = []
    var sends: [MixerMatrixSend] = []
    var appRoutes: [String: MixerAppRoute] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sources = (try? c.decodeIfPresent([MixerMatrixSource].self, forKey: .sources)) ?? []
        outputs = (try? c.decodeIfPresent([MixerMatrixOutput].self, forKey: .outputs)) ?? []
        sends = (try? c.decodeIfPresent([MixerMatrixSend].self, forKey: .sends)) ?? []
        appRoutes = (try? c.decodeIfPresent([String: MixerAppRoute].self, forKey: .appRoutes)) ?? [:]
    }

    /// Whether anything asks for the engine at all.
    var wantsEngine: Bool {
        (enabled && !sources.isEmpty && !outputs.isEmpty) || appRoutes.values.contains { $0.enabled && !$0.outputs.isEmpty }
    }

    func send(_ source: String, _ output: String) -> MixerMatrixSend? {
        sends.first { $0.source == source && $0.output == output }
    }

    mutating func setSend(_ source: String, _ output: String, gainDB: Float, muted: Bool = false) {
        if let index = sends.firstIndex(where: { $0.source == source && $0.output == output }) {
            sends[index].gainDB = gainDB
            sends[index].muted = muted
        } else {
            sends.append(MixerMatrixSend(source: source, output: output, gainDB: gainDB, muted: muted))
        }
    }

    mutating func removeSend(_ source: String, _ output: String) {
        sends.removeAll { $0.source == source && $0.output == output }
    }

    mutating func removeSource(_ id: String) {
        sources.removeAll { $0.id == id }
        sends.removeAll { $0.source == id }
    }

    mutating func removeOutput(_ id: String) {
        outputs.removeAll { $0.id == id }
        sends.removeAll { $0.output == id }
    }

    static func decode(_ data: Data?) -> MixerMatrixConfiguration {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }
}

// MARK: - What exists right now

struct MixerInventoryDevice: Equatable {
    var uid: String
    var name: String
    /// Channels of each input stream, in stream order.
    var inputStreams: [Int]
    var outputStreams: [Int]
    var sampleRate: Double
    var isAggregate = false

    var inputChannels: Int { inputStreams.reduce(0, +) }
    var outputChannels: Int { outputStreams.reduce(0, +) }
}

struct MixerInventoryApp: Equatable {
    var bundleID: String
    var name: String
    var objects: [UInt32]
    /// The volume mixer's level for the app, 0…2, so its slider keeps
    /// working for an app the matrix took over.
    var volume: Double = 1
}

struct MixerInventory: Equatable {
    var devices: [MixerInventoryDevice] = []
    var apps: [MixerInventoryApp] = []
    var tapsSupported = false
    var captureDenied = false

    func device(_ match: MixerDeviceMatch) -> MixerInventoryDevice? {
        devices.first { !match.uid.isEmpty && $0.uid == match.uid }
            ?? devices.first { !match.name.isEmpty && $0.name == match.name }
    }

    func app(_ bundleID: String) -> MixerInventoryApp? {
        apps.first { $0.bundleID == bundleID && !$0.objects.isEmpty }
    }
}

// MARK: - Plan

enum MixerStripProblem: Equatable {
    case noApp
    case needsNewerMacOS
    case needsPermission
    case appNotRunning
    case notConnected(String)
    case noOutputs(String)
    case noInputs(String)
    case aggregate(String)
    case tooFewChannels(String, Int)
    case sampleRate(device: String, rate: Double, mixerRate: Double)
    case tooMany
    case engineStopped
}

enum MixerStripState: Equatable {
    case off
    case active
    case waiting(MixerStripProblem)
    case unavailable(MixerStripProblem)

    var isActive: Bool { self == .active }
}

struct MixerMatrixTopology: Equatable {
    struct SubDevice: Equatable {
        var uid: String
        var readsInput: Bool
        var writesOutput: Bool
    }

    struct Tap: Equatable {
        var bundleID: String
        /// Sorted and without repeats.
        var objects: [UInt32]
        /// The app is heard only through the mix while the tap exists.
        var mutesOriginal: Bool
    }

    enum Input: Equatable {
        case tap(Int)
        case device(uid: String, firstChannel: Int, mono: Bool)
    }

    struct Source: Equatable {
        var key: String
        var input: Input
    }

    struct Output: Equatable {
        var key: String
        var uid: String
        var firstChannel: Int
    }

    /// Clock and main sub-device; also the first of `subDevices`.
    var clockUID: String
    var sampleRate: Double
    var subDevices: [SubDevice]
    var taps: [Tap]
    var sources: [Source]
    var outputs: [Output]
}

/// What the audio thread is told about one strip.
struct MixerStripValues: Equatable {
    /// The fader, with mute, solo and the app's own level folded in.
    var gain: Float = 1
    var trim: Float = 1
    var eq: [MixerBiquadCoefficients] = []
    var limiter = MixerLimiterSettings()
}

struct MixerMatrixValues: Equatable {
    var sources: [MixerStripValues] = []
    var outputs: [MixerStripValues] = []
    /// Row-major, sources × outputs; 0 where nothing is connected.
    var sends: [Float] = []
}

struct MixerStripStatus: Equatable, Identifiable {
    var id: String
    var name: String
    var state: MixerStripState
    var deviceName: String?
}

struct MixerRouteStatus: Equatable, Identifiable {
    var id: String { bundleID }
    var bundleID: String
    var state: MixerStripState
    /// Per target, in configuration order: nil when it plays there.
    var targetProblems: [MixerStripProblem?]
}

struct MixerMatrixPlan: Equatable {
    var topology: MixerMatrixTopology?
    var values = MixerMatrixValues()
    var sources: [MixerStripStatus] = []
    var outputs: [MixerStripStatus] = []
    var routes: [MixerRouteStatus] = []
    /// Bundle ids whose own output the running engine mutes. The volume
    /// mixer leaves these apps to the matrix instead of tapping them again.
    var exclusiveApps: Set<String> = []
    var clockName: String?
    var sampleRate: Double?
}

enum MixerMatrixPlanner {
    static let routeSourcePrefix = "route:"
    static let routeOutputPrefix = "route-out:"

    static func gain(dB: Float) -> Float {
        dB <= -96 ? 0 : powf(10, dB / 20)
    }

    static func decibels(_ gain: Float) -> Float {
        gain <= 0.000_016 ? -96 : 20 * log10f(gain)
    }

    static func stripValues(_ effects: MixerEffects, gain: Float, sampleRate: Double) -> MixerStripValues {
        var eq: [MixerBiquadCoefficients] = []
        if effects.eqEnabled {
            for band in effects.bands.prefix(MixerEffects.maximumBands) where band.enabled {
                let coefficients = MixerBiquadCoefficients.design(band, sampleRate: sampleRate)
                if !coefficients.isIdentity { eq.append(coefficients) }
            }
        }
        var limiter = effects.limiter
        limiter.ceilingDB = min(max(limiter.ceilingDB, -60), 0)
        limiter.releaseMS = min(max(limiter.releaseMS, 1), 2000)
        limiter.lookaheadMS = min(max(limiter.lookaheadMS, 0), MixerLimiter.maximumLookaheadMS)
        return MixerStripValues(gain: gain, trim: Self.gain(dB: effects.trimDB), eq: eq, limiter: limiter)
    }

    private static func outputProblem(_ device: MixerInventoryDevice, firstChannel: Int) -> MixerStripProblem? {
        if device.outputChannels == 0 { return .noOutputs(device.name) }
        if device.isAggregate { return .aggregate(device.name) }
        if firstChannel >= device.outputChannels { return .tooFewChannels(device.name, device.outputChannels) }
        return nil
    }

    private static func inputProblem(_ device: MixerInventoryDevice, firstChannel: Int) -> MixerStripProblem? {
        if device.inputChannels == 0 { return .noInputs(device.name) }
        if device.isAggregate { return .aggregate(device.name) }
        if firstChannel >= device.inputChannels { return .tooFewChannels(device.name, device.inputChannels) }
        return nil
    }

    private static func rateProblem(_ device: MixerInventoryDevice, rate: Double) -> MixerStripProblem? {
        device.sampleRate > 0 && abs(device.sampleRate - rate) > 0.5
            ? .sampleRate(device: device.name, rate: device.sampleRate, mixerRate: rate) : nil
    }

    private static func appProblem(_ inventory: MixerInventory, _ bundleID: String) -> MixerStripState? {
        if bundleID.isEmpty { return .unavailable(.noApp) }
        if !inventory.tapsSupported { return .unavailable(.needsNewerMacOS) }
        if inventory.captureDenied { return .unavailable(.needsPermission) }
        if inventory.app(bundleID) == nil { return .waiting(.appNotRunning) }
        return nil
    }

    static func plan(_ configuration: MixerMatrixConfiguration, inventory: MixerInventory) -> MixerMatrixPlan {
        var plan = MixerMatrixPlan()
        let matrixOn = configuration.enabled

        // Outputs the matrix and the routes play on.
        struct Candidate {
            var key: String
            var device: MixerInventoryDevice
            var firstChannel: Int
            var gain: Float
            var effects: MixerEffects?
            /// Index into `plan.outputs`, nil for a route's own output.
            var status: Int?
        }
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for (index, output) in configuration.outputs.enumerated() {
            let device = inventory.device(output.device)
            var status = MixerStripStatus(id: output.id, name: output.name.isEmpty ? (device?.name ?? output.device.name)
                                                                                   : output.name,
                                          state: .off, deviceName: device?.name)
            if !matrixOn {
                status.state = .off
            } else if index >= MixerMatrixConfiguration.maximumOutputs || !seen.insert(output.id).inserted {
                status.state = .unavailable(.tooMany)
            } else if let device {
                if let problem = outputProblem(device, firstChannel: output.firstChannel) {
                    status.state = .unavailable(problem)
                } else {
                    status.state = .active
                    candidates.append(Candidate(key: output.id, device: device, firstChannel: output.firstChannel,
                                                gain: output.muted ? 0 : gain(dB: output.gainDB),
                                                effects: output.effects, status: plan.outputs.count))
                }
            } else {
                status.state = .waiting(.notConnected(output.device.name.isEmpty ? output.device.uid
                                                                                  : output.device.name))
            }
            plan.outputs.append(status)
        }

        let routes = configuration.appRoutes.sorted { $0.key < $1.key }
        var routeTargets: [[MixerInventoryDevice?]] = []
        for (bundleID, route) in routes {
            var status = MixerRouteStatus(bundleID: bundleID, state: .off, targetProblems: [])
            let appState = appProblem(inventory, bundleID)
            var devices: [MixerInventoryDevice?] = []
            for target in route.outputs {
                let device = inventory.device(target)
                let problem = device.map { outputProblem($0, firstChannel: 0) }
                    ?? .notConnected(target.name.isEmpty ? target.uid : target.name)
                status.targetProblems.append(problem)
                devices.append(route.enabled && appState == nil && problem == nil ? device : nil)
            }
            if !route.enabled || route.outputs.isEmpty {
                status.state = .off
            } else if let appState {
                status.state = appState
            } else if devices.allSatisfy({ $0 == nil }) {
                status.state = .waiting(status.targetProblems.compactMap { $0 }.first ?? .noApp)
            } else {
                status.state = .active
            }
            routeTargets.append(devices)
            plan.routes.append(status)
        }
        for device in routeTargets.joined().compactMap({ $0 }) {
            let key = routeOutputPrefix + device.uid
            guard !candidates.contains(where: { $0.key == key }) else { continue }
            candidates.append(Candidate(key: key, device: device, firstChannel: 0, gain: 1, effects: nil, status: nil))
        }

        guard let clock = candidates.first?.device else {
            markSourcesWithoutEngine(configuration, inventory: inventory, matrixOn: matrixOn, plan: &plan)
            return plan
        }
        let rate = clock.sampleRate > 0 ? clock.sampleRate : 48_000
        plan.clockName = clock.name
        plan.sampleRate = rate

        var subDevices: [MixerMatrixTopology.SubDevice] = []
        func addSubDevice(_ uid: String, input: Bool, output: Bool) {
            if let index = subDevices.firstIndex(where: { $0.uid == uid }) {
                subDevices[index].readsInput = subDevices[index].readsInput || input
                subDevices[index].writesOutput = subDevices[index].writesOutput || output
            } else {
                subDevices.append(.init(uid: uid, readsInput: input, writesOutput: output))
            }
        }
        var outputs: [(MixerMatrixTopology.Output, MixerStripValues)] = []
        var deadRouteOutputs = Set<String>()
        for candidate in candidates {
            if let problem = rateProblem(candidate.device, rate: rate) {
                if let status = candidate.status {
                    plan.outputs[status].state = .unavailable(problem)
                } else {
                    deadRouteOutputs.insert(candidate.device.uid)
                }
                continue
            }
            addSubDevice(candidate.device.uid, input: false, output: true)
            let values = candidate.effects.map { stripValues($0, gain: candidate.gain, sampleRate: rate) }
                ?? MixerStripValues(gain: candidate.gain)
            outputs.append((.init(key: candidate.key, uid: candidate.device.uid, firstChannel: candidate.firstChannel),
                            values))
        }

        var taps: [MixerMatrixTopology.Tap] = []
        func tap(_ bundleID: String, mutesOriginal: Bool) -> Int {
            if let index = taps.firstIndex(where: { $0.bundleID == bundleID }) {
                taps[index].mutesOriginal = taps[index].mutesOriginal || mutesOriginal
                return index
            }
            let objects = Array(Set(inventory.app(bundleID)?.objects ?? [])).sorted()
            taps.append(.init(bundleID: bundleID, objects: objects, mutesOriginal: mutesOriginal))
            return taps.count - 1
        }

        var sources: [(MixerMatrixTopology.Source, MixerStripValues)] = []
        var sendList: [(source: Int, output: Int, gain: Float)] = []
        let anySolo = matrixOn && configuration.sources.contains { $0.solo }
        seen.removeAll()
        for (index, source) in configuration.sources.enumerated() {
            var status = MixerStripStatus(id: source.id, name: source.name, state: .off, deviceName: nil)
            var input: MixerMatrixTopology.Input?
            var level: Float = 1
            if !matrixOn {
                status.state = .off
            } else if index >= MixerMatrixConfiguration.maximumSources || !seen.insert(source.id).inserted {
                status.state = .unavailable(.tooMany)
            } else {
                switch source.kind {
                case .app(let bundleID):
                    if status.name.isEmpty { status.name = inventory.app(bundleID)?.name ?? bundleID }
                    if let problem = appProblem(inventory, bundleID) {
                        status.state = problem
                    } else {
                        input = .tap(tap(bundleID, mutesOriginal: !source.keepOriginal))
                        level = Float(min(max(inventory.app(bundleID)?.volume ?? 1, 0), 2))
                        status.state = .active
                    }
                case .input(let match):
                    guard let device = inventory.device(match) else {
                        status.state = .waiting(.notConnected(match.name.isEmpty ? match.uid : match.name))
                        break
                    }
                    if status.name.isEmpty { status.name = device.name }
                    status.deviceName = device.name
                    if let problem = inputProblem(device, firstChannel: source.firstChannel)
                        ?? rateProblem(device, rate: rate) {
                        status.state = .unavailable(problem)
                    } else {
                        addSubDevice(device.uid, input: true, output: false)
                        input = .device(uid: device.uid, firstChannel: source.firstChannel,
                                        mono: source.mono || device.inputChannels - source.firstChannel < 2)
                        status.state = .active
                    }
                }
            }
            plan.sources.append(status)
            guard let input else { continue }
            let fader: Float = source.muted || (anySolo && !source.solo) ? 0 : gain(dB: source.gainDB) * level
            let sourceIndex = sources.count
            sources.append((.init(key: source.id, input: input),
                            stripValues(source.effects, gain: fader, sampleRate: rate)))
            for send in configuration.sends where send.source == source.id && !send.muted {
                guard let outputIndex = outputs.firstIndex(where: { $0.0.key == send.output }) else { continue }
                sendList.append((sourceIndex, outputIndex, gain(dB: send.gainDB)))
            }
        }

        // Routes: their own source, sent at unity to each target output.
        for ((bundleID, route), devices) in zip(routes, routeTargets) {
            let live = devices.compactMap { $0 }.filter { !deadRouteOutputs.contains($0.uid) }
            guard !live.isEmpty, let app = inventory.app(bundleID) else {
                if let index = plan.routes.firstIndex(where: { $0.bundleID == bundleID }),
                   plan.routes[index].state == .active, !devices.compactMap({ $0 }).isEmpty {
                    plan.routes[index].state = .unavailable(.sampleRate(device: devices.compactMap { $0 }[0].name,
                                                                        rate: devices.compactMap { $0 }[0].sampleRate,
                                                                        mixerRate: rate))
                }
                continue
            }
            let sourceIndex = sources.count
            let gain = gain(dB: route.gainDB) * Float(min(max(app.volume, 0), 2))
            sources.append((.init(key: routeSourcePrefix + bundleID,
                                  input: .tap(tap(bundleID, mutesOriginal: !route.keepDefault))),
                            MixerStripValues(gain: gain)))
            for device in live {
                guard let outputIndex = outputs.firstIndex(where: { $0.0.key == routeOutputPrefix + device.uid })
                        ?? outputs.firstIndex(where: { $0.0.uid == device.uid }) else { continue }
                sendList.append((sourceIndex, outputIndex, 1))
            }
        }

        guard !outputs.isEmpty, !sources.isEmpty, let clockSub = subDevices.first(where: { $0.writesOutput }) else {
            markSourcesWithoutEngine(configuration, inventory: inventory, matrixOn: matrixOn, plan: &plan)
            return plan
        }
        // The clock leads the list.
        subDevices.removeAll { $0.uid == clockSub.uid }
        subDevices.insert(clockSub, at: 0)
        plan.clockName = inventory.devices.first { $0.uid == clockSub.uid }?.name ?? plan.clockName

        var sends = [Float](repeating: 0, count: sources.count * outputs.count)
        for send in sendList { sends[send.source * outputs.count + send.output] += send.gain }
        plan.topology = MixerMatrixTopology(clockUID: clockSub.uid, sampleRate: rate, subDevices: subDevices,
                                            taps: taps, sources: sources.map(\.0), outputs: outputs.map(\.0))
        plan.values = MixerMatrixValues(sources: sources.map(\.1), outputs: outputs.map(\.1), sends: sends)
        plan.exclusiveApps = Set(taps.filter(\.mutesOriginal).map(\.bundleID))
        return plan
    }

    /// Without outputs there is nothing to run, and sources say so.
    private static func markSourcesWithoutEngine(_ configuration: MixerMatrixConfiguration, inventory: MixerInventory,
                                                 matrixOn: Bool, plan: inout MixerMatrixPlan) {
        if plan.sources.isEmpty {
            plan.sources = configuration.sources.map { source in
                var name = source.name
                if name.isEmpty {
                    switch source.kind {
                    case .app(let bundleID): name = inventory.app(bundleID)?.name ?? bundleID
                    case .input(let match): name = inventory.device(match)?.name ?? match.name
                    }
                }
                return MixerStripStatus(id: source.id, name: name, state: matrixOn ? .waiting(.engineStopped) : .off,
                                        deviceName: nil)
            }
        } else {
            for index in plan.sources.indices where plan.sources[index].state.isActive {
                plan.sources[index].state = .waiting(.engineStopped)
            }
        }
        plan.topology = nil
    }
}

// MARK: - Stream layout

/// One channel of an aggregate stream: which buffer of the callback's list,
/// and which interleaved channel inside it.
struct MixerChannel: Equatable {
    var stream: Int
    var channel: Int
}

/// Where each strip reads and writes. A missing right channel is mono: a
/// source copies left to both sides, an output writes the average to left.
struct MixerMatrixLayout: Equatable {
    var sources: [(left: MixerChannel, right: MixerChannel?)]
    var outputs: [(left: MixerChannel, right: MixerChannel?)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sources.map { [$0.left, $0.right] } == rhs.sources.map { [$0.left, $0.right] }
            && lhs.outputs.map { [$0.left, $0.right] } == rhs.outputs.map { [$0.left, $0.right] }
    }
}

/// The aggregate as the HAL actually built it: sub-devices in their real
/// order with their stream layouts, and the tap streams after every
/// sub-device's inputs.
struct MixerRealizedAggregate: Equatable {
    struct SubDevice: Equatable {
        var uid: String
        var inputStreams: [Int]
        var outputStreams: [Int]
    }

    var subDevices: [SubDevice]
    var tapChannels: [Int]

    var inputStreams: [Int] { subDevices.flatMap(\.inputStreams) + tapChannels }
    var outputStreams: [Int] { subDevices.flatMap(\.outputStreams) }

    static func locate(channel: Int, in streams: [Int], startingAt base: Int) -> MixerChannel? {
        var remaining = channel
        for (offset, count) in streams.enumerated() {
            if remaining < count { return MixerChannel(stream: base + offset, channel: remaining) }
            remaining -= count
        }
        return nil
    }

    /// Maps the topology's strips onto real streams, nil when a strip has
    /// nowhere to read or write.
    func layout(for topology: MixerMatrixTopology) -> MixerMatrixLayout? {
        var inputBase: [String: Int] = [:], outputBase: [String: Int] = [:]
        var inputOffset = 0, outputOffset = 0
        for device in subDevices {
            inputBase[device.uid] = inputOffset
            outputBase[device.uid] = outputOffset
            inputOffset += device.inputStreams.count
            outputOffset += device.outputStreams.count
        }
        var sources: [(MixerChannel, MixerChannel?)] = []
        for source in topology.sources {
            switch source.input {
            case .tap(let index):
                guard tapChannels.indices.contains(index), tapChannels[index] > 0 else { return nil }
                let stream = inputOffset + index
                sources.append((MixerChannel(stream: stream, channel: 0),
                                tapChannels[index] > 1 ? MixerChannel(stream: stream, channel: 1) : nil))
            case .device(let uid, let first, let mono):
                guard let device = subDevices.first(where: { $0.uid == uid }), let base = inputBase[uid],
                      let left = Self.locate(channel: first, in: device.inputStreams, startingAt: base)
                else { return nil }
                let right = mono ? nil : Self.locate(channel: first + 1, in: device.inputStreams, startingAt: base)
                sources.append((left, right))
            }
        }
        var outputs: [(MixerChannel, MixerChannel?)] = []
        for output in topology.outputs {
            guard let device = subDevices.first(where: { $0.uid == output.uid }), let base = outputBase[output.uid],
                  let left = Self.locate(channel: output.firstChannel, in: device.outputStreams, startingAt: base)
            else { return nil }
            outputs.append((left, Self.locate(channel: output.firstChannel + 1, in: device.outputStreams,
                                              startingAt: base)))
        }
        return MixerMatrixLayout(sources: sources, outputs: outputs)
    }
}

// MARK: - Signal processing

/// RBJ cookbook biquad coefficients, normalised by a0.
struct MixerBiquadCoefficients: Equatable {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    static func design(_ band: MixerEQBand, sampleRate: Double) -> MixerBiquadCoefficients {
        let nyquist = sampleRate / 2
        let frequency = min(max(Double(band.frequency), 10), nyquist * 0.98)
        let q = min(max(Double(band.q), 0.05), 40)
        let gain = Double(band.gainDB)
        if band.kind.usesGain, abs(gain) < 0.01 { return MixerBiquadCoefficients() }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w0), alpha = sin(w0) / (2 * q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosine; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosine; a2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let root = 2 * a.squareRoot() * alpha
            let sign: Double = band.kind == .lowShelf ? 1 : -1
            b0 = a * ((a + 1) - sign * (a - 1) * cosine + root)
            b1 = sign * 2 * a * ((a - 1) - sign * (a + 1) * cosine)
            b2 = a * ((a + 1) - sign * (a - 1) * cosine - root)
            a0 = (a + 1) + sign * (a - 1) * cosine + root
            a1 = -sign * 2 * ((a - 1) + sign * (a + 1) * cosine)
            a2 = (a + 1) + sign * (a - 1) * cosine - root
        case .lowPass:
            b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = (1 - cosine) / 2
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = (1 + cosine) / 2
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosine; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        }
        return MixerBiquadCoefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                                       a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// Magnitude in dB at `frequency`, for drawing the response curve.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2
        let ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2
        let di = -(Double(a1) * s1 + Double(a2) * s2)
        let magnitude = ((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)).squareRoot()
        return 20 * log10(max(magnitude, 1e-9))
    }
}

/// A stereo cascade of up to ten biquads, direct form II transposed. Its
/// storage is fixed at creation; `set` only copies coefficients in.
final class MixerEqualizer {
    private var coefficients = [MixerBiquadCoefficients](repeating: .init(), count: MixerEffects.maximumBands)
    private var state = [Float](repeating: 0, count: MixerEffects.maximumBands * 4)
    private(set) var count = 0

    func set(_ next: [MixerBiquadCoefficients]) {
        let previous = count
        count = min(next.count, MixerEffects.maximumBands)
        for index in 0..<count { coefficients[index] = next[index] }
        // A changed band count changes what each stage filters.
        if previous != count { reset() }
    }

    func reset() {
        for index in state.indices { state[index] = 0 }
    }

    /// `left` and `right` hold `frames` samples each.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard count > 0 else { return }
        state.withUnsafeMutableBufferPointer { z in
            coefficients.withUnsafeBufferPointer { bands in
                for stage in 0..<count {
                    let c = bands[stage]
                    let base = stage * 4
                    var l1 = z[base], l2 = z[base + 1], r1 = z[base + 2], r2 = z[base + 3]
                    for frame in 0..<frames {
                        let l = left[frame]
                        let lo = c.b0 * l + l1
                        l1 = c.b1 * l - c.a1 * lo + l2
                        l2 = c.b2 * l - c.a2 * lo
                        left[frame] = lo
                        let r = right[frame]
                        let ro = c.b0 * r + r1
                        r1 = c.b1 * r - c.a1 * ro + r2
                        r2 = c.b2 * r - c.a2 * ro
                        right[frame] = ro
                    }
                    // Denormals and a blown-up state would otherwise linger.
                    z[base] = l1.isFinite ? l1 : 0
                    z[base + 1] = l2.isFinite ? l2 : 0
                    z[base + 2] = r1.isFinite ? r1 : 0
                    z[base + 3] = r2.isFinite ? r2 : 0
                }
            }
        }
    }
}

/// A linked stereo look-ahead limiter. The gain falls to what the loudest
/// sample entering the delay needs, over the look-ahead time, so it has
/// arrived when that sample leaves; it then recovers over the release time.
/// A final clamp at the ceiling keeps the rare overshoot inaudible.
final class MixerLimiter {
    static let maximumLookaheadMS: Float = 20
    private let capacity: Int
    private var delayLeft: [Float]
    private var delayRight: [Float]
    private var position = 0
    private var delay = 0
    private var gain: Float = 1
    private var ceiling: Float = 1
    private var attack: Float = 1
    private var release: Float = 0.999
    private var hold: Float = 0
    private var holdCounter = 0
    private let sampleRate: Float
    /// The lowest gain of the last processed block, for the meter.
    private(set) var blockMinimumGain: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = Float(max(sampleRate, 8000))
        capacity = Int(self.sampleRate * Self.maximumLookaheadMS / 1000) + 2
        delayLeft = [Float](repeating: 0, count: capacity)
        delayRight = [Float](repeating: 0, count: capacity)
    }

    func configure(_ settings: MixerLimiterSettings) {
        ceiling = MixerMatrixPlanner.gain(dB: min(max(settings.ceilingDB, -60), 0))
        let nextDelay = min(Int(sampleRate * min(max(settings.lookaheadMS, 0), Self.maximumLookaheadMS) / 1000),
                            capacity - 1)
        if nextDelay != delay {
            delay = nextDelay
            reset()
        }
        let attackSamples = Float(max(delay, 1))
        attack = 1 - expf(-2.2 / attackSamples)
        release = expf(-1 / max(sampleRate * min(max(settings.releaseMS, 1), 2000) / 1000, 1))
    }

    func reset() {
        for index in 0..<capacity {
            delayLeft[index] = 0
            delayRight[index] = 0
        }
        position = 0
        gain = 1
        hold = 0
        holdCounter = 0
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var minimum: Float = 1
        delayLeft.withUnsafeMutableBufferPointer { dl in
            delayRight.withUnsafeMutableBufferPointer { dr in
                for frame in 0..<frames {
                    let inLeft = left[frame], inRight = right[frame]
                    let peak = max(abs(inLeft), abs(inRight))
                    // The requirement of the loudest sample still in the delay.
                    let needed: Float = peak > ceiling ? ceiling / peak : 1
                    if needed <= hold || holdCounter <= 0 {
                        hold = needed
                        holdCounter = delay + 1
                    } else {
                        holdCounter -= 1
                    }
                    if hold < gain {
                        gain += (hold - gain) * attack
                    } else {
                        gain = hold + (gain - hold) * release
                    }
                    var outLeft = inLeft, outRight = inRight
                    if delay > 0 {
                        let read = (position + capacity - delay) % capacity
                        dl[position] = inLeft
                        dr[position] = inRight
                        outLeft = dl[read]
                        outRight = dr[read]
                        position = (position + 1) % capacity
                    }
                    left[frame] = min(max(outLeft * gain, -ceiling), ceiling)
                    right[frame] = min(max(outRight * gain, -ceiling), ceiling)
                    minimum = min(minimum, gain)
                }
            }
        }
        blockMinimumGain = minimum
    }
}

/// Peak and RMS of a stereo strip, smoothed the way meters fall.
struct MixerMeterState {
    var peak: Float = 0
    var rms: Float = 0
    var clipped = false

    mutating func update(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        guard frames > 0 else { return }
        var blockPeak: Float = 0, sum: Float = 0
        for frame in 0..<frames {
            let l = left[frame], r = right[frame]
            blockPeak = max(blockPeak, abs(l), abs(r))
            sum += (l * l + r * r) * 0.5
        }
        if blockPeak >= 1 { clipped = true }
        let seconds = Float(frames) / Float(max(sampleRate, 1))
        // Peaks fall 20 dB a second, RMS settles over 300 ms.
        let fall = powf(10, -20 * seconds / 20)
        peak = max(blockPeak, peak * fall)
        let blockRMS = (sum / Float(frames)).squareRoot()
        let smoothing = 1 - expf(-seconds / 0.3)
        rms += (blockRMS - rms) * smoothing
        if !peak.isFinite { peak = 0 }
        if !rms.isFinite { rms = 0 }
    }
}
