import SwiftUI
import AppleWatchCursorCore

struct AxisCalibrationView: View {
    @ObservedObject var model: MacPilotModel
    private var cue: (title: String, detail: String, icon: String, color: Color) {
        if model.axisStep == .review { return ("READY TO GO", "Calibration saved", "checkmark.circle.fill", .mint) }
        if model.axisStep == .failed { return ("TRY AGAIN", "Your previous calibration is kept", "arrow.clockwise.circle", .orange) }
        if model.axisStep == .waiting { return ("WAIT", "Connecting to your Watch", "clock.fill", .orange) }
        if model.axisPhase == .detected { return ("DETECTED", "Movement confirmed", "checkmark.circle.fill", .mint) }
        if model.axisPhase == .demonstrating { return ("WATCH", "Watch the animation first", "play.circle.fill", .cyan) }
        if !model.axisHasFreshData { return ("WAIT", "Wake the Watch display", "moon.zzz.fill", .orange) }
        if model.axisCanGo { return ("GO — MOVE NOW", model.axisStep.direction?.title ?? "Follow the arrow", "arrow.right.circle.fill", .mint) }
        if model.axisIsMoving { return ("MOVING", "Hold still when you reach the end", "waveform.path", .cyan) }
        let start = model.axisStep.direction?.startName ?? "starting point"
        let preparation = model.axisPreparationSeconds > 0 ? "Move to the " + start + " · " + String(model.axisPreparationSeconds) : "Hold at the " + start
        return ("GET READY", preparation, "hand.raised.fill", .orange)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("POINTING CALIBRATION", systemImage: "scope")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.mint)
                Spacer()
                if let direction = model.axisStep.direction {
                    Text("Step \(direction.rawValue+1) of 4").monospacedDigit()
                } else { Text("\(model.axisDetectedDirections.count) complete").monospacedDigit() }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(cue.title, systemImage: cue.icon)
                    .font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(cue.color)
                Text(cue.detail).font(.callout).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(cue.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(cue.color.opacity(0.5), lineWidth: 1))
                .accessibilityElement(children: .combine)
            if let reason = model.axisRetryReason {
                Label("Last attempt: " + reason,systemImage: "info.circle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false,vertical: true)
            }
            ScrollView {
                VStack(spacing: 18) {
                    if let direction = model.axisStep.direction {
                        Text(direction.title).font(.system(size: 32, weight: .semibold, design: .rounded))
                        SweepAnimation(direction: direction, phase: model.axisPhase, demoID: model.axisDemoID)
                            .frame(height: 180)
                    } else if model.axisStep == .review {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(.mint)
                        Text("Calibration complete").font(.system(size: 34, weight: .semibold, design: .rounded))
                    } else if model.axisStep == .failed {
                        Image(systemName: "arrow.clockwise.circle").font(.system(size: 56)).foregroundStyle(.secondary)
                        Text("Let's try again").font(.title)
                    } else {
                        ProgressView().padding(.vertical, 36)
                        Text("Connecting to Watch").font(.title)
                    }
                    Text(model.axisMessage).font(.title3).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(minHeight: 52)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(SweepDirection.allCases, id: \.self) { direction in
                            VStack(spacing: 8) {
                                Image(systemName: model.axisDetectedDirections.contains(direction) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(model.axisDetectedDirections.contains(direction) ? .mint : .secondary)
                                Text(direction.title).font(.caption).fixedSize()
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(.vertical, 10)
                    Text("Use comfortable forearm sweeps from your elbow, from your perspective. A natural arc is fine. Hold briefly at each start and end. Keep the Watch awake. Cursor control stays paused.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
            }
            HStack {
                Button(model.axisStep == .review ? "Done" : "Cancel") { model.showAxisCalibration = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.axisStep == .failed {
                    Button("Try again") { model.beginAxisCalibration() }
                        .buttonStyle(.borderedProminent).disabled(!model.paired)
                }
            }
        }.padding(28).frame(width: 640, height: 680).preferredColorScheme(.dark)
    }
}

private struct SweepAnimation: View {
    let direction: SweepDirection
    let phase: MacPilotModel.AxisPhase
    let demoID: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var atEnd = false
    private var start: CGPoint {
        switch direction {
        case .topDown: return .init(x: 0.5,y: 0.18)
        case .bottomUp: return .init(x: 0.5,y: 0.82)
        case .leftRight: return .init(x: 0.18,y: 0.5)
        case .rightLeft: return .init(x: 0.82,y: 0.5)
        }
    }
    private var end: CGPoint { .init(x: 1-start.x,y: 1-start.y) }
    private var arrow: String {
        switch direction {
        case .topDown: return "arrow.down"
        case .bottomUp: return "arrow.up"
        case .leftRight: return "arrow.right"
        case .rightLeft: return "arrow.left"
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let a = CGPoint(x: start.x*geometry.size.width,y: start.y*geometry.size.height)
            let b = CGPoint(x: end.x*geometry.size.width,y: end.y*geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.04))
                if phase == .detected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(.mint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Path { $0.move(to: a); $0.addLine(to: b) }
                        .stroke(.mint.opacity(0.22),style: StrokeStyle(lineWidth: 3,dash: [5,7]))
                    Circle().stroke(.mint.opacity(0.5),lineWidth: 2).frame(width: 24,height: 24).position(a)
                    Circle().stroke(.mint.opacity(0.5),lineWidth: 2).frame(width: 24,height: 24).position(b)
                    Image(systemName: arrow).font(.system(size: 30,weight: .medium)).foregroundStyle(.mint.opacity(0.7))
                    if phase == .demonstrating && !reduceMotion {
                        Circle().fill(.mint).frame(width: 22,height: 22)
                            .shadow(color: .mint.opacity(0.5),radius: 10).position(atEnd ? b : a)
                    }
                }
            }.animation(.spring(response: 0.3),value: phase == .detected)
        }
        .task(id: demoID) {
            atEnd = false
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.25)) { atEnd = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction.title + (phase == .detected ? " detected" : phase == .demonstrating ? " demonstration" : " your turn"))
    }
}
