import Foundation
import Testing
import UIKit
@testable import RouteLocation

struct V1_2_14UXTests {
    @Test func routeCopyDocumentPreservesRouteAndPlaybackMetadata() throws {
        let coordinates = [
            RouteCoordinate(latitude: 25.033996, longitude: 121.561216),
            RouteCoordinate(latitude: 25.040123, longitude: 121.570456),
            RouteCoordinate(latitude: 25.028765, longitude: 121.568321)
        ]
        let document = RouteCopyDocument(
            name: "臺北鐵三角",
            waypoints: coordinates,
            isClosedLoop: true,
            playbackMode: .infiniteLoop
        )

        let text = try RouteCopySerializer.serialize(document)
        let decoded = try RouteCopySerializer.deserialize(text)

        #expect(decoded == document)
        #expect(decoded.waypoints == coordinates)
        #expect(try CoordinateImportParser.parseInline(text) == coordinates)
    }

    @Test func speedTextReplacementKeepsOldValueUntilValidCommit() {
        #expect(PlaybackSpeedEntryPolicy.committedValue("42.5", preserving: 18.6) == 42.5)
        #expect(PlaybackSpeedEntryPolicy.committedValue("", preserving: 18.6) == nil)
        #expect(PlaybackSpeedEntryPolicy.committedValue("fast", preserving: 18.6) == nil)
        #expect(PlaybackSpeedEntryPolicy.committedValue("0", preserving: 18.6) == nil)
        #expect(PlaybackSpeedEntryPolicy.committedValue("-2", preserving: 18.6) == nil)
        #expect(PlaybackSpeedEntryPolicy.committedValue("301", preserving: 18.6) == nil)
    }

    @Test func selectedCandidateTakesPriorityOverActiveSinglePoint() {
        let active = RouteCoordinate(latitude: 25, longitude: 121)
        let candidate = RouteCoordinate(latitude: 35, longitude: 139)
        #expect(MapSinglePointCardPriority.coordinate(active: active, selected: candidate) == candidate)
        #expect(MapSinglePointCardPriority.coordinate(active: active, selected: active) == active)
        #expect(MapSinglePointCardPriority.coordinate(active: nil, selected: candidate) == candidate)
        #expect(MapSinglePointCardPriority.coordinate(active: active, selected: nil) == active)
    }

    @Test @MainActor func classicActiveASelectedBShowsAndRetargetsSelectedB() async {
        let active = RouteCoordinate(latitude: 25, longitude: 121)
        let candidate = RouteCoordinate(latitude: 35, longitude: 139)
        let cardCandidate = ClassicRouteMapCardSelection.selectedCandidate(active: active, selected: candidate)
        #expect(cardCandidate == candidate)

        let sink = ClassicRetargetLocationSink()
        let model = RouteLocationModel(simulationService: sink)
        model.testSetSimulationModeForTesting(.singlePoint(active))
        model.selectedCoordinate = candidate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.testTeleportCompletion = { continuation.resume() }
            model.requestSinglePointSimulation(at: cardCandidate)
        }

