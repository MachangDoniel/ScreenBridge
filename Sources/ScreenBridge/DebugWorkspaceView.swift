#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import SwiftUI
import UIKit
import ScreenBridgeProtocol

/// The screenshot and annotations share pixel coordinates. Only the movable tool
/// palette overlays the app; selection details live in the More sheet.
struct DebugWorkspaceView: View {
    @ObservedObject var model: InspectorModel
    let onMore: () -> Void
    let onSend: (ClaudeDestination) -> Void
    @AppStorage("ScreenBridge.toolsCorner") private var corner = "topRight"
    @State private var toolsHidden = false
    @GestureState private var translation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let width = min(392, max(48, geometry.size.width - 16))
            let size = toolsHidden ? CGSize(width: 44, height: 44)
                : CGSize(width: width, height: model.hasEdits ? 102 : 52)
            let origin = center(in: geometry.size, palette: size)
            ZStack(alignment: .topLeading) {
                if let capture = model.capture {
                    AnnotationCanvas(image: capture.image,
                                     pixelSize: CGSize(width: capture.cgImage.width, height: capture.cgImage.height),
                                     scale: capture.scale, annotations: $model.annotations, tool: model.tool,
                                     color: model.annotationColor, mode: model.workspaceMode,
                                     selectedRegion: model.selectedRegion, selectedFrame: model.selection?.element?.frameInScreenshot,
                                     onSelect: model.onSelectPoint, onRegion: { region in
                        model.selectArea(region)
                    })
                    .ignoresSafeArea()
                    .allowsHitTesting(!toolsHidden)
                }
                Group {
                    if toolsHidden {
                        Button { toolsHidden = false } label: {
                            Image(systemName: "viewfinder").font(.title3).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Show tools")
                        .simultaneousGesture(drag(in: geometry.size, palette: size))
                    } else {
                        palette(in: geometry.size, size: size)
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(clamped(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                                  in: geometry.size, palette: size))
            }
        }
        .coordinateSpace(name: "screenbridge.workspace")
        .tint(.blue)
    }

    private func palette(in available: CGSize, size: CGSize) -> some View {
        let toolWidth = max(28, (size.width - 74) / 9)
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 0) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel("Move tools")
                    .accessibilityIdentifier("screenbridge.drag")
                    .accessibilityAction(named: "Move to next corner") { nextCorner() }
                    .gesture(drag(in: available, palette: size))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        toolButton("Select", "cursorarrow", width: toolWidth,
                                   selected: model.workspaceMode == .inspect, tint: .purple) {
                            model.workspaceMode = .inspect
                        }
                        Divider().frame(width: 1, height: 20).padding(.horizontal, 1)
                        ForEach([AnnotationTool.pen, .rectangle, .ellipse, .arrow], id: \.self) { tool in
                            toolButton(tool == .rectangle ? "Rect" : tool.title, tool.symbol, width: toolWidth,
                                       selected: model.workspaceMode == .draw && model.tool == tool, tint: .blue) {
                                if model.workspaceMode == .draw && model.tool == tool {
                                    model.workspaceMode = .inspect
                                } else {
                                    model.workspaceMode = .draw
                                    model.tool = tool
                                }
                            }
                        }
                        toolButton("Edit annotations", "cursorarrow.motionlines", width: toolWidth,
                                   selected: model.workspaceMode == .editAnnotations, tint: .orange) {
                            model.workspaceMode = .editAnnotations
                        }
                        Divider().frame(width: 1, height: 20).padding(.horizontal, 1)
                        toolButton("Undo", "arrow.uturn.backward", width: toolWidth) { model.undo() }.disabled(!model.canUndo)
                        toolButton("Redo", "arrow.uturn.forward", width: toolWidth) { model.redo() }.disabled(!model.canRedo)
                        toolButton("More", "ellipsis", width: toolWidth) { onMore() }.accessibilityIdentifier("screenbridge.more")
                    }
                }
                Button { toolsHidden = true } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide tools")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                    .contentShape(Rectangle())
                    .gesture(drag(in: available, palette: size))
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            if model.hasEdits {
                HStack(spacing: 0) {
                    Button { onSend(.inbox) } label: {
                        Label("Send", systemImage: "paperplane").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 40)
                    }
                    .accessibilityIdentifier("screenbridge.send")
                    Divider().frame(height: 18)
                    Button { onSend(.code) } label: {
                        ClaudeMark().stroke(Color(red: 0.8, green: 0.4, blue: 0.29), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .frame(width: 21, height: 21).frame(width: 44, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send to Claude")
                    .accessibilityIdentifier("screenbridge.claude")
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 13).fill(.regularMaterial)
                        .contentShape(Rectangle())
                        .gesture(drag(in: available, palette: size))
                }
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.1)).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                .padding(.trailing, 4)
            }
        }
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(drag(in: available, palette: size))
        }
    }

    private func center(in available: CGSize, palette: CGSize) -> CGPoint {
        CGPoint(x: corner.hasSuffix("Right") ? available.width - palette.width / 2 - 8 : palette.width / 2 + 8,
                y: corner.hasPrefix("bottom") ? available.height - palette.height / 2 - 8 : palette.height / 2 + 8)
    }

    private func clamped(_ point: CGPoint, in available: CGSize, palette: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, palette.width / 2 + 8), available.width - palette.width / 2 - 8),
                y: min(max(point.y, palette.height / 2 + 8), available.height - palette.height / 2 - 8))
    }

    private func drag(in available: CGSize, palette: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("screenbridge.workspace"))
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in
                let current = center(in: available, palette: palette)
                let end = CGPoint(x: current.x + value.translation.width, y: current.y + value.translation.height)
                corner = (end.y > available.height / 2 ? "bottom" : "top")
                    + (end.x > available.width / 2 ? "Right" : "Left")
            }
    }

    private func nextCorner() {
        let corners = ["topRight", "bottomRight", "bottomLeft", "topLeft"]
        corner = corners[((corners.firstIndex(of: corner) ?? 0) + 1) % corners.count]
    }

    private func toolButton(_ title: String, _ symbol: String, width: CGFloat, selected: Bool = false, tint: Color = .primary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: width, height: 40)
                .foregroundStyle(tint)
                .background(selected ? tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for index in 0..<12 {
            let angle = CGFloat(index) * .pi / 6
            let radius = min(rect.width, rect.height) * (index.isMultiple(of: 3) ? 0.46 : 0.4)
            path.move(to: CGPoint(x: center.x + cos(angle) * 2, y: center.y + sin(angle) * 2))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        }
        return path
    }
}

