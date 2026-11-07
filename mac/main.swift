import Cocoa
import Network
import AVFoundation
import CoreMedia

final class InputView: NSView {
    var onLine: ((String) -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var videoSize = CGSize(width: 1920, height: 1080)

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    func move(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * scale, h = videoSize.height * scale
        let x0 = (bounds.width - w) / 2, y0 = (bounds.height - h) / 2
        let nx = Double((p.x - x0) / w), ny = Double(1 - (p.y - y0) / h)
        onLine?(String(format: "M %.5f %.5f", nx, ny))
    }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func mouseDown(with e: NSEvent) { move(e); onLine?("D 0") }
    override func mouseUp(with e: NSEvent) { move(e); onLine?("U 0") }
    override func rightMouseDown(with e: NSEvent) { move(e); onLine?("D 1") }
    override func rightMouseUp(with e: NSEvent) { move(e); onLine?("U 1") }
    override func otherMouseDown(with e: NSEvent) { move(e); onLine?("D 2") }
    override func otherMouseUp(with e: NSEvent) { move(e); onLine?("U 2") }

    override func scrollWheel(with e: NSEvent) {
        let k = e.hasPreciseScrollingDeltas ? 8.0 : 40.0
        onLine?(String(format: "W %.2f %.2f", e.scrollingDeltaX * k, e.scrollingDeltaY * k))
    }

    // Ctrl+Cmd+F toggles fullscreen and is not sent to Windows
    func isFullscreenCombo(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 3 && f.contains(.command) && f.contains(.control)
    }

    override func keyDown(with e: NSEvent) {
        if isFullscreenCombo(e) { onToggleFullscreen?(); return }
        onLine?("K \(e.keyCode) 1")
        if e.modifierFlags.contains(.command) { onLine?("K \(e.keyCode) 0") }
    }
    override func keyUp(with e: NSEvent) { onLine?("K \(e.keyCode) 0") }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.type == .keyDown { keyDown(with: e); return true }
        return false
    }
    override func flagsChanged(with e: NSEvent) {
        if e.keyCode == 0x39 { onLine?("K 57 1"); onLine?("K 57 0"); return }
        let flag: NSEvent.ModifierFlags
        switch e.keyCode {
        case 0x37, 0x36: flag = .command
        case 0x38, 0x3C: flag = .shift
        case 0x3A, 0x3D: flag = .option
        default: return
        }
        onLine?("K \(e.keyCode) \(e.modifierFlags.contains(flag) ? 1 : 0)")
    }
}

final class Viewer: NSObject, NSApplicationDelegate {
    var host: String?
    let netQueue = DispatchQueue(label: "net", qos: .userInteractive)
    var window: NSWindow!
    let displayLayer = AVSampleBufferDisplayLayer()
    let inputView = InputView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    let overlay = WinCursorOverlay()

    var conn: NWConnection?
    var videoGen = 0
    var inputConn: NWConnection?
    var inputGen = 0
    var inputReady = false

    var bytes = [UInt8]()
    var sps: Data?
    var pps: Data?
    var format: CMVideoFormatDescription?

