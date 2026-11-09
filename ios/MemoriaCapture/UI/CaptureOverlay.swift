import CaptureCore
import SwiftUI

/// AR の画面の上に重ねる案内（SwiftUI。保存する写真には入らない）。
struct CaptureOverlay: View {
    @ObservedObject var controller: CaptureController
    let onReview: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let banner = controller.banner {
                BannerView(message: banner.message, isError: banner.isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if controller.phase == .capturing {
                topPanel
            }
            if controller.isComplete {
                completePanel
            }
            guidance
            Spacer(minLength: 0)
            if controller.phase == .capturing {
                StatusChips(assessment: controller.assessment)
            }
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    // MARK: 上：方向の地図・進み具合

    private var topPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            DirectionMiniMap(
                plan: controller.plan, progress: controller.progress,
                nextId: controller.direction?.nextTarget?.id,
                currentAzimuth: controller.direction?.azimuthDeg,
                hasFront: controller.referenceState == .ready
            )
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(controller.progress.doneCount) / \(controller.plan.targets.count)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(controller.referenceState == .ready ? "そろった方向" : "まず正面から 1 枚")
                    .font(.caption).foregroundStyle(.secondary)
                progressDetail
                ElevationIndicator(
                    current: controller.direction?.elevationDeg,
                    target: (controller.direction?.frontTarget ?? controller.direction?.nextTarget)?.elevationDeg
                )
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 確認中・撮り直しの数。
    @ViewBuilder
    private var progressDetail: some View {
        let checking = controller.progress.checkingIds.count, retake = controller.progress.retakeIds.count
        if checking > 0 || retake > 0 {
            HStack(spacing: 8) {
                if checking > 0 { Text("確認中 \(checking)").foregroundStyle(.yellow) }
                if retake > 0 { Text("撮り直し \(retake)").foregroundStyle(.orange) }
            }
            .font(.caption.bold())
        }
    }

    /// すべての方向がそろったとき。
    private var completePanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
            Text("そろいました（\(controller.progress.doneCount)/\(controller.progress.totalCount)）— 確認して送信できます")
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("確認へ", action: onReview)
                .buttonStyle(.borderedProminent)
                .disabled(controller.captureInFlight)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var guidance: some View {
        Text(controller.guidanceText)
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }

    // MARK: 下：操作

    @ViewBuilder
    private var bottomPanel: some View {
        switch controller.phase {
        case .starting:
            ProgressView().padding()
        case .unsupported:
            EmptyView()
        case .failed:
            Button("もう一度試す") { controller.retryAfterFailure() }
                .buttonStyle(.borderedProminent)
        case .placingBase:
            VStack(spacing: 10) {
                Button {
                    controller.confirmBasePoint()
                } label: {
                    Label("ここが底の中心", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.hasPlaneHit)
                shutterRow(compact: true)
            }
        case .adjustingSize:
            VStack(spacing: 10) {
                SizeSlider(title: "高さ", value: $controller.heightCm, range: CaptureController.heightRangeCm)
                SizeSlider(title: "半径", value: $controller.radiusCm, range: CaptureController.radiusRangeCm)
                HStack {
                    Button("底の位置をやり直す") { controller.beginPlacingBase() }
                        .buttonStyle(.bordered)
                    Button {
                        controller.confirmReference()
                    } label: {
                        Text("基準を確定").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .capturing:
            shutterRow(compact: false)
        }
    }

    private func shutterRow(compact: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                if controller.phase == .capturing {
                    Toggle(isOn: $controller.autoCaptureEnabled) {
                        Text("自動撮影").font(.subheadline.bold())
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Button("基準をやり直す") { controller.resetReference() }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                } else {
                    Text("先に基準を設定してください（基準なしだと方向が記録されません）")
                        .font(.caption).foregroundStyle(.white)
                }
            }
            Spacer()
            ShutterButton(
                progress: controller.assessment.stabilityProgress,
                busy: controller.captureInFlight,
                enabled: controller.assessment.canManualCapture && !controller.captureInFlight,
                size: compact ? 60 : 78
            ) {
                controller.shutterTapped()
            }
            Spacer()
            Button(action: onReview) {
                VStack(spacing: 2) {
                    Image(systemName: "photo.stack").font(.title2)
                    Text("\(controller.photoCount) 枚").font(.caption)
                }
                .frame(width: 72)
            }
            .buttonStyle(.bordered)
            .disabled(controller.captureInFlight)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct BannerView: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.bold())
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? Color.red.opacity(0.9) : Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }
}

struct SizeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: $value, in: range, step: 0.5)
            Text(String(format: "%.1f cm", value)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
        .font(.subheadline)
    }
}

struct ShutterButton: View {
    let progress: Double
    let busy: Bool
    let enabled: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(enabled ? Color.white : Color.gray.opacity(0.6)).padding(8)
                if busy { ProgressView() }
            }
            .frame(width: size, height: size)
        }
        .disabled(!enabled)
        .accessibilityLabel("シャッター")
    }
}

