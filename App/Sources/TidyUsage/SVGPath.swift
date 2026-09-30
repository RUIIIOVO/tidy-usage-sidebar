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
