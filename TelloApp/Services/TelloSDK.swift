// TelloSDK.swift
// v11 — fixed: conn_req retried until "ok", reconnect loop wired correctly
//
// Three bugs fixed vs v10:
//
//  1. "command" was sent once and never retried.  UDP has no delivery
//     guarantee; if the drone isn't on WiFi yet that one packet is gone.
//     Fix: re-send "command" every 3 s inside the recv loop until "ok" arrives.
//
//  2. The watchdog called teardownSockets() but nothing called scheduleReconnect()
//     afterward — the reconnect branch was simply missing from startWatchdog().
//
//  3. openSockets() guarded on `loopsRunning` which could still be true while
//     old threads were draining after teardown.  Fix: use a monotonically
//     incrementing `generation` counter; each loop checks its own generation
//     and exits cleanly without any shared boolean.

import Foundation

struct TelloState {
    var pitch=0, roll=0, yaw=0, vgx=0, vgy=0, vgz=0
    var templ=0, temph=0, tof=0, h=0, bat=0, time=0
    var baro=0.0, agx=0.0, agy=0.0, agz=0.0
}

protocol TelloSDKDelegate: AnyObject {
    func telloDidConnect()
    func telloDidDisconnect()
    func telloDidReceiveState(_ state: TelloState)
    func telloDidReceiveResponse(_ response: String)
    func telloDidFailWithError(_ error: String)
}

final class TelloSDK: NSObject {

    static let shared = TelloSDK()
    private override init() {}

    weak var delegate: TelloSDKDelegate?

    // MARK: - Network constants
    private let telloIP   = "192.168.10.1"
    private let telloPort = UInt16(8889)
    private let statePort = UInt16(8890)

    // MARK: - Sockets
    // Accessed only from their respective loops (cmd/state), except cmdSock
    // which is also written during teardown from an arbitrary thread.
    // Protected by a dedicated queue for the write + RC-read path.
    private let sockQ = DispatchQueue(label: "tello.sock")
    private var _cmdSock:   Int32 = -1
    private var _stateSock: Int32 = -1
    private var cmdSock:   Int32 { sockQ.sync { _cmdSock   } }
    private var stateSock: Int32 { sockQ.sync { _stateSock } }

    // MARK: - Generation counter (replaces loopsRunning boolean)
    // Each call to openSockets() stamps a new generation.  Loop threads capture
    // their generation at start; when teardownSockets() increments it they see
    // the mismatch and exit — no shared boolean, no race.
    private var _generation: Int = 0
    private let genQ = DispatchQueue(label: "tello.gen")
    private var generation: Int {
        get { genQ.sync { _generation } }
    }
    private func nextGeneration() -> Int {
        genQ.sync { _generation += 1; return _generation }
    }

    // MARK: - Session flag
    private var sessionActive = false

    // MARK: - Public state
    private(set) var isConnected = false

    // MARK: - RC axes
    var rcLR=0, rcFB=0, rcUD=0, rcYaw=0
    private let rcQ = DispatchQueue(label: "tello.rc", qos: .userInteractive)
    private var rcTimer: DispatchSourceTimer?
    private var rcPaused = false   // set true during throw-detection window

    // MARK: - FLIGHT_STATUS watchdog
    // Only port-8890 FLIGHT_STATUS packets reset this timestamp.
    // Timeout: 4 s  (observed gap in pcap between last FLIGHT_STATUS and
    //                first conn_req retry after drone powers off).
    private let stampQ = DispatchQueue(label: "tello.stamp")
    private var _lastStateStamp: Date = .distantPast
    private var lastStateStamp: Date {
        get { stampQ.sync { _lastStateStamp } }
        set { stampQ.sync { _lastStateStamp = newValue } }
    }
    private var watchdog: Timer?
    private let stateTimeoutSeconds: TimeInterval = 4.0

    // MARK: - Public API

    /// Begin a persistent session.  The SDK reconnects autonomously until
    /// disconnect() is called.
    func connect() {
        guard !sessionActive else { return }
        sessionActive = true
        startAlwaysOnRC()
        openSockets()
    }

    /// End the session permanently.  The SDK will not reconnect.
    func disconnect() {
        sessionActive = false
        stopWatchdog()
        teardownSockets()
        stopAlwaysOnRC()
        if isConnected {
            isConnected = false
            DispatchQueue.main.async { self.delegate?.telloDidDisconnect() }
        }
    }

    // MARK: - Internal socket lifecycle

    private func openSockets() {
        guard sessionActive else { return }
        let gen = nextGeneration()   // invalidates any running loops from prior cycles
        print("[Tello] openSockets generation=\(gen)")
        startCommandLoop(gen: gen)
        startStateLoop(gen: gen)
    }

