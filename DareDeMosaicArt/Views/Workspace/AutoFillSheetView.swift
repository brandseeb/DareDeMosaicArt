import SwiftUI

/// スマート・オートフィル（空きマスの段階的近似自動配置）シート画面
public struct AutoFillSheetView: View {
    @Binding public var project: MosaicProject
    public let availablePhotos: [IndexedPhoto]
    public let onApplied: (Int) -> Void
    public let onReset: (Int) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var allowDuplicates: Bool = false
    @State private var selectedLevel: AutoFillLevel = .completeMax
    @State private var simulations: [AutoFillSimulation] = []
    @State private var loadedPhotos: [IndexedPhoto] = []
    @State private var isLoading: Bool = true
    @State private var showStaleAlert: Bool = false
    @State private var showResetConfirmAlert: Bool = false
    @State private var simulationTask: Task<Void, Never>? = nil
    
    public init(
        project: Binding<MosaicProject>,
        availablePhotos: [IndexedPhoto],
        onApplied: @escaping (Int) -> Void,
        onReset: @escaping (Int) -> Void
    ) {
        self._project = project
        self.availablePhotos = availablePhotos
        self.onApplied = onApplied
        self.onReset = onReset
    }
    
    /// 現在自動配置（.autoFilled かつ未ロック）されているマス数
    private var autoFilledCount: Int {
        project.tiles.filter { $0.origin == .autoFilled && !$0.isLocked }.count
    }
    
