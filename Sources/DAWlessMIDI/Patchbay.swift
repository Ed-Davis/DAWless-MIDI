import SwiftUI
import DAWlessCore

/// The routing matrix, laid out like the VCS3's pin board: inputs down the
/// left with letters, outputs across the top with numbers and their names
/// turned on end, and a pin in a hole for each connection.
///
/// White pins are plain routes, green pins are routes that change or filter
/// what passes, and red pins in the bottom row send clock.
struct Patchbay: View {
    @EnvironmentObject private var model: AppModel
    @State private var hover: PatchPoint?

    static let pitch: CGFloat = 20
    static let labelWidth: CGFloat = 176
    static let nameLength: CGFloat = 112
    static let headerHeight: CGFloat = 136
    static let boardPad: CGFloat = 9
    static let clockGap: CGFloat = 12
    static let labelGap: CGFloat = 6

    /// How wide the patchbay is for a number of outputs.
    static func width(outputs: Int) -> CGFloat {
        labelWidth + labelGap + boardPad * 2 + CGFloat(max(outputs, 4)) * pitch
    }

    var body: some View {
        let inputs = model.inputRows
        let outputs = model.outputRows
        VStack(alignment: .leading, spacing: 12) {
            PanelHeading(title: "Patchbay", detail: "inputs ▸ outputs")

            HStack(alignment: .top, spacing: Self.labelGap) {
                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(height: Self.headerHeight + Self.boardPad)
                    ForEach(Array(inputs.enumerated()), id: \.element.id) { i, row in
                        InputLabel(row: row, index: i, highlighted: hover?.row == i)
                            .frame(height: Self.pitch)
                    }
                    Color.clear.frame(height: Self.clockGap)
                    ClockLabel(highlighted: hover?.row == PatchPoint.clockRow)
                        .frame(height: Self.pitch)
                }
                .frame(width: Self.labelWidth)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(outputs.enumerated()), id: \.element.id) { j, row in
                            OutputHeader(row: row, index: j, highlighted: hover?.col == j)
                        }
                    }
                    .padding(.horizontal, Self.boardPad)
                    .frame(height: Self.headerHeight, alignment: .bottom)

                    board(inputs: inputs, outputs: outputs)
                }
            }

            Readout(hover: hover)
                .frame(width: Self.width(outputs: outputs.count), alignment: .leading)
            PinKey()
        }
        .padding(16)
        .fixedSize()
    }

    private func board(inputs: [DeviceRow], outputs: [DeviceRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(inputs.enumerated()), id: \.element.id) { i, input in
                HStack(spacing: 0) {
                    ForEach(Array(outputs.enumerated()), id: \.element.id) { j, output in
                        RouteHole(input: input, output: output, socket: PatchPoint(row: i, col: j), hover: $hover)
                    }
                }
            }
            Color.clear.frame(height: Self.clockGap)
            HStack(spacing: 0) {
                ForEach(Array(outputs.enumerated()), id: \.element.id) { j, output in
                    ClockHole(row: output, socket: PatchPoint(row: PatchPoint.clockRow, col: j), hover: $hover)
                }
            }
        }
        .frame(minWidth: outputs.isEmpty ? CGFloat(4) * Self.pitch : nil, alignment: .leading)
        .padding(Self.boardPad)
        .background(BoardFace(rows: inputs.count, cols: outputs.count, hover: hover))
        .overlay {
            if outputs.isEmpty {
                Text("No outputs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.45))
            }
        }
        .onHover { inside in if !inside { hover = nil } }
    }
}

/// A hole in the board: a row (an input, or the clock row) and a column (an output).
struct PatchPoint: Hashable {
    static let clockRow = -1
    let row: Int
    let col: Int
}

enum MatrixLabel {
    /// A, B … Z, then AA, AB …
    static func letter(_ i: Int) -> String {
        let s = String(UnicodeScalar(UInt8(65 + i % 26)))
        return i < 26 ? s : letter(i / 26 - 1) + s
    }

    static func number(_ j: Int) -> String { "\(j + 1)" }
}

// MARK: - The board

/// The board itself: an off-white plate with a line through every row and
/// column of holes, heavier lines every four, and screws in the corners.
private struct BoardFace: View {
    let rows: Int
    let cols: Int
    let hover: PatchPoint?

