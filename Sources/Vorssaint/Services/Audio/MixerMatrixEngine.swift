// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - The device

/// The HAL objects of one running topology: its taps, the private aggregate
/// and the IO callback. Nothing changes in place: a new topology is a new
/// engine, and values reach the running one through `parameters`.
@available(macOS 14.4, *)
final class MixerMatrixEngine {
    enum Failure: Error, Equatable {
        case tap(String)
        case device(String)
        case aggregate
        case layout
        case format
        case start
    }

    let topology: MixerMatrixTopology
    let parameters: MixerMatrixParameters
    private(set) var values: MixerMatrixValues
    private var taps: [AudioObjectID] = []
    private var aggregate = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?

    private static let teardownQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.vorssaint.utils.mixer-matrix.teardown"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// Builds and starts. Call off the main thread: the HAL can take a
    /// moment to attach sub-devices.
    init(topology: MixerMatrixTopology, values: MixerMatrixValues) throws {
        self.topology = topology
        self.values = values
        parameters = MixerMatrixParameters(sourceCount: topology.sources.count, outputCount: topology.outputs.count)
        parameters.store(values, previous: nil)
        do {
            try build()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func update(_ next: MixerMatrixValues) {
        parameters.store(next, previous: values)
        values = next
    }

    func meters() -> (sources: [MixerMeterReading], outputs: [MixerMeterReading]) {
        func reading(_ strip: MixerMatrixParameters.Strip) -> MixerMeterReading {
            let limiter = strip.limiterGain.value
            return MixerMeterReading(peak: strip.peak.value, rms: strip.rms.value,
                                     limiterReductionDB: limiter > 0 && limiter < 1
                                         ? -MixerMatrixPlanner.decibels(limiter) : 0,
                                     clipped: strip.clipped.value != 0)
        }
        return (parameters.sources.map(reading), parameters.outputs.map(reading))
    }

    func resetClips() {
        for strip in parameters.sources + parameters.outputs { strip.clipped.value = 0 }
    }

    var callbackCount: Float { parameters.callbacks.value }

    private func build() throws {
        var tapUIDs: [String] = []
        for tap in topology.taps {
            guard !tap.objects.isEmpty else { throw Failure.tap(tap.bundleID) }
            let description = CATapDescription(stereoMixdownOfProcesses: tap.objects.map { AudioObjectID($0) })
            description.muteBehavior = tap.mutesOriginal ? .mutedWhenTapped : .unmuted
            description.isPrivate = true
            var id = AudioObjectID(0)
            guard AudioHardwareCreateProcessTap(description, &id) == noErr, id != 0 else {
                throw Failure.tap(tap.bundleID)
            }
            taps.append(id)
            tapUIDs.append(description.uuid.uuidString)
        }
        for device in topology.subDevices where MixerMatrixHAL.deviceID(forUID: device.uid) == nil {
            throw Failure.device(device.uid)
        }
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vorssaint Mixer Matrix",
            kAudioAggregateDeviceUIDKey: "com.vorssaint.mixer-matrix." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: topology.clockUID,
            kAudioAggregateDeviceClockDeviceKey: topology.clockUID,
            kAudioAggregateDeviceSubDeviceListKey: topology.subDevices.map {
                [kAudioSubDeviceUIDKey: $0.uid,
                 kAudioSubDeviceDriftCompensationKey: $0.uid != topology.clockUID] as [String: Any]
            },
        ]
        if !tapUIDs.isEmpty {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            }
        }
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr,
              aggregate != 0 else {
            aggregate = 0
            throw Failure.aggregate
        }

        // The HAL can attach sub-devices and taps a moment later; wait until
        // the aggregate's streams add up to its parts.
        var realized = MixerMatrixHAL.realized(aggregate: aggregate, topology: topology)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let inputs = MixerMatrixHAL.streamChannels(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outputs = MixerMatrixHAL.streamChannels(aggregate, scope: kAudioObjectPropertyScopeOutput)
            if realized.subDevices.count == topology.subDevices.count, realized.tapChannels.count == taps.count,
               inputs == realized.inputStreams, outputs == realized.outputStreams { break }
            usleep(20_000)
            realized = MixerMatrixHAL.realized(aggregate: aggregate, topology: topology)
        }
        guard MixerMatrixHAL.streamChannels(aggregate, scope: kAudioObjectPropertyScopeInput) == realized.inputStreams,
              MixerMatrixHAL.streamChannels(aggregate, scope: kAudioObjectPropertyScopeOutput) == realized.outputStreams,
              let layout = realized.layout(for: topology) else { throw Failure.layout }
        guard MixerMatrixHAL.usesFloat32(aggregate, scope: kAudioObjectPropertyScopeOutput),
              realized.inputStreams.isEmpty || MixerMatrixHAL.usesFloat32(aggregate, scope: kAudioObjectPropertyScopeInput)
        else { throw Failure.format }

        let graph = MixerMatrixGraph(parameters: parameters, layout: layout, sampleRate: topology.sampleRate)
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil, { _, input, _, output, _ in
            graph.process(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                          output: UnsafeMutableAudioBufferListPointer(output))
        }) == noErr, let ioProc else {
            self.ioProc = nil
            throw Failure.start
        }
        // Streams of a sub-device nobody reads are switched off for this
        // callback, so an input that only clocks costs nothing.
        MixerMatrixHAL.setStreamUsage(aggregate, ioProc: ioProc, realized: realized, topology: topology)
        guard AudioDeviceStart(aggregate, ioProc) == noErr else { throw Failure.start }
    }

    /// Stops reading first, so muted apps are heard again at once; the
    /// destroys that a wedged HAL can park in run elsewhere.
    func stop() {
        let aggregate = self.aggregate, ioProc = self.ioProc, taps = self.taps
        self.aggregate = 0
        self.ioProc = nil
        self.taps = []
        if let ioProc, aggregate != 0 { AudioDeviceStop(aggregate, ioProc) }
        guard aggregate != 0 || !taps.isEmpty else { return }
        Self.teardownQueue.addOperation {
            if let ioProc, aggregate != 0 { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
            for tap in taps { AudioHardwareDestroyProcessTap(tap) }
        }
    }
}

