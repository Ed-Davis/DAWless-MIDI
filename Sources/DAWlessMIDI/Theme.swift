import SwiftUI

/// The look of the window: a black front panel with off-white legends and a
/// pin matrix board, after the EMS VCS3.
enum VCS3 {
    static let panel = Color(red: 0.102, green: 0.100, blue: 0.096)
    static let panelRaised = Color(red: 0.145, green: 0.141, blue: 0.135)
    static let panelLit = Color(red: 0.195, green: 0.188, blue: 0.178)
    static let well = Color(red: 0.070, green: 0.069, blue: 0.066)
    static let legend = Color(red: 0.925, green: 0.905, blue: 0.855)
    static let legendDim = legend.opacity(0.55)
    static let legendFaint = legend.opacity(0.30)
    static let rule = legend.opacity(0.22)

    // The matrix board
    static let board = Color(red: 0.885, green: 0.872, blue: 0.828)
    static let boardEdge = Color(red: 0.62, green: 0.61, blue: 0.57)
    static let boardLine = Color(red: 0.20, green: 0.20, blue: 0.19).opacity(0.38)
    static let boardHover = Color(red: 0.95, green: 0.62, blue: 0.20).opacity(0.18)
    static let hole = Color(red: 0.12, green: 0.12, blue: 0.115)

    // Lamps
    static let lampGreen = Color(red: 0.42, green: 0.98, blue: 0.48)
    static let lampAmber = Color(red: 1.00, green: 0.70, blue: 0.22)
    static let lampRed = Color(red: 1.00, green: 0.30, blue: 0.24)
    static let lampViolet = Color(red: 0.78, green: 0.55, blue: 1.00)
    static let lampBlue = Color(red: 0.45, green: 0.75, blue: 1.00)

    static func legendFont(_ size: CGFloat = 9.5, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 10.5, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Panel lettering: small, upper case, spaced out.
struct Legend: View {
    let text: String
    var size: CGFloat = 9.5
    var colour: Color = VCS3.legendDim

    init(_ text: String, size: CGFloat = 9.5, colour: Color = VCS3.legendDim) {
        self.text = text
        self.size = size
        self.colour = colour
    }

    var body: some View {
        Text(text.uppercased())
            .font(VCS3.legendFont(size))
            .tracking(size * 0.09)
            .foregroundStyle(colour)
            .lineLimit(1)
    }
}

/// A small indicator lamp that glows when lit.
struct Lamp: View {
    let lit: Bool
    var colour: Color = VCS3.lampGreen
    var size: CGFloat = 7
    var present = true

    var body: some View {
        Circle()
            .fill(lit ? colour : Color.black.opacity(present ? 0.55 : 0.3))
            .overlay(Circle().strokeBorder(Color.white.opacity(lit ? 0.35 : 0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: lit ? colour.opacity(0.9) : .clear, radius: size * 0.55)
    }
}

/// A module on the front panel: a title in panel lettering above its controls,
/// set in a recessed box with a thin rule around it.
struct PanelModule<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Legend(title, size: 10, colour: VCS3.legend)
                Rectangle().fill(VCS3.rule).frame(height: 1)
                if let trailing { trailing }
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 5).fill(VCS3.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(VCS3.rule, lineWidth: 1))
    }
}

/// A heading across a section of the panel: lettering with a rule running off it.
struct PanelHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Legend(title, size: 10.5, colour: VCS3.legend)
            if let detail { Legend(detail, size: 9) }
            Rectangle().fill(VCS3.rule).frame(height: 1)
        }
    }
}

// MARK: - Pins

/// The three pin colours of the VCS3 matrix.
enum PinKind {
    /// A plain route.
    case white
    /// A route that changes or filters what passes (the VCS3's green pins attenuate).
    case green
    /// Clock.
    case red

    var colours: (hi: Color, mid: Color, lo: Color) {
        switch self {
        case .white: return (Color(white: 1.0), Color(white: 0.93), Color(white: 0.66))
        case .green: return (Color(red: 0.55, green: 0.86, blue: 0.58), Color(red: 0.13, green: 0.58, blue: 0.27), Color(red: 0.05, green: 0.30, blue: 0.13))
        case .red: return (Color(red: 1.0, green: 0.55, blue: 0.48), Color(red: 0.84, green: 0.15, blue: 0.12), Color(red: 0.45, green: 0.05, blue: 0.04))
        }
    }

    var name: String {
        switch self {
        case .white: return "White pin"
        case .green: return "Green pin"
        case .red: return "Red pin"
        }
    }
}

/// A pin head, seen from above, with a highlight and a shadow on the board.
struct PinHead: View {
    let kind: PinKind
    var size: CGFloat = 13
    var dim = false

    var body: some View {
        let c = kind.colours
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .offset(x: size * 0.07, y: size * 0.12)
                .blur(radius: size * 0.07)
            Circle()
                .fill(RadialGradient(colors: [c.hi, c.mid, c.lo],
                                     center: UnitPoint(x: 0.36, y: 0.30),
                                     startRadius: 0, endRadius: size * 0.62))
            Circle()
                .strokeBorder(Color.black.opacity(0.45), lineWidth: 0.6)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: -size * 0.16, y: -size * 0.18)
                .blur(radius: 0.3)
        }
        .frame(width: size, height: size)
        .opacity(dim ? 0.45 : 1)
    }
}

/// An empty hole in the board.
struct BoardHole: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(VCS3.hole)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
            .background(Circle().fill(Color.white.opacity(0.7)).offset(y: 0.6))
            .frame(width: size, height: size)
    }
}