extension AnnotationTool {
    var title: String {
        switch self {
        case .pen: return "Pen"
        case .ellipse: return "Ellipse"
        case .rectangle: return "Rectangle"
        case .arrow: return "Arrow"
        case .redaction: return "Redact"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .ellipse: return "circle"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .redaction: return "rectangle.fill"
        }
    }
}

struct AnnotationColorPicker: View {
    @Binding var color: SBColor
    private let choices: [(String, SBColor)] = [
        ("Red", .markup), ("Orange", SBColor(red: 1, green: 0.55, blue: 0)),
        ("Yellow", SBColor(red: 1, green: 0.85, blue: 0)), ("Green", SBColor(red: 0.2, green: 0.8, blue: 0.35)),
        ("Blue", SBColor(red: 0, green: 0.48, blue: 1)), ("Purple", SBColor(red: 0.7, green: 0.32, blue: 0.9)),
        ("White", SBColor(red: 1, green: 1, blue: 1)), ("Black", .redaction)
    ]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                Button { color = choice.1 } label: {
                    Circle().fill(Color(red: choice.1.red, green: choice.1.green, blue: choice.1.blue))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.gray.opacity(0.5)))
                        .padding(4)
                        .overlay(Circle().strokeBorder(color == choice.1 ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(choice.0) annotation color")
                .accessibilityAddTraits(color == choice.1 ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AppLogsView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let entries = LogStore.shared.recent(limit: 200)
            List {
                Section {
                    if entries.isEmpty { Text("No app logs yet. Call ScreenBridge.log from your app.").foregroundStyle(.secondary) }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) · \(entry.level) · \(entry.category)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("ScreenBridge app logs and connection diagnostics. System and Xcode loader messages are not collected. Logged messages also print to the Debug console.")
                }
            }
        }
        .navigationTitle("App logs")
    }
}
#endif
