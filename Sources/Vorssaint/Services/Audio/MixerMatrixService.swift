// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreAudio

/// Runs app routes and the mixer matrix. It plans against what is connected
/// and what is playing, and only a change of structure (a strip, a device,
/// a tap) rebuilds the engine; gains, mutes, solo, sends, EQ and the limiter
/// reach the running callback as parameter updates without a gap.
///
/// Apps come from the volume mixer's own discovery, so there is one list of
/// audio processes, and an app the matrix takes over is left out of the
/// volume mixer's taps while its volume slider becomes a gain here.
final class MixerMatrixService: ObservableObject {
    static let shared = MixerMatrixService()

    @Published private(set) var configuration = MixerMatrixConfiguration()
    @Published private(set) var plan = MixerMatrixPlan()
    @Published private(set) var isRunning = false
    @Published private(set) var startFailed = false
    @Published private(set) var inputDevices: [MixerInventoryDevice] = []
    @Published private(set) var outputDevices: [MixerInventoryDevice] = []
    /// By strip id, refreshed only while someone watches.
    @Published private(set) var meters: [String: MixerMeterReading] = [:]

    private var engine: AnyObject?
    private var inventory = MixerInventory()
    private var subscriptions: Set<AnyCancellable> = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var reconcileScheduled = false
    private var buildGeneration = 0
    private var building = false
    private var failed: (topology: MixerMatrixTopology, at: Date)?
    private var meterTimer: Timer?
    private var meterWatchers = 0
    private var active = false
    private let buildQueue = DispatchQueue(label: "com.vorssaint.utils.mixer-matrix.build", qos: .userInitiated)
    private static let retryInterval: TimeInterval = 30

    private init() {
        configuration = MixerMatrixConfiguration.decode(
            UserDefaults.standard.data(forKey: DefaultsKey.mixerMatrixConfiguration))
    }

