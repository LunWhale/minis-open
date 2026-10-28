//
//  ComposerUndoAfterProgrammaticTextTests.swift
//  MinisTests
//
//  [T-composer-undo-range-crash] TestFlight crashpoint CvY8hje8GickQbwj8mQbej
//  (1.15 (12), iPad8,10, iOS 16.2): SIGABRT from
//  -[NSMutableRLEArray replaceObjectsInRange:withObject:length:] under
//  -[_UITextUndoOperationTyping undoRedo], reached from the Undo button on the
//  iPad keyboard's shortcut bar. The composer's updateUIView replaces the whole
//  text from code (cleared after send, draft restored), and UITextView keeps
//  the typing-undo records of the text it had before. Undo then replays a
//  range of the OLD text against the new, shorter storage and raises
//  NSRangeException, which aborts the app.
//
//  These tests type into a real PastableUITextView, replace its text the way
//  updateUIView does, and press Undo inside an Objective-C @try so a raise is
//  a test failure instead of a crashed test host.
//

import XCTest
import UIKit
@testable import Minis

@MainActor
final class ComposerUndoAfterProgrammaticTextTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// A composer in a key window. The hosted test app cannot always make it
    /// first responder, but insertText registers typing undo either way (each
    /// test asserts canUndo as its premise).
    private func makeComposer() -> PastableUITextView {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController()
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        let tv = PastableUITextView(frame: CGRect(x: 0, y: 100, width: 390, height: 120))
        vc.view.addSubview(tv)
        _ = tv.becomeFirstResponder()
        return tv
    }

    /// Let the undo manager close the current group (it groups by run-loop pass).
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func type(_ s: String, into tv: PastableUITextView) {
        tv.insertText(s)
        settle()
    }

    /// Press Undo the way the keyboard's shortcut bar does; nil = no raise.
    private func undoCatchingRaise(_ tv: PastableUITextView) -> String? {
        var reason: NSString?
        let ok = MinisCatchObjCException({
            if tv.undoManager?.canUndo == true { tv.undoManager?.undo() }
        }, &reason)
        settle()
        return ok ? nil : (reason as String? ?? "raised")
    }

    func testUndoAfterClearingPostSendDoesNotRaise() {
        let tv = makeComposer()
        type("hello world, a message long enough to send", into: tv)
        XCTAssertEqual(tv.undoManager?.canUndo, true, "test premise: typing registered an undo")

        tv.applyProgrammaticText("")          // what updateUIView does after send
        settle()

        XCTAssertNil(undoCatchingRaise(tv))
        XCTAssertEqual(tv.text, "")
    }

    func testUndoAfterReplacingWithShorterDraftDoesNotRaise() {
        let tv = makeComposer()
        type("a long draft that the user typed in this session", into: tv)
        XCTAssertEqual(tv.undoManager?.canUndo, true, "test premise: typing registered an undo")

        tv.applyProgrammaticText("hi")        // e.g. another session's draft restored
        settle()

        XCTAssertNil(undoCatchingRaise(tv))
        XCTAssertEqual(tv.text, "hi")
    }

    func testTypingAfterAProgrammaticWriteIsStillUndoable() {
        let tv = makeComposer()
        type("old text", into: tv)
        tv.applyProgrammaticText("")
        settle()

        type("new", into: tv)
        XCTAssertEqual(tv.undoManager?.canUndo, true, "Undo keeps working for text typed afterwards")
        XCTAssertNil(undoCatchingRaise(tv))
        XCTAssertEqual(tv.text, "", "undo removes only what was typed after the write")
    }
}
