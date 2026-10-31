// Candidate layout adapted from nagi (https://github.com/nvalleo/nagi),
// licensed under Apache License 2.0; see Nagi-LICENSE.txt.

import AppKit
import Observation
import SwiftUI

/// A candidate supplied by MoGRU's existing renderer protocol.
@objc(MoGRUCandidateItem)
public final class MoGRUCandidateItem: NSObject, Identifiable {
    @objc public let index: Int
    @objc public let candidateID: Int32
    @objc public let text: String
    @objc public let shortcut: String
    @objc public let descriptionText: String
    @objc public let hasSubCandidates: Bool

    public var id: Int { index }

    /// Creates the display data for one candidate on the current page.
    @objc public init(
        index: Int,
        candidateID: Int32,
        text: String,
        shortcut: String,
        descriptionText: String,
        hasSubCandidates: Bool
    ) {
        self.index = index
        self.candidateID = candidateID
        self.text = text
        self.shortcut = shortcut
        self.descriptionText = descriptionText
        self.hasSubCandidates = hasSubCandidates
    }

    /// Whether this candidate should use nagi's compact pictograph grid.
    public var isPictograph: Bool {
        descriptionText.hasPrefix("絵文字") || descriptionText.hasPrefix("顔文字")
    }
}

/// Receives mouse selections and forwards them to the existing Mozc session.
@objc(MoGRUCandidateSelectionDelegate)
public protocol MoGRUCandidateSelectionDelegate: AnyObject {
    /// Selects the candidate identified by Mozc's stable candidate ID.
    func candidateView(_ view: MoGRUCandidateView, didSelectCandidateWithID candidateID: Int32)
}

/// Observable state shared by the AppKit host and the SwiftUI candidate list.
@MainActor
@Observable
private final class CandidateListState {
    var candidates: [MoGRUCandidateItem] = []
    var focusedIndex: Int = -1
    var footer = ""

    init(
        candidates: [MoGRUCandidateItem] = [],
        focusedIndex: Int = -1,
        footer: String = ""
    ) {
        self.candidates = candidates
        self.focusedIndex = focusedIndex
        self.footer = footer
    }
}

/// A nonactivating candidate view embedded in MoGRU's renderer window.
@objc(MoGRUCandidateView)
public final class MoGRUCandidateView: NSView {
    private let state: CandidateListState
    private lazy var hostingView = NSHostingView(
        rootView: CandidateListView(state: state, selectCandidate: { [weak self] candidateID in
            guard let self else { return }
            self.selectionDelegate?.candidateView(self, didSelectCandidateWithID: candidateID)
        })
    )

    @objc public var selectionDelegate: MoGRUCandidateSelectionDelegate?

    /// Creates a SwiftUI backed view for the existing AppKit renderer window.
    public override init(frame frameRect: NSRect) {
        let state = CandidateListState()
        self.state = state
        super.init(frame: frameRect)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
    }

    /// Interface Builder is not used by the renderer.
    public required init?(coder: NSCoder) {
        return nil
    }

    /// Refreshes the displayed page, focus, and footer from one renderer update.
    @objc public func update(
        with candidates: [MoGRUCandidateItem],
        focusedIndex: Int,
        footer: String
    ) {
        state.candidates = candidates
        state.focusedIndex = focusedIndex
        state.footer = footer
        hostingView.invalidateIntrinsicContentSize()
        hostingView.needsLayout = true
    }

    /// Returns the SwiftUI content size for the surrounding NSPanel.
    @objc public var preferredSize: NSSize {
        // Resolve pending SwiftUI layout before positioning the panel.
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        return NSSize(width: max(180, fitting.width), height: min(300, fitting.height))
    }

    /// Returns a candidate's current row in AppKit coordinates for a submenu.
    @objc public func frameForCandidate(at index: Int) -> NSRect {
        CandidateListView(state: state)
            .frame(forCandidateAt: index, in: preferredSize) ?? .zero
    }
}

/// Nagi's candidate layout adapted to MoGRU's renderer data.
private struct CandidateListView: View {
    let state: CandidateListState
    let selectCandidate: (Int32) -> Void
    @Namespace private var focusNamespace

    private static let animationEnabled = true
    private static let animationDuration = 0.1
    private static let footerEnabled = false
    private static let fontSize: CGFloat = 15
    private static let rowHeight: CGFloat = 27
    private static let gridColumns = 9
    private static let gridCellSize: CGFloat = 26
    private static let gridVerticalPadding: CGFloat = 4
    private static let maxRows = 10
    private static let dividerHeight: CGFloat = 1
    private static let focusCornerRadius: CGFloat = 8