    var body: some View {
        Canvas { ctx, size in
            let p = Patchbay.pitch, pad = Patchbay.boardPad
            let plate = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            ctx.fill(plate, with: .color(VCS3.board))
            ctx.stroke(plate, with: .color(VCS3.boardEdge), lineWidth: 1.5)

            let clockY = pad + CGFloat(rows) * p + Patchbay.clockGap + p / 2
            func rowY(_ r: Int) -> CGFloat { r == PatchPoint.clockRow ? clockY : pad + (CGFloat(r) + 0.5) * p }
            let gridBottom = clockY + p / 2

            // Where the pointer is: light up its row and column.
            if let hover {
                let x = pad + CGFloat(hover.col) * p
                ctx.fill(Path(CGRect(x: x, y: pad, width: p, height: gridBottom - pad)), with: .color(VCS3.boardHover))
                ctx.fill(Path(CGRect(x: pad, y: rowY(hover.row) - p / 2, width: CGFloat(cols) * p, height: p)), with: .color(VCS3.boardHover))
            }

            // Lines through the holes.
            var fine = Path()
            for c in 0..<cols {
                let x = pad + (CGFloat(c) + 0.5) * p
                fine.move(to: CGPoint(x: x, y: pad))
                fine.addLine(to: CGPoint(x: x, y: gridBottom))
            }
            for r in Array(0..<rows) + [PatchPoint.clockRow] {
                let y = rowY(r)
                fine.move(to: CGPoint(x: pad, y: y))
                fine.addLine(to: CGPoint(x: pad + CGFloat(cols) * p, y: y))
            }
            ctx.stroke(fine, with: .color(VCS3.boardLine.opacity(0.45)), lineWidth: 0.5)

            // Heavier lines between groups of four, as on the real board.
            var groups = Path()
            for c in stride(from: 4, to: cols, by: 4) {
                let x = pad + CGFloat(c) * p
                groups.move(to: CGPoint(x: x, y: pad - 3))
                groups.addLine(to: CGPoint(x: x, y: gridBottom + 3))
            }
            for r in stride(from: 4, to: rows, by: 4) {
                let y = pad + CGFloat(r) * p
                groups.move(to: CGPoint(x: pad - 3, y: y))
                groups.addLine(to: CGPoint(x: pad + CGFloat(cols) * p + 3, y: y))
            }
            ctx.stroke(groups, with: .color(VCS3.boardLine), lineWidth: 1)

            // The clock row sits apart, under a double rule.
            let ruleY = pad + CGFloat(rows) * p + Patchbay.clockGap / 2
            for dy: CGFloat in [-1.5, 1.5] {
                var rule = Path()
                rule.move(to: CGPoint(x: pad - 3, y: ruleY + dy))
                rule.addLine(to: CGPoint(x: pad + CGFloat(cols) * p + 3, y: ruleY + dy))
                ctx.stroke(rule, with: .color(VCS3.boardLine), lineWidth: 0.8)
            }

            // Corner screws.
            for (x, y): (CGFloat, CGFloat) in [(4.5, 4.5), (size.width - 4.5, 4.5), (4.5, size.height - 4.5), (size.width - 4.5, size.height - 4.5)] {
                let r = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                ctx.fill(Path(ellipseIn: r), with: .color(VCS3.boardEdge))
                var slot = Path()
                slot.move(to: CGPoint(x: x - 1.8, y: y + 1.2))
                slot.addLine(to: CGPoint(x: x + 1.8, y: y - 1.2))
                ctx.stroke(slot, with: .color(Color.black.opacity(0.45)), lineWidth: 0.7)
            }
        }
    }
}

// MARK: - Sockets

private struct RouteHole: View {
    @EnvironmentObject private var model: AppModel
    let input: DeviceRow
    let output: DeviceRow
    let socket: PatchPoint
    @Binding var hover: PatchPoint?

