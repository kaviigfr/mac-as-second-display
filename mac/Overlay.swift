import Cocoa
import Network

final class WinCursorOverlay {
    private let layer = CALayer()
    private weak var view: InputView?
    private var buf = Data()
    private let image = NSCursor.arrow.image

    func attach(to v: InputView) {
        view = v
        layer.isHidden = true
        layer.zPosition = 100
        layer.anchorPoint = CGPoint(x: 0, y: 1)
        layer.bounds = CGRect(origin: .zero, size: image.size)
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            layer.contents = cg
        }
        v.layer?.addSublayer(layer)
    }

    func feed(_ data: Data) {
        buf.append(data)
        while let nl = buf.firstIndex(of: 10) {
            let lineData = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let p = line.split(separator: " ")
            if p.first == "C", p.count >= 3, let nx = Double(p[1]), let ny = Double(p[2]) {
                DispatchQueue.main.async { self.show(nx, ny) }
            } else if p.first == "H" {
                DispatchQueue.main.async { self.hide() }
            }
        }
    }

    func show(_ nx: Double, _ ny: Double) {
        guard let v = view else { return }
        let scale = min(v.bounds.width / v.videoSize.width, v.bounds.height / v.videoSize.height)
        let w = v.videoSize.width * scale, h = v.videoSize.height * scale
        let x0 = (v.bounds.width - w) / 2, y0 = (v.bounds.height - h) / 2
        let px = x0 + CGFloat(nx) * w
        let py = y0 + CGFloat(1 - ny) * h
        let hs = NSCursor.arrow.hotSpot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: px - hs.x, y: py + hs.y)
        layer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }
}

extension Viewer {
    func readInput(_ c: NWConnection, _ gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self = self, gen == self.inputGen else { return }
            if let data = data, !data.isEmpty { self.overlay.feed(data) }
            if done || err != nil { self.reconnectInput(gen); return }
            self.readInput(c, gen)
        }
    }
}
