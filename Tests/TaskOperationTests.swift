import Combine
import Foundation
import Observation

@main struct TaskOperationTests {
    @MainActor static func main() async {
        var failures = 0
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition {
                failures += 1
                print("FAIL: \(message)")
            }
        }
        func waitFor(_ gate: Gate) async {
            for _ in 0..<10000 {
                if gate.entered { return }
                await Task.yield()
            }
            fatalError("Gate was not reached")
        }
        let starts: [(String, @MainActor (MAAViewModel) async throws -> Void)] = [
            ("Copilot", { try await $0.startCopilot(type: .Copilot, params: "{}") }),
            ("Recruit", { try await $0.recognizeRecruit() }),
            ("Depot", { try await $0.recognizeDepot() }),
            ("Video", { try await $0.recognizeVideo(video: URL(filePath: "/fixture.mp4")) }),
            ("OperBox", { try await $0.recognizeOperBox() }),
            ("Gacha", { try await $0.gachaPoll(once: true) }),
            ("MiniGame", { try await $0.miniGame(name: "Fixture") }),
        ]

        // Review 1: a busy core must not be touched or have its visible status reset.
        for (name, start) in starts {
            let model = MAAViewModel()
            let dailyStarted = await model.tryStartTasks()
            check(dailyStarted, "fixture daily startup succeeds")
            var rejected = false
            do { try await start(model) } catch { rejected = true }
            check(rejected, "\(name) reports rejection while daily core is running")
            check(model.status == .busy, "\(name) preserves busy UI on rejection")
            check(model.ensureCount == 1, "\(name) rejects before touching handle")
            check(model.handle?.appendCount == 0, "\(name) appends nothing to busy core")
        }

        // Review 2/4: callback exposes idle while connection is still suspended.
        do {
            let model = MAAViewModel()
            let gate = Gate()
            model.connectionGate = gate
            let startup = Task { await model.tryStartTasks() }
            await waitFor(gate)
            model.reportIdleCallback()
            check(model.menuStartDisabled, "menu disabled while idle callback overlaps startup")
            let duplicate = await model.tryStartTasks()
            check(!duplicate, "duplicate daily start rejected during connection")
            var stopRejected = false
            do { try await model.stop() } catch { stopRejected = true }
            check(stopRejected, "stop during startup reports explicit rejection")
            check(!model.errors.isEmpty, "stop rejection emits user-facing log")
            for (name, start) in starts.prefix(4) {
                var rejected = false
                do { try await start(model) } catch { rejected = true }
                check(rejected, "\(name) reports in-flight rejection")
                check(model.status == .idle, "\(name) does not change callback status on rejection")
            }
            gate.release()
            let started = await startup.value
            check(started, "original startup still completes")
            check(!model.operationInFlightForTest, "startup releases operation flag")
            model.connectionGate = nil
            try! await model.stop()
            check(model.status == .idle && model.handle?.isRunning == false, "retry stop actually stops core")
            check(!model.menuStartDisabled, "menu reenabled after settled stop")
        }

        // Review 3: neither invalid config, rejected start nor failed start changes the token.
        do {
            let model = MAAViewModel()
            let bridge = NewViewModel(parent: model)
            bridge.copilot.content = .invalid
            try! await bridge.startCopilot()
            check(bridge.copilotStartToken == nil, "invalid Copilot leaves token unchanged")
            bridge.copilot.content = .copilot(URL(filePath: "/fixture.json"), .regular, false)
            model.failConnection = true
            do { try await bridge.startCopilot() } catch {}
            check(bridge.copilotStartToken == nil, "failed Copilot leaves token unchanged")
            model.failConnection = false
            let gate = Gate()
            model.connectionGate = gate
            let task = Task { try await bridge.startCopilot() }
            await waitFor(gate)
            check(bridge.copilotStartToken == nil, "pending Copilot does not announce success")
            gate.release()
            try! await task.value
            let token = bridge.copilotStartToken
            check(token != nil, "successful Copilot emits token")
            do { try await bridge.startCopilot() } catch {}
            check(bridge.copilotStartToken == token, "busy Copilot preserves prior token")
        }

        // Every throwing path must release ownership; retry must succeed.
        for (name, start) in starts {
            let model = MAAViewModel()
            model.failConnection = true
            do { try await start(model) } catch {}
            check(!model.operationInFlightForTest, "\(name) releases flag on connection error")
            check(model.status == .idle, "\(name) restores idle on connection error")
            model.failConnection = false
            do { try await start(model) } catch { check(false, "\(name) retry failed: \(error)") }
            check(model.status == .busy, "\(name) retry succeeds")
        }

