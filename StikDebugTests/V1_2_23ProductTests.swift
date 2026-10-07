import Foundation
import Testing
@testable import RouteLocation

struct V1_2_23MapAndRoutePolicyTests {
    @Test func mapTapDoesNotRequestCameraRecenterButIntentionalFocusDoes() {
        #expect(!MapCameraActionPolicy.shouldRecenter(for: .mapTapSelection))
        #expect(MapCameraActionPolicy.shouldRecenter(for: .intentionalNavigation))
    }

    @Test func routeMapTapKeepsFastSingleAndRouteActionsButIgnoresPlaybackGestures() {
        #expect(MapTapRoutePolicy.action(mode: .singlePoint, routeIsActive: false) == .selectPlace)
        #expect(MapTapRoutePolicy.action(mode: .route, routeIsActive: false) == .addWaypoint)
        #expect(MapTapRoutePolicy.action(mode: .route, routeIsActive: true) == .ignoreWhileRouteActive)
        #expect(MapTapRoutePolicy.action(mode: .singlePoint, routeIsActive: true) == .ignoreWhileRouteActive)
    }

    @Test func singleModeKeepsDraftBadgeWithoutShowingDraftGeometry() {
        #expect(!RouteMapOverlayPolicy.shouldShowRouteGeometry(mode: .singlePoint, hasPreview: false, routeIsActive: false))
        #expect(RouteMapOverlayPolicy.shouldShowRouteGeometry(mode: .route, hasPreview: false, routeIsActive: false))
        #expect(RouteMapOverlayPolicy.shouldShowRouteGeometry(mode: .singlePoint, hasPreview: true, routeIsActive: false))
        #expect(RouteMapOverlayPolicy.shouldShowRouteGeometry(mode: .singlePoint, hasPreview: false, routeIsActive: true))
        #expect(RoutePlanningControlsPolicy.shouldShow(mode: .route, hasPreview: false, routeIsActive: false))
        #expect(!RoutePlanningControlsPolicy.shouldShow(mode: .route, hasPreview: true, routeIsActive: false))
        #expect(!RoutePlanningControlsPolicy.shouldShow(mode: .singlePoint, hasPreview: false, routeIsActive: false))
        #expect(!RoutePlanningControlsPolicy.shouldShow(mode: .route, hasPreview: false, routeIsActive: true))
    }

    @Test func multiCoordinatePasteRequiresAnExplicitChoiceOnlyWhenDraftExists() {
        #expect(MultiCoordinatePastePolicy.requiresChoice(existingDraftCount: 0) == false)
        #expect(MultiCoordinatePastePolicy.requiresChoice(existingDraftCount: 3))
        #expect(MultiCoordinatePasteDecision.allCases == [.replace, .append, .cancel])
    }