    init(
        state: CandidateListState,
        selectCandidate: @escaping (Int32) -> Void = { _ in }
    ) {
        self.state = state
        self.selectCandidate = selectCandidate
    }

    private enum Row: Identifiable {
        case text(MoGRUCandidateItem)
        case grid([MoGRUCandidateItem])

        var id: Int {
            switch self {
            case .text(let candidate): return candidate.index
            case .grid(let candidates): return candidates.first?.index ?? -1
            }
        }

        @MainActor var height: CGFloat {
            switch self {
            case .text: return CandidateListView.rowHeight
            case .grid: return CandidateListView.gridCellSize + CandidateListView.gridVerticalPadding * 2
            }
        }

        func contains(_ index: Int) -> Bool {
            switch self {
            case .text(let candidate): return candidate.index == index
            case .grid(let candidates): return candidates.contains { $0.index == index }
            }
        }

        var isText: Bool {
            if case .text = self {
                return true
            }
            return false
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        var pictographs: [MoGRUCandidateItem] = []

        for candidate in state.candidates {
            if candidate.isPictograph {
                pictographs.append(candidate)
                if pictographs.count == Self.gridColumns {
                    result.append(.grid(pictographs))
                    pictographs.removeAll()
                }
            } else {
                if !pictographs.isEmpty {
                    result.append(.grid(pictographs))
                    pictographs.removeAll()
                }
                result.append(.text(candidate))
            }
        }
        if !pictographs.isEmpty {
            result.append(.grid(pictographs))
        }
        return result
    }

    private var visibleRows: [Row] {
        let allRows = rows
        guard allRows.count > Self.maxRows else { return allRows }
        let focusedRow = allRows.firstIndex { $0.contains(state.focusedIndex) } ?? 0
        let start = min(max(0, focusedRow - Self.maxRows / 2), allRows.count - Self.maxRows)
        return Array(allRows[start..<(start + Self.maxRows)])
    }

    /// Finds the visible row for a candidate in AppKit's bottom-up coordinates.
    func frame(forCandidateAt index: Int, in size: NSSize) -> NSRect? {
        var topOffset: CGFloat = 4
        for (rowIndex, row) in visibleRows.enumerated() {
            if rowIndex > 0 && row.isText && visibleRows[rowIndex - 1].isText {
                topOffset += Self.dividerHeight
            }
            if row.contains(index) {
                return NSRect(
                    x: 0,
                    y: size.height - topOffset - row.height,
                    width: size.width,
                    height: row.height
                )
            }
            topOffset += row.height
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 && row.isText && visibleRows[index - 1].isText {
                    Divider()
                        .frame(height: Self.dividerHeight)
                        .opacity(
                            row.contains(state.focusedIndex) ||
                            visibleRows[index - 1].contains(state.focusedIndex) ? 0 : 0.5
                        )
                }
                switch row {
                case .text(let candidate):
                    textRow(candidate)
                case .grid(let candidates):
                    gridRow(candidates)
                }
            }
            if Self.footerEnabled && !state.footer.isEmpty {
                Text(state.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .padding(4)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: true, vertical: false)
        .animation(
            Self.animationEnabled ? .easeInOut(duration: Self.animationDuration) : nil,
            value: state.focusedIndex
        )
    }

    private func textRow(_ candidate: MoGRUCandidateItem) -> some View {
        HStack(spacing: 6) {
            Text(candidate.shortcut.isEmpty ? String(candidate.index + 1) : candidate.shortcut)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
//                .frame(width: 20, alignment: .trailing)
            Text(candidate.text)
                .font(.system(size: Self.fontSize))
            if candidate.hasSubCandidates {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !candidate.descriptionText.isEmpty {
                Text(candidate.descriptionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if candidate.index == state.focusedIndex {
                RoundedRectangle(cornerRadius: Self.focusCornerRadius)
                    .fill(Color.accentColor.opacity(0.18))
                    .matchedGeometryEffect(id: "focus", in: focusNamespace)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectCandidate(candidate.candidateID) }
        .accessibilityLabel("\(candidate.index + 1). \(candidate.text)")
    }

    private func gridRow(_ candidates: [MoGRUCandidateItem]) -> some View {
        HStack(spacing: 4) {
            ForEach(candidates) { candidate in
                Text(candidate.text)
                    .font(.system(size: 20))
                    .frame(width: Self.gridCellSize, height: Self.gridCellSize)
                    .background {
                        if candidate.index == state.focusedIndex {
                            RoundedRectangle(cornerRadius: Self.focusCornerRadius)
                                .fill(Color.accentColor.opacity(0.25))
                                .matchedGeometryEffect(id: "focus", in: focusNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectCandidate(candidate.candidateID) }
                    .accessibilityLabel(candidate.text)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, Self.gridVerticalPadding)
    }
}
