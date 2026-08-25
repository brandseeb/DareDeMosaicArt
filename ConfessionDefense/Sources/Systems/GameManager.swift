import Foundation
import Combine
import SwiftUI

public enum GameState: Equatable, Sendable {
    case preparing        // 朝の準備 / 休み時間の家具配置
    case battle           // 授業開始前・休み時間などの防衛戦闘中
    case classmateArrival // 登校イベント（3択選択中）
    case levelUpUpgrade   // レベルアップ（3択強化カード選択中）
    case gameOver         // マドンナのストレス限界によるゲームオーバー
    case victory          // 放課後防衛成功！
}

@MainActor
public final class GameManager: ObservableObject {
    // MARK: - マドンナ・ステータス
    @Published public var stressLevel: Int = 0
    @Published public var maxStress: Int = 10
    @Published public var madonnaPosition: GridPosition = GridPosition(col: 3, row: 10)
    
    // MARK: - ゲーム進行・タイムライン
    @Published public var schoolTimeText: String = "08:00"
    @Published public var waveNumber: Int = 1
    @Published public var totalWaves: Int = 5
    @Published public var friendshipPoints: Int = 0
    @Published public var nextLevelPoints: Int = 30
    @Published public var classLevel: Int = 1
    @Published public var gameSpeed: Double = 1.0
    @Published public var isPaused: Bool = false
    @Published public var gameState: GameState = .preparing
    
    // MARK: - クラスメイト編成
    @Published public var activeMembers: [Classmate] = []
    @Published public var benchMembers: [Classmate] = []
    @Published public var placedClassmates: [GridPosition: Classmate] = [:]
    @Published public var maxPlacedCount: Int = 5
    @Published public var arrivalCandidates: [Classmate] = []
    @Published public var upgradeCandidates: [FriendshipCard] = []
    
    // MARK: - 教室グリッド状態
    @Published public var grid: [GridPosition: CellType] = [:]
    @Published public var previewPathLeft: [GridPosition] = []
    @Published public var previewPathRight: [GridPosition] = []
    @Published public var warningMessage: String? = nil
    
    public enum PlacementTool: Equatable {
        case none
        case desk
        case chair
        case classmate(Classmate)
    }
    @Published public var selectedTool: PlacementTool = .desk
    
    private var allUnusedClassmates: [Classmate] = Classmate.allPresets
    private let pathFinder = PathFinder.shared
    
    public init() {
        resetGame()
    }
    
    public func resetGame() {
        stressLevel = 0
        maxStress = 10
        schoolTimeText = "08:00"
        waveNumber = 1
        friendshipPoints = 0
        nextLevelPoints = 30
        classLevel = 1
        gameState = .preparing
        activeMembers = []
        benchMembers = []
        placedClassmates = [:]
        allUnusedClassmates = Classmate.allPresets.shuffled()
        
        // 8x10の配置マス + row 10のマドンナエリア
        grid = [:]
        madonnaPosition = GridPosition(col: 3, row: 10)
        grid[madonnaPosition] = .madonna
        grid[GridPosition(col: 0, row: 0)] = .doorLeft
        grid[GridPosition(col: 7, row: 0)] = .doorRight
        
        triggerInitialArrival()
        updatePathPreviews()
    }
    
    // MARK: - 登校イベント
    public func triggerInitialArrival() {
        guard allUnusedClassmates.count >= 3 else { return }
        arrivalCandidates = Array(allUnusedClassmates.prefix(3))
        allUnusedClassmates.removeFirst(3)
        gameState = .classmateArrival
    }
    
    public func selectClassmateFromArrival(_ selected: Classmate) {
        activeMembers.append(selected)
        
        let unselected = arrivalCandidates.filter { $0.id != selected.id }
        benchMembers.append(contentsOf: unselected)
        arrivalCandidates = []
        
        // 最初の仲間はマドンナの直上（row 9）に配置
        let initialPos = GridPosition(col: 3, row: 9)
        if grid[initialPos] == nil || grid[initialPos] == .empty {
            placedClassmates[initialPos] = selected
            grid[initialPos] = .classmate(id: selected.id)
        }
        
        gameState = .preparing
        updatePathPreviews()
    }
    
