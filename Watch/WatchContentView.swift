import SwiftUI

private let accent = Color(red: 0.54, green: 0.94, blue: 0.78)

struct WatchContentView: View {
    @ObservedObject var model: WatchPilotModel
    @State private var showConnect = false
    @State private var showCalibration = false
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Text("APPLE-WATCH-CURSOR").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Circle().fill(model.link.isPaired ? accent : .gray).frame(width: 6, height: 6)
                }.foregroundStyle(accent)
                Image(systemName: model.isRunning ? "scope" : "hand.pinch")
                    .font(.system(size: 32, weight: .light)).foregroundStyle(accent).padding(.vertical, 2)
                Text(model.mode == .axes ? "Follow your Mac" : model.mode == .recentering ? "Finding center" : model.isRunning ? (model.link.hostEnabled ? "Mouse ON" : "Mouse standby") : "Wrist, meet Mac.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(model.message).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

                if model.mode == .axes {
                    Button("Cancel calibration", role: .destructive) { model.pause() }
                } else if model.isRunning {
                    Button(action: model.recenter) { Label("Recenter", systemImage: "scope").frame(maxWidth: .infinity) }
                        .tint(accent).foregroundStyle(.black).buttonStyle(.borderedProminent)
                    Button("Pause", role: .destructive) { model.pause() }
                    Text(model.link.hostEnabled ? "Double finger tap to exit" : "Double finger tap to enter")
                        .font(.system(size: 10)).foregroundStyle(accent)
                } else {
                    Text(model.link.state).font(.system(size: 10)).foregroundStyle(accent)
                    Button("Arm mouse gestures") { model.startPointing() }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(!model.canStart)
                    Button(model.profile == nil ? "Calibrate finger taps" : "Recalibrate taps") {
                        showCalibration = true
                    }
                    Button(model.link.isPaired ? "Connection" : "Connect to Mac") { showConnect = true }
                }
            }.padding(.horizontal, 3)
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .axes { showConnect = false; showCalibration = false }
        }
        .sheet(isPresented: $showConnect) { WatchConnectionView(model: model) }
        .sheet(isPresented: $showCalibration) { WatchCalibrationView(model: model) }
    }
}

private struct WatchConnectionView: View {
    @ObservedObject var model: WatchPilotModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect to Mac").font(.headline)
                Text("Your Mac is found automatically. Click Trust this Watch on Mac once. Future connections are automatic.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(model.link.isScanning ? "Searching…" : "Find Mac") { model.link.scan() }
                    .disabled(model.link.isScanning || model.link.isPaired)
                Text(model.link.state).font(.caption2).foregroundStyle(accent)
                ForEach(model.link.hosts, id: \.identifier) { host in
                    Button(host.name ?? "Apple-Watch-Cursor Mac") { model.link.connect(host) }
                        .disabled(model.link.isPaired)
                }
                if model.link.isPaired { Button("Done") { dismiss() }; Button("Disconnect") { model.link.disconnect() } }
                Divider()
                Text("\(model.device) · \(model.wrist)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchCalibrationView: View {
    @ObservedObject var model: WatchPilotModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            if model.isRecording {
                VStack(spacing: 9) {
                    Text("FOLLOW THE SIX CUES").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                    Text(model.cueNumber == 0 ? "READY" : "TAP \(model.cueNumber)")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                    Text(model.cueNumber == 0 ? "Hold your wrist still" : "Index finger → thumb, once")
                        .font(.caption2).multilineTextAlignment(.center)
                    Text("\(model.sensorRate) Hz · Keep screen awake").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Cancel") { model.pause(reason: "cancelled") }.font(.caption)
                }
            } else {
                ScrollView {
            VStack(spacing: 10) {
                Text("Teach your tap").font(.headline)
                Image(systemName: "hand.pinch").font(.largeTitle).foregroundStyle(accent)
                Text("Wear on your right wrist. Keep the band snug. Hold still at READY, then tap index finger to thumb once at each of six cues.")
                    .font(.caption2).multilineTextAlignment(.center)
                Text("\(model.calibrationCount) / 6")
                    .font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(accent)
                    Button(model.profile == nil ? "Begin calibration" : "Record six new taps") { model.beginCalibration() }
                        .tint(accent)
                    Button("Record missed taps") { model.recordMissedTaps() }
                    Text("Saves a 12-second motion sample locally for tuning: hold still first, then tap once at each cue.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.profile != nil { Button("Done") { dismiss() } }
                Text(model.message).font(.caption2).foregroundStyle(model.calibrationIssue ? .orange : .secondary)
                    .multilineTextAlignment(.center)
                Text("Experimental detector. Use Practice on Mac to check for missed or accidental taps.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
                }
            }
        }.onDisappear { if model.isRecording { model.pause(reason: "sheetClosed") } }
    }
}
