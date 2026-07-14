// IR-006 (verified model installation) and IR-008 (progress observer lifetime).
// AssetInventory is behind the ModelAssetInstalling seam; no Apple framework state.

import Speech
import XCTest
@testable import Internos

@MainActor
final class OnboardingModelTests: XCTestCase {
    func testNilInstallationRequestDoesNotMarkInstalled() async {
        let store = FakeAssetStore()
        store.request = nil
        store.statusValue = .supported
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { model.modelState != .downloading }

        XCTAssertFalse(model.modelInstalled,
                       "a nil installation request is not proof of installation")
        if case .failed = model.modelState {} else {
            XCTFail("expected a visible failure, got \(model.modelState)")
        }
    }

    func testCompletedRequestWithoutInstalledStatusIsFailure() async {
        let store = FakeAssetStore()
        store.request = FakeInstallRequest() // downloadAndInstall() succeeds…
        store.statusValue = .supported       // …but the verified status never becomes .installed
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { model.modelState != .downloading }

        XCTAssertFalse(model.modelInstalled)
        if case .failed = model.modelState {} else {
            XCTFail("expected a visible failure, got \(model.modelState)")
        }
    }

    func testVerifiedInstalledStatusSucceeds() async {
        let store = FakeAssetStore()
        store.request = FakeInstallRequest()
        store.statusValue = .installed
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { model.modelState == .installed }

        XCTAssertTrue(model.modelInstalled)
        XCTAssertEqual(model.downloadProgress, 1)
        XCTAssertNil(model.progressTicker, "success must stop the progress observer")
    }

    func testUnsupportedStatusIsTerminalError() async {
        let store = FakeAssetStore()
        store.statusValue = .unsupported
        let model = OnboardingModel(store: store)

        model.refresh()
        await waitUntil { model.modelState == .unsupported }
        XCTAssertEqual(model.modelState, .unsupported)
        XCTAssertFalse(model.allDone)
    }

    func testRepeatedDownloadClicksStartOneRequest() async {
        let store = FakeAssetStore()
        let gate = Gate()
        store.request = FakeInstallRequest(gate: gate)
        store.statusValue = .installed
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { store.requestCount == 1 }
        model.downloadModel()
        model.downloadModel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.requestCount, 1, "concurrent installation attempts must be prevented")

        gate.open()
        await waitUntil { model.modelState == .installed }
    }

    func testDownloadErrorIsVisibleAndStopsProgressObserver() async {
        let store = FakeAssetStore()
        store.request = FakeInstallRequest(installError: InternosError.modelNotInstalled)
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { model.modelState != .downloading }

        if case .failed(let message) = model.modelState {
            XCTAssertFalse(message.isEmpty, "the setup window must show the failure")
        } else {
            XCTFail("expected a visible failure, got \(model.modelState)")
        }
        XCTAssertNil(model.progressTicker, "a thrown error must stop the progress observer (IR-008)")
    }

    func testStopPollingStopsProgressObserver() async {
        let store = FakeAssetStore()
        let gate = Gate()
        store.request = FakeInstallRequest(gate: gate)
        store.statusValue = .installed
        let model = OnboardingModel(store: store)

        model.downloadModel()
        await waitUntil { model.progressTicker != nil }

        model.stopPolling() // window closed mid-download
        XCTAssertNil(model.progressTicker,
                     "closing the setup window must stop progress observation")

        gate.open()
        await waitUntil { model.modelState == .installed }
    }

    func testAllDoneRequiresVerifiedInstall() {
        let model = OnboardingModel(store: FakeAssetStore())
        model.mic = .granted
        model.inputMonitoring = .granted
        model.accessibility = .granted

        model.modelState = .downloading
        XCTAssertFalse(model.allDone, "Start Dictating stays disabled until the install is verified")
        model.modelState = .installed
        XCTAssertTrue(model.allDone)
    }
}