    // MARK: - 家具・クラスメイト配置操作
    public func handleCellTap(at pos: GridPosition) {
        // ドアやマドンナエリア(row 10)は配置不可
        if pos.row >= 10 || (pos.row == 0 && (pos.col == 0 || pos.col == 7)) {
            return
        }
        
        switch selectedTool {
        case .desk:
            toggleDesk(at: pos)
        case .chair:
            toggleChair(at: pos)
        case .classmate(let classmate):
            placeClassmate(classmate, at: pos)
        case .none:
            removeAt(pos)
        }
    }
    
    public func toggleDesk(at pos: GridPosition) {
        if grid[pos] == .desk {
            grid.removeValue(forKey: pos)
            updatePathPreviews()
            return
        }
        
        var testGrid = grid
        testGrid[pos] = .desk
        
        if pathFinder.validatePaths(madonna: madonnaPosition, grid: testGrid) {
            grid[pos] = .desk
            updatePathPreviews()
        } else {
            showWarning("先生に怒られるので、通路は残してください。")
        }
    }
    
    public func toggleChair(at pos: GridPosition) {
        if grid[pos] == .chair {
            grid.removeValue(forKey: pos)
        } else {
            grid[pos] = .chair
        }
        updatePathPreviews()
    }
    
    public func placeClassmate(_ classmate: Classmate, at pos: GridPosition) {
        guard placedClassmates.count < maxPlacedCount else {
            showWarning("配置上限（最大\(maxPlacedCount)人）に達しています！")
            return
        }
        
        if let existing = grid[pos], existing != .empty && existing != .chair {
            return
        }
        
        var testGrid = grid
        testGrid[pos] = .classmate(id: classmate.id)
        
        if pathFinder.validatePaths(madonna: madonnaPosition, grid: testGrid) {
            placedClassmates[pos] = classmate
            grid[pos] = .classmate(id: classmate.id)
            updatePathPreviews()
        } else {
            showWarning("先生に怒られるので、通路は残してください。")
        }
    }
    
    public func removeAt(_ pos: GridPosition) {
        grid.removeValue(forKey: pos)
        placedClassmates.removeValue(forKey: pos)
        updatePathPreviews()
    }
    
    public func updatePathPreviews() {
        previewPathLeft = pathFinder.findPath(from: GridPosition(col: 0, row: 0), to: madonnaPosition, grid: grid) ?? []
        previewPathRight = pathFinder.findPath(from: GridPosition(col: 7, row: 0), to: madonnaPosition, grid: grid) ?? []
    }
    
    public func showWarning(_ message: String) {
        warningMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.warningMessage == message {
                self.warningMessage = nil
            }
        }
    }
    
    public func startBattle() {
        gameState = .battle
    }
    
    public func addFriendshipPoints(_ points: Int) {
        friendshipPoints += points
        if friendshipPoints >= nextLevelPoints {
            levelUp()
        }
    }
    
    private func levelUp() {
        classLevel += 1
        friendshipPoints -= nextLevelPoints
        nextLevelPoints = Int(Double(nextLevelPoints) * 1.5)
        
        upgradeCandidates = Array(FriendshipCard.allCards.shuffled().prefix(3))
        gameState = .levelUpUpgrade
    }
    
    public func applyUpgradeCard(_ card: FriendshipCard) {
        switch card.id {
        case "unity_power":
            for pos in placedClassmates.keys {
                placedClassmates[pos]?.attackPower *= 1.15
            }
        case "rapid_study":
            for pos in placedClassmates.keys {
                placedClassmates[pos]?.attackInterval *= 0.88
            }
        case "wide_blackboard":
            for pos in placedClassmates.keys {
                placedClassmates[pos]?.range += 0.8
            }
        case "mind_relief":
            maxStress += 3
            stressLevel = max(0, stressLevel - 2)
        default:
            break
        }
        
        gameState = .battle
    }
    
    public func damageMadonna(by amount: Int) {
        stressLevel += amount
        if stressLevel >= maxStress {
            gameState = .gameOver
        }
    }
}
