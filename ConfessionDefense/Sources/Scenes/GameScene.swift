import SpriteKit
import SwiftUI

public final class GameScene: SKScene {
    public weak var gameManager: GameManager?
    
    private var cellNodes: [GridPosition: SKShapeNode] = [:]
    private var pathDotNodes: [SKShapeNode] = []
    private var enemyNodes: [UUID: SKNode] = [:]
    private var activeEnemies: [Enemy] = []
    
    // マドンナノード
    private var madonnaNode: SKNode?
    private var bottomAreaNode: SKShapeNode?
    
    // スポーンタイマー
    private var spawnTimer: TimeInterval = 0
    private var attackTimers: [GridPosition: TimeInterval] = [:]
    
    private let cols = 8
    private let rows = 10 // 配置可能なグリッドは10行
    private var cellSize: CGFloat = 36
    private var gridOrigin: CGPoint = .zero
    
    private let topAreaHeight: CGFloat = 46
    private let bottomAreaHeight: CGFloat = 42
    
    public override func didMove(to view: SKView) {
        backgroundColor = .white
        setupGrid()
    }
    
    public override func didChangeSize(_ oldSize: CGSize) {
        setupGrid()
    }
    
    // MARK: - 教室レイアウト構築（上下余白の最適化とマドンナエリア配置）
    private func setupGrid() {
        removeAllChildren()
        cellNodes.removeAll()
        pathDotNodes.removeAll()
        enemyNodes.removeAll()
        activeEnemies.removeAll()
        
        let horizontalMargin: CGFloat = 16
        let availableWidth = size.width - (horizontalMargin * 2)
        
        // 上下HUD・ツールバーに被らないよう、全体の高さを計算してセルサイズを最適化
        let verticalAvailable = size.height - topAreaHeight - bottomAreaHeight - 14
        cellSize = min(availableWidth / CGFloat(cols), verticalAvailable / CGFloat(rows))
        
        let gridWidth = cellSize * CGFloat(cols)
        let gridHeight = cellSize * CGFloat(rows)
        
        // 全体を上下中央に正確に配置
        gridOrigin = CGPoint(
            x: (size.width - gridWidth) / 2,
            y: (size.height - gridHeight + bottomAreaHeight - topAreaHeight) / 2
        )
        
        // ==========================================
        // 1. 上部エリア（入口 & 教卓・黒板）
        // ==========================================
        let topY = gridOrigin.y + gridHeight
        
        // 左入口 (Door Left)
        let leftDoorX = gridOrigin.x + (cellSize * 0.5)
        let leftDoorNode = createDoorNode(title: "入口", arrowDown: true)
        leftDoorNode.position = CGPoint(x: leftDoorX, y: topY + (topAreaHeight * 0.5))
        addChild(leftDoorNode)
        
        // 右入口 (Door Right)
        let rightDoorX = gridOrigin.x + gridWidth - (cellSize * 0.5)
        let rightDoorNode = createDoorNode(title: "入口", arrowDown: true)
        rightDoorNode.position = CGPoint(x: rightDoorX, y: topY + (topAreaHeight * 0.5))
        addChild(rightDoorNode)
        
        // 中央教壇エリア（グレー背景）
        let teacherAreaWidth = gridWidth - (cellSize * 2)
        let teacherArea = SKShapeNode(rectOf: CGSize(width: teacherAreaWidth, height: topAreaHeight))
        teacherArea.fillColor = SKColor(white: 0.88, alpha: 1.0)
        teacherArea.strokeColor = SKColor(white: 0.2, alpha: 1.0)
        teacherArea.lineWidth = 1.0
        teacherArea.position = CGPoint(x: size.width / 2, y: topY + (topAreaHeight * 0.5))
        teacherArea.zPosition = 1
        addChild(teacherArea)
        
        // 黒板（濃緑ライン）
        let blackboard = SKShapeNode(rectOf: CGSize(width: teacherAreaWidth * 0.72, height: 5), cornerRadius: 2)
        blackboard.fillColor = SKColor(red: 0.15, green: 0.38, blue: 0.25, alpha: 1.0)
        blackboard.strokeColor = .clear
        blackboard.position = CGPoint(x: 0, y: (topAreaHeight * 0.5) - 4)
        teacherArea.addChild(blackboard)
        
        // 教卓（角丸長方形）
        let teacherDesk = SKShapeNode(rectOf: CGSize(width: teacherAreaWidth * 0.62, height: 22), cornerRadius: 6)
        teacherDesk.fillColor = .white
        teacherDesk.strokeColor = SKColor(white: 0.2, alpha: 1.0)
        teacherDesk.lineWidth = 1.0
        teacherDesk.position = CGPoint(x: 0, y: -3)
        teacherArea.addChild(teacherDesk)
        
        let deskLabel = SKLabelNode(text: "教卓")
        deskLabel.fontName = "HiraginoSans-W6"
        deskLabel.fontSize = 11
        deskLabel.fontColor = .black
        deskLabel.verticalAlignmentMode = .center
        teacherDesk.addChild(deskLabel)
        
        // ==========================================
        // 2. 下部エリア（マドンナエリア）
        // ==========================================
        let bottomY = gridOrigin.y - (bottomAreaHeight * 0.5)
        let bottomArea = SKShapeNode(rectOf: CGSize(width: gridWidth, height: bottomAreaHeight))
        bottomArea.fillColor = SKColor(white: 0.88, alpha: 1.0)
        bottomArea.strokeColor = SKColor(white: 0.2, alpha: 1.0)
        bottomArea.lineWidth = 1.0
        bottomArea.position = CGPoint(x: size.width / 2, y: bottomY)
        bottomArea.zPosition = 1
        addChild(bottomArea)
        bottomAreaNode = bottomArea
        
        let madonnaAreaLabel = SKLabelNode(text: "マドンナエリア")
        madonnaAreaLabel.fontName = "HiraginoSans-W6"
        madonnaAreaLabel.fontSize = 12
        madonnaAreaLabel.fontColor = SKColor(white: 0.3, alpha: 1.0)
        madonnaAreaLabel.verticalAlignmentMode = .center
        madonnaAreaLabel.position = CGPoint(x: 0, y: -10)
        bottomArea.addChild(madonnaAreaLabel)
        
        // マドンナ本体（マドンナエリア内に配置）
        let madonna = SKLabelNode(text: "👸")
        madonna.fontSize = 24
        madonna.verticalAlignmentMode = .center
        madonna.position = CGPoint(x: 0, y: 6)
        madonna.zPosition = 10
        bottomArea.addChild(madonna)
        madonnaNode = madonna
        
        // ==========================================
        // 3. 中央 8×10 グリッド（配置できる範囲）
        // ==========================================
        for r in 0..<rows {
            for c in 0..<cols {
                let pos = GridPosition(col: c, row: r)
                let point = pointFor(pos: pos)
                
                let cellRect = CGRect(x: -cellSize/2, y: -cellSize/2, width: cellSize, height: cellSize)
                let cellNode = SKShapeNode(rect: cellRect)
                cellNode.position = point
                cellNode.fillColor = .white
                cellNode.strokeColor = SKColor(white: 0.35, alpha: 1.0)
                cellNode.lineWidth = 1.0
                cellNode.zPosition = 2
                addChild(cellNode)
                cellNodes[pos] = cellNode
            }
        }
        
        updateGridDisplay()
    }
    