    static var isSupported: Bool { AppVolumeMixer.isSupported }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        let wanted = AppFeature.mixer.isAvailable && Self.isSupported && configuration.wantsEngine
        wanted ? start() : stop()
    }

    private func start() {
        if !active {
            active = true
            let mixer = AppVolumeMixer.shared
            mixer.$apps.removeDuplicates().sink { [weak self] _ in self?.scheduleReconcile() }
                .store(in: &subscriptions)
            mixer.$needsPermission.removeDuplicates().sink { [weak self] _ in self?.scheduleReconcile() }
                .store(in: &subscriptions)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleReconcile() }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main,
                                                   listener) == noErr {
                deviceListener = listener
            }
        }
        reconcile()
    }

    /// Tears the engine down; every app goes back to its own output.
    func stop() {
        guard active || engine != nil else {
            refreshDevicesForSettings()
            publishPlanWithoutEngine()
            return
        }
        active = false
        subscriptions.removeAll()
        if let deviceListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main,
                                                   deviceListener)
        }
        deviceListener = nil
        stopEngine()
        failed = nil
        publishPlanWithoutEngine()
    }

    private func stopEngine() {
        buildGeneration += 1
        building = false
        if #available(macOS 14.4, *), let running = engine as? MixerMatrixEngine { running.stop() }
        engine = nil
        isRunning = false
        AppVolumeMixer.shared.setMatrixClaimedApps([])
    }

    // MARK: - Configuration

    /// Applies an edit at once. A slider drag calls this per step, so it
    /// plans against the devices already read and saves a moment after the
    /// last change.
    func update(_ change: (inout MixerMatrixConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        schedulePersist()
        let wanted = AppFeature.mixer.isAvailable && Self.isSupported && configuration.wantsEngine
        if wanted, active {
            reconcile(refreshInventory: false)
        } else {
            syncWithPreferences()
        }
    }

    private var persistScheduled = false

    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            UserDefaults.standard.set(self.configuration.encoded, forKey: DefaultsKey.mixerMatrixConfiguration)
        }
    }

    // MARK: - Planning

    private func scheduleReconcile() {
        guard active, !reconcileScheduled else { return }
        reconcileScheduled = true
        // Device and process notifications arrive in bursts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    private func readInventory() -> MixerInventory {
        let devices = MixerMatrixHAL.devices()
        let mixer = AppVolumeMixer.shared
        var apps: [String: MixerInventoryApp] = [:]
        for app in mixer.apps where !app.isBypassed {
            guard let id = app.persistenceID else { continue }
            var entry = apps[id] ?? MixerInventoryApp(bundleID: id, name: app.name, objects: [], volume: app.volume)
            entry.objects += app.audioObjects.map { UInt32($0) }
            apps[id] = entry
        }
        return MixerInventory(devices: devices, apps: Array(apps.values), tapsSupported: Self.isSupported,
                              captureDenied: mixer.needsPermission)
    }

    private func refreshDevicesForSettings() {
        let devices = inventory.devices.isEmpty ? MixerMatrixHAL.devices() : inventory.devices
        let inputs = devices.filter { $0.inputChannels > 0 && !$0.isAggregate }
        let outputs = devices.filter { $0.outputChannels > 0 && !$0.isAggregate }
        if inputs != inputDevices { inputDevices = inputs }
        if outputs != outputDevices { outputDevices = outputs }
    }

    private func publishPlanWithoutEngine() {
        var next = MixerMatrixPlanner.plan(configuration, inventory: inventory)
        next.topology = nil
        for index in next.sources.indices where next.sources[index].state.isActive {
            next.sources[index].state = .waiting(.engineStopped)
        }
        for index in next.outputs.indices where next.outputs[index].state.isActive {
            next.outputs[index].state = .waiting(.engineStopped)
        }
        if next != plan { plan = next }
    }

    func reconcile(refreshInventory: Bool = true) {
        if refreshInventory || inventory.devices.isEmpty { inventory = readInventory() }
        refreshDevicesForSettings()
        guard active else { return }
        let next = MixerMatrixPlanner.plan(configuration, inventory: inventory)
        guard #available(macOS 14.4, *) else { return }
        let running = engine as? MixerMatrixEngine
        if let running, let topology = next.topology, running.topology == topology {
            running.update(next.values)
            publish(next, running: true)
            return
        }
        guard !building || next.topology == nil else {
            // A build in flight answers for an older plan and is dropped;
            // this plan starts once it has.
            publish(next, running: running != nil)
            return
        }
        stopEngine()
        guard let topology = next.topology else {
            publish(next, running: false)
            return
        }
        if let failed, failed.topology == topology, Date().timeIntervalSince(failed.at) < Self.retryInterval {
            startFailed = true
            publish(next, running: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                self?.scheduleReconcile()
            }
            return
        }
        building = true
        buildGeneration += 1
        let generation = buildGeneration
        let values = next.values
        publish(next, running: false)
        buildQueue.async { [weak self] in
            let result = Result { try MixerMatrixEngine(topology: topology, values: values) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.buildGeneration else {
                    if case .success(let engine) = result { engine.stop() }
                    return
                }
                self.building = false
                switch result {
                case .success(let built):
                    self.engine = built
                    self.failed = nil
                    self.startFailed = false
                    // Values may have moved on while the device was built.
                    self.reconcile()
                case .failure:
                    self.failed = (topology, Date())
                    self.startFailed = true
                    self.publish(next, running: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                        self?.scheduleReconcile()
                    }
                }
            }
        }
    }

    private func publish(_ next: MixerMatrixPlan, running: Bool) {
        var shown = next
        if !running {
            for index in shown.sources.indices where shown.sources[index].state.isActive {
                shown.sources[index].state = .waiting(.engineStopped)
            }
            for index in shown.outputs.indices where shown.outputs[index].state.isActive {
                shown.outputs[index].state = .waiting(.engineStopped)
            }
            for index in shown.routes.indices where shown.routes[index].state.isActive {
                shown.routes[index].state = .waiting(.engineStopped)
            }
        }
        if shown != plan { plan = shown }
        if running != isRunning { isRunning = running }
        AppVolumeMixer.shared.setMatrixClaimedApps(running ? next.exclusiveApps : [])
    }

    // MARK: - Meters

    /// The settings call this while the matrix is on screen; meters cost
    /// nothing otherwise.
    func beginWatchingMeters() {
        meterWatchers += 1
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.readMeters() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func endWatchingMeters() {
        meterWatchers = max(meterWatchers - 1, 0)
        guard meterWatchers == 0 else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        if !meters.isEmpty { meters = [:] }
    }

    func resetClips() {
        if #available(macOS 14.4, *), let running = engine as? MixerMatrixEngine { running.resetClips() }
    }

    private func readMeters() {
        guard #available(macOS 14.4, *), let running = engine as? MixerMatrixEngine else {
            if !meters.isEmpty { meters = [:] }
            return
        }
        let readings = running.meters()
        var next: [String: MixerMeterReading] = [:]
        for (source, reading) in zip(running.topology.sources, readings.sources) { next[source.key] = reading }
        for (output, reading) in zip(running.topology.outputs, readings.outputs) { next[output.key] = reading }
        if next != meters { meters = next }
    }
}
