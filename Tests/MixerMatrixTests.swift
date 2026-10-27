// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreAudio
import Foundation

enum MixerMatrixTests {
    static func run(_ suite: TestSuite) {
        configuration(suite)
        planning(suite)
        routes(suite)
        layout(suite)
        equalizer(suite)
        limiter(suite)
        meter(suite)
        graph(suite)
    }

    /// One callback on fake buffers: a stereo source sent at half level to
    /// a stereo output, with an unused output stream that must come out silent.
    private static func graph(_ suite: TestSuite) {
        let parameters = MixerMatrixParameters(sourceCount: 1, outputCount: 1)
        parameters.store(MixerMatrixValues(sources: [MixerStripValues(gain: 1)], outputs: [MixerStripValues(gain: 1)],
                                           sends: [0.5]), previous: nil)
        let layout = MixerMatrixLayout(sources: [(MixerChannel(stream: 0, channel: 0), MixerChannel(stream: 0, channel: 1))],
                                       outputs: [(MixerChannel(stream: 1, channel: 0), MixerChannel(stream: 1, channel: 1))])
        let graph = MixerMatrixGraph(parameters: parameters, layout: layout, sampleRate: 48_000)
        let frames = 700
        func buffers(_ streams: Int, fill: Float) -> UnsafeMutableAudioBufferListPointer {
            let list = AudioBufferList.allocate(maximumBuffers: streams)
            for index in 0..<streams {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
                data.initialize(repeating: fill, count: frames * 2)
                list[index] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * 4), mData: data)
            }
            return list
        }
        let input = buffers(1, fill: 0)
        let input0 = input[0].mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            input0[frame * 2] = 0.5
            input0[frame * 2 + 1] = 0.25
        }
        let output = buffers(2, fill: 9)
        defer {
            for list in [input, output] {
                for buffer in list { buffer.mData?.deallocate() }
                list.unsafeMutablePointer.deallocate()
            }
        }
        graph.process(input: input, output: output)
        graph.process(input: input, output: output)
        let unused = output[0].mData!.assumingMemoryBound(to: Float.self)
        let used = output[1].mData!.assumingMemoryBound(to: Float.self)
        suite.expect((0..<(frames * 2)).allSatisfy { unused[$0] == 0 }, "streams the mix does not use are silenced")
        suite.expectClose(Double(used[(frames - 1) * 2]), 0.25, "the send scales the left channel", tol: 1e-5)
        suite.expectClose(Double(used[(frames - 1) * 2 + 1]), 0.125, "the right channel stays its own", tol: 1e-5)
        suite.expect(parameters.sources[0].peak.value > 0.49 && parameters.layoutMismatches.value == 0,
                     "meters read the source and a matching layout reports no mismatch")
        parameters.sources[0].gain.value = 0
        graph.process(input: input, output: output)
        graph.process(input: input, output: output)
        suite.expect(abs(used[(frames - 1) * 2]) < 1e-6, "a muted source ramps to silence")
    }

    private static func device(_ uid: String, inputs: [Int] = [], outputs: [Int] = [2], rate: Double = 48_000,
                               aggregate: Bool = false) -> MixerInventoryDevice {
        MixerInventoryDevice(uid: uid, name: uid.capitalized, inputStreams: inputs, outputStreams: outputs,
                             sampleRate: rate, isAggregate: aggregate)
    }

    private static func match(_ uid: String) -> MixerDeviceMatch { MixerDeviceMatch(uid: uid, name: uid.capitalized) }

    private static let inventory = MixerInventory(
        devices: [device("speakers"), device("headphones"), device("mic", inputs: [1], outputs: []),
                  device("interface", inputs: [2, 2], outputs: [4]), device("slow", rate: 44_100),
                  device("group", aggregate: true)],
        apps: [MixerInventoryApp(bundleID: "com.music", name: "Music", objects: [7, 3, 7], volume: 0.5)],
        tapsSupported: true)

    private static func configuration(_ suite: TestSuite) {
        let old = Data(#"{"enabled":true,"sources":[]}"#.utf8)
        let decoded = MixerMatrixConfiguration.decode(old)
        suite.expect(decoded.enabled && decoded.appRoutes.isEmpty && decoded.outputs.isEmpty,
                     "a saved configuration without newer keys still loads")
        let route = try? JSONDecoder().decode(MixerAppRoute.self, from: Data(#"{"outputs":[]}"#.utf8))
        suite.expect(route?.enabled == true && route?.keepDefault == false && route?.gainDB == 0,
                     "a route missing its options takes the defaults")
        suite.expect(MixerMatrixConfiguration.decode(Data("[]".utf8)) == MixerMatrixConfiguration(),
                     "unreadable data falls back to an empty configuration")
        var edited = MixerMatrixConfiguration()
        edited.setSend("a", "b", gainDB: -3)
        edited.setSend("a", "b", gainDB: -6, muted: true)
        suite.expect(edited.sends.count == 1 && edited.send("a", "b")?.gainDB == -6,
                     "setting a send twice edits the same crosspoint")
        edited.removeSource("a")
        suite.expect(edited.sends.isEmpty, "removing a source drops its sends")
        let bands = MixerEffects.flatBands(1)
        suite.expect(bands.count == 3 && bands.first?.kind == .lowShelf && bands.last?.kind == .highShelf
                        && MixerEffects.flatBands(99).count == MixerEffects.maximumBands,
                     "a flat EQ has shelves at both ends and a bounded band count")
        suite.expect(!MixerMatrixConfiguration().wantsEngine, "nothing configured asks for no engine")
        var withInput = MixerMatrixConfiguration()
        withInput.enabled = true
        withInput.sources = [MixerMatrixSource(kind: .app(bundleID: "com.music"))]
        func microphoneUsers(_ configuration: MixerMatrixConfiguration) -> [AppFeature] {
            let data = configuration.encoded
            return AppFeature.activeFeatures(using: .microphone, isAvailable: { $0 == .mixer }, boolFor: { _ in false },
                                             stringFor: { _ in nil },
                                             dataFor: { $0 == DefaultsKey.mixerMatrixConfiguration ? data : nil })
        }
        suite.expect(microphoneUsers(withInput).isEmpty, "app sources alone never ask for the microphone")
        withInput.sources.append(MixerMatrixSource(kind: .input(match("mic"))))
        suite.expect(microphoneUsers(withInput) == [.mixer], "an input source puts the mixer on the microphone list")
        withInput.enabled = false
        suite.expect(microphoneUsers(withInput).isEmpty, "a switched-off matrix uses no microphone")
    }

    private static func basicMatrix() -> MixerMatrixConfiguration {
        var configuration = MixerMatrixConfiguration()
        configuration.enabled = true
        configuration.sources = [
            MixerMatrixSource(id: "music", kind: .app(bundleID: "com.music"), gainDB: -6),
            MixerMatrixSource(id: "voice", kind: .input(match("mic"))),
        ]
        configuration.outputs = [MixerMatrixOutput(id: "main", device: match("speakers")),
                                 MixerMatrixOutput(id: "phones", device: match("headphones"), gainDB: -20)]
        configuration.sends = [MixerMatrixSend(source: "music", output: "main"),
                               MixerMatrixSend(source: "voice", output: "phones", gainDB: -6)]
        return configuration
    }

    private static func planning(_ suite: TestSuite) {
        let plan = MixerMatrixPlanner.plan(basicMatrix(), inventory: inventory)
        guard let topology = plan.topology else {
            suite.expect(false, "a connected matrix plans a topology")
            return
        }
        suite.expect(topology.clockUID == "speakers" && topology.subDevices.first?.uid == "speakers",
                     "the first output clocks the mixer and leads the sub-devices")
        suite.expect(topology.subDevices.first { $0.uid == "mic" }?.readsInput == true
                        && topology.subDevices.first { $0.uid == "mic" }?.writesOutput == false,
                     "an input joins the aggregate for reading only")
        suite.expect(topology.taps == [MixerMatrixTopology.Tap(bundleID: "com.music", objects: [3, 7], mutesOriginal: true)],
                     "an app source taps its sorted processes and takes over its output")
        suite.expect(plan.exclusiveApps == ["com.music"], "the volume mixer is told which app the matrix owns")
        suite.expectClose(Double(plan.values.sources[0].gain), Double(MixerMatrixPlanner.gain(dB: -6) * 0.5),
                          "the app's own volume scales its fader")
        suite.expect(topology.sources[1].input == .device(uid: "mic", firstChannel: 0, mono: true),
                     "a one-channel input is read as mono")
        suite.expect(plan.values.sends == [1, 0, 0, MixerMatrixPlanner.gain(dB: -6)],
                     "sends land row-major, sources by outputs")

        var solo = basicMatrix()
        solo.sources[1].solo = true
        let soloed = MixerMatrixPlanner.plan(solo, inventory: inventory)
        suite.expect(soloed.values.sources[0].gain == 0 && soloed.values.sources[1].gain == 1,
                     "while a source is soloed only soloed sources are heard")
        suite.expect(soloed.topology == plan.topology, "solo changes values, never the topology")

        var keep = basicMatrix()
        keep.sources[0].keepOriginal = true
        suite.expect(MixerMatrixPlanner.plan(keep, inventory: inventory).exclusiveApps.isEmpty,
                     "an app kept on its own output is not taken over")

        var problems = basicMatrix()
        problems.outputs.append(MixerMatrixOutput(id: "slow", device: match("slow")))
        problems.outputs.append(MixerMatrixOutput(id: "group", device: match("group")))
        problems.outputs.append(MixerMatrixOutput(id: "gone", device: match("gone")))
        let checked = MixerMatrixPlanner.plan(problems, inventory: inventory)
        suite.expect(checked.outputs[2].state == .unavailable(.sampleRate(device: "Slow", rate: 44_100, mixerRate: 48_000))
                        && checked.outputs[3].state == .unavailable(.aggregate("Group"))
                        && checked.outputs[4].state == .waiting(.notConnected("Gone")),
                     "outputs that cannot join say why")
        suite.expect(checked.topology?.outputs.count == 2, "only usable outputs are built")

        var renamed = basicMatrix()
        renamed.outputs[0].device = MixerDeviceMatch(uid: "old-uid", name: "Speakers")
        suite.expect(MixerMatrixPlanner.plan(renamed, inventory: inventory).topology?.clockUID == "speakers",
                     "a device whose UID changed is found by name")

        var notRunning = basicMatrix()
        notRunning.sources[0].kind = .app(bundleID: "com.other")
        let waiting = MixerMatrixPlanner.plan(notRunning, inventory: inventory)
        suite.expect(waiting.sources[0].state == .waiting(.appNotRunning) && waiting.topology?.taps.isEmpty == true,
                     "an app that is not playing waits without a tap")

        var denied = inventory
        denied.captureDenied = true
        suite.expect(MixerMatrixPlanner.plan(basicMatrix(), inventory: denied).sources[0].state
                        == .unavailable(.needsPermission),
                     "app sources need System Audio Recording")

        var off = basicMatrix()
        off.enabled = false
        let offPlan = MixerMatrixPlanner.plan(off, inventory: inventory)
        suite.expect(offPlan.topology == nil && offPlan.sources.allSatisfy { $0.state == .off },
                     "a switched-off matrix builds nothing")
    }

    private static func routes(_ suite: TestSuite) {
        var configuration = MixerMatrixConfiguration()
        configuration.appRoutes["com.music"] = MixerAppRoute(outputs: [match("headphones"), match("gone")], gainDB: -6)
        let plan = MixerMatrixPlanner.plan(configuration, inventory: inventory)
        suite.expect(plan.topology?.clockUID == "headphones" && plan.topology?.sources.count == 1
                        && plan.topology?.outputs.first?.key == MixerMatrixPlanner.routeOutputPrefix + "headphones",
                     "a route runs on its own, without the matrix")
        suite.expect(plan.routes.first?.state == .active
                        && plan.routes.first?.targetProblems.last == .notConnected("Gone"),
                     "a route plays where it can and names the missing target")
        suite.expect(plan.exclusiveApps == ["com.music"], "a route moves the app off its own output by default")
        suite.expectClose(Double(plan.values.sources[0].gain), Double(MixerMatrixPlanner.gain(dB: -6) * 0.5),
                          "the route's level and the app's volume both apply")

        configuration.appRoutes["com.music"]?.keepDefault = true
        suite.expect(MixerMatrixPlanner.plan(configuration, inventory: inventory).exclusiveApps.isEmpty,
                     "a route that keeps the normal output leaves the app there too")

        var shared = basicMatrix()
        shared.appRoutes["com.music"] = MixerAppRoute(outputs: [match("speakers")])
        let both = MixerMatrixPlanner.plan(shared, inventory: inventory)
        suite.expect(both.topology?.taps.count == 1 && both.topology?.outputs.count == 3,
                     "a route and a matrix source share one tap; the route keeps its own output, outside the matrix master")

        configuration.appRoutes["com.music"]?.enabled = false
        suite.expect(MixerMatrixPlanner.plan(configuration, inventory: inventory).topology == nil,
                     "a disabled route builds nothing")
    }

    private static func layout(_ suite: TestSuite) {
        let topology = MixerMatrixTopology(
            clockUID: "speakers", sampleRate: 48_000,
            subDevices: [.init(uid: "speakers", readsInput: false, writesOutput: true),
                         .init(uid: "interface", readsInput: true, writesOutput: true)],
            taps: [.init(bundleID: "app", objects: [1], mutesOriginal: true)],
            sources: [.init(key: "app", input: .tap(0)),
                      .init(key: "line", input: .device(uid: "interface", firstChannel: 1, mono: false))],
            outputs: [.init(key: "main", uid: "speakers", firstChannel: 0),
                      .init(key: "cue", uid: "interface", firstChannel: 3)])
        let realized = MixerRealizedAggregate(
            subDevices: [.init(uid: "speakers", inputStreams: [], outputStreams: [2]),
                         .init(uid: "interface", inputStreams: [2, 2], outputStreams: [4])],
            tapChannels: [2])
        let mapped = realized.layout(for: topology)
        suite.expect(mapped?.sources[0].left == MixerChannel(stream: 2, channel: 0)
                        && mapped?.sources[0].right == MixerChannel(stream: 2, channel: 1),
                     "tap streams follow every sub-device input")
        suite.expect(mapped?.sources[1].left == MixerChannel(stream: 0, channel: 1)
                        && mapped?.sources[1].right == MixerChannel(stream: 1, channel: 0),
                     "a stereo pair may straddle two streams of one device")
        suite.expect(mapped?.outputs[1].left == MixerChannel(stream: 1, channel: 3) && mapped?.outputs[1].right == nil,
                     "an output on the last channel writes mono")
        var missing = realized
        missing.tapChannels = []
        suite.expect(missing.layout(for: topology) == nil, "a tap the HAL did not attach fails the layout")
    }

    private static func equalizer(_ suite: TestSuite) {
        let rate = 48_000.0
        let bell = MixerBiquadCoefficients.design(MixerEQBand(kind: .peak, frequency: 1000, gainDB: 6, q: 1),
                                                  sampleRate: rate)
        suite.expectClose(bell.magnitudeDB(at: 1000, sampleRate: rate), 6, "a bell boosts its centre", tol: 0.05)
        suite.expectClose(bell.magnitudeDB(at: 20, sampleRate: rate), 0, "a bell leaves far bands alone", tol: 0.1)
        let shelf = MixerBiquadCoefficients.design(MixerEQBand(kind: .lowShelf, frequency: 200, gainDB: -9, q: 0.707),
                                                   sampleRate: rate)
        suite.expectClose(shelf.magnitudeDB(at: 20, sampleRate: rate), -9, "a low shelf sets the lows", tol: 0.3)
        suite.expectClose(shelf.magnitudeDB(at: 10_000, sampleRate: rate), 0, "a low shelf leaves the highs", tol: 0.2)
        let pass = MixerBiquadCoefficients.design(MixerEQBand(kind: .highPass, frequency: 100, q: 0.707),
                                                  sampleRate: rate)
        suite.expect(pass.magnitudeDB(at: 20, sampleRate: rate) < -20 && abs(pass.magnitudeDB(at: 5000, sampleRate: rate)) < 0.1,
                     "a high-pass removes rumble only")
        suite.expect(MixerBiquadCoefficients.design(MixerEQBand(kind: .peak, gainDB: 0), sampleRate: rate).isIdentity,
                     "a flat band costs nothing")
        let values = MixerMatrixPlanner.stripValues(
            MixerEffects(trimDB: 0, eqEnabled: true,
                         bands: [MixerEQBand(gainDB: 3), MixerEQBand(enabled: false, gainDB: 3), MixerEQBand(gainDB: 0)]),
            gain: 1, sampleRate: rate)
        suite.expect(values.eq.count == 1, "only enabled bands that change something reach the audio thread")

        let eq = MixerEqualizer()
        eq.set([bell])
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
        defer { left.deallocate(); right.deallocate() }
        for frame in 0..<4800 {
            left[frame] = sinf(2 * .pi * 1000 * Float(frame) / 48_000) * 0.25
            right[frame] = left[frame]
        }
        eq.process(left: left, right: right, frames: 4800)
        var peak: Float = 0
        for frame in 2400..<4800 { peak = max(peak, abs(left[frame])) }
        suite.expectClose(Double(peak), 0.25 * 1.995, "the cascade applies the designed gain", tol: 0.01)
    }

    private static func limiter(_ suite: TestSuite) {
        let limiter = MixerLimiter(sampleRate: 48_000)
        limiter.configure(MixerLimiterSettings(enabled: true, ceilingDB: -6, releaseMS: 50, lookaheadMS: 5))
        let frames = 9600
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        for frame in 0..<frames {
            let sample = sinf(2 * .pi * 440 * Float(frame) / 48_000) * (frame > 4800 ? 1.5 : 0.1)
            left[frame] = sample
            right[frame] = -sample
        }
        limiter.process(left: left, right: right, frames: frames)
        let ceiling = MixerMatrixPlanner.gain(dB: -6)
        var peak: Float = 0
        for frame in 0..<frames { peak = max(peak, abs(left[frame]), abs(right[frame])) }
        suite.expect(peak <= ceiling + 0.0001, "nothing leaves the limiter above its ceiling")
        suite.expect(limiter.blockMinimumGain < 0.5, "the limiter reports how far it turned down")
        var quiet: Float = 0
        for frame in 240..<4000 { quiet = max(quiet, abs(left[frame])) }
        suite.expectClose(Double(quiet), 0.1, "quiet material passes untouched, only delayed", tol: 0.002)
    }

    private static func meter(_ suite: TestSuite) {
        var meter = MixerMeterState()
        var samples = [Float](repeating: 0.5, count: 4800)
        samples.withUnsafeBufferPointer { buffer in
            meter.update(left: buffer.baseAddress!, right: buffer.baseAddress!, frames: 4800, sampleRate: 48_000)
        }
        suite.expect(meter.peak == 0.5 && meter.rms > 0 && !meter.clipped, "the meter reads peak and RMS")
        samples[10] = 1.2
        samples.withUnsafeBufferPointer { buffer in
            meter.update(left: buffer.baseAddress!, right: buffer.baseAddress!, frames: 4800, sampleRate: 48_000)
        }
        suite.expect(meter.clipped, "a sample past full scale marks the strip as clipped")
        suite.expectClose(Double(MixerMatrixPlanner.decibels(MixerMatrixPlanner.gain(dB: -12))), -12, "dB round trip")
        suite.expect(MixerMatrixPlanner.gain(dB: -100) == 0, "the bottom of the fader is silence")
    }
}