    var body: some View {
        let routed = model.isRouted(input.device, output.device)
        let filter = routed ? model.filter(input.device, output.device).wrappedValue : RouteFilter()
        let kind: PinKind? = routed ? (filter.isDefault ? .white : .green) : nil
        HoleView(kind: kind, dim: !(input.online && output.online))
            .onTapGesture { toggle() }
            .onHover { inside in
                if inside { hover = socket } else if hover == socket { hover = nil }
            }
            .help(routed ? "\(input.name) → \(output.name): \(filter.inWords). Right-click for channels and filters."
                         : "Send \(input.name) to \(output.name)")
            .contextMenu { RouteMenu(input: input.device, output: output.device) }
            .accessibilityElement()
            .accessibilityLabel("\(input.name) to \(output.name)")
            .accessibilityValue(routed ? filter.inWords : "Not connected")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
    }

    private func toggle() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
            model.toggleRoute(input.device, output.device)
        }
    }
}

private struct ClockHole: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow
    let socket: PatchPoint
    @Binding var hover: PatchPoint?

    var body: some View {
        let on = model.patch.sendsClock(to: row.device)
        let off = model.patch.clockSource == .off
        HoleView(kind: on ? .red : nil, dim: off || !row.online)
            .onTapGesture { toggle() }
            .onHover { inside in
                if inside { hover = socket } else if hover == socket { hover = nil }
            }
            .help(off ? "Clock is off. Choose a clock source at the top to send clock to \(row.name)."
                      : on ? "\(row.name) gets clock from \(model.clockSourceName)" : "Send clock to \(row.name)")
            .accessibilityElement()
            .accessibilityLabel("Clock to \(row.name)")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
    }

    private func toggle() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
            model.clockBinding(row.device).wrappedValue.toggle()
        }
    }
}

/// One hole, with a pin in it or not.
private struct HoleView: View {
    let kind: PinKind?
    let dim: Bool

    var body: some View {
        ZStack {
            BoardHole()
            if let kind {
                PinHead(kind: kind, dim: dim)
                    .transition(.scale(scale: 1.7).combined(with: .opacity))
            }
        }
        .frame(width: Patchbay.pitch, height: Patchbay.pitch)
        .contentShape(Rectangle())
    }
}

// MARK: - Labels

private struct InputLabel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: MonitorModel
    let row: DeviceRow
    let index: Int
    let highlighted: Bool

    var body: some View {
        let monitored = monitor.focusSourceID == row.device.uniqueID
        HStack(spacing: 6) {
            Lamp(lit: model.litInputs.contains(row.device), present: row.online)
            Spacer(minLength: 0)
            if monitored {
                Image(systemName: "scope")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VCS3.lampAmber)
                    .help("The monitor is showing only this input")
            }
            if !row.online { Legend("off", size: 8, colour: VCS3.legendFaint) }
            Text(row.name)
                .font(.system(size: 11, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(highlighted ? VCS3.legend : VCS3.legend.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(MatrixLabel.letter(index))
                .font(VCS3.mono(10, weight: .bold))
                .foregroundStyle(highlighted ? VCS3.lampAmber : VCS3.legendDim)
                .frame(width: 18, alignment: .trailing)
        }
        .opacity(row.online ? 1 : 0.55)
        .contentShape(Rectangle())
        .help(row.online ? row.name : "\(row.name) (not connected)")
        .contextMenu {
            Button("Remove All Routes from \(row.name)") { model.clearRoutes(from: row.device) }
            if row.online {
                if monitored {
                    Button("Monitor All Inputs") { monitor.focusSourceID = nil }
                } else {
                    Button("Monitor Only \(row.name)") { monitor.focusSourceID = row.device.uniqueID }
                }
            } else {
                Button("Forget \(row.name)") { model.forget(input: row.device) }
            }
        }
    }
}

/// An output's name, turned on end so it reads up the page.
private struct OutputHeader: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow
    let index: Int
    let highlighted: Bool

    var body: some View {
        VStack(spacing: 3) {
            Lamp(lit: model.litOutputs.contains(row.device), size: 6, present: row.online)
            Text(row.name)
                .font(.system(size: 10.5, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(highlighted ? VCS3.legend : VCS3.legend.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Patchbay.nameLength, height: Patchbay.pitch, alignment: .leading)
                .rotationEffect(.degrees(-90))
                .frame(width: Patchbay.pitch, height: Patchbay.nameLength)
            Text(MatrixLabel.number(index))
                .font(VCS3.mono(9.5, weight: .bold))
                .foregroundStyle(highlighted ? VCS3.lampAmber : VCS3.legendDim)
                .frame(height: 12)
        }
        .frame(width: Patchbay.pitch)
        .opacity(row.online ? 1 : 0.55)
        .contentShape(Rectangle())
        .help(row.online ? row.name : "\(row.name) (not connected)")
        .contextMenu {
            Button("Remove All Routes to \(row.name)") { model.clearRoutes(to: row.device) }
            if !row.online {
                Button("Forget \(row.name)") { model.forget(output: row.device) }
            }
        }
    }
}

private struct ClockLabel: View {
    @EnvironmentObject private var model: AppModel
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "metronome")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VCS3.lampRed.opacity(model.patch.clockSource == .off ? 0.4 : 0.9))
            Legend("Clock", size: 10, colour: VCS3.legend)
            Text(model.clockSourceName)
                .font(.system(size: 10))
                .foregroundStyle(VCS3.legendDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("CK")
                .font(VCS3.mono(10, weight: .bold))
                .foregroundStyle(highlighted ? VCS3.lampAmber : VCS3.legendDim)
                .frame(width: 18, alignment: .trailing)
        }
        .help("Clock goes only to the outputs with a red pin in this row. Choose where it comes from at the top.")
    }
}

