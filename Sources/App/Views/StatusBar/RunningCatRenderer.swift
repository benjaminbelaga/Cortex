import AppKit

/// Draws the RunCat-style running cat for the menu-bar glyph.
///
/// The cat is parametric, not an asset: one drawing function takes a phase
/// (0..<1 of the stride cycle) and renders body bob, leg angles, and tail
/// sway from it — so the 8 animation frames stay perfectly consistent, there
/// is no bundled image set to license or maintain, and the whole cat tints
/// in one `.sourceAtop` pass like every other status-item pixel.
enum RunningCatRenderer {

    /// Number of distinct frames in the stride cycle. 8 frames at ~12 fps
    /// reads as a natural run without strobing.
    static let frameCount = 8

    /// Point size of the drawing canvas — matches the status item's other
    /// 12pt content; the cat's ink is inset so descender-free clipping is
    /// impossible.
    private static let canvas: CGFloat = 16

    /// Renders one stride frame tinted with `color`.
    ///
    /// - Parameters:
    ///   - frame: stride frame index (wrapped internally).
    ///   - color: tint for the whole silhouette (health color).
    @MainActor
    static func image(frame: Int, color: NSColor) -> NSImage {
        let phase = Double(frame) / Double(frameCount) * 2 * .pi
        let untinted = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            drawCat(phase: phase, in: rect)
            return true
        }
        let tinted = NSImage(size: untinted.size, flipped: false) { rect in
            untinted.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    // MARK: - Parametric cat

    /// Geometry constants (in unit space, 0…1 of the canvas).
    private enum Cat {
        static let bodyCenter = CGPoint(x: 0.5, y: 0.5)
        static let bodySize = CGSize(width: 0.42, height: 0.24)
        static let headCenter = CGPoint(x: 0.76, y: 0.58)
        static let headRadius: CGFloat = 0.10
        static let earSize: CGFloat = 0.055
        static let upperLeg: CGFloat = 0.14
        static let legWidth: CGFloat = 0.045
        static let tailBase = CGPoint(x: 0.30, y: 0.58)
    }

    /// Draws the cat for a stride `phase` (radians, full cycle = 2π).
    ///
    /// Movement model: front and back leg pairs each swing as two-segment
    /// pendulums, the pairs counter-phased (gallop read); the tail sways
    /// opposite the rear legs; the body bobs at twice the stride rate.
    private static func drawCat(phase: CGFloat, in rect: CGRect) {
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        func pw(_ s: CGSize) -> CGSize {
            CGSize(width: s.width * rect.width, height: s.height * rect.height)
        }
        let bob = CGFloat(sin(2 * phase)) * 0.02

        NSColor.black.set()

        // Tail — sways opposite the rear leg swing.
        let tailAngle: CGFloat = -0.5 + 0.35 * sin(phase + .pi)
        let tailTip = CGPoint(
            x: Cat.tailBase.x - 0.22 * cos(tailAngle),
            y: Cat.tailBase.y + 0.16 * sin(tailAngle) + 0.10
        )
        let tailPath = NSBezierPath()
        tailPath.lineWidth = pw(CGSize(width: Cat.legWidth * 0.9, height: 0)).width
        tailPath.lineCapStyle = .round
        tailPath.move(to: px(CGPoint(x: Cat.tailBase.x, y: Cat.tailBase.y + bob)))
        tailPath.curve(
            to: px(CGPoint(x: tailTip.x, y: tailTip.y + bob)),
            controlPoint1: px(CGPoint(x: Cat.tailBase.x - 0.12, y: Cat.tailBase.y + 0.14 + bob)),
            controlPoint2: px(CGPoint(x: tailTip.x + 0.08, y: tailTip.y + 0.10 + bob))
        )
        tailPath.stroke()

        // Legs — two-segment pendulums: front pair and back pair counter-phased.
        drawLegPair(
            hip: CGPoint(x: Cat.bodyCenter.x + 0.13, y: Cat.bodyCenter.y - 0.08),
            baseAngle: sin(phase),
            counterAngle: sin(phase + .pi),
            px: px, pw: pw, bob: bob
        )
        drawLegPair(
            hip: CGPoint(x: Cat.bodyCenter.x - 0.13, y: Cat.bodyCenter.y - 0.08),
            baseAngle: sin(phase + .pi),
            counterAngle: sin(phase + 2 * .pi),
            px: px, pw: pw, bob: bob
        )

        // Body — ellipse with the bob.
        let bodyRect = NSRect(
            origin: px(CGPoint(
                x: Cat.bodyCenter.x - Cat.bodySize.width / 2,
                y: Cat.bodyCenter.y - Cat.bodySize.height / 2 + bob
            )),
            size: pw(Cat.bodySize)
        )
        NSBezierPath(ovalIn: bodyRect).fill()

        // Head + ears.
        let headCenter = px(CGPoint(x: Cat.headCenter.x, y: Cat.headCenter.y + bob))
        let headR = Cat.headRadius * rect.width
        NSBezierPath(ovalIn: NSRect(
            origin: CGPoint(x: headCenter.x - headR, y: headCenter.y - headR),
            size: CGSize(width: headR * 2, height: headR * 2)
        )).fill()

        let ear = Cat.earSize * rect.width
        for offset in [CGPoint(x: -0.35, y: 0.85), CGPoint(x: 0.25, y: 0.95)] {
            let earBase = CGPoint(x: headCenter.x + offset.x * headR, y: headCenter.y + offset.y * headR)
            let earPath = NSBezierPath()
            earPath.move(to: CGPoint(x: earBase.x - ear * 0.5, y: earBase.y))
            earPath.line(to: CGPoint(x: earBase.x + ear * 0.15, y: earBase.y + ear))
            earPath.line(to: CGPoint(x: earBase.x + ear * 0.5, y: earBase.y - ear * 0.1))
            earPath.close()
            earPath.fill()
        }
    }

    /// One hip's leg pair: the near leg leads the cycle, the far leg trails
    /// by a quarter phase (visible as a scissor motion).
    private static func drawLegPair(
        hip: CGPoint,
        baseAngle: CGFloat,
        counterAngle: CGFloat,
        px: (CGPoint) -> CGPoint,
        pw: (CGSize) -> CGSize,
        bob: CGFloat
    ) {
        drawLeg(hip: hip, swing: baseAngle, px: px, pw: pw, bob: bob, alpha: 0.85)
        drawLeg(hip: hip, swing: counterAngle * 0.5, px: px, pw: pw, bob: bob, alpha: 1.0)
    }

    /// Two-segment leg in unit space: upper segment swings with `swing`,
    /// lower segment folds with half the amplitude — a decent run gait
    /// without IK.
    private static func drawLeg(
        hip: CGPoint,
        swing: CGFloat,
        px: (CGPoint) -> CGPoint,
        pw: (CGSize) -> CGSize,
        bob: CGFloat,
        alpha: CGFloat
    ) {
        let upper = Cat.upperLeg
        let upperAngle = -CGFloat.pi / 2 + swing * 0.7
        let knee = CGPoint(
            x: hip.x + upper * sin(upperAngle),
            y: hip.y + upper * cos(upperAngle) + bob
        )
        let lowerAngle = upperAngle - swing * 0.5 - 0.25
        let foot = CGPoint(
            x: knee.x + upper * 0.8 * sin(lowerAngle),
            y: knee.y + upper * 0.8 * cos(lowerAngle)
        )

        let path = NSBezierPath()
        path.lineWidth = pw(CGSize(width: Cat.legWidth, height: 0)).width
        path.lineCapStyle = .round
        path.move(to: px(CGPoint(x: hip.x, y: hip.y + bob)))
        path.line(to: px(knee))
        path.line(to: px(foot))
        NSColor.black.withAlphaComponent(alpha).set()
        path.stroke()
    }
}