    @Test func importedRouteUsesValidatedLocalStraightGeometryAndUniqueName() throws {
        let points = [
            RouteCoordinate(latitude: 25.033964, longitude: 121.564468),
            RouteCoordinate(latitude: 25.040000, longitude: 121.570000)
        ]
        let route = try #require(ImportedSavedRouteFactory.make(
            coordinates: points,
            requestedName: "Pasted Route",
            existingNames: ["Pasted Route"],
            speedKmh: 18.6,
            now: Date(timeIntervalSince1970: 1_000)
        ))
        #expect(route.name != "Pasted Route")
        #expect(route.routeMode == .straight)
        #expect(route.waypoints == points)
        #expect(route.resolvedGeometry.coordinates == points + [points[0]])
        #expect(route.totalDistance > 0)
        #expect(route.lastUsedAt == nil)
    }

    @Test func importedRouteRejectsInvalidOrInsufficientCoordinatesAtomically() {
        #expect(ImportedSavedRouteFactory.make(coordinates: [RouteCoordinate(latitude: 25, longitude: 121)], requestedName: nil, existingNames: [], speedKmh: 18.6) == nil)
        #expect(ImportedSavedRouteFactory.make(coordinates: [RouteCoordinate(latitude: 91, longitude: 0), RouteCoordinate(latitude: 25, longitude: 121)], requestedName: nil, existingNames: [], speedKmh: 18.6) == nil)
    }

    @Test func recentRouteOrderingUsesLastUsedAtWithoutMutatingStoredOrder() {
        let old = SavedRoute(name: "Old", waypoints: [], resolvedGeometry: RouteGeometry(coordinates: []), routeMode: .straight, isClosedLoop: false, preferredSpeedKmh: 18.6, playbackMode: .once, lastUsedAt: Date(timeIntervalSince1970: 10))
        let recent = SavedRoute(name: "Recent", waypoints: [], resolvedGeometry: RouteGeometry(coordinates: []), routeMode: .straight, isClosedLoop: false, preferredSpeedKmh: 18.6, playbackMode: .once, lastUsedAt: Date(timeIntervalSince1970: 20))
        let never = SavedRoute(name: "Never", waypoints: [], resolvedGeometry: RouteGeometry(coordinates: []), routeMode: .straight, isClosedLoop: false, preferredSpeedKmh: 18.6, playbackMode: .once)
        let source = [old, never, recent]
        #expect(RouteLibrarySortPolicy.recentlyUsed(source).map(\.id) == [recent.id, old.id])
        #expect(source.map(\.id) == [old.id, never.id, recent.id])
    }

    @MainActor
    @Test func mapSelectionDoesNotMoveCameraButExplicitFocusRequestsNavigation() {
        let model = RouteLocationModel()
        let cameraRevision = model.mapFocusRevision
        let coordinate = CLLocationCoordinate2D(latitude: 25.033964, longitude: 121.564468)
        model.select(coordinate)
        #expect(model.selectedCoordinate == RouteCoordinate(coordinate))
        #expect(model.mapFocusRevision == cameraRevision)

        model.focusOnMap(RouteCoordinate(latitude: 35.6762, longitude: 139.6503))
        #expect(model.mapFocusRevision != cameraRevision)
    }

    @MainActor
    @Test func routeDraftChangesDoNotReuseAnOldPlaceSelectionAsCameraNavigation() {
        let model = RouteLocationModel()
        let selected = CLLocationCoordinate2D(latitude: 25.033964, longitude: 121.564468)
        model.select(selected)
        let selectionCameraRevision = model.mapFocusRevision
        let points = [
            RouteCoordinate(latitude: 35.0, longitude: 139.0),
            RouteCoordinate(latitude: 35.01, longitude: 139.01)
        ]

        #expect(model.replaceWaypoints(points))
        #expect(model.mapFocusRevision == selectionCameraRevision)
        #expect(model.selectedCoordinate == RouteCoordinate(selected))
    }

    @MainActor
    @Test func addingWaypointDuringPreviewDismissesPreviewAndAppendsToOriginalDraft() {
        let model = RouteLocationModel()
        let first = RouteCoordinate(latitude: 25.0, longitude: 121.0)
        let second = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        let third = RouteCoordinate(latitude: 25.02, longitude: 121.02)
        #expect(model.replaceWaypoints([first, second]))
        model.previewRoute(SavedRoute(
            name: "Read-only preview",
            waypoints: [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.1, longitude: 139.1)],
            resolvedGeometry: RouteGeometry(coordinates: [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.1, longitude: 139.1)]),
            routeMode: .straight,
            isClosedLoop: false,
            preferredSpeedKmh: 18.6,
            playbackMode: .once
        ))

        #expect(model.addWaypointAndSwitchToRoute(third))
        #expect(model.previewingRoute == nil)
        #expect(model.waypoints == [first, second, third])
        #expect(model.quickRouteMode == .route)
    }

    @MainActor
    @Test func editingPreviewRouteDismissesReadOnlySnapshotBeforeDraftBecomesEditable() {
        let model = RouteLocationModel()
        let first = RouteCoordinate(latitude: 25, longitude: 121)
        let second = RouteCoordinate(latitude: 25.01, longitude: 121.01)
        let route = SavedRoute(
            name: "Preview route",
            waypoints: [first, second],
            resolvedGeometry: RouteGeometry(coordinates: [first, second]),
            routeMode: .straight,
            isClosedLoop: false,
            preferredSpeedKmh: 18.6,
            playbackMode: .once
        )
        model.previewRoute(route)

        #expect(model.requestEditRoute(route))
        #expect(model.previewingRoute == nil)
        #expect(model.waypoints == route.waypoints)
        #expect(model.loadedRouteID == route.id)
    }

    @MainActor
    @Test func selectingPlaceDismissesReadOnlyPreviewWithoutChangingRouteDraft() {
        let model = RouteLocationModel()
        let draft = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.01, longitude: 121.01)]
        #expect(model.replaceWaypoints(draft))
        let preview = SavedRoute(
            name: "Preview route",
            waypoints: [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)],
            resolvedGeometry: RouteGeometry(coordinates: [RouteCoordinate(latitude: 35, longitude: 139), RouteCoordinate(latitude: 35.01, longitude: 139.01)]),
            routeMode: .straight,
            isClosedLoop: false,
            preferredSpeedKmh: 18.6,
            playbackMode: .once
        )
        model.previewRoute(preview)

        model.focusOnMap(RouteCoordinate(latitude: 25.033964, longitude: 121.564468))

        #expect(model.previewingRoute == nil)
        #expect(model.waypoints == draft)
        #expect(model.selectedCoordinate == RouteCoordinate(latitude: 25.033964, longitude: 121.564468))
    }

    @MainActor
    @Test func importedRoutePersistsBeforePublishingAndDoesNotReplaceDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RouteLocation-v1.2.23-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutePersistenceStore(rootURL: root)
        let model = RouteLocationModel(persistence: store)
        let draft = [RouteCoordinate(latitude: 25.0, longitude: 121.0), RouteCoordinate(latitude: 25.01, longitude: 121.01)]
        #expect(model.replaceWaypoints(draft))
        let importedWaypoints = [RouteCoordinate(latitude: 35.0, longitude: 139.0), RouteCoordinate(latitude: 35.01, longitude: 139.01)]

        let saved = await model.importSavedRoute(importedWaypoints)

        let persisted = try await store.loadRoutes()
        #expect(saved != nil)
        #expect(model.waypoints == draft)
        #expect(model.previewingRoute?.id == saved?.id)
        #expect(persisted.map(\.id) == [saved?.id].compactMap { $0 })
        #expect(persisted.first?.waypoints == importedWaypoints)
        #expect(persisted.first?.routeMode == .straight)
    }

    @MainActor
    @Test func failedImportedRoutePersistencePublishesNoPartialRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RouteLocation-v1.2.23-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: support.appendingPathComponent("routes"))
        let store = RoutePersistenceStore(rootURL: root)
        let model = RouteLocationModel(persistence: store)
        let draft = [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 25.01, longitude: 121.01)]
        #expect(model.replaceWaypoints(draft))

        let imported = await model.importSavedRoute([
            RouteCoordinate(latitude: 35, longitude: 139),
            RouteCoordinate(latitude: 35.01, longitude: 139.01)
        ])

        #expect(imported == nil)
        #expect(model.savedRoutes.isEmpty)
        #expect(model.previewingRoute == nil)
        #expect(model.waypoints == draft)
    }

    @Test func recentLocationDateGroupsDistinguishTodayAndYesterdayDeterministically() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 1)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23)))
        #expect(RecentLocationDatePolicy.title(for: today, now: now, calendar: calendar) == L10n.text("今天"))
        #expect(RecentLocationDatePolicy.title(for: yesterday, now: now, calendar: calendar) == L10n.text("昨天"))
    }
}