    private func createDoorNode(title: String, arrowDown: Bool) -> SKNode {
        let node = SKNode()
        node.zPosition = 2
        
        let roof = SKShapeNode(rectOf: CGSize(width: cellSize * 1.1, height: 5))
        roof.fillColor = SKColor(red: 0.72, green: 0.45, blue: 0.25, alpha: 1.0)
        roof.strokeColor = SKColor(white: 0.2, alpha: 1.0)
        roof.lineWidth = 1
        roof.position = CGPoint(x: 0, y: 18)
        node.addChild(roof)
        
        let label = SKLabelNode(text: title)
        label.fontName = "HiraginoSans-W6"
        label.fontSize = 10
        label.fontColor = .black
        label.position = CGPoint(x: 0, y: 24)
        node.addChild(label)
        
        if arrowDown {
            let arrow = SKLabelNode(text: "⬇️")
            arrow.fontSize = cellSize * 0.45
            arrow.verticalAlignmentMode = .center
            arrow.position = CGPoint(x: 0, y: 0)
            node.addChild(arrow)
        }
        
        return node
    }
    
    private func pointFor(pos: GridPosition) -> CGPoint {
        let x = gridOrigin.x + (CGFloat(pos.col) + 0.5) * cellSize
        if pos.row < rows {
            let y = gridOrigin.y + (CGFloat(rows - 1 - pos.row) + 0.5) * cellSize
            return CGPoint(x: x, y: y)
        } else {
            // row 10 はマドンナエリア
            let bottomY = gridOrigin.y - (bottomAreaHeight * 0.5)
            return CGPoint(x: x, y: bottomY)
        }
    }
    
