import Foundation

public enum OnboardingSetupRequirement: String, Equatable, Sendable {
    case notesAutomation
    case notesAccount
    case notesFolderName
    case screenshotFolder
}

/// Requirements that must exist before onboarding can begin its finalization task.
///
/// A prepared Notes folder is intentionally not a prerequisite: finalization creates
/// or reuses that folder so users do not have to discover a separate required button.
public struct OnboardingSetupReadiness: Equatable, Sendable {
    public let missingRequirements: [OnboardingSetupRequirement]

    public var canFinalize: Bool { missingRequirements.isEmpty }

    public init(
        notesPermission: NotesAutomationPermission,
        selectedAccountIdentifier: String,
        notesFolderName: String,
        hasScreenshotFolder: Bool
    ) {
        var missing: [OnboardingSetupRequirement] = []
        if notesPermission != .allowed {
            missing.append(.notesAutomation)
        }
        if selectedAccountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.notesAccount)
        }
        if notesFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.notesFolderName)
        }
        if !hasScreenshotFolder {
            missing.append(.screenshotFolder)
        }
        missingRequirements = missing
    }
}