struct V1_2_23TutorialLayoutTests {
    @Test(arguments: [
        (CGSize(width: 390, height: 844), CGSize(width: 330, height: 220), "zh-Hant"),
        (CGSize(width: 320, height: 568), CGSize(width: 296, height: 330), "en"),
        (CGSize(width: 390, height: 844), CGSize(width: 330, height: 440), "zh-Hant-large"),
        (CGSize(width: 430, height: 932), CGSize(width: 390, height: 250), "en-large")
    ])
    func coachCardNeverCoversProtectedInteractiveTarget(size: CGSize, desiredCard: CGSize, _: String) {
        let target = CGRect(x: size.width / 2 - 32, y: size.height / 2 - 24, width: 64, height: 48)
        let placement = TutorialCoachLayout.place(
            container: CGRect(origin: .zero, size: size),
            target: target,
            desiredSize: desiredCard
        )
        #expect(!placement.frame.intersects(placement.protectedTargetFrame))
        #expect(placement.maximumHeight > 0)
        #expect(CGRect(origin: .zero, size: size).contains(placement.frame))
    }

    @Test func everyInteractiveTargetRemainsUncoveredAcrossCompactAndLargeLayouts() {
        let scenarios: [(CGRect, CGSize)] = [
            (CGRect(x: 0, y: 0, width: 390, height: 844), CGSize(width: 330, height: 250)),
            (CGRect(x: 0, y: 0, width: 320, height: 568), CGSize(width: 296, height: 330)),
            (CGRect(x: 0, y: 0, width: 430, height: 932), CGSize(width: 390, height: 440))
        ]
        for (index, target) in TutorialTarget.allCases.enumerated() {
            for (container, desiredCard) in scenarios {
                let yPositions = [container.minY + 24, container.midY, container.maxY - 24]
                for y in yPositions {
                    let targetFrame = CGRect(x: container.midX - 28, y: y - 22, width: 56, height: 44)
                    let placement = TutorialCoachLayout.place(
                        container: container,
                        target: targetFrame,
                        desiredSize: desiredCard,
                        touchPadding: 14
                    )
                    #expect(!placement.frame.intersects(placement.protectedTargetFrame), "Coach overlaps \(target) layout \(index)")
                    #expect(container.contains(placement.frame))
                    #expect(placement.frame.width >= 0 && placement.frame.height > 0)
                }
            }
        }
    }

    @Test func tutorialSelectionCompletionUsesProductionSelectionRevisionNotCameraMovement() {
        let coordinate = RouteCoordinate(latitude: 25.033964, longitude: 121.564468)
        let oldRevision = UUID()
        let newRevision = UUID()
        #expect(!TutorialSelectionPolicy.changed(
            coordinate: coordinate,
            previousCoordinate: coordinate,
            revision: oldRevision,
            previousRevision: oldRevision
        ))
        #expect(TutorialSelectionPolicy.changed(
            coordinate: coordinate,
            previousCoordinate: coordinate,
            revision: newRevision,
            previousRevision: oldRevision
        ))
    }
}
