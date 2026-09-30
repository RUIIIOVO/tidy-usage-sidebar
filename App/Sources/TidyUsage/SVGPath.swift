import CoreGraphics

/// 极简 SVG path 解析器，只覆盖 logo 用到的指令：M L H V C S Q Z（含相对形式）。
enum SVGPath {
    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    static func parse(_ d: String) -> CGPath {
        let tokens = tokenize(d)
        let path = CGMutablePath()
        var i = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?

        func hasNumbers(_ n: Int) -> Bool {
            guard i + n <= tokens.count else { return false }
            for k in i..<(i + n) {
                if case .command = tokens[k] { return false }
            }
            return true
        }

        func take() -> CGFloat {
            defer { i += 1 }
            if case let .number(v) = tokens[i] { return v }
            return 0
        }

        while i < tokens.count {
            if case let .command(c) = tokens[i] {
                command = c
                i += 1
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    lastCubicControl = nil
                    continue
                }
            }

            let relative = command.isLowercase
            let base = relative ? current : .zero

            switch command {
            case "M", "m":
                guard hasNumbers(2) else { i += 1; continue }
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                // M 之后的坐标对按 L 处理
                command = relative ? "l" : "L"
            case "L", "l":
                guard hasNumbers(2) else { i += 1; continue }
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
            case "H", "h":
                guard hasNumbers(1) else { i += 1; continue }
                let x = take()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "V", "v":
                guard hasNumbers(1) else { i += 1; continue }
                let y = take()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "C", "c":
                guard hasNumbers(6) else { i += 1; continue }
                let c1 = CGPoint(x: base.x + take(), y: base.y + take())
                let c2 = CGPoint(x: base.x + take(), y: base.y + take())
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
            case "S", "s":
                guard hasNumbers(4) else { i += 1; continue }
                let c1: CGPoint
                if let last = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    c1 = current
                }
                let c2 = CGPoint(x: base.x + take(), y: base.y + take())
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
            case "A", "a":
                guard hasNumbers(7) else { i += 1; continue }
                let rx = take(), ry = take(), rot = take()
                let large = take() != 0, sweep = take() != 0
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                addArc(to: path, from: current, to: p, rx: rx, ry: ry,
                       rotation: rot, large: large, sweep: sweep)
                current = p
                lastCubicControl = nil
            case "Q", "q":
                guard hasNumbers(4) else { i += 1; continue }
                let c = CGPoint(x: base.x + take(), y: base.y + take())
                let p = CGPoint(x: base.x + take(), y: base.y + take())
                path.addQuadCurve(to: p, control: c)
                current = p
                lastCubicControl = nil
            default:
                i += 1
            }
        }
        return path
    }

    /// SVG 椭圆弧（endpoint 参数化）转成三次贝塞尔曲线，对应 SVG 规范 F.6.5。
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var th = theta1
        for _ in 0..<segments {
            let c1 = cos(th), s1 = sin(th)
            let c2 = cos(th + delta), s2 = sin(th + delta)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx,
                        y: sinPhi * rx * x + cosPhi * ry * y + cy)
            }
            let cp1 = map(c1 - t * s1, s1 + t * c1)
            let cp2 = map(c2 + t * s2, s2 - t * c2)
            let end = map(c2, s2)
            path.addCurve(to: end, control1: cp1, control2: cp2)
            th += delta
        }
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" {
                tokens.append(.command(c))
                i += 1
            } else if c == "-" || c == "+" || c == "." || c.isNumber {
                var s = String(c)
                var seenDot = c == "."
                var seenExp = false
                i += 1
                while i < chars.count {
                    let n = chars[i]
                    if n.isNumber {
                        s.append(n)
                    } else if n == "." && !seenDot && !seenExp {
                        seenDot = true
                        s.append(n)
                    } else if (n == "e" || n == "E") && !seenExp {
                        seenExp = true
                        s.append(n)
                    } else if (n == "-" || n == "+") && (s.last == "e" || s.last == "E") {
                        s.append(n)
                    } else {
                        break
                    }
                    i += 1
                }
                if let v = Double(s) { tokens.append(.number(CGFloat(v))) }
            } else {
                i += 1
            }
        }
        return tokens
    }
}
