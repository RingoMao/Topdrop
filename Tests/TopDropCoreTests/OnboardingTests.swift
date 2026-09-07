import Foundation
import TopDropCore

let onboardingTests: [UnitTest] = [
    UnitTest("Onboarding: Finish can provision the Notes folder itself") {
        let readiness = OnboardingSetupReadiness(
            notesPermission: .allowed,
            selectedAccountIdentifier: "icloud-account",
            notesFolderName: "TopDrop",
            hasScreenshotFolder: true
        )
        try expect(readiness.canFinalize)
        try expectEqual(readiness.missingRequirements, [])
    },
    UnitTest("Onboarding: missing prerequisites are reported explicitly") {
        let readiness = OnboardingSetupReadiness(
            notesPermission: .denied,
            selectedAccountIdentifier: "  ",
            notesFolderName: "\n",
            hasScreenshotFolder: false
        )
        try expect(!readiness.canFinalize)
        try expectEqual(
            readiness.missingRequirements,
            [.notesAutomation, .notesAccount, .notesFolderName, .screenshotFolder]
        )
    },
]
