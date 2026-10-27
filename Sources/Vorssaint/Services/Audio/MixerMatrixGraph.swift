// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreAudio
import Darwin
import Foundation

// MARK: - Shared parameters

/// Coefficients handed to the audio thread without a lock: the writer makes
/// the version odd, copies, and makes it even again; the reader keeps a copy
/// only when it saw the same even version before and after.
final class MixerCoefficientMailbox {
    private var version: Int32 = 0
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: MixerEffects.maximumBands * 5 + 1)

    init() { storage.initialize(repeating: 0, count: MixerEffects.maximumBands * 5 + 1) }
    deinit { storage.deallocate() }

    /// Main thread.
    func write(_ coefficients: [MixerBiquadCoefficients]) {
        OSAtomicIncrement32Barrier(&version)
        let count = min(coefficients.count, MixerEffects.maximumBands)
        storage[0] = Float(count)
        for (index, c) in coefficients.prefix(count).enumerated() {
            let base = 1 + index * 5
            storage[base] = c.b0; storage[base + 1] = c.b1; storage[base + 2] = c.b2
            storage[base + 3] = c.a1; storage[base + 4] = c.a2
        }
        OSAtomicIncrement32Barrier(&version)
    }

    /// Audio thread. Returns the new version when `into` was filled.
    func read(newerThan seen: Int32, into target: inout [MixerBiquadCoefficients]) -> Int32? {
        let before = OSAtomicAdd32Barrier(0, &version)
        guard before != seen, before & 1 == 0 else { return nil }
        let count = min(Int(storage[0]), MixerEffects.maximumBands)
        target.removeAll(keepingCapacity: true)
        for index in 0..<count {
            let base = 1 + index * 5
            target.append(MixerBiquadCoefficients(b0: storage[base], b1: storage[base + 1], b2: storage[base + 2],
                                                  a1: storage[base + 3], a2: storage[base + 4]))
        }
        return OSAtomicAdd32Barrier(0, &version) == before ? before : nil
    }
}

/// Everything the control side and the audio thread exchange, preallocated
/// for the topology's strip counts. Each value is one atomic float.
final class MixerMatrixParameters {
    final class Strip {
        let gain = AtomicFloatBox(0)
        let trim = AtomicFloatBox(1)
        let limiterEnabled = AtomicFloatBox(0)
        let ceilingDB = AtomicFloatBox(-1)
        let releaseMS = AtomicFloatBox(100)
        let lookaheadMS = AtomicFloatBox(5)
        let equalizer = MixerCoefficientMailbox()
        // Written by the audio thread.
        let peak = AtomicFloatBox(0)
        let rms = AtomicFloatBox(0)
        let limiterGain = AtomicFloatBox(1)
        let clipped = AtomicFloatBox(0)

        func store(_ values: MixerStripValues, previous: MixerStripValues?) {
            gain.value = values.gain
            trim.value = values.trim
            limiterEnabled.value = values.limiter.enabled ? 1 : 0
            ceilingDB.value = values.limiter.ceilingDB
            releaseMS.value = values.limiter.releaseMS
            lookaheadMS.value = values.limiter.lookaheadMS
            if previous?.eq != values.eq { equalizer.write(values.eq) }
        }
    }

    let sources: [Strip]
    let outputs: [Strip]
    let sends: [AtomicFloatBox]
    let callbacks = AtomicFloatBox(0)
    let layoutMismatches = AtomicFloatBox(0)

    init(sourceCount: Int, outputCount: Int) {
        sources = (0..<sourceCount).map { _ in Strip() }
        outputs = (0..<outputCount).map { _ in Strip() }
        sends = (0..<(sourceCount * outputCount)).map { _ in AtomicFloatBox(0) }
    }

