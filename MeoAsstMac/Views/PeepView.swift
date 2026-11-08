import SwiftUI

struct PeepView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var preview = PeepViewModel()
    @State private var automatic = false
    @State private var displaySize = CGSize.zero
    @State private var backingScale = 1.0
    /// T19：目标 FPS（持久化；WPF 缺省 20、钳制 1...600 同构）。
    @AppStorage("PeepTargetFps") private var peepTargetFps = PeepRefreshPolicy.defaultTargetFps
    @State private var measuredFps: Double = 0
    @State private var frameCountInWindow = 0
    @State private var fpsWindowStart = Date.now
    @State private var consecutiveFailures = 0
    @State private var fpsReducedNotice: String?

    /// A preview only needs as many pixels as its own area times the backing scale.
    /// `backingScale` mirrors the environment into state: the automatic-refresh `.task` below
    /// captures the view once at task start, and an environment read through that stale copy
    /// would keep downsampling with the scale of the display the task started on. State reads
    /// go through shared storage, so they stay current after the window changes displays.
    private var maxPixelSize: Int? {
        let longest = max(displaySize.width, displaySize.height) * backingScale
        return longest > 0 ? Int(longest.rounded(.up)) : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Peep.Automatic", isOn: $automatic)
                    .toggleStyle(.switch)
                Spacer()
                if automatic {
                    Stepper(
                        "Peep.TargetFps \(peepTargetFps)",
                        onIncrement: { peepTargetFps = PeepRefreshPolicy.clampTargetFps(peepTargetFps + 1) },
                        onDecrement: { peepTargetFps = PeepRefreshPolicy.clampTargetFps(peepTargetFps - 1) }
                    )
                    .fixedSize()
                }
                Button("Peep.Refresh") {
                    Task { await preview.refresh(from: viewModel, maxPixelSize: maxPixelSize) }
                }
                .disabled(preview.isReading)
                if preview.isReading { ProgressView().controlSize(.small) }
            }
            if let frame = preview.frame {
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("Peep.ReadAt")
                    Text(frame.readAt, style: .time)
                    Text(LocalizedStringKey(frame.requestedCapture ? "Peep.CaptureRequested" : "Peep.CachedFrame"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Peep.Waiting", systemImage: "eye", description: Text("Peep.ConnectionHint"))
            }
            if let error = preview.error {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("peepError")
            }
            if automatic {
                Text("Peep.FpsStatus \(peepTargetFps) \(Int(measuredFps.rounded()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fpsReducedNotice {
                Text(fpsReducedNotice).font(.caption).foregroundStyle(.orange)
            }
            Text("Peep.TimestampHint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 360, minHeight: 280)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        displaySize = proxy.size
                        backingScale = displayScale
                    }
                    .onChange(of: proxy.size) { displaySize = proxy.size }
            }
        )
        .onChange(of: displayScale) { backingScale = displayScale }
        // This first refresh can run before the GeometryReader reports a size, so maxPixelSize
        // may still be nil and the first frame decodes at full resolution. Core serves
        // task-scaled (720p-class) frames, so the one-shot fallback is cheap; every later
        // refresh downsamples. PeepTests pins this nil behavior.
        .task {
            if preview.frame == nil { await preview.refresh(from: viewModel, maxPixelSize: maxPixelSize) }
        }
        .task(id: automatic) {
            guard automatic else { return }
            // T19：按目标 FPS 循环；刷新耗时计入间隔（不叠加请求——refresh 内部
            // isReading 序列化）；连续 3 次出错降 1 FPS（WPF 信号量降速同构），
            // 成功则复位并按 1s 窗口统计实测 FPS。
            while !Task.isCancelled {
                let interval = 1.0 / Double(peepTargetFps)
                let start = Date.now
                await preview.refresh(from: viewModel, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                if preview.error != nil {
                    consecutiveFailures += 1
                    let adapted = PeepRefreshPolicy.adaptedFps(
                        current: peepTargetFps, consecutiveFailures: consecutiveFailures)
                    if adapted < peepTargetFps {
                        peepTargetFps = adapted
                        fpsReducedNotice = String(
                            localized: "Peep.FpsReduced \(adapted)")
                    }
                } else {
                    consecutiveFailures = 0
                    frameCountInWindow += 1
                    let window = Date.now.timeIntervalSince(fpsWindowStart)
                    if window >= 1 {
                        measuredFps = Double(frameCountInWindow) / window
                        frameCountInWindow = 0
                        fpsWindowStart = .now
                    }
                }
                let elapsed = Date.now.timeIntervalSince(start)
                let remaining = max(0, interval - elapsed)
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
        }
        .onChange(of: preview.frame?.readAt) {
            // Fires on publish, pre-render and regardless of window visibility — the full
            // contract lives on MAAPreviewFrameDisplayed.
            if preview.frame != nil {
                NotificationCenter.default.post(name: .MAAPreviewFrameDisplayed, object: nil)
            }
        }
        .onDisappear { preview.cancel() }
    }
}