    init(host: String?) { self.host = host }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Screen Viewer - waiting for Windows..."
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        let view = inputView
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = view.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        displayLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(displayLayer)
        overlay.attach(to: view)
        view.onLine = { [weak self] line in self?.send(line) }
        view.onToggleFullscreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: window, queue: .main) { [weak self] _ in
            for k in [55, 54, 56, 60, 58, 61] { self?.send("K \(k) 0") }  // release modifiers
        }
        netQueue.async { [weak self] in
            self?.connect()
            self?.connectInput()
            if self?.host == nil { self?.startDiscovery() }
        }
    }

    func setStatus(_ connected: Bool) {
        DispatchQueue.main.async {
            self.window.title = connected ? "Screen Viewer" : "Screen Viewer - waiting for Windows..."
        }
    }

    // MARK: video connection (auto-reconnect)

    func connect() {
        videoGen += 1
        let gen = videoGen
        bytes.removeAll(); sps = nil; pps = nil; format = nil
        guard let h = host else { netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }; return }
        let c = NWConnection(host: NWEndpoint.Host(h), port: 5000, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, gen == self.videoGen else { return }
            switch st {
            case .ready:
                print("video connected")
                self.setStatus(true)
                self.receive(c, gen)
            case .waiting, .failed:
                self.reconnectVideo(gen)
            default: break
            }
        }
        c.start(queue: netQueue)
    }

    func reconnectVideo(_ gen: Int) {
        guard gen == videoGen else { return }
        videoGen += 1
        conn?.cancel()
        setStatus(false)
        DispatchQueue.main.async { self.displayLayer.flushAndRemoveImage() }
        netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    func receive(_ c: NWConnection, _ gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self, gen == self.videoGen else { return }
            if let data = data, !data.isEmpty { self.bytes.append(contentsOf: data); self.parse() }
            if done || err != nil { print("video disconnected"); self.reconnectVideo(gen); return }
            self.receive(c, gen)
        }
    }

    // MARK: input connection (auto-reconnect)

    func connectInput() {
        inputGen += 1
        let gen = inputGen
        inputReady = false
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let h = host else { netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectInput() }; return }
        let c = NWConnection(host: NWEndpoint.Host(h), port: 5001, using: NWParameters(tls: nil, tcp: tcp))
        inputConn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, gen == self.inputGen else { return }
            switch st {
            case .ready:
                self.inputReady = true
                print("input ready")
                self.readInput(c, gen)
            case .waiting, .failed:
                self.reconnectInput(gen)
            default: break
            }
        }
        c.start(queue: netQueue)
    }

    func reconnectInput(_ gen: Int) {
        guard gen == inputGen else { return }
        inputGen += 1
        inputReady = false
        inputConn?.cancel()
        netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectInput() }
    }

    func send(_ line: String) {
        if line.hasPrefix("M ") { DispatchQueue.main.async { [weak self] in self?.overlay.hide() } }
        netQueue.async { [weak self] in
            guard let self = self, self.inputReady, let c = self.inputConn else { return }
            c.send(content: (line + "\n").data(using: .utf8), completion: .contentProcessed({ _ in }))
        }
    }

    // MARK: H.264 parsing and decoding

    func parse() {
        var starts: [(sc: Int, payload: Int)] = []
        var i = 0
        let n = bytes.count
        while i + 3 <= n {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let sc = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((sc, i + 3))
                i += 3
            } else { i += 1 }
        }
        guard starts.count >= 2 else { return }
        for k in 0..<(starts.count - 1) {
            handle(Array(bytes[starts[k].payload..<starts[k + 1].sc]))
        }
        bytes.removeSubrange(0..<starts[starts.count - 1].sc)
    }

    func handle(_ nal: [UInt8]) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: sps = Data(nal)
        case 8:
            let d = Data(nal)
            if pps != d || format == nil { pps = d; makeFormat() }
        case 1, 5: decode(nal)
        default: break
        }
    }

    func makeFormat() {
        guard let sps = sps, let pps = pps else { return }
        var fd: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { sp in
            pps.withUnsafeBytes { pp in
                let ptrs: [UnsafePointer<UInt8>] = [
                    sp.bindMemory(to: UInt8.self).baseAddress!,
                    pp.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        if status == noErr, let fd = fd {
            format = fd
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            DispatchQueue.main.async {
                self.inputView.videoSize = CGSize(width: Int(d.width), height: Int(d.height))
            }
            print("format ready", d.width, d.height)
        }
    }

    func decode(_ nal: [UInt8]) {
        guard let format = format else { return }
        let len = UInt32(nal.count)
        var avcc: [UInt8] = [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        avcc += nal

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                flags: 0, blockBufferOut: &block) == noErr, let block = block else { return }
        guard CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: avcc.count) == noErr else { return }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample = sample else { return }

        if let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async {
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            self.displayLayer.enqueue(sample)
        }
    }
}

let host: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let app = NSApplication.shared
let viewer = Viewer(host: host)
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