        #expect(model.activeSimulatedCoordinate == candidate)
        #expect(await sink.coordinatesWritten() == [candidate])
        #expect(await sink.clearCallCount() == 0)
        await model.returnToRealLocation()
    }

    @Test @MainActor func routeDraftMutationsAreRejectedUntilPlaybackStops() async throws {
        let model = RouteLocationModel(simulationService: NoopLocationSink())
        let a = RouteCoordinate(latitude: 25, longitude: 121)
        let b = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        let d = RouteCoordinate(latitude: 25.02, longitude: 121.02)
        #expect(model.addWaypoint(a))
        #expect(model.addWaypoint(b))
        let originalGeometry = model.geometry
        let originalName = model.routeName
        try await model.playback.start(
            routeName: "Snapshot",
            geometry: originalGeometry,
            speedKmh: 18.6,
            mode: .infiniteLoop
        )

        for state in [PlaybackRunState.running, .paused, .reconnecting] {
            model.testSetSimulationModeForTesting(.routePlaying)
            model.playback.testSetStateForTesting(state)
            model.statusMessage = nil
            #expect(!model.addWaypoint(d, notifyIfLocked: false))
            #expect(model.statusMessage == nil)
            #expect(!model.addWaypoint(d))
            #expect(model.statusMessage == L10n.text("路線播放中，請先停止路線再編輯。"))
            model.appendWaypoints([d])
            model.replaceWaypoints([a, d])
            model.removeWaypoints(at: IndexSet(integer: 0))
            model.moveWaypoints(from: IndexSet(integer: 0), to: 1)
            model.updateWaypoint(at: 0, latitude: 36, longitude: 140)
            model.clearWaypoints()
            model.clearCurrentDraft()
            model.isClosedLoop = false
            model.playbackMode = .finite(5)
            model.routeMode = .navigation
            model.routeName = "Mutated while playing"
            #expect(model.waypoints == [a, b])
            #expect(model.geometry == originalGeometry)
            #expect(model.isClosedLoop)
            #expect(model.playbackMode == .infiniteLoop)
            #expect(model.routeMode == .straight)
            #expect(model.routeName == originalName)
            #expect(model.playback.testRouteGeometryForTesting?.coordinates == originalGeometry.coordinates)
        }

        model.stopRoutePlayback()
        #expect(model.addWaypoint(d))
        #expect(model.waypoints == [a, b, d])
    }

    @Test @MainActor func activeSinglePointShowsSelectedCandidateAndRetargetsDirectly() async throws {
        let sink = RetargetRecordingSink()
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )
        let active = RouteCoordinate(latitude: 25, longitude: 121)
        let selected = RouteCoordinate(latitude: 35, longitude: 139)
        await model.executeTeleport(to: active)
        model.selectedCoordinate = selected

        #expect(MapSinglePointCardPriority.coordinate(active: model.activeSimulatedCoordinate, selected: model.selectedCoordinate) == selected)

        let completed = AsyncSignal()
        model.testTeleportCompletion = { Task { await completed.signal() } }
        model.requestSinglePointSimulation(at: selected)
        #expect(await completed.wait(timeout: .seconds(3)))
        #expect(model.activeSimulatedCoordinate == selected)
        #expect(await sink.clearCallCount() == 0)
        await model.returnToRealLocation()
    }

    @Test @MainActor func currentSavedRouteCanBeFavoritedAndUnfavoritedWithoutDuplicate() async throws {
        let store = RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = RouteLocationModel(persistence: store, simulationService: NoopLocationSink())
        model.addWaypoint(RouteCoordinate(latitude: 25, longitude: 121))
        model.addWaypoint(RouteCoordinate(latitude: 25.01, longitude: 121.01))
        #expect(await model.saveCurrentRoute(named: "臺北鐵三角"))
        let original = try #require(model.currentSavedRoute)

        #expect(await model.toggleFavoriteCurrentRoute())
        #expect(model.currentSavedRoute?.id == original.id)
        #expect(model.currentRouteIsFavorite)
        let routesAfterFavorite = try await store.loadRoutes()
        #expect(routesAfterFavorite.count == 1)

        #expect(await model.toggleFavoriteCurrentRoute())
        #expect(!model.currentRouteIsFavorite)
        let routesAfterUnfavorite = try await store.loadRoutes()
        #expect(routesAfterUnfavorite.count == 1)
    }

    @Test @MainActor func favoritingUnsavedPlayingRoutePersistsOneFavoriteSnapshot() async throws {
        let store = RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = RouteLocationModel(persistence: store, simulationService: NoopLocationSink())
        model.addWaypoint(RouteCoordinate(latitude: 25, longitude: 121))
        model.addWaypoint(RouteCoordinate(latitude: 25.01, longitude: 121.01))
        model.testSetSimulationModeForTesting(.routePlaying)
        model.playback.testSetStateForTesting(.running)

        #expect(!(await model.saveCurrentRoute(named: "不可編輯")))
        #expect(await model.favoriteCurrentRoute(named: "目前路線"))
        #expect(model.savedRoutes.count == 1)
        #expect(model.currentRouteIsFavorite)
        #expect(model.currentSavedRoute?.name == "目前路線")
        let persistedRoutes = try await store.loadRoutes()
        #expect(persistedRoutes.count == 1)
        #expect(persistedRoutes.first?.isFavorite == true)
        model.stopRoutePlayback()
    }

    @Test @MainActor func coordinateEntryModalUsesAVisibleSiblingPasteControlAndStableField() throws {
        let controller = CoordinateEntryModalViewController(onSubmit: { _, _ in }, onCancel: {})
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let field = controller.coordinateTextField
        let pasteControl = try #require(controller.pasteControl)
        #expect(field.rightView == nil)
        #expect(field.leftView == nil)
        #expect(field.superview === pasteControl.superview)
        #expect(controller.inputRowStack.arrangedSubviews.contains(where: { $0 === field }))
        #expect(controller.inputRowStack.arrangedSubviews.contains(where: { $0 === pasteControl }))
        #expect(field.bounds.width > 140)
        #expect(field.bounds.height >= 44)
        #expect(pasteControl.bounds.width >= 80)
        #expect(pasteControl.bounds.height >= 44)
        #expect(!pasteControl.isHidden)
        #expect(field.textColor?.isEqual(UIColor.label) == true)
        #expect(field.tintColor.isEqual(UIColor.systemBlue))
        let placeholderColor = field.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(placeholderColor?.isEqual(UIColor.placeholderText) == true)
        #expect(field.accessibilityLabel == L10n.text("座標或 Google Maps 連結"))
        #expect(pasteControl.accessibilityLabel == L10n.text("貼上座標"))
        controller.requestInitialFocus()
        #expect(controller.initialFocusWasRequested)
    }

    @Test @MainActor func coordinateEntryModalActionsEnableOnlyForValidInput() throws {
        let controller = CoordinateEntryModalViewController(onSubmit: { _, _ in }, onCancel: {})
        controller.loadViewIfNeeded()

        #expect(!controller.previewButton.isEnabled)
        #expect(!controller.simulateButton.isEnabled)

        controller.coordinateTextField.text = "not a coordinate"
        controller.coordinateTextField.sendActions(for: .editingChanged)
        #expect(!controller.previewButton.isEnabled)
        #expect(!controller.simulateButton.isEnabled)

        controller.coordinateTextField.text = "25.033964,121.564468"
        controller.coordinateTextField.sendActions(for: .editingChanged)
        #expect(controller.previewButton.isEnabled)
        #expect(controller.simulateButton.isEnabled)

        controller.coordinateTextField.text = ""
        controller.coordinateTextField.sendActions(for: .editingChanged)
        #expect(!controller.previewButton.isEnabled)
        #expect(!controller.simulateButton.isEnabled)

        controller.coordinateTextField.text = "https://maps.google.com/maps/@25.033964,121.564468,17z"
        controller.coordinateTextField.sendActions(for: .editingChanged)
        #expect(controller.previewButton.isEnabled)
        #expect(controller.simulateButton.isEnabled)
    }

    @Test @MainActor func coordinateEntryPreviewReturnsCoordinateWithoutStartingSimulation() throws {
        let expected = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        var submitted: (RouteCoordinate, Bool)?
        let controller = CoordinateEntryModalViewController(
            onSubmit: { coordinate, simulateImmediately in submitted = (coordinate, simulateImmediately) },
            onCancel: {}
        )
        controller.loadViewIfNeeded()
        controller.coordinateTextField.text = "25.033964,121.564468"
        controller.coordinateTextField.sendActions(for: .editingChanged)
        controller.previewButton.sendActions(for: .touchUpInside)

        #expect(submitted?.0 == expected)
        #expect(submitted?.1 == false)
    }

    @Test @MainActor func coordinateEntrySimulateReturnsTheParsedCoordinateForExistingSimulationPath() {
        let expected = RouteCoordinate(latitude: 25.034620, longitude: 121.562165)
        var submitted: (RouteCoordinate, Bool)?
        let controller = CoordinateEntryModalViewController(
            onSubmit: { coordinate, simulateImmediately in submitted = (coordinate, simulateImmediately) },
            onCancel: {}
        )
        controller.loadViewIfNeeded()
        controller.coordinateTextField.text = "25.034620,121.562165"
        controller.coordinateTextField.sendActions(for: .editingChanged)
        controller.simulateButton.sendActions(for: .touchUpInside)

        #expect(submitted?.0 == expected)
        #expect(submitted?.1 == true)
    }

    @Test @MainActor func coordinateEntryCancelNotifiesPresentationOwner() {
        var cancelled = false
        let controller = CoordinateEntryModalViewController(onSubmit: { _, _ in }, onCancel: { cancelled = true })
        controller.loadViewIfNeeded()
        controller.cancelButton.sendActions(for: .touchUpInside)
        #expect(cancelled)
    }

    @Test func playbackRepeatModesRoundTripAndMigrateLegacyValues() throws {
        #expect(try JSONDecoder().decode(RoutePlaybackMode.self, from: Data(#""once""#.utf8)) == .once)
        #expect(try JSONDecoder().decode(RoutePlaybackMode.self, from: Data(#""infiniteLoop""#.utf8)) == .infiniteLoop)
        let finite = RoutePlaybackMode.finite(5)
        let decoded = try JSONDecoder().decode(RoutePlaybackMode.self, from: JSONEncoder().encode(finite))
        #expect(decoded == finite)
        #expect(RoutePlaybackMode.infiniteLoop.normalized(isClosedLoop: false) == .once)
        #expect(RoutePlaybackMode.finite(5).normalized(isClosedLoop: false) == .once)
        #expect(RoutePlaybackMode.finite(0).normalized(isClosedLoop: true) == .once)
    }

    @Test func finitePlaybackMathCompletesExactlyAndReportsLaps() {
        #expect(PlaybackMath.completionDistance(total: 100, mode: .finite(3)) == 300)
        #expect(PlaybackMath.isComplete(traveled: 299.99, total: 100, mode: .finite(3)) == false)
        #expect(PlaybackMath.isComplete(traveled: 300, total: 100, mode: .finite(3)))
        #expect(PlaybackMath.lapNumber(traveled: 0, total: 100, mode: .finite(3)) == 1)
        #expect(PlaybackMath.lapNumber(traveled: 100, total: 100, mode: .finite(3)) == 2)
        #expect(PlaybackMath.lapNumber(traveled: 300, total: 100, mode: .finite(3)) == 3)
    }

    @Test @MainActor func singlePointRetargetWritesBWithoutClearingOrRestoring() async throws {
        let sink = RetargetRecordingSink()
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )
        let a = RouteCoordinate(latitude: 25, longitude: 121)
        let b = RouteCoordinate(latitude: 35, longitude: 139)
        await model.executeTeleport(to: a)
        await model.executeTeleport(to: b)
        #expect(model.activeSimulatedCoordinate == b)
        #expect(await sink.clearCallCount() == 0)
        #expect(await sink.updates().last == b)
        model.stopRoutePlayback(clearMarker: false)
    }

    @Test @MainActor func naturalOnceCompletionKeepsFinalCoordinateAsSinglePoint() async throws {
        let sink = RetargetRecordingSink()
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )
        model.playbackMode = .once
        model.testSetSimulationModeForTesting(.routePlaying)

        let final = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        model.playback.testSetStateForTesting(.completed, currentCoordinate: final)

        #expect(model.simulationMode == .singlePoint(final))
        #expect(model.activeSimulatedCoordinate == final)
        #expect(await sink.clearCallCount() == 0)
        await model.returnToRealLocation()
    }

    @Test @MainActor func naturalFiniteCompletionKeepsFinalCoordinateAsSinglePoint() async throws {
        let sink = RetargetRecordingSink()
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )
        model.playbackMode = .finite(3)
        model.testSetSimulationModeForTesting(.routePlaying)

        let final = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        model.playback.testSetStateForTesting(.completed, currentCoordinate: final)

        #expect(model.simulationMode == .singlePoint(final))
        #expect(model.activeSimulatedCoordinate == final)
        #expect(await sink.clearCallCount() == 0)
        await model.returnToRealLocation()
    }

    @Test @MainActor func latestSinglePointRetargetRequestWinsOverDelayedOlderWrite() async throws {
        let a = RouteCoordinate(latitude: 25, longitude: 121)
        let b = RouteCoordinate(latitude: 35, longitude: 139)
        let c = RouteCoordinate(latitude: 37, longitude: -122)
        let sink = DelayedRetargetSink(blockedCoordinate: b)
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )

        await model.executeTeleport(to: a)
        let delayedB = Task { @MainActor in await model.executeTeleport(to: b) }
        await sink.waitForBlockedWrite()

        let newestC = Task { @MainActor in await model.executeTeleport(to: c) }
        await newestC.value
        await sink.releaseBlockedWrite()
        await delayedB.value

        #expect(model.activeSimulatedCoordinate == c)
        #expect(model.recentLocations.first?.coordinate == c)
        #expect(!model.recentLocations.contains(where: { $0.coordinate == b }))
        await model.returnToRealLocation()
    }

    @Test @MainActor func retryAfterFailureCannotWriteStaleRetarget() async throws {
        let a = RouteCoordinate(latitude: 25, longitude: 121)
        let b = RouteCoordinate(latitude: 35, longitude: 139)
        let c = RouteCoordinate(latitude: 37, longitude: -122)
        let sink = RetryAfterFailureRetargetSink(failingCoordinate: b)
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: sink
        )
        let retryStarted = AsyncSignal()
        let retryGate = AsyncGate()
        model.testRetryDelayHandler = { delay in
            guard delay > 0 else { return }
            await retryStarted.signal()
            await retryGate.wait()
        }

        await model.executeTeleport(to: a)
        let staleB = Task { @MainActor in await model.executeTeleport(to: b) }
        #expect(await retryStarted.wait(timeout: .seconds(2)))

        await model.executeTeleport(to: c)
        await retryGate.signal()
        await staleB.value

        #expect(await sink.writeCount(for: b) == 1)
        #expect(model.activeSimulatedCoordinate == c)
        #expect(model.recentLocations.first?.coordinate == c)
        #expect(!model.recentLocations.contains(where: { $0.coordinate == b }))
        await model.returnToRealLocation()
    }

    @Test func favoriteSortPolicySupportsManualAndDistance() {
        let origin = RouteCoordinate(latitude: 25, longitude: 121)
        let near = FavoriteLocation(name: "Near", coordinate: origin)
        let far = FavoriteLocation(name: "Far", coordinate: RouteCoordinate(latitude: 35, longitude: 139))
        let values = [far, near]
        #expect(FavoriteSortPolicy.sort(values, option: .distance, manualOrder: [], deviceCoordinate: origin).first?.name == "Near")
        #expect(FavoriteSortPolicy.sort(values, option: .manual, manualOrder: [near.id, far.id], deviceCoordinate: nil).map(\.name) == ["Near", "Far"])
    }

    @Test @MainActor func favoriteCoordinateCaptureKeepsActionSource() async throws {
        let active = RouteCoordinate(latitude: 25.0, longitude: 121.0)
        let selected = RouteCoordinate(latitude: 35.0, longitude: 139.0)
        #expect(FavoriteCoordinateCapture.coordinate(for: .activeSimulation, active: active, selected: selected) == active)
        #expect(FavoriteCoordinateCapture.coordinate(for: .selectedPlace, active: active, selected: selected) == selected)
        #expect(FavoriteCoordinateCapture.coordinate(for: .activeSimulation, active: nil, selected: selected) == nil)

        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: NoopLocationSink()
        )
        let capturedActive = FavoriteCoordinateCapture.coordinate(for: .activeSimulation, active: active, selected: selected)
        let capturedSelected = FavoriteCoordinateCapture.coordinate(for: .selectedPlace, active: active, selected: selected)
        await model.addFavorite(name: "Active", coordinate: capturedActive)
        await model.addFavorite(name: "Selected", coordinate: capturedSelected)
        #expect(model.favorites.map(\.coordinate) == [active, selected])
    }

    @Test func playbackSpeedPolicyClampsAndStepsByPointOne() {
        #expect(abs(PlaybackSpeedPolicy.adjusted(18.6, by: 0.1) - 18.7) < 0.000001)
        #expect(abs(PlaybackSpeedPolicy.adjusted(18.6, by: -0.1) - 18.5) < 0.000001)
        #expect(PlaybackSpeedPolicy.clamp(-4) == 0.1)
        #expect(PlaybackSpeedPolicy.clamp(999) == 300.0)
    }

    @Test func countryFlagsUseGenericIsoConversion() {
        #expect(CountryFlagFormatter.flag(for: "TW") == "🇹🇼")
        #expect(CountryFlagFormatter.flag(for: "jp") == "🇯🇵")
        #expect(CountryFlagFormatter.flag(for: "US") == "🇺🇸")
        #expect(CountryFlagFormatter.flag(for: "XXX") == nil)
        #expect(CountryFlagFormatter.flag(for: "?") == nil)
    }

    @Test func libraryDisplayDensityHasStablePersistenceValues() {
        #expect(LibraryDisplayDensity.preferenceKey == "RouteLocation.libraryDisplayDensity")
        #expect(LibraryDisplayDensity(rawValue: "compact") == .compact)
        #expect(LibraryDisplayDensity(rawValue: "detailed") == .detailed)
        #expect(LibraryDisplayDensity(rawValue: "other") == nil)
    }

    @Test func bottomCardSnapsOnlyToFixedDetents() {
        var state = MapBottomCardExpansion.collapsed
        state.snap(for: -80)
        #expect(state == .expanded)
        state.snap(for: 80)
        #expect(state == .collapsed)
        state.snap(for: 10)
        #expect(state == .collapsed)
    }

    @Test @MainActor func deletingOneRecentLocationDoesNotTouchFavorites() async throws {
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            simulationService: NoopLocationSink()
        )
        let first = RouteCoordinate(latitude: 25, longitude: 121)
        let second = RouteCoordinate(latitude: 26, longitude: 122)
        await model.recordRecent(coordinate: first)
        await model.recordRecent(coordinate: second)
        let favoriteCount = model.favorites.count
        let target = try #require(model.recentLocations.first)
        await model.deleteRecentLocation(target)
        #expect(model.recentLocations.count == 1)
        #expect(model.recentLocations.first?.coordinate == first)
        #expect(model.favorites.count == favoriteCount)
    }

    @Test @MainActor func clearingRecentLocationsDoesNotTouchFavorites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = RouteLocationModel(
            persistence: RoutePersistenceStore(rootURL: root),
            simulationService: NoopLocationSink()
        )
        let favoriteCoordinate = RouteCoordinate(latitude: 25, longitude: 121)
        let recentCoordinate = RouteCoordinate(latitude: 26, longitude: 122)
        await model.addFavorite(name: "Favorite", coordinate: favoriteCoordinate)
        await model.recordRecent(coordinate: recentCoordinate)
        await model.clearRecentLocations()
        #expect(model.recentLocations.isEmpty)
        #expect(model.favorites.count == 1)
        let loadedRecent = try await RoutePersistenceStore(rootURL: root).loadRecentLocations()
        #expect(loadedRecent.isEmpty)
    }

    @Test @MainActor func recentFavoriteActionIsIdempotentAndManualOrderIsStable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = RouteLocationModel(persistence: RoutePersistenceStore(rootURL: root), simulationService: NoopLocationSink())
        let coordinate = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        await model.addFavoriteIfNeeded(name: "捷徑位置", coordinate: coordinate)
        await model.addFavoriteIfNeeded(name: "捷徑位置", coordinate: coordinate)
        #expect(model.favorites.count == 1)
        let ids = model.favorites.map(\.id)
        model.setManualFavoriteOrder(ids)
        #expect(model.sortedFavorites.map(\.id) == ids)
        let loaded = try await RoutePersistenceStore(rootURL: root).loadFavorites()
        #expect(loaded.count == 1)
    }

    @Test func uniqueNamesUseIndependentSuffixesAndNormalizeWhitespace() {
        #expect(UniqueNameGenerator.makeUnique(base: " 新地點 ", existing: ["新地點", "新地點1", "新地點2"], fallback: "新地點") == "新地點3")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司", "公司1"], fallback: "新地點") == "公司2")
        #expect(UniqueNameGenerator.makeUnique(base: "公司", existing: ["公司11"], fallback: "新地點") == "公司")
        #expect(UniqueNameGenerator.makeUnique(base: "", existing: ["新路線"], fallback: "新路線") == "新路線1")
    }

    @Test func parserAcceptsLabeledAndGoogleMapsCoordinates() throws {
        #expect(try CoordinateImportParser.parseInline("latitude=25.033964 longitude=121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("https://maps.google.com/maps/@25.033964,121.564468,17z").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(try CoordinateImportParser.parseInline("25.033964 121.564468").first == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
    }

    @Test func coordinateAlertValidationEnablesOnlyValidInput() {
        #expect(CoordinateAlertInputValidation.coordinate(in: "") == nil)
        #expect(CoordinateAlertInputValidation.coordinate(in: "not a coordinate") == nil)
        #expect(CoordinateAlertInputValidation.coordinate(in: "25.033964,121.564468") == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
        #expect(CoordinateAlertInputValidation.coordinate(in: "https://maps.google.com/maps/@25.033964,121.564468,17z") == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
    }

    @Test func timezoneComparisonUsesTaiwanBaseline() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let taipeiText = PlaceTimeFormatter.offsetText(for: taipei)
        #expect(taipeiText == "與台灣時間相同" || taipeiText == "Same as Taiwan time")
        let tokyoText = PlaceTimeFormatter.offsetText(for: tokyo)
        #expect(tokyoText.contains("快") || tokyoText.contains("ahead"))
    }

    @Test func routeAppendPreservesExistingWaypoints() {
        let first = RouteCoordinate(latitude: 25, longitude: 121)
        let second = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        var values = [first]
        values.append(contentsOf: [second, second])
        #expect(values.count == 3)
    }

    @Test func stalePreparedRecoveryIsDistinctFromColdStartEvidence() {
        #expect(AssistedBootstrapReason.coldStart.usesRecentSuccessEvidence)
        #expect(!AssistedBootstrapReason.stalePreparedSessionRecovery.usesRecentSuccessEvidence)
        #expect(!AssistedBootstrapReason.playbackFailureRecovery.usesRecentSuccessEvidence)
        #expect(PreparedSessionRecoveryPolicy.shouldForceAssistedRecovery(
            preparedSession: true, transport: .cellular, wifiAvailable: false, shortcutAssistedEnabled: true
        ))
        #expect(!PreparedSessionRecoveryPolicy.shouldForceAssistedRecovery(
            preparedSession: true, transport: .cellular, wifiAvailable: true, shortcutAssistedEnabled: true
        ))
    }

    @Test @MainActor func confirmedStaleSessionInvalidatesOnlyRecentSuccessEvidence() {
        let health = LocationDataPathHealth.shared
        health.resetForTesting()
        health.recordSuccess()
        #expect(health.hasRecentSuccess)
        health.invalidateAfterConfirmedStaleSessionFailure(LocationSimulationError.deviceTunnelUnavailable)
        #expect(!health.hasRecentSuccess)
        #expect(health.status == .failed)
        health.resetForTesting()
    }

    @Test func timezoneBaselineChangesComparisonWording() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .taiwan).contains("台灣") ||
                PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .taiwan).contains("Taiwan"))
        #expect(PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .device).contains("目前") ||
                PlaceTimeFormatter.offsetText(for: tokyo, at: date, baseline: .device).contains("current"))
    }

    @Test func resolverSharesSameKeyAndSerializesDifferentKeys() async {
        let client = TestPlaceGeocodingClient()
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        let first = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let second = RouteCoordinate(latitude: 35.689487, longitude: 139.691711)
        async let firstValue = resolver.resolve(first, debounceNanoseconds: 0)
        async let firstDuplicate = resolver.resolve(first, debounceNanoseconds: 0)
        async let secondValue = resolver.resolve(second, debounceNanoseconds: 0)
        _ = await (firstValue, firstDuplicate, secondValue)
        #expect(await client.maximumConcurrentRequests() == 1)
        #expect(await client.requestCount() == 2)
    }

    @Test func selectedResolverRequestCanBeSuperseded() async {
        let client = TestPlaceGeocodingClient(blockRequests: true)
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        let first = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let second = RouteCoordinate(latitude: 35.689487, longitude: 139.691711)
        let firstTask = Task { await resolver.resolve(first, debounceNanoseconds: 0, scope: .selected) }
        await client.waitUntilStarted()
        let secondTask = Task { await resolver.resolve(second, debounceNanoseconds: 0, scope: .selected) }
        await client.releaseAll()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await client.requestCount() == 2)
    }

    @Test func placeInfoFailureIsSilentFallback() async {
        let client = TestPlaceGeocodingClient(shouldFail: true)
        let resolver = PlaceInfoResolver(
            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            geocoder: client
        )
        #expect(await resolver.resolve(RouteCoordinate(latitude: 25, longitude: 121), debounceNanoseconds: 0) == nil)
    }

    @Test @MainActor func routeFavoriteActionPersistsDraftWithoutDuplicateCopy() async {
        let store = RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = RouteLocationModel(persistence: store, simulationService: NoopLocationSink())
        model.addWaypoint(RouteCoordinate(latitude: 25, longitude: 121))
        model.addWaypoint(RouteCoordinate(latitude: 25.01, longitude: 121.01))
        #expect(model.suggestedFavoriteRouteName() == "新路線")
        #expect(await model.favoriteCurrentRoute(named: "新路線"))
        #expect(model.favoriteRoutes.count == 1)
        #expect(model.savedRoutes.count == 1)
        #expect(model.favoriteRoutes.first?.isFavorite == true)
    }

    @Test @MainActor func existingRouteFavoritePreservesNameAndID() async throws {
        let store = RoutePersistenceStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = RouteLocationModel(persistence: store, simulationService: NoopLocationSink())
        model.addWaypoint(RouteCoordinate(latitude: 25, longitude: 121))
        model.addWaypoint(RouteCoordinate(latitude: 25.01, longitude: 121.01))
        #expect(await model.saveCurrentRoute(named: "回家"))
        let original = try #require(model.savedRoutes.first)
        #expect(model.suggestedFavoriteRouteName() == "回家")
        #expect(await model.favoriteCurrentRoute(named: model.suggestedFavoriteRouteName()))
        #expect(model.savedRoutes.count == 1)
        #expect(model.favoriteRoutes.first?.id == original.id)
        #expect(model.favoriteRoutes.first?.name == "回家")

        #expect(await model.favoriteCurrentRoute(named: "新名稱"))
        #expect(model.savedRoutes.count == 1)
        #expect(model.favoriteRoutes.first?.id == original.id)
        #expect(model.favoriteRoutes.first?.name == "新名稱")
    }

    @Test @MainActor func userStopRoutePlaybackIsTerminalAcrossMapStyles() {
        let model = RouteLocationModel(simulationService: NoopLocationSink())
        for style in MapInteractionStyle.allCases {
            model.mapInteractionStyle = style
            model.playback.testSetStateForTesting(.reconnecting)
            model.showPlaybackRecoveryConsent = true
            model.stopRoutePlayback()
            #expect(model.playback.state == PlaybackRunState.stopped)
            #expect(!model.showPlaybackRecoveryConsent)
        }
    }

    @Test func timezoneOffsetFormatterPreservesFractionalOffsets() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlaceTimeFormatter.gmtOffsetText(for: TimeZone(identifier: "Asia/Taipei")!, at: date) == "GMT+8")
        #expect(PlaceTimeFormatter.gmtOffsetText(for: TimeZone(identifier: "Asia/Tokyo")!, at: date) == "GMT+9")
        #expect(PlaceTimeFormatter.gmtOffsetText(for: TimeZone(identifier: "Asia/Kolkata")!, at: date) == "GMT+5:30")
        #expect(PlaceTimeFormatter.gmtOffsetText(for: TimeZone(identifier: "Asia/Kathmandu")!, at: date) == "GMT+5:45")
        #expect(PlaceTimeFormatter.gmtOffsetText(for: TimeZone(identifier: "America/St_Johns")!, at: Date(timeIntervalSince1970: 1_704_067_200)) == "GMT-3:30")
    }

    @Test func timezoneOffsetFormatterUsesSuppliedDateForDST() {
        let zone = TimeZone(identifier: "America/New_York")!
        let winter = Date(timeIntervalSince1970: 1_704_067_200)
        let summer = Date(timeIntervalSince1970: 1_720_000_000)
        #expect(PlaceTimeFormatter.gmtOffsetText(for: zone, at: winter) == "GMT-5")
        #expect(PlaceTimeFormatter.gmtOffsetText(for: zone, at: summer) == "GMT-4")
    }

    @Test @MainActor func stopInvalidatesInFlightPlaybackRecovery() async throws {
        let sink = FailingSequenceSink()
        await sink.configureFailures([2, 3, 4, 5, 6])
        let gate = AsyncGate()
        let clock = TestUptimeBox()
        let geometry = RouteGeometry(coordinates: [
            RouteCoordinate(latitude: 0, longitude: 0),
            RouteCoordinate(latitude: 0, longitude: 0.01)
        ])
        let monitor = ConnectionMonitor.shared
        defer { monitor.resetForTesting() }
        monitor.updateForTesting(transport: NetworkTransport.cellular, isWifiAvailable: false, isCellularAvailable: true, deviceSession: DeviceSessionStatus.idle)
        let engine = RoutePlaybackEngine(
            sink: sink, connectionMonitor: monitor, updateInterval: 60, uptime: { clock.get() },
            acquireKeepAlive: {}, releaseKeepAlive: {}, reconnectAction: {},
            reconnectDelays: [0], transportDebounce: 0
        )
        let started = AsyncSignal()
        engine.assistedRecoveryAction = { (_: RouteCoordinate?) in
            await started.signal()
            await gate.wait()
            return true
        }
        try await engine.start(routeName: "Cancel", geometry: geometry, speedKmh: 18.6, mode: RoutePlaybackMode.once)
        clock.set(10)
        await engine.verifyConnectionAfterTransportChange()
        await engine.verifyConnectionAfterTransportChange()
        let recoveryTask = Task { await engine.verifyConnectionAfterTransportChange() }
        await started.wait()
        engine.stop()
        await gate.signal()
        await recoveryTask.value
        #expect(engine.state == PlaybackRunState.stopped)
    }
}

