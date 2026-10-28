//
//  MinisTestHostApp.swift
//  MinisTestHost - the process the MinisTests unit-test bundle runs in.
//
//  [T-ios-unit-test-infra] Why this exists: MinisTests used to be hosted by
//  Minis.app itself (TEST_HOST = Minis.app/Minis). Running it on a Mac
//  ("Designed for iPad") launched the real app under com.openminis.app, in the
//  real ~/Library/Containers/<uuid> and App Group, and rewrote real data
//  (2026-10-04 08:30). This host has its own bundle id
//  (com.openminis.MinisTestHost), so the system gives it its own container. It
//  is signed with no entitlements: no App Group, no iCloud, no shared keychain
//  group, so it cannot reach the app's data even by path.
//
//  It runs none of the app: the test bundle links Minis.debug.dylib (the Debug
//  app's code) and calls it directly. Do not add app code, storage, networking
//  or startup work here; the host must stay inert. scripts/ios-unit-tests.sh
//  refuses to run if the built host's bundle id or entitlements change.
//
//  Resources: the jieba dictionaries (jieba.dict.utf8, hmm_model.utf8) are
//  copied into this bundle because JiebaWrapper, now inside Minis.debug.dylib,
//  falls back to the main bundle to find them - which here is this host.
//

import SwiftUI

@main
struct MinisTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("MinisTestHost: unit-test host, no app code")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