    private func teardownSockets() {
        // Bump generation → running loops will see gen mismatch and exit
        let _ = nextGeneration()

        let c = sockQ.sync { let v = _cmdSock;   _cmdSock   = -1; return v }
        let s = sockQ.sync { let v = _stateSock; _stateSock = -1; return v }
        if c >= 0 { Darwin.close(c) }
        if s >= 0 { Darwin.close(s) }
    }

    private func scheduleReconnect() {
        guard sessionActive else { return }
        print("[Tello] Scheduling reconnect in 500 ms…")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.sessionActive else { return }
            self.openSockets()
        }
    }

    // MARK: - Command loop (port 8889)
    //
    // Sends "command" immediately, then re-sends every 3 s until "ok" arrives.
    // This is the conn_req retry the pcap shows: the real app keeps sending
    // handshakes until the drone's WiFi router comes up and replies.

    private func startCommandLoop(gen: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // ── Open socket ──────────────────────────────────────────────────
            let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else {
                print("[Tello] cmd socket() failed errno=\(errno)")
                self.scheduleReconnect()
                return
            }

            // No bind: the Tello replies to whichever ephemeral source port the
            // OS assigns. Binding to 8889 caused EADDRINUSE on every reconnect
            // because the previous generation's blocking recvfrom hadn't returned
            // yet when close() was called, keeping the port alive. SO_REUSEPORT
            // doesn't fully solve this on Darwin with an active blocking caller.
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            self.sockQ.sync { self._cmdSock = sock }

            // ── Recv loop ────────────────────────────────────────────────────
            var buf      = [UInt8](repeating: 0, count: 1024)
            var from     = sockaddr_in()
            var fromLen  = socklen_t(MemoryLayout<sockaddr_in>.size)
            var connected = false

            // Send the first handshake immediately
            self.rawSend("command", sock: sock)
            print("[Tello] gen=\(gen) → command (initial)")

            while self.generation == gen {

                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(sock, &buf, buf.count, 0, $0, &fromLen)
                    }
                }

                // Check again after blocking call — teardown may have fired
                guard self.generation == gen else { break }

                if n > 0, let text = String(bytes: buf.prefix(n), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) {

                    print("[Tello] gen=\(gen) ← '\(text)'")

                    if !connected && text == "ok" {
                        connected = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self, self.generation == gen else { return }
                            self.isConnected = true
                            self.lastStateStamp = Date()   // seed watchdog
                            self.startWatchdog()
                            self.delegate?.telloDidConnect()
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.telloDidReceiveResponse(text)
                    }

                } else if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        // 3 s timeout expired — re-send handshake if not yet connected
                        if !connected {
                            self.rawSend("command", sock: sock)
                            print("[Tello] gen=\(gen) → command (retry)")
                        }
                    } else {
                        // Real socket error (EBADF after close, etc.) — exit
                        print("[Tello] gen=\(gen) cmd recv errno=\(errno) — exiting loop")
                        break
                    }
                }
            }

            Darwin.close(sock)
            print("[Tello] gen=\(gen) command loop done")
        }
    }

    // MARK: - State loop (port 8890, FLIGHT_STATUS packets)

    private func startStateLoop(gen: Int) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else {
                print("[Tello] state socket() failed errno=\(errno)")
                return
            }

            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var sa = sockaddr_in()
            sa.sin_family      = sa_family_t(AF_INET)
            sa.sin_port        = self.statePort.bigEndian
            sa.sin_addr.s_addr = INADDR_ANY
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            self.sockQ.sync { self._stateSock = sock }

            var buf = [UInt8](repeating: 0, count: 2048)

            while self.generation == gen {
                let n = Darwin.recv(sock, &buf, buf.count, 0)

                guard self.generation == gen else { break }

                if n > 0 {
                    // FLIGHT_STATUS arrived → reset disconnect watchdog
                    self.lastStateStamp = Date()
                    if let raw = String(bytes: buf.prefix(n), encoding: .utf8) {
                        let st = self.parseState(raw)
                        DispatchQueue.main.async { [weak self] in
                            self?.delegate?.telloDidReceiveState(st)
                        }
                    }
                } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    print("[Tello] gen=\(gen) state recv errno=\(errno) — exiting loop")
                    break
                }
            }

            Darwin.close(sock)
            print("[Tello] gen=\(gen) state loop done")
        }
    }

    // MARK: - FLIGHT_STATUS watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }

            let silent = Date().timeIntervalSince(self.lastStateStamp)
            print("[Tello] Watchdog: silent \(String(format:"%.1f",silent))s / \(self.stateTimeoutSeconds)s")

            guard silent > self.stateTimeoutSeconds else { return }

            print("[Tello] ⚠️ FLIGHT_STATUS timeout — drone offline")
            self.isConnected = false
            self.watchdog?.invalidate()
            self.watchdog = nil

            self.delegate?.telloDidDisconnect()   // on main thread (Timer fires on main)

            // Tear down dead sockets, then reopen — RC heartbeat keeps running
            self.teardownSockets()
            self.scheduleReconnect()              // ← was missing in v10
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Always-on RC heartbeat

    private func startAlwaysOnRC() {
        guard rcTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: rcQ)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))   // 50 Hz
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard !self.rcPaused else { return }   // suspended during throw-detection
            self.rawSend("rc \(self.rcLR) \(self.rcFB) \(self.rcUD) \(self.rcYaw)")
        }
        t.resume()
        rcTimer = t
        print("[Tello] Always-on RC heartbeat started (50 Hz)")
    }

    private func stopAlwaysOnRC() {
        rcTimer?.cancel()
        rcTimer = nil
    }

    // MARK: - Send

    /// Send using the current cmdSock (for the RC heartbeat timer).
    @discardableResult
    func rawSend(_ cmd: String) -> Bool {
        return rawSend(cmd, sock: sockQ.sync { _cmdSock })
    }

    /// Send using an explicit socket handle (for the command loop, which holds
    /// its own local `sock` copy so it can send even during teardown races).
    @discardableResult
    private func rawSend(_ cmd: String, sock: Int32) -> Bool {
        guard sock >= 0 else { return false }
        guard let data = cmd.data(using: .utf8) else { return false }

        var remote = sockaddr_in()
        remote.sin_family      = sa_family_t(AF_INET)
        remote.sin_port        = telloPort.bigEndian
        remote.sin_addr.s_addr = telloIP.withCString { inet_addr($0) }

        let n = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(sock, ptr.baseAddress!, data.count, 0, $0,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if !cmd.hasPrefix("rc ") {
            print("[Tello] → '\(cmd)'  n=\(n) errno=\(n<0 ? errno : 0)")
        }
        return n == data.count
    }

    func sendCommand(_ cmd: String) {
        DispatchQueue.global(qos: .userInitiated).async { self.rawSend(cmd) }
    }

    // MARK: - Flight commands
    func takeoff()          { sendCommand("takeoff") }
    func land()             { sendCommand("land") }
    func emergency()        { sendCommand("emergency") }
    func streamon()         { sendCommand("streamon") }
    func streamoff()        { sendCommand("streamoff") }
    func flip(_ d: String)  { sendCommand("flip \(d)") }
    func setSpeed(_ s: Int) { sendCommand("speed \(max(10, min(100, s)))") }

    func startRC()   { rcPaused = false; print("[Tello] RC axes live") }
    func stopRC()    { resetRC() }
    func resetRC()   { rcLR=0; rcFB=0; rcUD=0; rcYaw=0 }
    func pauseRC()   { rcPaused = true;  print("[Tello] RC heartbeat paused") }
    func resumeRC()  { rcPaused = false; print("[Tello] RC heartbeat resumed") }

    // MARK: - Parse FLIGHT_STATUS
    private func parseState(_ raw: String) -> TelloState {
        var s = TelloState()
        for pair in raw.components(separatedBy: ";") {
            let kv = pair.components(separatedBy: ":")
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "pitch":  s.pitch  = Int(v)    ?? 0
            case "roll":   s.roll   = Int(v)    ?? 0
            case "yaw":    s.yaw    = Int(v)    ?? 0
            case "vgx":    s.vgx    = Int(v)    ?? 0
            case "vgy":    s.vgy    = Int(v)    ?? 0
            case "vgz":    s.vgz    = Int(v)    ?? 0
            case "templ":  s.templ  = Int(v)    ?? 0
            case "temph":  s.temph  = Int(v)    ?? 0
            case "tof":    s.tof    = Int(v)    ?? 0
            case "h":      s.h      = Int(v)    ?? 0
            case "bat":    s.bat    = Int(v)    ?? 0
            case "time":   s.time   = Int(v)    ?? 0
            case "baro":   s.baro   = Double(v) ?? 0
            case "agx":    s.agx    = Double(v) ?? 0
            case "agy":    s.agy    = Double(v) ?? 0
            case "agz":    s.agz    = Double(v) ?? 0
            default:       break
            }
        }
        return s
    }
}
