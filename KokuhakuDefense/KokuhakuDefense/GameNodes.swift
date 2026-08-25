import SpriteKit

final class EnemyNode: SKNode {
    var hitPoints: CGFloat
    let maxHitPoints: CGFloat
    let moveSpeed: CGFloat
    var path: [CGPoint] = []
    var pathIndex = 0

    private let healthBar = SKShapeNode(rectOf: CGSize(width: 25, height: 3), cornerRadius: 1.5)

    init(hitPoints: CGFloat, speed: CGFloat) {
        self.hitPoints = hitPoints
        self.maxHitPoints = hitPoints
        self.moveSpeed = speed
        super.init()

        let body = SKShapeNode(circleOfRadius: 13)
        body.fillColor = SKColor(red: 0.91, green: 0.32, blue: 0.42, alpha: 1)
        body.strokeColor = .white.withAlphaComponent(0.75)
        body.lineWidth = 1.5
        addChild(body)

        let letter = SKLabelNode(fontNamed: "AvenirNext-Bold")
        letter.text = "💌"
        letter.fontSize = 14
        letter.verticalAlignmentMode = .center
        letter.position.y = 1
        body.addChild(letter)

        healthBar.fillColor = SKColor(red: 0.31, green: 0.92, blue: 0.53, alpha: 1)
        healthBar.strokeColor = .clear
        healthBar.position = CGPoint(x: 0, y: 18)
        healthBar.zPosition = 2
        addChild(healthBar)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func takeDamage(_ amount: CGFloat) -> Bool {
        hitPoints -= amount
        let ratio = max(0, hitPoints / maxHitPoints)
        healthBar.xScale = ratio
        healthBar.position.x = -12.5 * (1 - ratio)
        return hitPoints <= 0
    }
}

final class DefenderNode: SKNode {
    let profile: DefenderProfile
    var cooldown: TimeInterval = 0

    init(profile: DefenderProfile) {
        self.profile = profile
        super.init()

        let shadow = SKShapeNode(ellipseOf: CGSize(width: 27, height: 10))
        shadow.fillColor = .black.withAlphaComponent(0.2)
        shadow.strokeColor = .clear
        shadow.position.y = -12
        addChild(shadow)

        let body = SKShapeNode(circleOfRadius: 14)
        body.fillColor = SKColor(red: 0.20, green: 0.55, blue: 0.86, alpha: 1)
        body.strokeColor = .white.withAlphaComponent(0.8)
        body.lineWidth = 2
        addChild(body)

        let symbol = SKLabelNode(fontNamed: "AvenirNext-Bold")
        symbol.text = profile.symbol
        symbol.fontSize = 16
        symbol.verticalAlignmentMode = .center
        symbol.position.y = 1
        body.addChild(symbol)

        let name = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        name.text = profile.name
        name.fontSize = 8
        name.fontColor = .white
        name.position.y = -24
        name.verticalAlignmentMode = .center
        addChild(name)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
