import SwiftUI
import AppleWatchCursorCore

private let mint = Color(red: 0.54, green: 0.94, blue: 0.78)

struct MacContentView: View {
    @ObservedObject var model: MacPilotModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("APPLE-WATCH-CURSOR").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(3).foregroundStyle(mint)
                    Text("Your hand. Your cursor.").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("Move your right wrist. Tap index finger to thumb to click.").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                Label(model.modeTitle, systemImage: model.enabled ? "circle.fill" : "pause.circle")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(10).background(mint.opacity(0.12), in: Capsule()).foregroundStyle(mint)
                    Button(model.hasAxisCalibration ? "Recalibrate pointing…" : "Calibrate pointing…") { model.beginAxisCalibration() }
                        .disabled(!model.paired)
                    if !model.permission && !model.practiceOnly {
                        Button("Allow Accessibility…") { model.requestPermission() }
                    }
                    if model.hasAxisCalibration { Label("Pointing calibrated", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(mint) }
                }
            }
            ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("01", "Connect your Watch")
                    HStack {
                        Text(model.paired ? "Connected" : "Auto connect").font(.system(size: 27, weight: .medium, design: .rounded))
                        Spacer()
                        Image(systemName: model.paired ? "checkmark.circle.fill" : "applewatch").font(.title).foregroundStyle(mint)
                    }
                    Text(model.paired ? "Watch connected" : model.approvalPending ? "Approve the connection from your Watch." : "Open Apple-Watch-Cursor on your Watch. It finds this Mac automatically.")
                        .foregroundStyle(.secondary).font(.callout)
                    if model.approvalPending {
                        Button("Trust this Watch") { model.trustPendingWatch() }
                            .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                    }
                    HStack {
                        Button(model.advertising ? "Stop Bluetooth" : "Start Bluetooth") {
                            if model.advertising { model.stop() } else { model.start() }
                        }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                        if model.hasTrustedWatch { Button("Forget Watch") { model.forgetWatch() }.buttonStyle(.borderless).font(.caption) }
                    }
                    Text(model.bluetooth).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    sectionTitle("02", "Control the mouse")
                    Toggle("Practice in preview", isOn: $model.practiceOnly).tint(mint)
                    Text(model.practiceOnly ? "Preview only. Double finger tap toggles Practice; a single tap is a practice click." : "Double finger tap to enter or exit mouse mode. Single tap to click after a brief pause. Control stays on the primary display.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.practiceOnly && !model.permission {
                        Button("Allow Accessibility…") { model.requestPermission() }
                        Text("macOS needs this permission to move and click the cursor.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Mouse control", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                        .tint(mint).disabled(!model.paired || !model.hasAxisCalibration)
                    HStack {
                        Toggle("Flip X", isOn: $model.flipHorizontal)
                        Toggle("Flip Y", isOn: $model.flipVertical)
                    }.font(.caption).toggleStyle(.checkbox)
                    HStack(spacing: 8) {
                        Text("Y sensitivity").font(.caption)
                        Slider(value: $model.verticalGain, in: 0.5...4, step: 0.1)
                            .accessibilityLabel("Vertical sensitivity")
                        Text(String(format: "%.1f×", model.verticalGain)).font(.system(.caption, design: .monospaced))
                    }
                    Button("Pause") { model.disable() }.controlSize(.large).frame(maxWidth: .infinity)
                }.padding(22).frame(width: 310).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("MOVEMENT PREVIEW").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
                        Spacer()
                        Text("\(model.tapCount) taps · \(model.mouseClickCount) clicks").font(.system(.caption, design: .monospaced)).foregroundStyle(mint)
                    }
                    PointerPreview(offset: model.offset, pulse: model.tapCount)
                        .frame(minHeight: 290).clipShape(RoundedRectangle(cornerRadius: 18))
                    Label(model.event, systemImage: "waveform.path").font(.callout).foregroundStyle(mint)
                        .frame(height: 36, alignment: .leading)
                    Text(model.motionStatus).font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Double finger-to-thumb tap: mouse on/off. Single tap: click.", systemImage: "hand.pinch")
                        Label("Tap Recenter on the Watch, then hold your hand comfortably still.", systemImage: "scope")
                        Label("Pause from the menu bar anytime. Escape pauses when this window is focused.", systemImage: "pause.circle")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity)
            }
            }
            Spacer(minLength: 0)
            Text("PROTOTYPE  /  Personal tap calibration · Local Bluetooth · No cloud")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(30).frame(minWidth: 900, minHeight: 720)
            .background(Color(red: 0.045, green: 0.065, blue: 0.075))
            .sheet(isPresented: $model.showAxisCalibration, onDismiss: model.cancelAxisCalibration) {
                AxisCalibrationView(model: model)
            }
    }
    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.system(.caption, design: .monospaced)).foregroundStyle(mint)
            Text(title).font(.headline)
        }
    }
}

private struct PointerPreview: View {
    let offset: PointerOffset
    let pulse: Int
    @State private var flashing = false
    @State private var flashTask: Task<Void, Never>?
    private var pointerColor: Color { flashing ? .red : mint }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.025)
                Path { path in
                    for column in 1..<8 {
                        let x = geometry.size.width * Double(column)/8
                        path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: geometry.size.height))
                    }
                    for row in 1..<6 {
                        let y = geometry.size.height * Double(row)/6
                        path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: geometry.size.width, y: y))
                    }
                }.stroke(.white.opacity(0.05), lineWidth: 1)
                Image(systemName: "plus").foregroundStyle(.white.opacity(0.25))
                Circle().fill(pointerColor.opacity(flashing ? 0.3 : 0.12)).frame(width: 44, height: 44)
                    .overlay(Circle().fill(pointerColor).frame(width: 12, height: 12))
                    .overlay(Circle().stroke(pointerColor.opacity(0.8), lineWidth: flashing ? 3 : 1))
                    .scaleEffect(flashing ? 1.3 : 1)
                    .shadow(color: flashing ? .red.opacity(0.5) : .clear, radius: 12)
                    .position(x: 24 + (offset.x+1)/2 * (geometry.size.width-48),
                              y: 24 + (offset.y+1)/2 * (geometry.size.height-48))
                VStack { Spacer(); Text("RECENTER = NEUTRAL WRIST + SCREEN CENTER")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).padding(12) }
                if flashing {
                    VStack { HStack { Spacer(); Label("Tap received", systemImage: "hand.pinch.fill")
                        .font(.caption.bold()).foregroundStyle(.red).padding(12) }; Spacer() }
                }
            }
        }
        .accessibilityLabel("Cursor movement preview")
        .accessibilityValue("Horizontal \(Int(offset.x * 100)), vertical \(Int(offset.y * 100)), \(pulse) taps")
        .onChange(of: pulse) { _, _ in
            flashTask?.cancel()
            withAnimation(.easeOut(duration: 0.06)) { flashing = true }
            flashTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { flashing = false }
            }
        }
        .onDisappear { flashTask?.cancel(); flashing = false }
    }
}