// MARK: - Readout and key

/// A line under the board saying what the hole under the pointer does.
private struct Readout: View {
    @EnvironmentObject private var model: AppModel
    let hover: PatchPoint?

    var body: some View {
        let lines = text
        VStack(alignment: .leading, spacing: 2) {
            Text(lines.0)
                .font(VCS3.mono(10.5, weight: .semibold))
                .foregroundStyle(VCS3.lampAmber)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(lines.1)
                .font(.system(size: 10.5))
                .foregroundStyle(VCS3.legendDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(VCS3.well))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(VCS3.rule, lineWidth: 1))
    }

    private var text: (String, String) {
        let inputs = model.inputRows, outputs = model.outputRows
        guard let hover, outputs.indices.contains(hover.col) else {
            return ("READY", "Click a hole to put a pin in. Right-click a pin for channels and filters.")
        }
        let output = outputs[hover.col]
        let column = MatrixLabel.number(hover.col)
        if hover.row == PatchPoint.clockRow {
            let on = model.patch.sendsClock(to: output.device)
            return ("CK → \(column)   Clock → \(output.name)",
                    model.patch.clockSource == .off ? "Clock is off. Choose a clock source at the top."
                    : on ? "Red pin: gets clock from \(model.clockSourceName)." : "Empty. Click to send clock here.")
        }
        guard inputs.indices.contains(hover.row) else { return ("", "") }
        let input = inputs[hover.row]
        let head = "\(MatrixLabel.letter(hover.row)) → \(column)   \(input.name) → \(output.name)"
        guard model.isRouted(input.device, output.device) else {
            return (head, "Empty. Click to send \(input.name) to \(output.name).")
        }
        let filter = model.filter(input.device, output.device).wrappedValue
        return (head, (filter.isDefault ? "White pin: " : "Green pin: ") + filter.inWords + ".")
    }
}

private struct PinKey: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.white, "Route")
            item(.green, "Channel or filter set")
            item(.red, "Clock")
        }
    }

    private func item(_ kind: PinKind, _ text: String) -> some View {
        HStack(spacing: 5) {
            PinHead(kind: kind, size: 10)
            Legend(text, size: 8.5)
        }
    }
}

extension RouteFilter {
    /// In words, for the readout and tooltips.
    var inWords: String {
        var parts: [String]
        switch (channel, sendOn) {
        case (nil, nil): parts = ["all channels, unchanged"]
        case let (c?, nil): parts = ["channel \(c) only"]
        case let (nil, s?): parts = ["all channels, sent on \(s)"]
        case let (c?, s?): parts = [c == s ? "channel \(c) only" : "channel \(c), sent on \(s)"]
        }
        if !blocked.isEmpty {
            let names = MessageKind.filterable.filter(blocked.contains).map { $0.label.lowercased() }
            parts.append("blocks " + names.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }
}