private final class TestUptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func get() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor RetargetRecordingSink: LocationSimulationSink {
    private var values: [RouteCoordinate] = []
    private var clears = 0

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        values.append(coordinate)
    }

    func clearSimulatedLocation() async throws {
        clears += 1
    }

    func updates() -> [RouteCoordinate] { values }
    func clearCallCount() -> Int { clears }
}

private actor DelayedRetargetSink: LocationSimulationSink {
    private let blockedCoordinate: RouteCoordinate
    private let started = AsyncSignal()
    private let release = AsyncGate()
    private var values: [RouteCoordinate] = []

    init(blockedCoordinate: RouteCoordinate) {
        self.blockedCoordinate = blockedCoordinate
    }

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        values.append(coordinate)
        guard coordinate == blockedCoordinate else { return }
        await started.signal()
        await release.wait()
    }

    func clearSimulatedLocation() async throws {}

    func waitForBlockedWrite() async { await started.wait() }
    func releaseBlockedWrite() async { await release.signal() }
}

private actor RetryAfterFailureRetargetSink: LocationSimulationSink {
    private let failingCoordinate: RouteCoordinate
    private var writes: [RouteCoordinate: Int] = [:]

    init(failingCoordinate: RouteCoordinate) {
        self.failingCoordinate = failingCoordinate
    }

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        writes[coordinate, default: 0] += 1
        if coordinate == failingCoordinate, writes[coordinate] == 1 {
            throw LocationSimulationError.updateFailure(code: 901)
        }
    }

    func clearSimulatedLocation() async throws {}

    func writeCount(for coordinate: RouteCoordinate) -> Int {
        writes[coordinate, default: 0]
    }
}