    private func gridPosFor(point: CGPoint) -> GridPosition? {
        let col = Int((point.x - gridOrigin.x) / cellSize)
        let row = rows - 1 - Int((point.y - gridOrigin.y) / cellSize)
        
        if col >= 0 && col < cols && row >= 0 && row < rows {
            return GridPosition(col: col, row: row)
        }
        return nil
    }
    
    // MARK: - グリッド表示更新（机・椅子・クラスメイト・経路プレビュー）
    public func updateGridDisplay() {
        guard let gm = gameManager else { return }
        
        for dot in pathDotNodes {
            dot.removeFromParent()
        }
        pathDotNodes.removeAll()
        
        // マドンナエリア内のマドンナ位置更新
        if let bottomArea = bottomAreaNode, let madonna = madonnaNode {
            let targetX = (CGFloat(gm.madonnaPosition.col) - 3.5) * cellSize
            madonna.position = CGPoint(x: targetX, y: 6)
        }
        
        for (pos, cellNode) in cellNodes {
            cellNode.removeAllChildren()
            
            let cellType = gm.grid[pos] ?? .empty
            switch cellType {
            case .desk:
                // 机のグラフィック（木目調天板 ＋ 角丸枠線）
                cellNode.fillColor = SKColor(red: 0.88, green: 0.72, blue: 0.52, alpha: 1.0)
                
                // 机の天板イラスト（角丸長方形）
                let deskTop = SKShapeNode(rectOf: CGSize(width: cellSize * 0.78, height: cellSize * 0.58), cornerRadius: 4)
                deskTop.fillColor = SKColor(red: 0.76, green: 0.54, blue: 0.32, alpha: 1.0)
                deskTop.strokeColor = SKColor(red: 0.52, green: 0.34, blue: 0.18, alpha: 1.0)
                deskTop.lineWidth = 1.2
                cellNode.addChild(deskTop)
                
                // 机の引き出し線
                let drawer = SKShapeNode(rectOf: CGSize(width: cellSize * 0.55, height: 3))
                drawer.fillColor = SKColor(red: 0.52, green: 0.34, blue: 0.18, alpha: 1.0)
                drawer.strokeColor = .clear
                drawer.position = CGPoint(x: 0, y: -cellSize * 0.12)
                deskTop.addChild(drawer)
                
            case .chair:
                // 椅子（木製の椅子アイコン 🪑）
                cellNode.fillColor = SKColor(red: 0.96, green: 0.90, blue: 0.78, alpha: 0.8)
                let label = SKLabelNode(text: "🪑")
                label.fontSize = cellSize * 0.55
                label.verticalAlignmentMode = .center
                cellNode.addChild(label)
                
            case .classmate:
                cellNode.fillColor = SKColor(red: 0.86, green: 0.93, blue: 1.0, alpha: 1.0)
                if let classmate = gm.placedClassmates[pos] {
                    let label = SKLabelNode(text: classmate.emoji)
                    label.fontSize = cellSize * 0.65
                    label.verticalAlignmentMode = .center
                    cellNode.addChild(label)
                }
            default:
                cellNode.fillColor = .white
            }
        }
        
        // 最短経路プレビュー（ドット描画）
        drawPathPreview(gm.previewPathLeft, color: SKColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.45))
        drawPathPreview(gm.previewPathRight, color: SKColor(red: 1.0, green: 0.5, blue: 0.2, alpha: 0.45))
    }
    
    private func drawPathPreview(_ path: [GridPosition], color: SKColor) {
        for pos in path {
            let point = pointFor(pos: pos)
            let dot = SKShapeNode(circleOfRadius: cellSize * 0.14)
            dot.fillColor = color
            dot.strokeColor = .clear
            dot.position = point
            dot.zPosition = 6
            addChild(dot)
            pathDotNodes.append(dot)
        }
    }
    
    // MARK: - タップ処理
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        
        if let pos = gridPosFor(point: location) {
            gameManager?.handleCellTap(at: pos)
            updateGridDisplay()
        }
    }
    
    // MARK: - ゲームループ
    public override func update(_ currentTime: TimeInterval) {
        guard let gm = gameManager, !gm.isPaused else { return }
        
        if gm.gameState == .battle {
            let dt: TimeInterval = 1.0 / 60.0 * gm.gameSpeed
            
            spawnTimer += dt
            if spawnTimer >= 2.0 / gm.gameSpeed {
                spawnTimer = 0
                spawnEnemy()
            }
            
            updateEnemies(dt: dt)
            updateClassmateAttacks(dt: dt)
        }
    }
    
    // MARK: - 敵スポーン
    private func spawnEnemy() {
        guard let gm = gameManager else { return }
        
        let startDoor = (Bool.random() ? GridPosition(col: 0, row: 0) : GridPosition(col: 7, row: 0))
        let path = PathFinder.shared.findPath(from: startDoor, to: gm.madonnaPosition, grid: gm.grid) ?? []
        
        let enemyType: EnemyType = (gm.waveNumber >= 3 && Double.random(in: 0...1) < 0.3) ? .athletic : .normal
        let enemy = Enemy(type: enemyType, startDoor: startDoor, path: path)
        
        let node = SKNode()
        node.position = pointFor(pos: startDoor)
        node.zPosition = 10
        
        let label = SKLabelNode(text: enemy.emoji)
        label.fontSize = cellSize * 0.65
        label.verticalAlignmentMode = .center
        node.addChild(label)
        
        // HPバー
        let hpBarBg = SKShapeNode(rectOf: CGSize(width: cellSize * 0.8, height: 4), cornerRadius: 2)
        hpBarBg.fillColor = .gray
        hpBarBg.strokeColor = .clear
        hpBarBg.position = CGPoint(x: 0, y: cellSize * 0.38)
        node.addChild(hpBarBg)
        
        let hpBar = SKShapeNode(rectOf: CGSize(width: cellSize * 0.8, height: 4), cornerRadius: 2)
        hpBar.fillColor = .red
        hpBar.strokeColor = .clear
        hpBar.name = "hpBar"
        hpBar.position = CGPoint(x: 0, y: cellSize * 0.38)
        node.addChild(hpBar)
        
        addChild(node)
        enemyNodes[enemy.id] = node
        activeEnemies.append(enemy)
    }
    
    // MARK: - 敵移動
    private func updateEnemies(dt: TimeInterval) {
        guard let gm = gameManager else { return }
        
        var remainingEnemies: [Enemy] = []
        
        for var enemy in activeEnemies {
            guard !enemy.isDefeated, let node = enemyNodes[enemy.id] else {
                enemyNodes[enemy.id]?.removeFromParent()
                enemyNodes.removeValue(forKey: enemy.id)
                continue
            }
            
            if let nextTarget = enemy.path.first {
                let targetPoint = pointFor(pos: nextTarget)
                let dx = targetPoint.x - node.position.x
                let dy = targetPoint.y - node.position.y
                let dist = sqrt(dx*dx + dy*dy)
                
                let moveDist = CGFloat(enemy.currentSpeed) * cellSize * CGFloat(dt)
                
                if dist <= moveDist {
                    node.position = targetPoint
                    enemy.gridPosition = nextTarget
                    enemy.path.removeFirst()
                    
                    // マドンナ到達チェック（row 10のマドンナエリア到達）
                    if nextTarget.row >= 10 || nextTarget == gm.madonnaPosition {
                        showDamageEffect(at: targetPoint)
                        gm.damageMadonna(by: enemy.stressDamage)
                        node.removeFromParent()
                        enemyNodes.removeValue(forKey: enemy.id)
                        continue
                    }
                } else {
                    node.position.x += (dx / dist) * moveDist
                    node.position.y += (dy / dist) * moveDist
                }
            }
            
            remainingEnemies.append(enemy)
        }
        
        activeEnemies = remainingEnemies
    }
    
    // MARK: - クラスメイト自動攻撃
    private func updateClassmateAttacks(dt: TimeInterval) {
        guard let gm = gameManager else { return }
        
        for (pos, classmate) in gm.placedClassmates {
            var timer = attackTimers[pos] ?? 0
            timer += dt
            
            if timer >= classmate.attackInterval {
                let shooterPoint = pointFor(pos: pos)
                if let targetEnemy = findTargetIn(range: classmate.range, from: pos) {
                    timer = 0
                    fireProjectile(from: shooterPoint, to: targetEnemy, classmate: classmate)
                }
            }
            attackTimers[pos] = timer
        }
    }
    
    private func findTargetIn(range: Double, from pos: GridPosition) -> Enemy? {
        return activeEnemies.first { enemy in
            let d = pos.manhattanDistance(to: enemy.gridPosition)
            return Double(d) <= range && !enemy.isDefeated
        }
    }
    
    private func fireProjectile(from startPoint: CGPoint, to enemy: Enemy, classmate: Classmate) {
        guard let enemyNode = enemyNodes[enemy.id] else { return }
        
        let proj = SKLabelNode(text: classmate.projectileEmoji)
        proj.fontSize = cellSize * 0.45
        proj.position = startPoint
        proj.zPosition = 15
        addChild(proj)
        
        let targetPoint = enemyNode.position
        let moveAction = SKAction.move(to: targetPoint, duration: 0.2)
        let hitAction = SKAction.run { [weak self] in
            proj.removeFromParent()
            self?.applyDamage(to: enemy.id, damage: classmate.attackPower)
        }
        
        proj.run(SKAction.sequence([moveAction, hitAction]))
    }
    
    private func applyDamage(to enemyId: UUID, damage: Double) {
        guard let index = activeEnemies.firstIndex(where: { $0.id == enemyId }) else { return }
        activeEnemies[index].currentPassion -= damage
        
        if let node = enemyNodes[enemyId], let hpBar = node.childNode(withName: "hpBar") as? SKShapeNode {
            let ratio = max(0, activeEnemies[index].currentPassion / activeEnemies[index].maxPassion)
            hpBar.xScale = CGFloat(ratio)
        }
        
        if activeEnemies[index].currentPassion <= 0 {
            activeEnemies[index].isDefeated = true
            gameManager?.addFriendshipPoints(activeEnemies[index].dropFriendshipPoints)
            
            if let node = enemyNodes[enemyId] {
                let fade = SKAction.fadeOut(withDuration: 0.25)
                let scale = SKAction.scale(to: 0.5, duration: 0.25)
                node.run(SKAction.group([fade, scale])) {
                    node.removeFromParent()
                }
            }
        }
    }
    
    private func showDamageEffect(at point: CGPoint) {
        let heart = SKLabelNode(text: "💔")
        heart.fontSize = cellSize * 0.8
        heart.position = point
        heart.zPosition = 20
        addChild(heart)
        
        let moveUp = SKAction.moveBy(x: 0, y: 30, duration: 0.6)
        let fadeOut = SKAction.fadeOut(withDuration: 0.6)
        heart.run(SKAction.group([moveUp, fadeOut])) {
            heart.removeFromParent()
        }
    }
}
