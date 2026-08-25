import SpriteKit
import UIKit

final class ClassroomGameScene: SKScene {
    private let columns = 8
    private let rows = 10
    private let leftEntrance = GridPoint(column: 0, row: 9)
    private let rightEntrance = GridPoint(column: 7, row: 9)

    private var cellSize: CGFloat = 0
    private var gridOrigin = CGPoint.zero
    private var frontAreaHeight: CGFloat = 54
    private var madonnaAreaHeight: CGFloat = 54
    private var blocked: Set<GridPoint> = []
    private var defenders: [(grid: GridPoint, node: DefenderNode)] = []
    private var enemies: [EnemyNode] = []
    private var projectiles: [SKShapeNode] = []

    private var phase: GamePhase = .building
    private var lastUpdateTime: TimeInterval = 0
    private var spawnAccumulator: TimeInterval = 0
    private var spawnedCount = 0
    private var defeatedCount = 0
    private var stress = 0
    private var isSceneReady = false
    private let waveEnemyCount = 35

    private let worldLayer = SKNode()
    private let pathLayer = SKNode()
    private let furnitureLayer = SKNode()
    private let actorLayer = SKNode()
    private let projectileLayer = SKNode()
    private let hudLayer = SKNode()

    private let phaseLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let scoreLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private let stressLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let messageLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let primaryButton = SKShapeNode()
    private let primaryButtonLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = SKColor(red: 0.055, green: 0.075, blue: 0.08, alpha: 1)
    }

    override convenience init() {
        self.init(size: CGSize(width: 390, height: 844))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        view.preferredFramesPerSecond = 60
        view.isMultipleTouchEnabled = false
        isSceneReady = true
        setupScene()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard isSceneReady, view != nil, oldSize != size else { return }
        phase = .building
        enemies.removeAll()
        projectiles.removeAll()
        spawnedCount = 0
        defeatedCount = 0
        stress = 0
        setupScene()
    }

    private func setupScene() {
        removeAllChildren()
        worldLayer.removeAllChildren()
        pathLayer.removeAllChildren()
        furnitureLayer.removeAllChildren()
        actorLayer.removeAllChildren()
        projectileLayer.removeAllChildren()
        hudLayer.removeAllChildren()

        addChild(worldLayer)
        worldLayer.addChild(pathLayer)
        worldLayer.addChild(furnitureLayer)
        worldLayer.addChild(actorLayer)
        worldLayer.addChild(projectileLayer)
        addChild(hudLayer)

        let availableWidth = size.width - 20
        let classroomBottom: CGFloat = 128
        let classroomTop = size.height - 95
        frontAreaHeight = min(58, max(46, size.height * 0.07))
        madonnaAreaHeight = min(58, max(50, size.height * 0.07))
        let availableGridHeight = classroomTop - classroomBottom - frontAreaHeight - madonnaAreaHeight
        cellSize = min(availableWidth / CGFloat(columns), availableGridHeight / CGFloat(rows))
        let gridWidth = cellSize * CGFloat(columns)
        gridOrigin = CGPoint(x: (size.width - gridWidth) / 2, y: classroomBottom + madonnaAreaHeight)

        drawHeader()
        drawClassroom()
        drawFurniture()
        installDefenders()
        drawControls()
        refreshPaths()
        refreshHUD()
    }

    private func drawHeader() {
        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "告白お断りします！"
        title.fontSize = min(22, size.width * 0.057)
        title.fontColor = SKColor(red: 1, green: 0.86, blue: 0.39, alpha: 1)
        title.position = CGPoint(x: size.width / 2, y: size.height - 42)
        title.verticalAlignmentMode = .center
        hudLayer.addChild(title)

        phaseLabel.fontSize = 12
        phaseLabel.fontColor = .white.withAlphaComponent(0.8)
        phaseLabel.horizontalAlignmentMode = .left
        phaseLabel.position = CGPoint(x: 16, y: size.height - 78)
        hudLayer.addChild(phaseLabel)

        scoreLabel.fontSize = 12
        scoreLabel.fontColor = .white.withAlphaComponent(0.8)
        scoreLabel.horizontalAlignmentMode = .center
        scoreLabel.position = CGPoint(x: size.width / 2, y: size.height - 78)
        hudLayer.addChild(scoreLabel)

        stressLabel.fontSize = 12
        stressLabel.horizontalAlignmentMode = .right
        stressLabel.position = CGPoint(x: size.width - 16, y: size.height - 78)
        hudLayer.addChild(stressLabel)
    }

    private func drawClassroom() {
        let gridWidth = cellSize * CGFloat(columns)
        let gridHeight = cellSize * CGFloat(rows)
        let classroomRect = CGRect(
            x: gridOrigin.x,
            y: gridOrigin.y - madonnaAreaHeight,
            width: gridWidth,
            height: madonnaAreaHeight + gridHeight + frontAreaHeight
        )
        let classroomOutline = SKShapeNode(rect: classroomRect, cornerRadius: 5)
        classroomOutline.fillColor = .clear
        classroomOutline.strokeColor = SKColor(red: 0.77, green: 0.68, blue: 0.49, alpha: 0.9)
        classroomOutline.lineWidth = 2.5
        classroomOutline.zPosition = -3
        worldLayer.addChild(classroomOutline)

        let boardRect = CGRect(
            x: gridOrigin.x,
            y: gridOrigin.y,
            width: gridWidth,
            height: gridHeight
        )
        let floor = SKShapeNode(rect: boardRect)
        floor.fillColor = SKColor(red: 0.78, green: 0.70, blue: 0.55, alpha: 1)
        floor.strokeColor = SKColor(red: 0.22, green: 0.18, blue: 0.13, alpha: 0.95)
        floor.lineWidth = 1.5
        floor.zPosition = -2
        worldLayer.addChild(floor)

        for column in 0...columns {
            let x = gridOrigin.x + CGFloat(column) * cellSize
            let line = SKShapeNode(rectOf: CGSize(width: 1.1, height: gridHeight))
            line.fillColor = .black.withAlphaComponent(0.26)
            line.strokeColor = .clear
            line.position = CGPoint(x: x, y: gridOrigin.y + cellSize * CGFloat(rows) / 2)
            line.zPosition = -1
            worldLayer.addChild(line)
        }
        for row in 0...rows {
            let y = gridOrigin.y + CGFloat(row) * cellSize
            let line = SKShapeNode(rectOf: CGSize(width: gridWidth, height: 1.1))
            line.fillColor = .black.withAlphaComponent(0.26)
            line.strokeColor = .clear
            line.position = CGPoint(x: gridOrigin.x + cellSize * CGFloat(columns) / 2, y: y)
            line.zPosition = -1
            worldLayer.addChild(line)
        }

        drawFrontArea()
        drawMadonna()
    }

    private func drawFrontArea() {
        let gridWidth = cellSize * CGFloat(columns)
        let gridTop = gridOrigin.y + cellSize * CGFloat(rows)
        let front = SKShapeNode(rect: CGRect(x: gridOrigin.x, y: gridTop, width: gridWidth, height: frontAreaHeight))
        front.fillColor = SKColor(red: 0.67, green: 0.68, blue: 0.63, alpha: 1)
        front.strokeColor = SKColor(red: 0.20, green: 0.18, blue: 0.14, alpha: 1)
        front.lineWidth = 1.5
        front.zPosition = -2
        worldLayer.addChild(front)

        let chalkboard = SKShapeNode(rectOf: CGSize(width: gridWidth * 0.48, height: 8), cornerRadius: 2)
        chalkboard.fillColor = SKColor(red: 0.12, green: 0.31, blue: 0.20, alpha: 1)
        chalkboard.strokeColor = SKColor(red: 0.07, green: 0.12, blue: 0.08, alpha: 1)
        chalkboard.position = CGPoint(x: size.width / 2, y: gridTop + frontAreaHeight - 9)
        worldLayer.addChild(chalkboard)

        let teacherDesk = SKShapeNode(rectOf: CGSize(width: gridWidth * 0.31, height: frontAreaHeight * 0.48), cornerRadius: 7)
        teacherDesk.fillColor = SKColor(red: 0.83, green: 0.82, blue: 0.76, alpha: 1)
        teacherDesk.strokeColor = SKColor(red: 0.18, green: 0.16, blue: 0.13, alpha: 1)
        teacherDesk.lineWidth = 1.5
        teacherDesk.position = CGPoint(x: size.width / 2, y: gridTop + frontAreaHeight * 0.43)
        teacherDesk.zPosition = 2
        worldLayer.addChild(teacherDesk)

        let deskLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        deskLabel.text = "教卓"
        deskLabel.fontSize = 12
        deskLabel.fontColor = SKColor(red: 0.17, green: 0.15, blue: 0.12, alpha: 1)
        deskLabel.verticalAlignmentMode = .center
        teacherDesk.addChild(deskLabel)

        drawEntrance(at: leftEntrance, label: "入口")
        drawEntrance(at: rightEntrance, label: "入口")
    }

    private func drawEntrance(at grid: GridPoint, label: String) {
        let gridTop = gridOrigin.y + cellSize * CGFloat(rows)
        let center = entrancePoint(for: grid)
        let lane = SKShapeNode(rectOf: CGSize(width: cellSize, height: frontAreaHeight))
        lane.fillColor = SKColor(red: 0.91, green: 0.91, blue: 0.87, alpha: 1)
        lane.strokeColor = SKColor(red: 0.20, green: 0.18, blue: 0.14, alpha: 1)
        lane.lineWidth = 1
        lane.position = center
        lane.zPosition = 0
        worldLayer.addChild(lane)

        let door = SKShapeNode(rectOf: CGSize(width: cellSize * 0.72, height: 7), cornerRadius: 1.5)
        door.fillColor = SKColor(red: 0.78, green: 0.48, blue: 0.17, alpha: 1)
        door.strokeColor = SKColor(red: 0.18, green: 0.13, blue: 0.07, alpha: 1)
        door.position = CGPoint(x: center.x, y: gridTop + frontAreaHeight - 4)
        door.zPosition = 3
        worldLayer.addChild(door)

        let arrow = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        arrow.text = "↓"
        arrow.fontSize = min(28, frontAreaHeight * 0.52)
        arrow.fontColor = SKColor(red: 0.44, green: 0.46, blue: 0.44, alpha: 0.7)
        arrow.position = CGPoint(x: center.x, y: center.y - 9)
        arrow.verticalAlignmentMode = .center
        arrow.zPosition = 3
        worldLayer.addChild(arrow)

        let caption = SKLabelNode(fontNamed: "AvenirNext-Bold")
        caption.text = label
        caption.fontSize = 9
        caption.fontColor = .white.withAlphaComponent(0.9)
        caption.position = CGPoint(x: center.x, y: gridTop + frontAreaHeight + 5)
        caption.zPosition = 4
        worldLayer.addChild(caption)
    }

    private func drawMadonna() {
        let gridWidth = cellSize * CGFloat(columns)
        let zone = SKShapeNode(rect: CGRect(
            x: gridOrigin.x,
            y: gridOrigin.y - madonnaAreaHeight,
            width: gridWidth,
            height: madonnaAreaHeight
        ))
        zone.fillColor = SKColor(red: 0.73, green: 0.64, blue: 0.68, alpha: 1)
        zone.strokeColor = SKColor(red: 0.24, green: 0.17, blue: 0.20, alpha: 1)
        zone.lineWidth = 1.5
        zone.zPosition = -2
        worldLayer.addChild(zone)

        let center = madonnaPoint
        let aura = SKShapeNode(circleOfRadius: min(cellSize * 0.38, madonnaAreaHeight * 0.34))
        aura.fillColor = SKColor(red: 1, green: 0.42, blue: 0.65, alpha: 0.18)
        aura.strokeColor = SKColor(red: 1, green: 0.62, blue: 0.76, alpha: 0.8)
        aura.lineWidth = 2
        aura.position = center
        aura.zPosition = 2
        actorLayer.addChild(aura)

        let icon = SKLabelNode(fontNamed: "AvenirNext-Bold")
        icon.text = "👧🏻"
        icon.fontSize = min(cellSize * 0.50, madonnaAreaHeight * 0.42)
        icon.verticalAlignmentMode = .center
        icon.position.y = 2
        aura.addChild(icon)

        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.text = "マドンナエリア　ひかり"
        label.fontSize = 9
        label.fontColor = SKColor(red: 0.19, green: 0.12, blue: 0.15, alpha: 0.9)
        label.position = CGPoint(x: center.x, y: gridOrigin.y - madonnaAreaHeight + 7)
        label.zPosition = 4
        worldLayer.addChild(label)
    }

    private func drawFurniture() {
        furnitureLayer.removeAllChildren()
        for grid in blocked {
            let desk = SKShapeNode(rectOf: CGSize(width: cellSize * 0.76, height: cellSize * 0.52), cornerRadius: 4)
            desk.name = "desk_\(grid.column)_\(grid.row)"
            desk.fillColor = SKColor(red: 0.50, green: 0.32, blue: 0.17, alpha: 1)
            desk.strokeColor = SKColor(red: 0.88, green: 0.69, blue: 0.40, alpha: 1)
            desk.lineWidth = 1.5
            desk.position = point(for: grid)
            desk.zPosition = 5
            furnitureLayer.addChild(desk)

            let top = SKShapeNode(rectOf: CGSize(width: cellSize * 0.56, height: 3), cornerRadius: 1.5)
            top.fillColor = .white.withAlphaComponent(0.2)
            top.strokeColor = .clear
            top.position.y = cellSize * 0.12
            desk.addChild(top)
        }
    }

    private func installDefenders() {
        actorLayer.children.filter { $0 is DefenderNode }.forEach { $0.removeFromParent() }
        defenders.removeAll()

        let profiles = [
            DefenderProfile(name: "ミオ", role: "図書委員", symbol: "📚", range: cellSize * 3.0, damage: 20, attackInterval: 0.58, projectileColor: UIColor.systemYellow.cgColor),
            DefenderProfile(name: "ケンタ", role: "バスケ部", symbol: "🏀", range: cellSize * 2.4, damage: 27, attackInterval: 0.80, projectileColor: UIColor.systemOrange.cgColor),
            DefenderProfile(name: "ユイ", role: "美術部", symbol: "🖌", range: cellSize * 3.6, damage: 14, attackInterval: 0.38, projectileColor: UIColor.systemCyan.cgColor)
        ]
        let positions = [
            GridPoint(column: 1, row: 2),
            GridPoint(column: 6, row: 2),
            GridPoint(column: 4, row: 4)
        ]

        for (profile, grid) in zip(profiles, positions) {
            let node = DefenderNode(profile: profile)
            node.position = point(for: grid)
            node.zPosition = 12
            actorLayer.addChild(node)
            defenders.append((grid, node))
        }
    }

    private func drawControls() {
        let strip = SKShapeNode(rectOf: CGSize(width: size.width - 20, height: 102), cornerRadius: 16)
        strip.fillColor = SKColor(red: 0.10, green: 0.13, blue: 0.15, alpha: 0.98)
        strip.strokeColor = .white.withAlphaComponent(0.12)
        strip.position = CGPoint(x: size.width / 2, y: 72)
        hudLayer.addChild(strip)

        let instruction = SKLabelNode(fontNamed: "AvenirNext-Medium")
        instruction.name = "instruction"
        instruction.text = phase == .building ? "マスをタップして机を置く・もう一度で撤去" : "クラスメイトが自動で迎撃中！"
        instruction.fontSize = 10
        instruction.fontColor = .white.withAlphaComponent(0.65)
        instruction.position = CGPoint(x: 0, y: 28)
        instruction.verticalAlignmentMode = .center
        strip.addChild(instruction)

        let clearButton = makeButton(name: "clear", text: "机を片付ける", width: 112, color: SKColor(red: 0.24, green: 0.28, blue: 0.30, alpha: 1))
        clearButton.position = CGPoint(x: -67, y: -12)
        strip.addChild(clearButton)

        primaryButton.path = CGPath(roundedRect: CGRect(x: -57, y: -21, width: 114, height: 42), cornerWidth: 11, cornerHeight: 11, transform: nil)
        primaryButton.name = "primary"
        primaryButton.removeAllChildren()
        primaryButton.fillColor = SKColor(red: 0.96, green: 0.34, blue: 0.48, alpha: 1)
        primaryButton.strokeColor = .clear
        primaryButton.position = CGPoint(x: 65, y: -12)
        strip.addChild(primaryButton)

        primaryButtonLabel.name = "primary"
        primaryButtonLabel.text = "防衛開始！"
        primaryButtonLabel.fontSize = 13
        primaryButtonLabel.verticalAlignmentMode = .center
        primaryButtonLabel.position.y = 1
        primaryButton.addChild(primaryButtonLabel)

        messageLabel.fontSize = 13
        messageLabel.fontColor = SKColor(red: 1, green: 0.88, blue: 0.35, alpha: 1)
        messageLabel.position = CGPoint(x: size.width / 2, y: gridOrigin.y + cellSize * CGFloat(rows) + frontAreaHeight + 8)
        messageLabel.zPosition = 100
        messageLabel.alpha = 0
        hudLayer.addChild(messageLabel)
    }

    private func makeButton(name: String, text: String, width: CGFloat, color: SKColor) -> SKShapeNode {
        let button = SKShapeNode(rectOf: CGSize(width: width, height: 42), cornerRadius: 11)
        button.name = name
        button.fillColor = color
        button.strokeColor = .clear
        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.name = name
        label.text = text
        label.fontSize = 11
        label.verticalAlignmentMode = .center
        label.position.y = 1
        button.addChild(label)
        return button
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self) else { return }
        let tappedNames = nodes(at: location).compactMap(\.name)

        if tappedNames.contains("primary") {
            handlePrimaryButton()
            return
        }
        if tappedNames.contains("clear"), phase == .building {
            blocked.removeAll()
            drawFurniture()
            refreshPaths()
            showMessage("机をすべて片付けました")
            return
        }
        guard phase == .building, let grid = gridPoint(at: location) else { return }
        toggleDesk(at: grid)
    }

    private func toggleDesk(at grid: GridPoint) {
        let reserved = Set([leftEntrance, rightEntrance] + defenders.map(\.grid))
        guard !reserved.contains(grid) else {
            showMessage("ここには机を置けません", isError: true)
            return
        }

        if blocked.contains(grid) {
            blocked.remove(grid)
        } else {
            blocked.insert(grid)
            if !bothEntrancesHavePaths() {
                blocked.remove(grid)
                showMessage("通路を完全には塞げません", isError: true)
                pulseCell(grid)
                return
            }
        }
        drawFurniture()
        refreshPaths()
    }

    private func handlePrimaryButton() {
        switch phase {
        case .building:
            startWave()
        case .fighting:
            resetGame(keepFurniture: true)
        case .victory, .defeated:
            resetGame(keepFurniture: false)
        }
    }

    private func startWave() {
        guard bothEntrancesHavePaths() else {
            showMessage("入口からマドンナまでの道が必要です", isError: true)
            return
        }
        phase = .fighting
        spawnedCount = 0
        defeatedCount = 0
        stress = 0
        spawnAccumulator = 0.8
        primaryButtonLabel.text = "やり直す"
        primaryButton.fillColor = SKColor(red: 0.28, green: 0.32, blue: 0.35, alpha: 1)
        refreshHUD()
        showMessage("告白ラッシュ開始！")
    }

    private func resetGame(keepFurniture: Bool) {
        phase = .building
        enemies.forEach { $0.removeFromParent() }
        enemies.removeAll()
        projectiles.forEach { $0.removeFromParent() }
        projectiles.removeAll()
        if !keepFurniture { blocked.removeAll() }
        spawnedCount = 0
        defeatedCount = 0
        stress = 0
        lastUpdateTime = 0
        primaryButtonLabel.text = "防衛開始！"
        primaryButton.fillColor = SKColor(red: 0.96, green: 0.34, blue: 0.48, alpha: 1)
        drawFurniture()
        refreshPaths()
        refreshHUD()
    }

    override func update(_ currentTime: TimeInterval) {
        guard phase == .fighting else {
            lastUpdateTime = currentTime
            return
        }
        let delta = lastUpdateTime == 0 ? 0 : min(currentTime - lastUpdateTime, 1.0 / 20.0)
        lastUpdateTime = currentTime

        spawnAccumulator += delta
        if spawnedCount < waveEnemyCount, spawnAccumulator >= 0.68 {
            spawnAccumulator = 0
            spawnEnemy()
        }

        updateEnemies(delta: delta)
        if stress >= 100 {
            finishGame(as: .defeated)
            return
        }
        updateDefenders(delta: delta)

        if spawnedCount == waveEnemyCount, enemies.isEmpty {
            finishGame(as: .victory)
        }
    }

    private func finishGame(as result: GamePhase) {
        phase = result
        if result == .defeated {
            enemies.forEach { $0.removeFromParent() }
            enemies.removeAll()
            projectiles.forEach { $0.removeFromParent() }
            projectiles.removeAll()
        }
        primaryButtonLabel.text = "もう一度"
        primaryButton.fillColor = result == .victory ? .systemGreen : .systemRed
        showMessage(result == .victory ? "放課後まで守り切った！" : "ひかりの心が限界です…", isError: result == .defeated)
        refreshHUD()
    }

    private func spawnEnemy() {
        let entrance = spawnedCount.isMultiple(of: 2) ? leftEntrance : rightEntrance
        guard let gridPath = path(from: entrance) else { return }
        let health = CGFloat(45 + (spawnedCount / 8) * 12)
        let speed = cellSize * CGFloat(1.38 + Double(spawnedCount / 12) * 0.10)
        let enemy = EnemyNode(hitPoints: health, speed: speed)
        enemy.position = entrancePoint(for: entrance)
        enemy.path = gridPath.map(point(for:)) + [madonnaPoint]
        enemy.pathIndex = 0
        enemy.zPosition = 15
        actorLayer.addChild(enemy)
        enemies.append(enemy)
        spawnedCount += 1
        refreshHUD()
    }

    private func updateEnemies(delta: TimeInterval) {
        var reachedGoal: [EnemyNode] = []
        for enemy in enemies {
            guard enemy.pathIndex < enemy.path.count else {
                reachedGoal.append(enemy)
                continue
            }
            let target = enemy.path[enemy.pathIndex]
            let dx = target.x - enemy.position.x
            let dy = target.y - enemy.position.y
            let distance = hypot(dx, dy)
            let step = enemy.moveSpeed * CGFloat(delta)
            if distance <= step || distance < 0.5 {
                enemy.position = target
                enemy.pathIndex += 1
            } else {
                enemy.position.x += dx / distance * step
                enemy.position.y += dy / distance * step
            }
        }

        for enemy in reachedGoal {
            stress = min(100, stress + 20)
            removeEnemy(enemy, countedAsDefeat: false)
            flashMadonna()
        }
        refreshHUD()
    }

    private func updateDefenders(delta: TimeInterval) {
        for (_, defender) in defenders {
            defender.cooldown -= delta
            guard defender.cooldown <= 0,
                  let target = nearestEnemy(to: defender.position, within: defender.profile.range) else { continue }
            defender.cooldown = defender.profile.attackInterval
            fire(from: defender, at: target)
        }
    }

    private func nearestEnemy(to point: CGPoint, within range: CGFloat) -> EnemyNode? {
        enemies
            .map { enemy in (enemy, hypot(enemy.position.x - point.x, enemy.position.y - point.y)) }
            .filter { $0.1 <= range }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func fire(from defender: DefenderNode, at target: EnemyNode) {
        let projectile = SKShapeNode(circleOfRadius: 3.8)
        projectile.fillColor = SKColor(cgColor: defender.profile.projectileColor)
        projectile.strokeColor = .white.withAlphaComponent(0.7)
        projectile.glowWidth = 2
        projectile.position = defender.position
        projectile.zPosition = 25
        projectileLayer.addChild(projectile)
        projectiles.append(projectile)

        let duration = max(0.08, Double(hypot(target.position.x - defender.position.x, target.position.y - defender.position.y) / 650))
        let destination = target.position
        projectile.run(.sequence([
            .move(to: destination, duration: duration),
            .run { [weak self, weak target, weak projectile] in
                guard let self, let target, target.parent != nil else {
                    projectile?.removeFromParent()
                    return
                }
                if target.takeDamage(defender.profile.damage) {
                    self.removeEnemy(target, countedAsDefeat: true)
                } else {
                    target.run(.sequence([.scale(to: 1.18, duration: 0.04), .scale(to: 1, duration: 0.06)]))
                }
            },
            .run { [weak self, weak projectile] in
                guard let projectile else { return }
                self?.projectiles.removeAll { $0 === projectile }
            },
            .removeFromParent()
        ]))

        defender.run(.sequence([.scale(to: 1.18, duration: 0.05), .scale(to: 1, duration: 0.08)]))
    }

    private func removeEnemy(_ enemy: EnemyNode, countedAsDefeat: Bool) {
        guard let index = enemies.firstIndex(where: { $0 === enemy }) else { return }
        enemies.remove(at: index)
        if countedAsDefeat { defeatedCount += 1 }
        enemy.removeAllActions()
        enemy.run(.sequence([.scale(to: 0.01, duration: 0.12), .removeFromParent()]))
        refreshHUD()
    }

    private func refreshPaths() {
        pathLayer.removeAllChildren()
        guard phase == .building else { return }
        for entrance in [leftEntrance, rightEntrance] {
            guard let route = path(from: entrance) else { continue }
            for grid in route.dropFirst() {
                let dot = SKShapeNode(circleOfRadius: max(1.8, cellSize * 0.045))
                dot.fillColor = SKColor(red: 1, green: 0.82, blue: 0.28, alpha: 0.42)
                dot.strokeColor = .clear
                dot.position = point(for: grid)
                dot.zPosition = 0
                pathLayer.addChild(dot)
            }
        }
    }

    private func path(from entrance: GridPoint) -> [GridPoint]? {
        let bottomEdge = Set((0..<columns).map { GridPoint(column: $0, row: 0) })
        return Pathfinder.shortestPath(from: entrance, toAny: bottomEdge, blocked: blocked, columns: columns, rows: rows)
    }

    private func bothEntrancesHavePaths() -> Bool {
        path(from: leftEntrance) != nil && path(from: rightEntrance) != nil
    }

    private func refreshHUD() {
        switch phase {
        case .building: phaseLabel.text = "準備時間"
        case .fighting: phaseLabel.text = "1時間目"
        case .victory: phaseLabel.text = "防衛成功"
        case .defeated: phaseLabel.text = "防衛失敗"
        }
        scoreLabel.text = "撃退 \(defeatedCount) / \(waveEnemyCount)"
        stressLabel.text = "ストレス \(stress)%"
        stressLabel.fontColor = stress >= 60 ? .systemRed : .white
        if let instruction = hudLayer.childNode(withName: "//instruction") as? SKLabelNode {
            instruction.text = phase == .building ? "マスをタップして机を置く・もう一度で撤去" : "クラスメイトが自動で迎撃中！"
        }
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        messageLabel.removeAllActions()
        messageLabel.text = text
        messageLabel.fontColor = isError ? .systemRed : SKColor(red: 1, green: 0.88, blue: 0.35, alpha: 1)
        messageLabel.alpha = 1
        messageLabel.run(.sequence([.wait(forDuration: 1.5), .fadeOut(withDuration: 0.35)]))
    }

    private func pulseCell(_ grid: GridPoint) {
        let warning = SKShapeNode(rectOf: CGSize(width: cellSize * 0.82, height: cellSize * 0.82), cornerRadius: 6)
        warning.fillColor = .systemRed.withAlphaComponent(0.35)
        warning.strokeColor = .systemRed
        warning.position = point(for: grid)
        warning.zPosition = 30
        worldLayer.addChild(warning)
        warning.run(.sequence([.fadeOut(withDuration: 0.45), .removeFromParent()]))
    }

    private func flashMadonna() {
        guard let aura = actorLayer.children.first(where: { !($0 is DefenderNode) }) else { return }
        aura.run(.sequence([.scale(to: 1.35, duration: 0.08), .scale(to: 1, duration: 0.15)]))
    }

    private func point(for grid: GridPoint) -> CGPoint {
        CGPoint(
            x: gridOrigin.x + (CGFloat(grid.column) + 0.5) * cellSize,
            y: gridOrigin.y + (CGFloat(grid.row) + 0.5) * cellSize
        )
    }

    private var madonnaPoint: CGPoint {
        CGPoint(x: size.width / 2, y: gridOrigin.y - madonnaAreaHeight * 0.54)
    }

    private func entrancePoint(for grid: GridPoint) -> CGPoint {
        CGPoint(
            x: gridOrigin.x + (CGFloat(grid.column) + 0.5) * cellSize,
            y: gridOrigin.y + cellSize * CGFloat(rows) + frontAreaHeight * 0.46
        )
    }

    private func gridPoint(at point: CGPoint) -> GridPoint? {
        let column = Int((point.x - gridOrigin.x) / cellSize)
        let row = Int((point.y - gridOrigin.y) / cellSize)
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return GridPoint(column: column, row: row)
    }
}
