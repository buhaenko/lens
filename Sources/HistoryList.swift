// What the history popover is doing right now: the search, the row picked with the arrow keys,
// the last deletion that can be undone, and the "are you sure?" step of Clear.
// Kept out of the view so the keyboard (AppDelegate's key monitor) and the tests drive the same logic.

import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor final class HistoryList: ObservableObject {
    let history: History
    @Published var query = ""
    @Published var selected: UUID?
    @Published private(set) var undo: Undo?
    @Published private(set) var confirmingClear = false
    var open: (Scan) -> Void = { _ in }

    struct Undo: Equatable {
        let scans: [Scan]
        let id = UUID()
        var text: String {
            scans.count == 1 ? String(localized: "Deleted") : String(localized: "Cleared \(scans.count) scans")
        }
    }

    /// How long Undo stays offered, and how long Clear waits for the second click.
    var undoDuration: Duration = .seconds(6)
    var confirmDuration: Duration = .seconds(3)
    private var undoTimer: Task<Void, Never>?
    private var confirmTimer: Task<Void, Never>?

    init(history: History? = nil) { self.history = history ?? .shared }

    var pinned: [Scan] { history.pinned.filter { $0.matches(query) } }
    var recent: [Scan] { history.recent.filter { $0.matches(query) } }
    /// Top to bottom, as shown — what ↑ / ↓ walk through.
    var visible: [Scan] { pinned + recent }

    /// Every popover opening starts fresh: empty search, nothing picked, nothing pending.
    func reset() {
        query = ""
        selected = nil
        confirmingClear = false
        confirmTimer?.cancel()
    }

    // MARK: Changes — all animated, all undoable

    func remove(_ id: UUID) {
        let next = neighbour(of: id)
        var removed: [Scan] = []
        withAnimation(Motion.list) {
            removed = history.remove(id)
            if selected == id { selected = next }
        }
        offerUndo(removed)
    }

    func togglePin(_ id: UUID) {
        withAnimation(Motion.list) { history.togglePin(id) }
    }

    /// First click asks, second click clears (and can still be undone).
    func clear() {
        guard confirmingClear else {
            withAnimation(Motion.quick) { confirmingClear = true }
            confirmTimer?.cancel()
            confirmTimer = Task { [weak self, confirmDuration] in
                try? await Task.sleep(for: confirmDuration)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.quick) { self?.confirmingClear = false }
            }
            return
        }
        confirmTimer?.cancel()
        var removed: [Scan] = []
        withAnimation(Motion.list) {
            confirmingClear = false
            removed = history.clear()
            if let selected, !history.items.contains(where: { $0.id == selected }) { self.selected = nil }
        }
        offerUndo(removed)
    }

    func undoLast() {
        guard let undo else { return }
        undoTimer?.cancel()
        withAnimation(Motion.list) {
            history.restore(undo.scans)
            self.undo = nil
        }
    }

    private func offerUndo(_ scans: [Scan]) {
        guard !scans.isEmpty else { return }
        let offer = Undo(scans: scans)
        withAnimation(Motion.quick) { undo = offer }
        undoTimer?.cancel()
        undoTimer = Task { [weak self, undoDuration] in
            try? await Task.sleep(for: undoDuration)
            guard !Task.isCancelled, self?.undo?.id == offer.id else { return }
            withAnimation(Motion.quick) { self?.undo = nil }
        }
    }

    // MARK: Keyboard

    func move(_ step: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = selected.flatMap { id in list.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        withAnimation(Motion.quick) { selected = list[next].id }
    }

    private func neighbour(of id: UUID) -> UUID? {
        let list = visible
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1 < list.count ? list[index + 1].id : index > 0 ? list[index - 1].id : nil
    }

    private var current: Scan? { selected.flatMap { id in history.items.first { $0.id == id } } }

    /// ↑ ↓ pick · ↩ open · ⌘⌫ delete · ⌘C copy · ⌘P pin · ⌘Z undo. Returns false for keys it leaves to the search field.
    @discardableResult func handleKey(_ code: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        switch (code, mods) {
        case (kVK_DownArrow, []): move(1)
        case (kVK_UpArrow, []): move(-1)
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            guard let scan = current ?? (visible.count == 1 ? visible.first : nil) else { return false }
            open(scan)
        case (kVK_Delete, .command), (kVK_ForwardDelete, []):
            guard let id = current?.id else { return false }
            remove(id)
        case (kVK_ANSI_C, .command):
            guard let scan = current else { return false }        // nothing picked: ⌘C copies the search text as usual
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(scan.translated, forType: .string)
        case (kVK_ANSI_P, .command):
            guard let id = current?.id else { return false }
            togglePin(id)
        case (kVK_ANSI_Z, .command):
            guard undo != nil else { return false }
            undoLast()
        case (kVK_Escape, []) where !query.isEmpty || selected != nil:
            withAnimation(Motion.quick) { query = ""; selected = nil }
        default:
            return false
        }
        return true
    }
}

/// One motion for the whole app: quick, soft, no bounce to wait for — and a plain fade with Reduce Motion on.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var list: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.86) }
    static var quick: Animation { reduced ? .easeOut(duration: 0.1) : .easeOut(duration: 0.16) }
}
