import CaptureCore
import SwiftUI

/// 撮影セッションの一覧（作品名・枚数・マスク・転送の状態）。
struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showingNew = false
    /// 「撮影を始める」を押した内容（シートを閉じてから撮影画面を開く）。
    @State private var pendingNew: (title: String, kind: WorkKind)?
    @State private var pendingDelete: SessionSummary?

    var body: some View {
        List {
            if !settings.isReceiverConfigured {
                Section {
                    Button {
                        model.open(.settings)
                    } label: {
                        Label("送り先の Mac をまだ設定していません。設定を開く", systemImage: "desktopcomputer")
                    }
                }
            }
            if model.sessions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("まだ撮影がありません").font(.headline)
                        Text("「新しく撮る」から作品名と作品の種類（立体・平面）を選んで撮影します。作品は動かないように置いてください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            Section {
                ForEach(model.sessions) { summary in
                    Button {
                        model.open(summary.photoCount == 0 ? .capture(sessionId: summary.id, preferredTargetId: nil) : .review(sessionId: summary.id))
                    } label: {
                        SessionRow(summary: summary, store: model.store)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = summary
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .disabled(model.isLocked(summary.id))
                    }
                }
            }
        }
        .navigationTitle("Memoria Capture")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.open(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Label("新しく撮る", systemImage: "plus")
                }
            }
        }
        .refreshable { model.reloadSessions() }
        .onAppear { model.reloadSessions() }
        .sheet(isPresented: $showingNew, onDismiss: startPendingSession) {
            NewSessionSheet { title, kind in
                pendingNew = (title, kind)
                showingNew = false
            }
        }
        .confirmationDialog("このセッションを削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let id = pendingDelete?.id { model.deleteSession(id) }
                pendingDelete = nil
            }
        } message: {
            Text("写真とマスクがこの iPhone から消えます。Mac へ送ったものは残ります。")
        }
    }
}

extension SessionListView {
    private func startPendingSession() {
        guard let pending = pendingNew else { return }
        pendingNew = nil
        if let session = model.createSession(title: pending.title, workKind: pending.kind) {
            model.open(.capture(sessionId: session.sessionId, preferredTargetId: nil))
        }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    let store: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let photo = summary.firstPhoto {
                    PhotoThumbnail(url: store.photoURL(summary.id, photoId: photo.photoId), rotation: photo.image.displayRotationDegClockwise, maxPixel: 160)
                } else {
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        Image(systemName: "camera").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title.isEmpty ? "（名前なし）" : summary.title).font(.headline)
                HStack(spacing: 10) {
                    Label(summary.workKind == .flat ? "平面" : "立体", systemImage: summary.workKind == .flat ? "doc.richtext" : "cube")
                    Label("\(summary.photoCount) 枚", systemImage: "photo")
                    if summary.workKind == .flat {
                        Label("真上 \(summary.confirmedDirections)/\(summary.totalDirections)", systemImage: "arrow.down.to.line")
                    } else {
                        Label("方向 \(summary.confirmedDirections)/\(summary.totalDirections)", systemImage: "circle.dashed")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if summary.workKind != .flat {
                        Text(maskText).font(.caption).foregroundStyle(.secondary)
                    }
                    TransferBadge(status: summary.transferStatus)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var maskText: String {
        if summary.photoCount == 0 { return "切り抜き —" }
        var text = "切り抜き \(summary.maskReady)/\(summary.photoCount)"
        if summary.maskProcessing > 0 { text += "（作成中 \(summary.maskProcessing)）" }
        return text
    }
}

/// 新しいセッション：作品名と、作品の種類（立体・平面）を選ぶ。種類で撮り方が変わる（自動では見分けない）。
struct NewSessionSheet: View {
    let onStart: (String, WorkKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: WorkKind = .object

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("作品名（例：ねこの貯金箱）", text: $title)
                } header: {
                    Text("作品名")
                } footer: {
                    Text("空でもかまいません。AI が何の作品かを知る手がかりになります。")
                }
                Section {
                    ForEach(WorkKind.allCases) { option in
                        Button {
                            kind = option
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: kind == option ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(kind == option ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.displayName).font(.headline)
                                    Text(option.summary).font(.subheadline)
                                    Text("例：\(option.hint)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(kind == option ? .isSelected : [])
                    }
                } header: {
                    Text("どんな作品ですか")
                } footer: {
                    Text("迷ったら：机に置いて真横から見たとき、形が見えるなら立体、ほぼ紙の厚みだけなら平面です。紙に毛糸などを貼った絵は、どちらにしてもかまいません。")
                }
            }
            .navigationTitle("新しく撮る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("撮影を始める") { onStart(title, kind) }
                }
            }
        }
    }
}

struct TransferBadge: View {
    let status: TransferDisplayStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .sent: return .green
        case .modifiedSinceSent: return .orange
        case .failed: return .red
        case .inProgress: return .blue
        case .notSent: return .secondary
        }
    }
}
