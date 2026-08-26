import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// アプリホーム画面
public struct HomeView: View {
    @Binding public var projects: [MosaicProject]
    public let onDeleteProjects: ([UUID]) -> Void
    
    @StateObject private var storeKit = StoreKitManager.shared
    @State private var selectedProjectIndex: Int? = nil
    @State private var showSetupSheet: Bool = false
    @State private var showPaywall: Bool = false
    @State private var projectPendingDeletion: MosaicProject? = nil
    
    public init(
        projects: Binding<[MosaicProject]>,
        onDeleteProjects: @escaping ([UUID]) -> Void
    ) {
        self._projects = projects
        self.onDeleteProjects = onDeleteProjects
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                
                if projects.isEmpty {
                    emptyStateView
                } else {
                    projectListView
                }
            }
            .navigationTitle("誰でモザイクアート")
            .toolbar {
                // 左側: Pro アップグレードボタン
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(storeKit.isProUser ? .yellow : .orange)
                                if storeKit.proStatus == .loading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Text(storeKit.isProUser ? "PRO" : "Pro")
                                        .font(.caption.bold())
                                        .foregroundColor(storeKit.isProUser ? .primary : .orange)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(storeKit.isProUser ? Color(.systemGray5) : Color.orange.opacity(0.12))
                            .cornerRadius(12)
                        }
                        
                        #if DEBUG
                        // 開発・テスト用: ワンタップ Pro / Free トグルスイッチ
                        Button {
                            storeKit.toggleDebugPro()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: storeKit.isProUser ? "checkmark.circle.fill" : "circle")
                                Text(storeKit.isProUser ? "DEBUG: PRO" : "DEBUG: FREE")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(storeKit.isProUser ? Color.purple : Color.gray)
                            .cornerRadius(8)
                        }
                        #endif
                    }
                }
                
                // 右側: 新規作成ボタン
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        handleNewProjectTapped()
                    } label: {
                        if storeKit.proStatus == .loading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "plus")
                                .font(.headline)
                        }
                    }
                    .disabled(storeKit.proStatus == .loading)
                }
            }
            .sheet(isPresented: $showSetupSheet) {
                ProjectSetupView { newProject in
                    projects.insert(newProject, at: 0)
                    selectedProjectIndex = 0
                }
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywallView()
            }
            .fullScreenCover(item: Binding(
                get: {
                    if let index = selectedProjectIndex, projects.indices.contains(index) {
                        return projects[index]
                    }
                    return nil
                },
                set: { updated in
                    if let updated = updated, let index = selectedProjectIndex, projects.indices.contains(index) {
                        projects[index] = updated
                    } else if updated == nil {
                        selectedProjectIndex = nil
                    }
                }
            )) { _ in
                if let index = selectedProjectIndex, projects.indices.contains(index) {
                    MosaicWorkspaceView(project: $projects[index])
                }
            }
            // 削除確認アラート
            .alert(
                "「\(projectPendingDeletion?.title ?? "")」を削除しますか？",
                isPresented: Binding(
                    get: { projectPendingDeletion != nil },
                    set: { if !$0 { projectPendingDeletion = nil } }
                ),
                presenting: projectPendingDeletion
            ) { target in
                Button("削除", role: .destructive) {
                    onDeleteProjects([target.id])
                    projectPendingDeletion = nil
                }
                Button("キャンセル", role: .cancel) {
                    projectPendingDeletion = nil
                }
            } message: { _ in
                Text("このアートで撮影した画像データも一緒に端末から完全に消去されます。この操作は取り消せません。")
            }
        }
    }
    
    private func handleNewProjectTapped() {
        guard storeKit.proStatus != .loading else { return }
        
        // 無料版は最大3作品まで。4作品目以降はProが必要
        if !storeKit.isProUser && projects.count >= 3 {
            showPaywall = true
        } else {
            showSetupSheet = true
        }
    }
    
    // MARK: - 空状態
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor.opacity(0.8))
            
            VStack(spacing: 8) {
                Text("モザイクアートを作ろう")
                    .font(.title2.bold())
                Text("好きな写真を選んで、日常の景色から\n色を撮影して集めて完成させよう！")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                handleNewProjectTapped()
            } label: {
                HStack {
                    if storeKit.proStatus == .loading {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text("新しく作る")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(storeKit.proStatus == .loading ? Color.gray : Color.accentColor)
                .cornerRadius(25)
                .shadow(color: storeKit.proStatus == .loading ? Color.clear : Color.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .disabled(storeKit.proStatus == .loading)
            .padding(.top, 10)
        }
        .padding(32)
    }
    
    // MARK: - プロジェクト一覧
    private var projectListView: some View {
        List {
            Section(header: Text("作成中のアート (\(projects.count)\(storeKit.isProUser ? "" : "/3作品"))")) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    projectRow(for: project)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProjectIndex = index
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                projectPendingDeletion = project
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
    
    private func projectRow(for project: MosaicProject) -> some View {
        HStack(spacing: 14) {
            if let uiImage = UIImage(data: project.targetImageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.headline)
                
                Text("\(project.gridWidth)×\(project.gridHeight)マス (\(project.mode.rawValue))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    ProgressView(value: Double(project.progress))
                        .frame(width: 100)
                    
                    Text(project.isCompleted ? "完成！✨" : "\(project.progressPercentageString)")
                        .font(.caption.bold())
                        .foregroundColor(project.isCompleted ? .green : .secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
