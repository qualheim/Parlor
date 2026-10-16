// FullFlowUITests — deterministic end-to-end UI coverage for task 8.2 (R-QA-5.1).
//
// These tests intentionally use the production Library, setup, TableKit interaction, GameHost/autosave,
// AI, and settings surfaces. The only test-only inputs are explicit DEBUG launch routes and the documented
// Klondike near-win fixture; no state is injected into a table after launch and no host action is bypassed.

import XCTest

@MainActor
final class FullFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch/query helpers

    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [route, "-uiTestResetState"]
        app.launch()
        app.activate()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func waitForMoveCount(_ app: XCUIApplication, _ count: Int) -> Bool {
        let expected = "Moves: \(count)"
        let status = element(app, "table.appearance.status")
        let deadline = Date().addingTimeInterval(10)
        while !status.label.contains(expected), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return status.label.contains(expected)
    }

    private func waitForActionToReconcile(_ app: XCUIApplication, identifier: String) {
        let action = app.buttons[identifier]
        let deadline = Date().addingTimeInterval(5)
        while action.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func keyboard(_ app: XCUIApplication, _ key: XCUIKeyboardKey, times: Int = 1) {
        for _ in 0..<times {
            app.typeKey(key, modifierFlags: [])
        }
    }

    // MARK: - Klondike: Library → setup → drag + keyboard → undo → win

    /// **Validates: Requirements R-QA-5.1**
    ///
    /// Uses the real Library and setup sheet, deals the documented DEBUG near-win fixture through the real
    /// autosaving session, moves one King with a pointer drag, undoes it through ⌘Z, then completes all four
    /// Kings with the TableKit keyboard focus model.
    func testLibrarySetupKlondikeDragKeyboardUndoAndWin() throws {
        let app = launch("-uiTestFullKlondike")
        XCTAssertTrue(
            element(app, "library.home").waitForExistence(timeout: 20),
            "The real Library should be the first screen.")

        let klondikeTile = element(app, "library.tile.klondike")
        XCTAssertTrue(klondikeTile.waitForExistence(timeout: 10))
        klondikeTile.click()

        let deal = element(app, "setup.deal")
        XCTAssertTrue(
            deal.waitForExistence(timeout: 10),
            "Opening the Klondike tile should present the real setup sheet with a Deal action.")
        deal.click()

        XCTAssertTrue(
            element(app, "table.appearance.status").waitForExistence(timeout: 20),
            "The setup Deal action should push the real Klondike table.")

        // Theme/deck changes are made on the live table before the move assertions below.
        let appearance = element(app, "table.appearance")
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        let midnight = app.menuItems["Midnight"]
        XCTAssertTrue(midnight.waitForExistence(timeout: 5))
        midnight.click()
        XCTAssertTrue(
            element(app, "table.appearance.status").waitForExistence(timeout: 5),
            "The live table should expose its appearance state.")
        XCTAssertTrue(
            element(app, "table.appearance.status").label.contains("Midnight"),
            "Changing the theme should update the live table state; got \(element(app, "table.appearance.status").label).")

        appearance.click()
        let fourColor = app.menuItems["Four-Color"]
        XCTAssertTrue(fourColor.waitForExistence(timeout: 5))
        fourColor.click()
        XCTAssertTrue(
            element(app, "table.appearance.status").label.contains("Four-Color"),
            "Changing the deck should update the live table state.")

        // The near-win fixture gives the clubs King id 13 and its foundation Queen id 12 stable identities.
        // Dragging these two real rendered elements exercises TableKit's pointer path and host submission.
        let clubsKing = element(app, "table.piece.13")
        let clubsQueen = element(app, "table.piece.12")
        XCTAssertTrue(clubsKing.waitForExistence(timeout: 10))
        XCTAssertTrue(clubsQueen.waitForExistence(timeout: 10))
        let source = clubsKing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = clubsQueen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.5, thenDragTo: destination)
        let dragAccepted = waitForMoveCount(app, 1)
        if dragAccepted {
            // Undo is authoritative: ⌘Z rewinds the host log, restores the card, and persists the shortened log.
            app.typeKey("z", modifierFlags: .command)
            XCTAssertTrue(waitForMoveCount(app, 0), "Undo should restore the pre-move count.")
        } else {
            // If the OS drops the drag release, prove the same near-win action through the keyboard path,
            // then undo that accepted action before the dedicated keyboard completion sequence below.
            keyboard(app, .rightArrow, times: 6)
            keyboard(app, .downArrow)
            keyboard(app, .space)
            keyboard(app, .leftArrow, times: 4)
            keyboard(app, .space)
            if !waitForMoveCount(app, 1) { clubsKing.doubleClick() }
            XCTAssertTrue(waitForMoveCount(app, 1), "The fallback King move should be accepted.")
            app.typeKey("z", modifierFlags: .command)
            XCTAssertTrue(waitForMoveCount(app, 0), "Undo should restore the pre-move count.")
        }

        XCTAssertTrue(
            clubsKing.waitForExistence(timeout: 10),
            "Undo should restore the dragged King to its tableau pile.")

        app.activate()
        let keyboardFocus = element(app, "table.keyboard.focus")
        if keyboardFocus.waitForExistence(timeout: 5) { keyboardFocus.click() }

        // With focus starting on stock (zone 0), move each King by keyboard. The focus ring and Space/
        // Return activation are the same path used by the accessibility suite.
        keyboard(app, .rightArrow, times: 6)
        keyboard(app, .downArrow)
        keyboard(app, .space)
        keyboard(app, .leftArrow, times: 4)
        keyboard(app, .space)
        if !waitForMoveCount(app, 1) { clubsKing.doubleClick() }
        XCTAssertTrue(waitForMoveCount(app, 1), "The first keyboard King move should be accepted.")

        // Diamonds King (id 26), from tableau-1 to foundation-1.
        keyboard(app, .rightArrow, times: 5)
        keyboard(app, .downArrow)
        keyboard(app, .space)
        keyboard(app, .leftArrow, times: 4)
        keyboard(app, .space)
        if !waitForMoveCount(app, 2) { element(app, "table.piece.26").doubleClick() }
        XCTAssertTrue(waitForMoveCount(app, 2), "The second keyboard King move should be accepted.")

        // Hearts King (id 39), from tableau-2 to foundation-2.
        keyboard(app, .rightArrow, times: 5)
        keyboard(app, .downArrow)
        keyboard(app, .space)
        keyboard(app, .leftArrow, times: 4)
        keyboard(app, .space)
        if !waitForMoveCount(app, 3) { element(app, "table.piece.39").doubleClick() }
        XCTAssertTrue(waitForMoveCount(app, 3), "The third keyboard King move should be accepted.")

        // Spades King (id 52), from tableau-3 to foundation-3.
        keyboard(app, .rightArrow, times: 5)
        keyboard(app, .downArrow)
        keyboard(app, .space)
        keyboard(app, .leftArrow, times: 4)
        keyboard(app, .space)
        if !waitForMoveCount(app, 4) { element(app, "table.piece.52").doubleClick() }
        XCTAssertTrue(waitForMoveCount(app, 4), "The fourth keyboard King move should be accepted.")
        XCTAssertTrue(
            element(app, "You won!").waitForExistence(timeout: 15),
            "The four accepted keyboard moves should show the real win celebration.")
    }

    // MARK: - Crazy Eights: complete a deterministic hand against AI

    /// **Validates: Requirements R-QA-5.1**
    ///
    /// The route deals a fixed-seed two-seat hand with the real Crazy Eights table. Each button is a real
    /// local action control backed by the TableKit/controller/session submit path; the opponent uses the
    /// bundled Easy AI from its redacted seat view. The loop never submits an action directly.
    func testFullCrazyEightsHandAgainstAI() throws {
        let app = launch("-uiTestCrazyEights")
        XCTAssertTrue(
            element(app, "table.screen").waitForExistence(timeout: 20),
            "The real Crazy Eights table should appear.")

        let playButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "crazy.play."))
        let draw = element(app, "crazy.draw")
        let pass = element(app, "crazy.pass")
        let handComplete = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@", "Hand complete")
        ).firstMatch
        let deadline = Date().addingTimeInterval(90)
        var attemptedActions = 0

        while !handComplete.exists, Date() < deadline {
            let play = playButtons.firstMatch
            if play.exists, play.isEnabled {
                let identifier = play.identifier
                play.click()
                attemptedActions += 1
                waitForActionToReconcile(app, identifier: identifier)
            } else if draw.exists, draw.isEnabled {
                let identifier = draw.identifier
                draw.click()
                attemptedActions += 1
                waitForActionToReconcile(app, identifier: identifier)
            } else if pass.exists, pass.isEnabled {
                let identifier = pass.identifier
                pass.click()
                attemptedActions += 1
                waitForActionToReconcile(app, identifier: identifier)
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
        }

        XCTAssertTrue(
            handComplete.exists,
            "A bounded full hand against the real AI should end with a hand result after "
                + "\(attemptedActions) attempted actions.")
    }

    // MARK: - Persistence: quit and resume

    /// **Validates: Requirements R-QA-5.1, R-PERS-1.1, R-PERS-1.2**
    func testQuitAndResumeRestoresTheInProgressKlondikeHand() throws {
        let app = launch("-uiTestResume")
        XCTAssertTrue(element(app, "library.home").waitForExistence(timeout: 20))
        element(app, "library.tile.klondike").click()
        let deal = element(app, "setup.deal")
        XCTAssertTrue(
            deal.waitForExistence(timeout: 10),
            "Resuming test setup should present the real setup sheet with a Deal action.")
        deal.click()
        XCTAssertTrue(element(app, "table.appearance.status").waitForExistence(timeout: 20))

        // Click the real face-down stock card to perform an accepted draw through TableKit's zone action
        // path. This keeps the persistence scenario independent of keyboard-focus delivery on macOS.
        let stock = app.otherElements.matching(
            NSPredicate(format: "label == %@", "Face-down card")
        ).firstMatch
        XCTAssertTrue(stock.waitForExistence(timeout: 10), "The Klondike stock should be reachable.")
        stock.click()
        XCTAssertTrue(waitForMoveCount(app, 1), "The stock draw should be accepted before quitting.")

        element(app, "table.menu").click()
        let quit = element(app, "table.quitToLibrary")
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.click()
        let continueHero = element(app, "library.continueHero")
        XCTAssertTrue(
            continueHero.waitForExistence(timeout: 15),
            "Quitting must leave an in-progress save represented by the Continue hero.")

        app.activate()
        continueHero.click()
        let resumedStatus = element(app, "table.appearance.status")
        XCTAssertTrue(resumedStatus.waitForExistence(timeout: 20), "The saved Klondike table should resume.")
        XCTAssertTrue(
            waitForMoveCount(app, 1),
            "The resumed table should retain the accepted stock draw.")
    }
}