private actor TestPlaceGeocodingClient: PlaceGeocodingClient {
    private let shouldFail: Bool
    private let blockRequests: Bool
    private var requests = 0
    private var active = 0
    private var maximumActive = 0
    private var startedCount = 0
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(shouldFail: Bool = false, blockRequests: Bool = false) {
        self.shouldFail = shouldFail
        self.blockRequests = blockRequests
    }

    func reverseGeocode(_ coordinate: RouteCoordinate) async throws -> PlaceGeocodingResult? {
        requests += 1
        active += 1
        maximumActive = max(maximumActive, active)
        startedCount += 1
        startedContinuation?.resume()
        startedContinuation = nil
        if blockRequests && !released {
            await withCheckedContinuation { continuation in releaseContinuation = continuation }
        }
        active -= 1
        if shouldFail { throw NSError(domain: "test", code: 1) }
        return PlaceGeocodingResult(
            displayName: "Test",
            country: "Taiwan",
            countryCode: "TW",
            administrativeArea: "Taipei",
            locality: "Taipei",
            subLocality: "Xinyi",
            timeZoneIdentifier: "Asia/Taipei"
        )
    }

    func requestCount() -> Int { requests }
    func maximumConcurrentRequests() -> Int { maximumActive }
    func waitUntilStarted() async {
        if startedCount > 0 { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func releaseAll() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    private var streamWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
        streamWaiters.values.forEach { _ = $0.yield(()) }
        streamWaiters.removeAll()
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func wait(timeout: Duration) async -> Bool {
        if signaled { return true }
        let id = UUID()
        let (stream, streamContinuation) = AsyncStream<Void>.makeStream()
        streamWaiters[id] = streamContinuation
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        streamContinuation.finish()
        streamWaiters.removeValue(forKey: id)
        return result
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor NoopLocationSink: LocationSimulationSink {
    func setCoordinate(_ coordinate: RouteCoordinate) async throws {}
    func clearSimulatedLocation() async throws {}
}

private actor ClassicRetargetLocationSink: LocationSimulationSink {
    private var coordinates: [RouteCoordinate] = []
    private var clearCalls = 0

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        coordinates.append(coordinate)
    }

    func clearSimulatedLocation() async throws {
        clearCalls += 1
    }

    func coordinatesWritten() -> [RouteCoordinate] { coordinates }
    func clearCallCount() -> Int { clearCalls }
}

private actor FailingSequenceSink: LocationSimulationSink {
    private var call = 0
    private var failures: Set<Int> = []

    func configureFailures(_ values: [Int]) { failures = Set(values) }

    func setCoordinate(_ coordinate: RouteCoordinate) async throws {
        call += 1
        if failures.contains(call) { throw LocationSimulationError.updateFailure(code: Int32(call)) }
    }

    func clearSimulatedLocation() async throws {}
}