    func store(_ values: MixerMatrixValues, previous: MixerMatrixValues?) {
        for (index, strip) in sources.enumerated() where values.sources.indices.contains(index) {
            strip.store(values.sources[index], previous: previous?.sources[safe: index])
        }
        for (index, strip) in outputs.enumerated() where values.outputs.indices.contains(index) {
            strip.store(values.outputs[index], previous: previous?.outputs[safe: index])
        }
        for (index, send) in sends.enumerated() where values.sends.indices.contains(index) {
            send.value = values.sends[index]
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct MixerMeterReading: Equatable {
    var peak: Float
    var rms: Float
    /// dB the limiter took off, 0 when it did nothing.
    var limiterReductionDB: Float
    var clipped: Bool

    static let silent = MixerMeterReading(peak: 0, rms: 0, limiterReductionDB: 0, clipped: false)
}

// MARK: - The graph the IO callback runs

/// Owned by the audio thread once started. Every buffer is allocated here,
/// so `process` allocates nothing, takes no lock and makes no system call.
final class MixerMatrixGraph {
    static let chunk = 512

    private final class StripState {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: MixerMatrixGraph.chunk)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: MixerMatrixGraph.chunk)
        let equalizer = MixerEqualizer()
        let limiter: MixerLimiter
        var limiterOn = false
        var limiterSettings = MixerLimiterSettings()
        var eqVersion: Int32 = -1
        var eqScratch: [MixerBiquadCoefficients] = []
        var gain: Float = 0
        var trim: Float = 1
        var meter = MixerMeterState()

        init(sampleRate: Double) {
            limiter = MixerLimiter(sampleRate: sampleRate)
            eqScratch.reserveCapacity(MixerEffects.maximumBands)
            left.initialize(repeating: 0, count: MixerMatrixGraph.chunk)
            right.initialize(repeating: 0, count: MixerMatrixGraph.chunk)
        }

        deinit {
            left.deallocate()
            right.deallocate()
        }

        func refresh(_ shared: MixerMatrixParameters.Strip) {
            if let version = shared.equalizer.read(newerThan: eqVersion, into: &eqScratch) {
                eqVersion = version
                equalizer.set(eqScratch)
            }
            let on = shared.limiterEnabled.value != 0
            if on {
                let settings = MixerLimiterSettings(enabled: true, ceilingDB: shared.ceilingDB.value,
                                                    releaseMS: shared.releaseMS.value,
                                                    lookaheadMS: shared.lookaheadMS.value)
                if settings != limiterSettings {
                    limiter.configure(settings)
                    limiterSettings = settings
                }
                if !limiterOn { limiter.reset() }
            }
            limiterOn = on
        }

        /// Trim, EQ, limiter and fader on `frames` samples (for outputs the
        /// fader comes before the limiter), then the meter.
        func run(frames: Int, shared: MixerMatrixParameters.Strip, sampleRate: Double, limiterLast: Bool) {
            MixerMatrixGraph.ramp(left, right, frames: frames, current: &trim, target: shared.trim.value)
            equalizer.process(left: left, right: right, frames: frames)
            if limiterLast {
                MixerMatrixGraph.ramp(left, right, frames: frames, current: &gain, target: shared.gain.value)
                if limiterOn { limiter.process(left: left, right: right, frames: frames) }
            } else {
                if limiterOn { limiter.process(left: left, right: right, frames: frames) }
                MixerMatrixGraph.ramp(left, right, frames: frames, current: &gain, target: shared.gain.value)
            }
            meter.update(left: left, right: right, frames: frames, sampleRate: sampleRate)
            shared.peak.value = meter.peak
            shared.rms.value = meter.rms
            shared.limiterGain.value = limiterOn ? limiter.blockMinimumGain : 1
            if meter.clipped {
                shared.clipped.value = 1
                meter.clipped = false
            }
        }
    }

    private let parameters: MixerMatrixParameters
    private let layout: MixerMatrixLayout
    private let sampleRate: Double
    private let sources: [StripState]
    private let outputs: [StripState]
    private var sendCurrent: [Float]

    init(parameters: MixerMatrixParameters, layout: MixerMatrixLayout, sampleRate: Double) {
        self.parameters = parameters
        self.layout = layout
        self.sampleRate = sampleRate
        sources = parameters.sources.map { _ in StripState(sampleRate: sampleRate) }
        outputs = parameters.outputs.map { _ in StripState(sampleRate: sampleRate) }
        sendCurrent = [Float](repeating: 0, count: parameters.sends.count)
    }

    /// Multiplies by a gain moving linearly from `current` to `target` over
    /// the block, so no change clicks.
    static func ramp(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int,
                     current: inout Float, target: Float) {
        let target = target.isFinite ? min(max(target, 0), 16) : 0
        let from = current
        if abs(from - target) < 1e-7 {
            if target != 1 {
                for frame in 0..<frames {
                    left[frame] *= target
                    right[frame] *= target
                }
            }
        } else {
            let step = (target - from) / Float(max(frames, 1))
            for frame in 0..<frames {
                let gain = from + step * Float(frame + 1)
                left[frame] *= gain
                right[frame] *= gain
            }
        }
        current = target
    }

    private func read(_ channel: MixerChannel, from input: UnsafeMutableAudioBufferListPointer, offset: Int,
                      frames: Int, into target: UnsafeMutablePointer<Float>) -> Bool {
        guard channel.stream < input.count, let data = input[channel.stream].mData else {
            target.update(repeating: 0, count: frames)
            return false
        }
        let buffer = input[channel.stream]
        let channels = Int(buffer.mNumberChannels)
        let available = channels > 0 ? Int(buffer.mDataByteSize) / (4 * channels) : 0
        guard channel.channel < channels else {
            target.update(repeating: 0, count: frames)
            return false
        }
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            let index = offset + frame
            target[frame] = index < available ? samples[index * channels + channel.channel] : 0
        }
        return available >= offset + frames
    }