    /// 未配置の空きマス数
    private var emptyCount: Int {
        project.tiles.filter { !$0.isFilled && !$0.isLocked }.count
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. 現在のステータス
                    currentStatusHeader
                    
                    // 2. オプション設定（重複許可）
                    optionsSection
                    
                    // 3. 4段階のオートフィルレベル選択
                    simulationLevelsSection
                    
                    // 4. 自動配置リセットボタン（該当タイルがある場合のみ）
                    if autoFilledCount > 0 {
                        resetSection
                    }
                }
                .padding()
            }
            .navigationTitle("✨ スマート・オートフィル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        simulationTask?.cancel()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                applyButtonBottomBar
            }
            .alert(String(localized: "autofill.alert.stale.title"), isPresented: $showStaleAlert) {
                Button(String(localized: "common.ok")) {
                    startSimulation()
                }
            } message: {
                Text(LocalizedStringResource("autofill.alert.stale.message"))
            }
            .alert(String(localized: "autofill.alert.reset.title"), isPresented: $showResetConfirmAlert) {
                Button(String(localized: "autofill.button.reset"), role: .destructive) {
                    handleReset()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            } message: {
                Text(LocalizedStringResource("autofill.alert.reset.message.format \(autoFilledCount)"))
            }
            .onAppear {
                startSimulation()
            }
            .onDisappear {
                simulationTask?.cancel()
            }
        }
    }
    
    // MARK: - 現在のステータスヘッダー
    private var currentStatusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringResource("autofill.header.desc"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource("autofill.progress.format \(project.progressPercentageString)"))
                        .font(.headline)
                    Text(LocalizedStringResource("format.remainingTiles \(emptyCount)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                ProgressView(value: Double(project.progress))
                    .frame(width: 100)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
    
    // MARK: - オプション設定
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $allowDuplicates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource("autofill.option.allowDuplicates"))
                        .font(.subheadline.bold())
                    Text(LocalizedStringResource("autofill.option.allowDuplicates.desc"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: allowDuplicates) { _, _ in
                startSimulation()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
    
    // MARK: - シミュレーションレベル一覧
    private var simulationLevelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringResource("autofill.section.levels"))
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if isLoading && simulations.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(LocalizedStringResource("autofill.loading.simulation"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(simulations) { sim in
                    levelCard(for: sim)
                }
            }
        }
    }
    
    // MARK: - レベルカード
    private func levelCard(for sim: AutoFillSimulation) -> some View {
        let isSelected = (selectedLevel == sim.level)
        
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedLevel = sim.level
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(sim.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            if sim.isFullCompletion {
                                Text(LocalizedStringResource("autofill.badge.fullComplete"))
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green)
                                    .cornerRadius(6)
                            }
                        }
                        
                        Text(sim.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.4))
                        .font(.title3)
                }
                
                Divider()
                
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: sim.additionalCount > 0 ? "plus.circle.fill" : "minus.circle")
                            .font(.caption)
                            .foregroundColor(sim.additionalCount > 0 ? .accentColor : .secondary)
                        Text(sim.statusMessage)
                            .font(.caption.bold())
                            .foregroundColor(sim.additionalCount > 0 ? .primary : .secondary)
                    }
                    Spacer()
                    Text(LocalizedStringResource("autofill.progress.projected.format \(Int(sim.projectedProgress * 100))"))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(sim.isFullCompletion ? .green : .accentColor)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!sim.isExecutable && sim.additionalCount == 0)
        .opacity(sim.isExecutable || sim.additionalCount > 0 ? 1.0 : 0.6)
    }
    
    // MARK: - リセットセクション
    private var resetSection: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.vertical, 4)
            
            Button {
                showResetConfirmAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(LocalizedStringResource("autofill.reset.button.format \(autoFilledCount)"))
                }
                .font(.subheadline)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }
    
    // MARK: - 適用ボタン（ボトムバー）
    private var applyButtonBottomBar: some View {
        let currentSim = simulations.first(where: { $0.level == selectedLevel })
        let canApply = (currentSim?.additionalCount ?? 0) > 0
        let count = currentSim?.additionalCount ?? 0
        
        return VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                Button {
                    handleApply()
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        if canApply {
                            Text(LocalizedStringResource("autofill.apply.count.format \(count)"))
                        } else {
                            Text(LocalizedStringResource("autofill.apply.noPhotos"))
                        }
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canApply ? Color.accentColor : Color.gray)
                    .cornerRadius(12)
                }
                .disabled(!canApply || isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
        }
    }
    
    // MARK: - 非同期シミュレーション開始
    private func startSimulation() {
        simulationTask?.cancel()
        isLoading = true
        
        let currentProject = project
        let initialPhotos = !loadedPhotos.isEmpty ? loadedPhotos : availablePhotos
        let duplicates = allowDuplicates
        
        simulationTask = Task {
            var effectivePhotos = initialPhotos
            // 親ビューからの写真ロードがまだ完了していない場合はここでロード
            if effectivePhotos.isEmpty {
                effectivePhotos = (try? await PhotoLibraryScanner.shared.photos(for: currentProject.photoSource)) ?? []
                await MainActor.run {
                    self.loadedPhotos = effectivePhotos
                }
            }
            
            let results = await MosaicEngine.shared.simulateAutoFill(
                project: currentProject,
                availablePhotos: effectivePhotos,
                allowDuplicates: duplicates
            )
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.simulations = results
                self.isLoading = false
                
                // 実行可能な最初のレベルを選択
                if let firstExecutable = results.first(where: { $0.isExecutable && $0.level == self.selectedLevel }) {
                    self.selectedLevel = firstExecutable.level
                } else if let fallback = results.first(where: { $0.isExecutable }) {
                    self.selectedLevel = fallback.level
                }
            }
        }
    }
    
    // MARK: - 適用ハンドラ
    private func handleApply() {
        guard let currentSim = simulations.first(where: { $0.level == selectedLevel }) else { return }
        
        let result = MosaicEngine.shared.applyAutoFillPlan(
            project: project,
            plan: currentSim.plan
        )
        
        switch result {
        case .applied(let updatedProject, let placedCount):
            self.project = updatedProject
            self.onApplied(placedCount)
            dismiss()
            
        case .stale:
            self.showStaleAlert = true
            
        case .invalid:
            self.startSimulation()
        }
    }
    
    // MARK: - リセットハンドラ
    private func handleReset() {
        let (updatedProject, resetCount) = MosaicEngine.shared.resetAutoFilledTiles(project: project)
        self.project = updatedProject
        self.onReset(resetCount)
        dismiss()
    }
}