/// 6 つの確認項目（トラッキング・収まり・方向・動き・暗さ・ブレ）。
struct StatusChips: View {
    let assessment: QualityAssessment

    var body: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(CheckKind.allCases, id: \.self) { kind in
                let check = assessment.check(kind)
                HStack(spacing: 4) {
                    Image(systemName: Self.icon(check.status))
                    Text(kind.label).lineLimit(1)
                }
                .font(.caption.bold())
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Self.color(check.status).opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
            }
        }
    }

    static func icon(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    static func color(_ status: CheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

/// 上から見た撮影方向の地図（正面が下。そろった＝緑、確認中＝黄、撮り直し＝オレンジ、次＝水色、今のカメラ＝青）。
struct DirectionMiniMap: View {
    let plan: DirectionPlan
    let progress: CoverageProgress
    let nextId: String?
    let currentAzimuth: Double?
    let hasFront: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - 10
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().stroke(Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                Image(systemName: "cube.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).position(center)
                if hasFront {
                    ForEach(plan.targets) { target in
                        // 上から見て、正面（0°）が下側（カメラ側）、右へ回る（+X）と右側。
                        let ring = target.elevationDeg > 35 ? radius * 0.55 : radius
                        let p = point(azimuth: target.azimuthDeg, radius: ring, center: center)
                        let state = progress.state(of: target.id)
                        let size: CGFloat = target.id == nextId ? 14 : 10
                        ZStack {
                            Circle().fill(Self.color(state, isNext: target.id == nextId))
                            if state == .retake {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: state == .retake ? 14 : size, height: state == .retake ? 14 : size)
                        .position(p)
                    }
                    if let currentAzimuth {
                        let p = point(azimuth: currentAzimuth, radius: radius + 6, center: center)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .padding(3)
                            .background(Circle().fill(.white))
                            .position(p)
                    }
                } else {
                    Text("正面").font(.caption2.bold()).foregroundStyle(.orange)
                        .position(x: center.x, y: center.y + radius - 2)
                }
            }
        }
    }

    static func color(_ state: TargetState, isNext: Bool) -> Color {
        switch state {
        case .done: return .green
        case .checking: return .yellow
        case .retake: return .orange
        case .notShot: return isNext ? .cyan : .white
        }
    }

    private func point(azimuth: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let a = Geometry.radians(azimuth)
        // 地図は上から見る：作品の +Z（正面）を画面の下、+X（正面から見て右）を画面の右に描く。
        return CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y + radius * CGFloat(cos(a)))
    }
}

/// 仰角の表示（今の高さと、次に撮る高さ）。
struct ElevationIndicator: View {
    let current: Double?
    let target: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down")
            if let current {
                Text("高さ \(Int(current.rounded()))°").monospacedDigit()
            } else {
                Text("高さ —")
            }
            if let target {
                Text("（目標 \(Int(target.rounded()))°）").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