    private func add(_ source: UnsafeMutablePointer<Float>, to channel: MixerChannel,
                     of output: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int, scale: Float) {
        guard channel.stream < output.count, let data = output[channel.stream].mData else { return }
        let buffer = output[channel.stream]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, channel.channel < channels else { return }
        let available = Int(buffer.mDataByteSize) / (4 * channels)
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames where offset + frame < available {
            samples[(offset + frame) * channels + channel.channel] += source[frame] * scale
        }
    }

    func process(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        var frames = 0
        for buffer in output where buffer.mNumberChannels > 0 {
            frames = max(frames, Int(buffer.mDataByteSize) / (4 * Int(buffer.mNumberChannels)))
        }
        for buffer in output where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        guard frames > 0 else { return }
        for (state, shared) in zip(sources, parameters.sources) { state.refresh(shared) }
        for (state, shared) in zip(outputs, parameters.outputs) { state.refresh(shared) }
        var mismatch = false
        let outputCount = outputs.count
        var offset = 0
        while offset < frames {
            let count = min(Self.chunk, frames - offset)
            for (index, state) in sources.enumerated() {
                let place = layout.sources[index]
                mismatch = !read(place.left, from: input, offset: offset, frames: count, into: state.left) || mismatch
                if let right = place.right {
                    mismatch = !read(right, from: input, offset: offset, frames: count, into: state.right) || mismatch
                } else {
                    state.right.update(from: state.left, count: count)
                }
                state.run(frames: count, shared: parameters.sources[index], sampleRate: sampleRate, limiterLast: false)
            }
            for (outputIndex, bus) in outputs.enumerated() {
                bus.left.update(repeating: 0, count: count)
                bus.right.update(repeating: 0, count: count)
                for (sourceIndex, source) in sources.enumerated() {
                    let sendIndex = sourceIndex * outputCount + outputIndex
                    let target = parameters.sends[sendIndex].value
                    let from = sendCurrent[sendIndex]
                    guard from > 0 || target > 0 else { continue }
                    let step = (target - from) / Float(count)
                    for frame in 0..<count {
                        let gain = from + step * Float(frame + 1)
                        bus.left[frame] += source.left[frame] * gain
                        bus.right[frame] += source.right[frame] * gain
                    }
                    sendCurrent[sendIndex] = target
                }
                bus.run(frames: count, shared: parameters.outputs[outputIndex], sampleRate: sampleRate,
                        limiterLast: true)
                let place = layout.outputs[outputIndex]
                if let right = place.right {
                    add(bus.left, to: place.left, of: output, offset: offset, frames: count, scale: 1)
                    add(bus.right, to: right, of: output, offset: offset, frames: count, scale: 1)
                } else {
                    add(bus.left, to: place.left, of: output, offset: offset, frames: count, scale: 0.5)
                    add(bus.right, to: place.left, of: output, offset: offset, frames: count, scale: 0.5)
                }
            }
            offset += count
        }
        parameters.callbacks.value += 1
        if mismatch { parameters.layoutMismatches.value += 1 }
    }
}