        // Stop suspension, callback reentrancy, stop failure and duplicate stop.
        do {
            let model = MAAViewModel()
            _ = await model.tryStartTasks()
            let gate = Gate()
            model.handle?.stopGate = gate
            let stopping = Task { try await model.stop() }
            await waitFor(gate)
            model.reportIdleCallback()
            check(model.menuStartDisabled, "menu disabled until stop returns despite idle callback")
            var rejected = false
            do { try await model.stop() } catch { rejected = true }
            check(rejected, "duplicate stop reports conflict")
            check(model.handle?.stopCount == 1, "duplicate stop does not reach core")
            gate.release()
            try! await stopping.value
            check(!model.operationInFlightForTest && !model.menuStartDisabled, "stop releases flag and menu")
            model.handle?.stopGate = nil
            _ = await model.tryStartTasks()
            model.handle?.failStop = true
            do { try await model.stop() } catch {}
            check(
                !model.operationInFlightForTest && model.status == .busy, "failed stop restores busy and releases flag")
        }
        #if TASK_OPERATION_OBSERVATION
        // No status publication occurs on this release: only the operation flag changes.
        do {
            let model = MAAViewModel()
            let bridge = NewViewModel(parent: model)
            let gate = Gate()
            model.connectionGate = gate
            model.failConnection = true
            let startup = Task { await model.tryStartTasks() }
            await waitFor(gate)
            model.reportIdleCallback()
            check(!bridge.canStartTasks, "Copilot bridge remains disabled during idle callback")
            let flag = ObservationFlag()
            withObservationTracking {
                _ = bridge.canStartTasks
            } onChange: {
                flag.set()
            }
            gate.release()
            let started = await startup.value
            check(!started, "daily startup reports connection failure")
            check(bridge.canStartTasks, "bridge reenabled after failed startup settles")
            check(flag.isSet, "operation-only release invalidates observed Copilot availability")
        }
        // All same-core utility entries hold the flag while their own connection awaits.
        for (name, start) in starts {
            let model = MAAViewModel()
            let gate = Gate()
            model.connectionGate = gate
            let task = Task { try await start(model) }
            await waitFor(gate)
            model.reportIdleCallback()
            check(model.operationInFlightForTest, "\(name) holds flag across connection await")
            check(model.menuStartDisabled, "\(name) keeps menu disabled across callback")
            let duplicate = await model.tryStartTasks()
            check(!duplicate, "\(name) blocks interleaved daily startup")
            gate.release()
            try! await task.value
            check(model.status == .busy && !model.operationInFlightForTest, "\(name) settles busy and releases flag")
        }
        // A core-start error must also release the flag, and must not emit Copilot success.
        do {
            let model = MAAViewModel()
            let bridge = NewViewModel(parent: model)
            model.handle?.failStart = true
            do { try await bridge.startCopilot() } catch {}
            check(bridge.copilotStartToken == nil, "core start failure emits no token")
            check(!model.operationInFlightForTest && model.status == .idle, "core start failure releases ownership")
        }
        #endif
        // Review 4410030637: the UI can report idle after ownership is released
        // even though the core is still running. Reject before publishing pending.
        for (name, start) in starts {
            let model = MAAViewModel()
            _ = await model.tryStartTasks()
            model.reportIdleCallback()
            let count = model.ensureCount
            var states = [MAAViewModel.Status]()
            let subscription = model.$status.sink { states.append($0) }
            var rejected = false
            do { try await start(model) } catch { rejected = true }
            check(rejected, "\(name) rejects running core despite idle callback")
            check(model.status == .busy, "\(name) reconciles idle UI to running core")
            check(model.menuStartDisabled, "\(name) disables start after running-core rejection")
            check(!states.contains(.pending), "\(name) rejects running core before publishing pending")
            check(model.ensureCount == count, "\(name) checks running core before ensureHandle")
            check(model.handle?.appendCount == 0, "\(name) never appends to running core")
            check(!model.operationInFlightForTest, "\(name) releases reservation on running-core rejection")
            withExtendedLifetime(subscription) {}
            try! await model.stop()
            do { try await start(model) } catch { check(false, "\(name) retry after stop failed") }
            check(model.status == .busy, "\(name) can start again after core stops")
        }
        do {
            let model = MAAViewModel()
            _ = await model.tryStartTasks()
            model.reportIdleCallback()
            let count = model.ensureCount
            var states = [MAAViewModel.Status]()
            let subscription = model.$status.sink { states.append($0) }
            let started = await model.tryStartTasks()
            check(!started, "Daily rejects running core despite idle callback")
            check(model.status == .busy, "Daily reconciles idle UI to running core")
            check(model.menuStartDisabled, "Daily disables start after running-core rejection")
            check(!states.contains(.pending), "Daily rejects before publishing pending")
            check(model.ensureCount == count, "Daily checks running core before ensureHandle")
            check(!model.operationInFlightForTest, "Daily releases rejected reservation")
            withExtendedLifetime(subscription) {}
        }
        #if CORE_RUNNING_PREFLIGHT
        // Each entry must reserve ownership before the new core-state await.
        let allStarts =
            [
                (
                    "Daily",
                    { @MainActor (model: MAAViewModel) async throws in
                        if !(await model.tryStartTasks()) { throw FixtureError.connection }
                    }
                )
            ] + starts
        for (name, start) in allStarts {
            let model = MAAViewModel()
            let gate = Gate()
            model.handle?.runningGate = gate
            let startup = Task { try await start(model) }
            await waitFor(gate)
            check(model.status == .idle, "\(name) checks core before publishing pending")
            check(model.operationInFlightForTest && model.menuStartDisabled, "\(name) reserves across core-state await")
            let duplicate = await model.tryStartTasks()
            check(!duplicate, "\(name) blocks duplicate during core-state await")
            var stopRejected = false
            do { try await model.stop() } catch { stopRejected = true }
            check(stopRejected && model.handle?.stopCount == 0, "\(name) blocks stop during core-state await")
            gate.release()
            try! await startup.value
            check(model.status == .busy && !model.operationInFlightForTest, "\(name) transfers and releases ownership")
        }
        // Core running changes during the probe: rejection still releases ownership.
        do {
            let model = MAAViewModel()
            let gate = Gate()
            model.handle?.runningGate = gate
            let startup = Task { try await model.recognizeDepot() }
            await waitFor(gate)
            model.handle?.isRunning = true
            gate.release()
            var rejected = false
            do { try await startup.value } catch { rejected = true }
            check(rejected && model.status == .busy, "running result restores busy UI after suspended probe")
            check(
                !model.operationInFlightForTest && model.ensureCount == 0,
                "rejected probe releases ownership without preparing core")
        }
        // An idle core can still receive a state callback while queried.
        do {
            let model = MAAViewModel()
            let gate = Gate()
            model.handle?.runningGate = gate
            let startup = Task { try await model.recognizeDepot() }
            await waitFor(gate)
            model.reportBusyCallback()
            gate.release()
            var rejected = false
            do { try await startup.value } catch { rejected = true }
            check(
                rejected && model.status == .busy && model.ensureCount == 0,
                "admission rechecks status after awaiting core")
            check(!model.operationInFlightForTest, "status-change rejection releases reservation")
        }
        // Cancellation at the newly introduced suspension cannot leak the reservation.
        do {
            let model = MAAViewModel()
            let gate = Gate()
            model.handle?.runningGate = gate
            let startup = Task { try await model.recognizeDepot() }
            await waitFor(gate)
            startup.cancel()
            gate.release()
            var cancelled = false
            do { try await startup.value } catch is CancellationError { cancelled = true } catch {}
            check(cancelled && !model.operationInFlightForTest, "cancelled probe releases ownership")
            check(model.status == .idle && model.ensureCount == 0, "cancelled probe never prepares or starts core")
        }
        // Defensive ensureHandle rejection must also preserve busy if core changes later.
        for (name, start) in allStarts {
            let model = MAAViewModel()
            model.makeCoreBusyDuringEnsure = true
            do { try await start(model) } catch {}
            check(
                model.status == .busy && model.menuStartDisabled,
                "\(name) preserves busy on late running-core rejection")
            check(
                !model.operationInFlightForTest && model.handle?.appendCount == 0,
                "\(name) releases ownership without appending after late rejection")
        }
        // A first launch without a handle must still be admitted.
        do {
            let model = MAAViewModel()
            model.handle = nil
            let started = await model.tryStartTasks()
            check(started && model.status == .busy, "first launch without a handle still starts")
            check(!model.operationInFlightForTest, "first launch releases ownership")
        }
        #endif
        print("\(assertions) assertions; \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
