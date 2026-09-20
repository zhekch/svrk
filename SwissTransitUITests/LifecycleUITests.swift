import XCTest

final class LifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // Landscape tests leave the device on its side; the next launch must
        // not inherit that or the compact train card hides Done immediately.
        let app = XCUIApplication()
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            XCUIDevice.shared.orientation == .portrait ||
            (app.state == .notRunning)
        }, object: nil)
        _ = XCTWaiter.wait(for: [portrait], timeout: 3)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func saveShot(_ app: XCUIApplication, name: String) {
        let dir = URL(fileURLWithPath: "/tmp/svrk-landscape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = app.screenshot().pngRepresentation
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSearchRepeatedlyOpensKeyboardAndClearsOnCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-setting.dataMode", "Off"]
        app.launch()
        let search = app.buttons["Search for a stop or a service"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            search.exists && search.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        let field = app.textFields["Station, or IC8, or 726"]

        for _ in 0..<3 {
            search.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                          "Search must automatically focus after its expansion")
            field.typeText("zz")
            XCTAssertEqual(field.value as? String, "zz")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.keyboards.firstMatch.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
    }

    func testBoardGroupingToggleKeepsFrequencyAndScrollingFilters() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectNearest", "1", "-expandSheet", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "(train, tram, bus, boat, cable)"
        ]
        app.launch()
        let choice = app.buttons["Bern"].firstMatch
        let grouping = app.buttons["Board grouping"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || grouping.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(grouping.waitForExistence(timeout: 20))
        XCTAssertEqual(grouping.value as? String, "Off")
        let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' later times'")).firstMatch
        XCTAssertFalse(disclosure.exists)
        let frequency = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'every '")).firstMatch
        XCTAssertTrue(frequency.waitForExistence(timeout: 15), "Frequency remains visible on separate departures")
        XCTAssertFalse(app.buttons.matching(identifier: "Station service").allElementsBoundByIndex.contains {
            $0.label.contains(" ago")
        })
        saveShot(app, name: "board-ungrouped")
        grouping.tap()
        XCTAssertEqual(grouping.value as? String, "On")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Grouping restores the existing disclosure")
        saveShot(app, name: "board-grouped")
        grouping.tap()
        XCTAssertEqual(grouping.value as? String, "Off")
        XCTAssertFalse(disclosure.exists)
        let x = grouping.frame.midX
        let filters = app.scrollViews["Vehicle filters"]
        XCTAssertTrue(filters.exists)
        filters.swipeLeft()
        XCTAssertEqual(grouping.frame.midX, x, accuracy: 1, "Grouping stays fixed over the scrolling chips")
        XCTAssertTrue(grouping.isHittable)
        saveShot(app, name: "board-filters-scrolled")
    }

    func testZurichBoardScrollingPerformance() throws {
        let app = XCUIApplication()
        // Use the bundled daytime timetable, independent of the live feed.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let offset = Int(noon.timeIntervalSinceNow / 60)
        app.launchArguments = [
            "-startLat", "47.3779", "-startLon", "8.5403", "-startZoom", "15",
            "-startOffsetMinutes", "\(offset)", "-selectNearest", "1",
            "-expandSheet", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        let choice = app.buttons["Zürich HB"].firstMatch
        let grouping = app.buttons["Board grouping"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || grouping.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 90), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(grouping.waitForExistence(timeout: 30))
        XCTAssertEqual(grouping.value as? String, "Off")
        let services = app.buttons.matching(identifier: "Station service")
        XCTAssertTrue(services.firstMatch.waitForExistence(timeout: 30))
        let list = app.collectionViews.containing(.button, identifier: "Station service").firstMatch
        XCTAssertTrue(list.exists)
        XCTAssertTrue(app.navigationBars["Zürich HB"].exists)
        let firstPage = services.allElementsBoundByIndex.map(\.label)
        list.swipeUp(velocity: .slow)
        XCTAssertNotEqual(services.allElementsBoundByIndex.map(\.label), firstPage,
                          "Scrolling must reveal later services")
        list.swipeDown(velocity: .slow)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        // Repeated traversals also exercise the board's 15-second clock refresh.
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            list.swipeUp(velocity: .slow)
            list.swipeUp(velocity: .slow)
            list.swipeDown(velocity: .slow)
            list.swipeDown(velocity: .slow)
        }
        // A train-only board puts grouping in its scrolling section heading.
        for _ in 0..<8 {
            if grouping.isHittable { break }
            list.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(grouping.isHittable)
        grouping.tap()
        XCTAssertEqual(grouping.value as? String, "On")
        let disclosure = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' later times'"
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Hide ' AND label ENDSWITH ' later times'"
        )).firstMatch.waitForExistence(timeout: 5))
    }

    func testDistantCityLabelOpensItsRailwayStation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.758", "-startLon", "7.63", "-startZoom", "10",
            "-selectCityLabel", "Thun", "-setting.dataMode", "Off", "-setting.basemap", "Standard"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Thun"].waitForExistence(timeout: 90),
                      "A rendered Thun city label at zoom 10 must open Thun station")
        XCTAssertTrue(app.buttons["Done"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Departures"))
            .firstMatch.waitForExistence(timeout: 15))
    }

    func testFleetMenuCanToggleBusWithVehicleCardOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectVehicle", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        let fleet = app.buttons["Live data and map legend"]
        XCTAssertTrue(fleet.isHittable)
        fleet.tap()
        let bus = app.buttons["Buses"]
        XCTAssertTrue(bus.waitForExistence(timeout: 5), app.debugDescription)
        let previous = bus.value as? String
        bus.tap()
        XCTAssertNotEqual(bus.value as? String, previous)
        bus.tap()
        XCTAssertEqual(bus.value as? String, previous)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.15)).tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The fleet popover must retain the vehicle card")
        done.tap()
        fleet.tap()
        XCTAssertTrue(bus.waitForExistence(timeout: 5), "The fleet menu must reopen after the card closes")
    }

    func testFleetMenuCanToggleBusWithoutCard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-setting.dataMode", "Off"
        ]
        app.launch()
        let fleet = app.buttons["Live data and map legend"]
        XCTAssertTrue(app.buttons["About this map"].waitForExistence(timeout: 60))
        XCTAssertTrue(fleet.waitForExistence(timeout: 60))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fleet.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        fleet.tap()
        let bus = app.buttons["Buses"]
        XCTAssertTrue(bus.waitForExistence(timeout: 5), app.debugDescription)
        let previous = bus.value as? String
        bus.tap()
        XCTAssertNotEqual(bus.value as? String, previous)
        bus.tap()
        XCTAssertEqual(bus.value as? String, previous)
    }

    func testVehicleCanBeTappedAgainAfterClosingItsCard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectVehicle", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        app.buttons["Clock"].tap()
        let pause = app.buttons["Pause the map"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        app.buttons["Clock"].tap()
        done.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !done.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        // Ending follow removes its bottom padding, leaving the paused
        // vehicle at the map centre. Exercise the native map tap recognizer.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Live departures can put several buses at the same point. The native
        // chooser is the correct answer in that case, and must open a card too.
        let choice = app.collectionViews.buttons.firstMatch
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            done.exists || choice.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 5), .completed)
        if !done.exists, choice.exists { choice.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Tapping the same vehicle must open its card again")
    }

    func testMapStationTapOpensThenPopulatesBoard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.5873", "-startLon", "7.6498", "-startZoom", "14",
            "-selectNearest", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "(train, tram, bus, boat, cable)"
        ]
        app.launch()
        let choice = app.buttons["Frutigen"].firstMatch
        let done = app.buttons["Done"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || done.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 3))
        let departures = app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", "Departures"
        )).firstMatch
        XCTAssertTrue(departures.waitForExistence(timeout: 10), "The selected station must finish loading its local board")
        done.tap()
        XCTAssertTrue(app.buttons["Search for a stop or a service"].waitForExistence(timeout: 3))
    }

    func testLocalVehiclePanelExpandsAndDismissesWithoutLiveAPIs() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectVehicle", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        let stop = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["NEXT STOP", "CURRENTLY AT", "TERMINAL STOP"]
        )).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "Local stop data should not need a live API")

        // Pull the existing sheet through its expansion, then act immediately.
        let top = done.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let expanded = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.18))
        top.press(forDuration: 0.1, thenDragTo: expanded)
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Expanded local vehicle panel"
        attachment.lifetime = .keepAlways
        add(attachment)
        done.tap()
        let search = app.buttons["Search for a stop or a service"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        XCTAssertTrue(app.textFields["Station, or IC8, or 726"].waitForExistence(timeout: 3))
    }

    func testVehiclePanelRepeatedlyExpandsFromFullscreenWithoutReopening() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectVehicle", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        let fullscreen = app.buttons["Watch this service full screen"]
        for _ in 0..<3 {
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
            fullscreen.tap()
            let collapsed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !done.exists }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
            let pill = app.descendants(matching: .any)["Follow pill"].firstMatch
            if !pill.waitForExistence(timeout: 3) { print(app.debugDescription) }
            XCTAssertTrue(pill.exists)
            let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                pill.frame.height < 140 && pill.frame.minY > app.frame.height * 0.75
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 3), .completed,
                           "The live pill must not inherit a full panel's detent")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(done.frame.minY, app.frame.height * 0.4,
                                 "Expanding the compact bar should restore the resting card")
            let settledY = done.frame.minY
            for _ in 0..<4 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                XCTAssertTrue(done.exists, "The existing sheet must stay mounted")
                XCTAssertEqual(done.frame.minY, settledY, accuracy: 3,
                               "Delayed measurements must not replay the opening")
            }
        }
        done.tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !done.exists }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.buttons["Search for a stop or a service"].tap()
        XCTAssertTrue(app.textFields["Station, or IC8, or 726"].waitForExistence(timeout: 3))
    }

    func testStationRowLeadingSwipeOffersWatchDeparture() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.5873", "-startLon", "7.6498", "-startZoom", "14",
            "-selectNearest", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "()"
        ]
        app.launch()
        let choice = app.buttons["Frutigen"].firstMatch
        let done = app.buttons["Done"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || done.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 5))
        let row = app.buttons["Station service"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeRight(velocity: .slow)
        let watch = app.buttons["Watch departure"]
        XCTAssertTrue(watch.waitForExistence(timeout: 3), "A leading swipe on a board row must offer a Live Activity")
        watch.tap()
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 3),
                      "Pinning a departure must leave the board in place")
    }

    func testStationRowNativeSwipeOpensRouteAndReturnsToStation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.5873", "-startLon", "7.6498", "-startZoom", "14",
            "-selectNearest", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "()"
        ]
        app.launch()
        let choice = app.buttons["Frutigen"].firstMatch
        let done = app.buttons["Done"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || done.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 5))
        let row = app.buttons["Station service"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft(velocity: .slow)
        let endpoints = app.descendants(matching: .any)["Route endpoints"].firstMatch
        if !endpoints.waitForExistence(timeout: 2), app.buttons["Route map"].exists {
            app.buttons["Route map"].tap()
        }
        XCTAssertTrue(endpoints.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Done"].exists, "The existing detail sheet must remain in use")
        XCTAssertTrue(app.buttons["Search for a stop or a service"].exists,
                      "The main map controls must remain available")
        XCTAssertFalse(app.navigationBars["Route map"].exists, "No separate route screen")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["NEXT STOP", "CURRENTLY AT", "TERMINAL STOP", "NEXT DEPARTURE"]
        )).firstMatch.exists)
        let visibility = app.buttons["Route transport visibility"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 5))
        XCTAssertEqual(visibility.value as? String, "Visible")
        visibility.tap()
        XCTAssertEqual(visibility.value as? String, "Hidden")
        XCTAssertTrue(endpoints.exists)
        let hiddenScreenshot = XCTAttachment(screenshot: app.screenshot())
        hiddenScreenshot.name = "Route with all transport hidden"
        hiddenScreenshot.lifetime = .keepAlways
        add(hiddenScreenshot)
        visibility.tap()
        XCTAssertEqual(visibility.value as? String, "Visible")
        let stop = app.buttons["Route stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        let stopName = stop.label
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Full route on the interactive main map"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        stop.tap()
        XCTAssertTrue(app.navigationBars[stopName].waitForExistence(timeout: 10),
                      "A route stop must open its station board")
        app.buttons["Back"].tap()
        XCTAssertTrue(endpoints.waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 5))
    }

    func testStationBoardDaySectionsExpandAndCollapse() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.5873", "-startLon", "7.6498", "-startZoom", "14",
            "-selectNearest", "1", "-expandSheet", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "(train, tram, bus, boat, cable)"
        ]
        app.launch()
        let choice = app.buttons["Frutigen"].firstMatch
        let done = app.buttons["Done"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || done.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(app.navigationBars["Frutigen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Station service"].firstMatch.waitForExistence(timeout: 15))

        for kind in ["departures", "arrivals"] {
            let tomorrow = app.buttons["Tomorrow \(kind)"]
            for _ in 0..<8 {
                if tomorrow.exists && tomorrow.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(tomorrow.exists)
            let initiallyExpanded = tomorrow.value as? String == "Expanded"
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Default day expansion \(kind)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            tomorrow.tap()
            XCTAssertEqual(tomorrow.value as? String, initiallyExpanded ? "Collapsed" : "Expanded")
            tomorrow.tap()
            XCTAssertEqual(tomorrow.value as? String, initiallyExpanded ? "Expanded" : "Collapsed")
        }
    }

    func testLandscapeVehicleCardIsFullWidthBlurWithoutChrome() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.948", "-startLon", "7.439", "-startZoom", "15",
            "-selectVehicle", "1", "-setting.dataMode", "Off"
        ]
        app.launch()
        defer { saveShot(app, name: "landscape-vehicle-debug") }
        let done = app.buttons["Done"]
        let stop = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["NEXT STOP", "CURRENTLY AT", "TERMINAL STOP", "GOING TO"]
        )).firstMatch
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            done.exists || stop.exists
        }, object: nil)
        let openedResult = XCTWaiter.wait(for: [opened], timeout: 60)
        if openedResult != .completed {
            saveShot(app, name: "landscape-vehicle-missing")
            throw XCTSkip("No vehicle opened at this clock; board layout is covered separately")
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Portrait train card keeps Done")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        saveShot(app, name: "landscape-vehicle")

        XCTAssertFalse(done.exists, "Landscape train card hides Done with the line title")
        let goingTo = app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", "GOING TO"
        )).firstMatch
        XCTAssertTrue(goingTo.waitForExistence(timeout: 5), "Landscape overview names the destination column")
        let nextStop = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["NEXT STOP", "CURRENTLY AT", "TERMINAL STOP"]
        )).firstMatch
        XCTAssertTrue(nextStop.exists, "Landscape overview names the next-stop column")
        XCTAssertGreaterThan(goingTo.frame.maxX, app.frame.width * 0.08,
                             "The landscape card must use the width, not a nested inset")
        XCTAssertLessThan(goingTo.frame.minX, app.frame.width * 0.2)

        let fullscreen = app.buttons["Watch this service full screen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(fullscreen.frame.minY, app.frame.height * 0.4,
                             "Fullscreen control stays on the bottom of the landscape map")
        fullscreen.tap()
        let pill = app.descendants(matching: .any)["Follow pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        saveShot(app, name: "landscape-follow-pill")
        XCTAssertLessThan(pill.frame.height, 110,
                          "Inline next-stop caption should shorten the landscape pill")
        XCTAssertGreaterThan(pill.frame.minY, app.frame.height * 0.55)
        XCTAssertGreaterThan(pill.frame.width, app.frame.width * 0.85,
                             "The live pill is a full-width bottom bar")
    }

    func testLandscapeStationBoardSplitsDeparturesAndArrivals() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.5873", "-startLon", "7.6498", "-startZoom", "14",
            "-selectNearest", "1", "-setting.dataMode", "Off",
            "-setting.hiddenModes", "(train, tram, bus, boat, cable)"
        ]
        app.launch()
        let choice = app.buttons["Frutigen"].firstMatch
        let done = app.buttons["Done"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            choice.exists || done.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed)
        if choice.exists { choice.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        let stationName = app.staticTexts["Station name"].firstMatch
        XCTAssertTrue(
            stationName.waitForExistence(timeout: 5) ||
            app.navigationBars["Frutigen"].waitForExistence(timeout: 1),
            "Landscape board names the station on the chip row"
        )
        XCTAssertTrue(done.exists, "Done sits on the same row as the station name")
        let departures = app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", "Departures"
        )).firstMatch
        XCTAssertTrue(departures.waitForExistence(timeout: 10))
        let arrivals = app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", "Arrivals"
        )).firstMatch
        XCTAssertTrue(arrivals.waitForExistence(timeout: 5), "Landscape board keeps arrivals on screen")
        saveShot(app, name: "landscape-board")
        XCTAssertLessThan(abs(departures.frame.minY - arrivals.frame.minY), 80,
                          "Departures and arrivals sit as columns, not stacked pages")
        XCTAssertGreaterThan(arrivals.frame.minX, departures.frame.midX)
        XCTAssertGreaterThan(departures.frame.width + arrivals.frame.width, app.frame.width * 0.5)
        if stationName.exists {
            XCTAssertLessThan(stationName.frame.minX, app.frame.midX,
                              "Station name sits on the leading side, not centred in a navigation bar")
            XCTAssertLessThan(abs(stationName.frame.midY - done.frame.midY), 24,
                              "Station name and Done share the heading row")
        }
        saveShot(app, name: "landscape-board")
    }

    func testControlCenterDismissalLeavesAppInteractive() throws {
        let app = XCUIApplication()
        app.launch()

        let search = app.buttons["Search for a stop or a service"]
        XCTAssertTrue(search.waitForExistence(timeout: 60), "App never reached its interactive map UI")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let topRight = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01))
        let controlCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        let upper = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let controlCenterRoot = springboard.otherElements["cc-root-folder-view"]

        for round in 1...3 {
            topRight.press(forDuration: 0.1, thenDragTo: controlCenter)
            XCTAssertTrue(
                controlCenterRoot.waitForExistence(timeout: 5),
                "Control Center did not open in round \(round)"
            )

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Control Center visible, round \(round)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            bottom.press(forDuration: 0.1, thenDragTo: upper)

            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()

            let field = app.textFields["Station, or IC8, or 726"]
            XCTAssertTrue(
                field.waitForExistence(timeout: 5),
                "The app did not respond after Control Center round \(round)"
            )

            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
        }
    }

    func testIC61RouteDoesNotCrossAfrica() throws {
        let shot = URL(fileURLWithPath: "/tmp/svrk-route-shot", isDirectory: true)
        try? FileManager.default.removeItem(at: shot)
        let app = XCUIApplication()
        app.launchArguments = [
            "-startLat", "46.6904", "-startLon", "7.8690", "-startZoom", "10",
            "-openService", "IC61", "-routeShot", "1", "-dumpRoute", "1",
        ]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 90), "IC61 never opened a vehicle card")
        let card = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'IC61' OR label CONTAINS[c] 'IC 61'"
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Opened card is not IC61")
        let speed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'km/h'")).firstMatch
        if speed.waitForExistence(timeout: 5),
           let match = speed.label.range(of: #"[0-9]+\s*km/h"#, options: .regularExpression) {
            let value = Int(speed.label[match].prefix { $0.isNumber }) ?? 0
            XCTAssertLessThan(value, 400, "Speed \(speed.label) means the path still jumps to Africa")
        }
        let doneFile = shot.appendingPathComponent("done.txt")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: doneFile.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed, "routeShot never finished")
        let bbox = try String(contentsOf: shot.appendingPathComponent("bbox.txt"), encoding: .utf8)
        let attachment = XCTAttachment(string: bbox)
        attachment.name = "IC61 route bbox"
        attachment.lifetime = .keepAlways
        add(attachment)
        for name in ["framed.png", "world.png", "local.png"] {
            let url = shot.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                let image = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                image.name = name
                image.lifetime = .keepAlways
                add(image)
            }
        }
        XCTAssertFalse(bbox.contains("lat 0 "), "Route still includes a Null Island vertex:\n\(bbox)")
        let lats = bbox.split(separator: "\n").first { $0.hasPrefix("lat ") }?
            .split(separator: " ").compactMap { Double($0) } ?? []
        XCTAssertGreaterThanOrEqual(lats.count, 2, bbox)
        XCTAssertGreaterThan(lats.min() ?? 0, 35, "Route south edge is in Africa:\n\(bbox)")
        XCTAssertLessThan(lats.max() ?? 90, 60, "Route north edge left Europe:\n\(bbox)")
        saveShot(app, name: "ic61-after-live")
    }
}