// MARK: - HAL reads

enum MixerMatrixHAL {
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer($0)) == noErr
        }
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { $0 != 0 }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        guard read(object, selector, &value) else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }

    static func streamChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .map { Int($0.mNumberChannels) }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Every device the matrix could read or write, its own aggregates left out.
    static func devices() -> [MixerInventoryDevice] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.vorssaint.") else { return nil }
            var hidden: UInt32 = 0
            if read(id, kAudioDevicePropertyIsHidden, &hidden), hidden != 0 { return nil }
            var alive: UInt32 = 1
            if read(id, kAudioDevicePropertyDeviceIsAlive, &alive), alive == 0 { return nil }
            var transport: UInt32 = 0
            _ = read(id, kAudioDevicePropertyTransportType, &transport)
            var rate: Float64 = 0
            _ = read(id, kAudioDevicePropertyNominalSampleRate, &rate)
            let name = string(id, kAudioObjectPropertyName) ?? uid
            guard !MicMuteSupport.isOwnDevice(name: name) else { return nil }
            return MixerInventoryDevice(uid: uid, name: name,
                                        inputStreams: streamChannels(id, scope: kAudioObjectPropertyScopeInput),
                                        outputStreams: streamChannels(id, scope: kAudioObjectPropertyScopeOutput),
                                        sampleRate: rate,
                                        isAggregate: transport == kAudioDeviceTransportTypeAggregate
                                            || transport == kAudioDeviceTransportTypeAutoAggregate)
        }
    }

    static func realized(aggregate: AudioObjectID, topology: MixerMatrixTopology) -> MixerRealizedAggregate {
        var subDevices: [MixerRealizedAggregate.SubDevice] = []
        let active = objects(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)
        let ids = active.isEmpty ? topology.subDevices.compactMap { deviceID(forUID: $0.uid) } : active
        for id in ids {
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
            subDevices.append(.init(uid: uid,
                                    inputStreams: streamChannels(id, scope: kAudioObjectPropertyScopeInput),
                                    outputStreams: streamChannels(id, scope: kAudioObjectPropertyScopeOutput)))
        }
        let streams = streamChannels(aggregate, scope: kAudioObjectPropertyScopeInput)
        let deviceInputs = subDevices.reduce(0) { $0 + $1.inputStreams.count }
        let tapChannels = streams.count >= deviceInputs ? Array(streams.dropFirst(deviceInputs)) : []
        return MixerRealizedAggregate(subDevices: subDevices,
                                      tapChannels: tapChannels.count == topology.taps.count ? tapChannels
                                          : Array(tapChannels.prefix(topology.taps.count)))
    }

    static func usesFloat32(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return false }
        return streams.allSatisfy { stream in
            var format = AudioStreamBasicDescription()
            return read(stream, kAudioStreamPropertyVirtualFormat, &format)
                && format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                && format.mBitsPerChannel == 32
        }
    }

    static func setStreamUsage(_ aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID,
                               realized: MixerRealizedAggregate, topology: MixerMatrixTopology) {
        func apply(scope: AudioObjectPropertyScope, flags: [Bool]) {
            guard !flags.isEmpty else { return }
            let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
                + max(flags.count - 1, 0) * MemoryLayout<UInt32>.size
            let storage = UnsafeMutableRawPointer.allocate(byteCount: size,
                                                           alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
            defer { storage.deallocate() }
            let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
            usage.pointee.mIOProc = UnsafeMutableRawPointer(unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self))
            usage.pointee.mNumberStreams = UInt32(flags.count)
            withUnsafeMutablePointer(to: &usage.pointee.mStreamIsOn) { first in
                first.withMemoryRebound(to: UInt32.self, capacity: flags.count) { list in
                    for (index, on) in flags.enumerated() { list[index] = on ? 1 : 0 }
                }
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), storage)
        }
        var inputs: [Bool] = [], outputs: [Bool] = []
        for device in realized.subDevices {
            let wanted = topology.subDevices.first { $0.uid == device.uid }
            inputs += device.inputStreams.map { _ in wanted?.readsInput == true }
            outputs += device.outputStreams.map { _ in wanted?.writesOutput == true }
        }
        inputs += realized.tapChannels.map { _ in true }
        apply(scope: kAudioObjectPropertyScopeInput, flags: inputs)
        apply(scope: kAudioObjectPropertyScopeOutput, flags: outputs)
    }
}
