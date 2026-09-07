@preconcurrency import AppKit
import Foundation
import SwiftUI
import TopDropCore

@MainActor
final class TopDropAccessoryManager: ObservableObject {
    @Published private(set) var items = TopDropAccessory.defaults
    @Published private(set) var activeAccessoryID: UUID?
    @Published var lastErrorMessage: String?

    var onChange: (([TopDropAccessory]) -> Void)?
    var onBuiltinAction: ((TopDropBuiltinAccessory) -> Void)?

    private var feedbackTask: Task<Void, Never>?

    var availableBuiltins: [TopDropBuiltinAccessory] {
        let installed = Set(
            items.compactMap { item -> TopDropBuiltinAccessory? in
                guard case .builtin(let builtin) = item.kind else { return nil }
                return builtin
            })
        return TopDropBuiltinAccessory.allCases.filter { !installed.contains($0) }
    }

    func apply(_ accessories: [TopDropAccessory]) {
        items = TopDropAccessory.normalized(accessories)
    }

    func addBuiltin(_ builtin: TopDropBuiltinAccessory) {
        guard availableBuiltins.contains(builtin) else { return }
        items.append(.builtin(builtin))
        publish()
    }

    @discardableResult
    func addShortcut(
        name: String,
        input: TopDropShortcutInput
    ) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastErrorMessage = "Enter the shortcut name exactly as it appears in Apple Shortcuts."
            return false
        }
        items.append(.shortcut(name: normalized, input: input))
        lastErrorMessage = nil
        publish()
        return true
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        publish()
    }

    func move(id: UUID, onto targetID: UUID) {
        let updated = TopDropAccessoryOrdering.move(
            items,
            id: id,
            onto: targetID
        )
        guard updated != items else { return }
        items = updated
        publish()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var result = items
        result.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard result != items else { return }
        items = result
        publish()
    }

    func invoke(_ accessory: TopDropAccessory) {
        lastErrorMessage = nil
        switch accessory.kind {
        case .builtin(let builtin):
            onBuiltinAction?(builtin)
            showFeedback(for: accessory.id)
        case .shortcut(let name, let input):
            guard let url = TopDropShortcutURLBuilder.runURL(name: name, input: input),
                NSWorkspace.shared.open(url)
            else {
                lastErrorMessage = "Could not open “\(name)” in Apple Shortcuts. Confirm that the shortcut exists."
                return
            }
            showFeedback(for: accessory.id)
        }
    }

    func openShortcuts() {
        guard let url = URL(string: "shortcuts://") else { return }
        if !NSWorkspace.shared.open(url) {
            lastErrorMessage = "Could not open Apple Shortcuts."
        }
    }

    private func publish() {
        items = TopDropAccessory.normalized(items)
        onChange?(items)
    }

    private func showFeedback(for id: UUID) {
        activeAccessoryID = id
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch { return }
            self?.activeAccessoryID = nil
        }
    }
}
