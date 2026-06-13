// FlightViewController.swift
// SF Symbols throughout — buttons, HUD icons, joystick direction icons

import UIKit
import AVFoundation

// MARK: - Control Mode
enum ControlMode {
    case npg
    case manual

    var sfSymbol: String {
        switch self {
        case .npg:    return "brain.head.profile"
        case .manual: return "gamecontroller.fill"
        }
    }
}

// MARK: - Height Limit
enum HeightLimit {
    case cm100
    case cm180
    case unlimited

    /// Limit in cm, nil means no limit
    var centimeters: Int? {
        switch self {
        case .cm100:     return 100-10
        case .cm180:     return 180-10
        case .unlimited: return nil
        }
    }

    var label: String {
        switch self {
        case .cm100:      return "100cm"
        case .cm180:      return "180cm"
        case .unlimited:  return "∞"
        }
    }

    /// Cycles to next option
    var next: HeightLimit {
        switch self {
        case .cm100:      return .cm180
        case .cm180:      return .unlimited
        case .unlimited:  return .cm100
        }
    }
}

class FlightViewController: UIViewController {

    private var isFlying = false
    private var currentDroneHeight: Int = 0  // tracked from TelloState (cm)

    private var heightLimit: HeightLimit = .unlimited {
        didSet { updateHeightLimitUI() }
    }

    /// Returns true when drone height is at or above the active limit
    private var isAtHeightLimit: Bool {
        guard let limit = heightLimit.centimeters else { return false }
        return currentDroneHeight >= limit
    }

    private var controlMode: ControlMode = .manual {
        didSet { updateControlModeUI() }
    }

    private let videoLayer = VideoStreamService.shared.displayLayer

    // MARK: - HUD
    private let batteryIcon  = SFHUDView(symbol: "battery.75",        text: "--%")
    private let heightIcon   = SFHUDView(symbol: "arrow.up.and.down", text: "0cm")
    private let speedIcon    = SFHUDView(symbol: "speedometer",        text: "0.0")
    private let wifiIcon     = SFHUDView(symbol: "wifi.slash",         text: "—")
    private let npgIcon      = SFHUDView(symbol: "brain.head.profile", text: "—")
    private let npgModePill  = NPGModePillView()   // V / R / H / F pill

    // Command flash
    private let npgCmdFlashLbl: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        l.layer.cornerRadius = 10
        l.layer.borderWidth = 0.5
        l.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        l.clipsToBounds = true
        l.textAlignment = .center
        l.alpha = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - Buttons
    private let takeoffBtn      = SFCircleButton(symbol: "arrow.up.circle.fill", size: 22)
    private let emergencyBtn    = SFCircleButton(text: "STOP", textSize: 13, background: .systemRed)
    private let controlModeBtn  = SFCircleButton(symbol: "gamecontroller.fill",  size: 10)
    private let heightLimitBtn  = SFCircleButton(symbol: "infinity",             size: 14)

    // Joysticks
    private let leftJoy  = JoystickView()
    private let rightJoy = JoystickView()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupHUD()
        setupButtons()
        setupJoysticks()

        TelloSDK.shared.delegate = self
        TelloSDK.shared.connect()
        wifiIcon.setText("…")

        NPGBLEManager.shared.delegate = self
        NPGBLEManager.shared.isCommandsEnabled = false  // starts in manual mode
        NPGBLEManager.shared.startScanning()

        updateControlModeUI()
        updateHeightLimitUI()
        updateEmergencyBtnUI()  // starts disabled until Tello connects
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        TelloSDK.shared.stopRC()
        TelloSDK.shared.disconnect()
        VideoStreamService.shared.stop()
        NPGBLEManager.shared.disconnect()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: - Video
    private func setupVideo() {
        videoLayer.frame = view.bounds
        view.layer.addSublayer(videoLayer)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = view.bounds
    }

    // MARK: - HUD setup
    private func setupHUD() {
        let topStack = UIStackView(arrangedSubviews: [
            npgIcon, npgModePill, batteryIcon, speedIcon, heightIcon, wifiIcon
        ])
        topStack.axis      = .horizontal
        topStack.spacing   = 6
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            topStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        // Command flash — center screen
        view.addSubview(npgCmdFlashLbl)
        NSLayoutConstraint.activate([
            npgCmdFlashLbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            npgCmdFlashLbl.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            npgCmdFlashLbl.widthAnchor.constraint(equalToConstant: 240),
            npgCmdFlashLbl.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Upside Down Labs branding — centered at bottom
        let brandLbl = UILabel()
        brandLbl.text = "Upside Down Labs"
        brandLbl.font = .systemFont(ofSize: 13, weight: .semibold)
        brandLbl.textColor = UIColor.white.withAlphaComponent(0.55)
        brandLbl.textAlignment = .center
        brandLbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(brandLbl)
        NSLayoutConstraint.activate([
            brandLbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            brandLbl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Buttons setup
    private func setupButtons() {
        [takeoffBtn, emergencyBtn, controlModeBtn, heightLimitBtn].forEach { view.addSubview($0) }
        NSLayoutConstraint.activate([
            // Takeoff — top-left
            takeoffBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            takeoffBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            takeoffBtn.widthAnchor.constraint(equalToConstant: 48),
            takeoffBtn.heightAnchor.constraint(equalToConstant: 48),

            // Emergency — top-right
            emergencyBtn.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            emergencyBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            emergencyBtn.widthAnchor.constraint(equalToConstant: 48),
            emergencyBtn.heightAnchor.constraint(equalToConstant: 48),

            // Control Mode — left of emergency
            controlModeBtn.trailingAnchor.constraint(equalTo: emergencyBtn.leadingAnchor, constant: -10),
            controlModeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            controlModeBtn.widthAnchor.constraint(equalToConstant: 48),
            controlModeBtn.heightAnchor.constraint(equalToConstant: 48),

            // Height Limit — left of control mode
            heightLimitBtn.trailingAnchor.constraint(equalTo: controlModeBtn.leadingAnchor, constant: -10),
            heightLimitBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            heightLimitBtn.widthAnchor.constraint(equalToConstant: 48),
            heightLimitBtn.heightAnchor.constraint(equalToConstant: 48),
        ])
        takeoffBtn.addTarget(self,      action: #selector(takeoffTapped),      for: .touchUpInside)
        emergencyBtn.addTarget(self,    action: #selector(emergencyTapped),    for: .touchUpInside)
        controlModeBtn.addTarget(self,  action: #selector(controlModeTapped),  for: .touchUpInside)
        heightLimitBtn.addTarget(self,  action: #selector(heightLimitTapped),  for: .touchUpInside)
    }

    // MARK: - Joysticks setup
    private func setupJoysticks() {
        [leftJoy, rightJoy].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            leftJoy.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 50),
            leftJoy.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            leftJoy.widthAnchor.constraint(equalToConstant: 200),
            leftJoy.heightAnchor.constraint(equalToConstant: 200),

            rightJoy.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -50),
            rightJoy.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            rightJoy.widthAnchor.constraint(equalToConstant: 200),
            rightJoy.heightAnchor.constraint(equalToConstant: 200),
        ])

        // Left joy: Altitude (up/down) + Yaw (left/right)
        leftJoy.topSymbol    = "chevron.up.2"
        leftJoy.bottomSymbol = "chevron.down.2"
        leftJoy.leftSymbol   = "gobackward"
        leftJoy.rightSymbol  = "goforward"
        leftJoy.topText      = "UP"
        leftJoy.bottomText   = "DOWN"
        leftJoy.leftText     = "YAW L"
        leftJoy.rightText    = "YAW R"

        // Right joy: Forward/Back + Left/Right
        rightJoy.topSymbol    = "chevron.up.2"
        rightJoy.bottomSymbol = "chevron.down.2"
        rightJoy.leftSymbol   = "chevron.left.2"
        rightJoy.rightSymbol  = "chevron.right.2"
        rightJoy.topText      = "FWD"
        rightJoy.bottomText   = "BACK"
        rightJoy.leftText     = "LEFT"
        rightJoy.rightText    = "RIGHT"

        leftJoy.onValueChanged = { [weak self] x, y in
            guard self?.controlMode == .manual else { return }
            // Block upward movement when at height limit
            let ud = Int(-y * 50)
            if ud > 0 && self?.isAtHeightLimit == true {
                TelloSDK.shared.rcUD = 0
            } else {
                TelloSDK.shared.rcUD = ud
            }
            TelloSDK.shared.rcYaw = Int(x * 100)
        }
        rightJoy.onValueChanged = { [weak self] x, y in
            guard self?.controlMode == .manual else { return }
            TelloSDK.shared.rcFB = Int(-y * 100)
            TelloSDK.shared.rcLR = Int( x * 100)
        }
    }

    // MARK: - Control Mode Toggle
    @objc private func controlModeTapped() {
        controlMode = (controlMode == .manual) ? .npg : .manual
        if controlMode == .manual {
            TelloSDK.shared.rcUD = 0; TelloSDK.shared.rcYaw = 0
            TelloSDK.shared.rcFB = 0; TelloSDK.shared.rcLR  = 0
        }
        UIView.animate(withDuration: 0.1, animations: {
            self.controlModeBtn.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }) { _ in UIView.animate(withDuration: 0.12) { self.controlModeBtn.transform = .identity } }

        toast(controlMode == .npg ? "NPG Mode — NPG Lite controls drone" : "Manual Mode — Joystick controls drone")
    }

    // MARK: - Height Limit Toggle
    @objc private func heightLimitTapped() {
        heightLimit = heightLimit.next

        UIView.animate(withDuration: 0.1, animations: {
            self.heightLimitBtn.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }) { _ in UIView.animate(withDuration: 0.12) { self.heightLimitBtn.transform = .identity } }

        let msg: String
        switch heightLimit {
        case .cm100:      msg = "Height limit: 100 cm"
        case .cm180:      msg = "Height limit: 180 cm"
        case .unlimited:  msg = "Height limit: None"
        }
        toast(msg)
    }

    private func updateControlModeUI() {
        NPGBLEManager.shared.isCommandsEnabled = (controlMode == .npg)

        controlModeBtn.setSymbol(controlMode.sfSymbol, size: 10)
        controlModeBtn.setSymbol(controlMode.sfSymbol)
        let joyAlpha: CGFloat = controlMode == .npg ? 0.3 : 1.0
        UIView.animate(withDuration: 0.25) {
            self.leftJoy.alpha  = joyAlpha
            self.rightJoy.alpha = joyAlpha
        }
    }

    private func updateHeightLimitUI() {
        // Show text labels for limited states, SF Symbol for unlimited
        switch heightLimit {
        case .cm100:
            heightLimitBtn.setText("100cm", size: 11)
        case .cm180:
            heightLimitBtn.setText("180cm", size: 11)
        case .unlimited:
            heightLimitBtn.setSymbol("infinity", size: 14)
        }

        // Tint button orange when a limit is active, white when unlimited
        let isLimited = heightLimit != .unlimited
        heightLimitBtn.tintColor = isLimited ? UIColor.systemRed : .white
        heightLimitBtn.layer.borderColor = isLimited
            ? UIColor.systemRed.withAlphaComponent(0.75).cgColor
            : UIColor.white.withAlphaComponent(0.75).cgColor
    }

    // MARK: - Emergency Button UI
    /// Enables or disables the emergency button based on Tello connection state.
    private func updateEmergencyBtnUI() {
        let connected = TelloSDK.shared.isConnected
        emergencyBtn.isEnabled = connected
        UIView.animate(withDuration: 0.2) {
            self.emergencyBtn.alpha = connected ? 1.0 : 0.65
        }
    }

    // MARK: - Flying state
    private func setFlyingState(_ flying: Bool) {
        isFlying = flying
        takeoffBtn.setSymbol(flying ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
    }

    // MARK: - Takeoff guard
    /// Returns true if height > 8cm, meaning drone is already airborne — ignore takeoff.
    private var isDroneAlreadyAirborne: Bool {
        currentDroneHeight > 8
    }

    // MARK: - Button Actions
    @objc private func takeoffTapped() {
        guard TelloSDK.shared.isConnected else { toast("Not connected to Tello"); return }
        if !isFlying {
            guard !isDroneAlreadyAirborne else { return }  // silently ignore, no toast
            setFlyingState(true)
            TelloSDK.shared.takeoff()
            TelloSDK.shared.startRC()
        } else {
            TelloSDK.shared.stopRC()
            TelloSDK.shared.land()
            setFlyingState(false)
        }
    }

    @objc private func emergencyTapped() {
        guard TelloSDK.shared.isConnected else { toast("Not connected to Tello"); return }
        TelloSDK.shared.stopRC()
        TelloSDK.shared.emergency()
        setFlyingState(false)
        toast("Emergency stop!")
    }

    // MARK: - Height Limit Enforcement
    /// Call whenever a new drone height arrives. Clamps upward movement if limit reached.
    private func enforceHeightLimit() {
        guard let limit = heightLimit.centimeters else { return }
        guard currentDroneHeight >= limit else { return }

        // If drone is moving up, zero out the upward RC channel
        if TelloSDK.shared.rcUD > 0 {
            TelloSDK.shared.rcUD = 0
            TelloSDK.shared.sendCommand("rc \(TelloSDK.shared.rcLR) \(TelloSDK.shared.rcFB) 0 \(TelloSDK.shared.rcYaw)")
        }
    }

    // MARK: - NPG Command Flash + Joystick Animation
    private func flashNPGCommand(_ cmd: String) {
        let label: String
        switch cmd {
        case "t":
            label = "TAKEOFF"
        case "l":
            label = "LAND"
        case "fd":
            label = "FORWARD"
            rightJoy.animateInput(x: 0, y: -1)
        case "bd":
            label = "BACK"
            rightJoy.animateInput(x: 0, y: 1)
        case "u":
            label = "UP"
            leftJoy.animateInput(x: 0, y: -1)
        case "d":
            label = "DOWN"
            leftJoy.animateInput(x: 0, y: 1)
        case "R":
            label = "ROTATE"
            leftJoy.animateInput(x: 1, y: 0)
        case "b":
            label = "SPIN 360"
            leftJoy.animateInput(x: 1, y: 0, duration: 1.0)
        case "mode:V": label = "→ Vertical"
        case "mode:R": label = "→ Rotation"
        case "mode:H": label = "HOLD ON"
        case "mode:F": label = "FLY Resumed"
        default:       label = cmd
        }

        let symName: String
        switch cmd {
        case "t":      symName = "arrow.up.circle"
        case "l":      symName = "arrow.down.circle"
        case "fd":     symName = "arrow.up.to.line"
        case "bd":     symName = "arrow.down.to.line"
        case "u":      symName = "arrow.up"
        case "d":      symName = "arrow.down"
        case "R","b":  symName = "arrow.clockwise"
        case "mode:H": symName = "pause.circle"
        case "mode:F": symName = "play.circle"
        default:       symName = "bolt.fill"
        }

        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = UIImage(systemName: symName, withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment()
        attachment.image = img
        let attrStr = NSMutableAttributedString(attachment: attachment)
        attrStr.append(NSAttributedString(string: "  \(label)"))

        npgCmdFlashLbl.attributedText = attrStr
        npgCmdFlashLbl.alpha = 1
        UIView.animate(withDuration: 0.2, delay: 1.2, options: []) { self.npgCmdFlashLbl.alpha = 0 }
    }

    // MARK: - Toast
    private var activeToast: UILabel?

    private func toast(_ msg: String) {
        // Remove previous toast immediately before showing new one
        activeToast?.layer.removeAllAnimations()
        activeToast?.removeFromSuperview()
        activeToast = nil

        let l = UILabel()
        l.text = msg
        l.textColor = .white
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.backgroundColor = UIColor.gray.withAlphaComponent(0.4)
        l.layer.borderWidth = 0.5
        l.layer.borderColor = UIColor.gray.withAlphaComponent(0.5).cgColor
        l.textAlignment = .center
        l.layer.cornerRadius = 10
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50),
            l.widthAnchor.constraint(equalToConstant: 320),
            l.heightAnchor.constraint(equalToConstant: 36),
        ])
        activeToast = l
        UIView.animate(withDuration: 0.2, delay: 2.5, options: []) { l.alpha = 0 } completion: { _ in
            l.removeFromSuperview()
            if self.activeToast === l { self.activeToast = nil }
        }
    }
}

// MARK: - TelloSDK Delegate
extension FlightViewController: TelloSDKDelegate {
    func telloDidConnect() {
        wifiIcon.setSymbol("wifi"); wifiIcon.setText("ON")
        toast("Tello connected!")
        VideoStreamService.shared.stop(); VideoStreamService.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { TelloSDK.shared.streamon() }
        updateEmergencyBtnUI()  // enable emergency button on connect
    }
    func telloDidDisconnect() {
        wifiIcon.setSymbol("wifi.slash"); wifiIcon.setText("—")
        setFlyingState(false); TelloSDK.shared.stopRC()
        VideoStreamService.shared.stop()
        toast("Drone disconnected — reconnecting…")
        updateEmergencyBtnUI()  // disable emergency button on disconnect
    }
    func telloDidReceiveState(_ state: TelloState) {
        currentDroneHeight = state.h  // cm

        // Enforce height limit on every state update — covers both manual & NPG
        enforceHeightLimit()

        let bat = state.bat
        let batSym = bat > 75 ? "battery.100" : bat > 50 ? "battery.75" : bat > 25 ? "battery.50" : bat > 10 ? "battery.25" : "battery.0"
        batteryIcon.setSymbol(batSym)
        batteryIcon.setText("\(bat)%")
        heightLbl(state)
        speedLbl(state)
    }
    private func heightLbl(_ s: TelloState) { heightIcon.setText("\(s.h)cm") }
    private func speedLbl(_ s: TelloState)  { speedIcon.setText("\(abs(s.vgx)+abs(s.vgy)+abs(s.vgz))") }

    func telloDidReceiveResponse(_ response: String) {}
    func telloDidFailWithError(_ error: String) { wifiIcon.setSymbol("wifi.exclamationmark"); wifiIcon.setText("ERR") }
}

// MARK: - NPGBLEDelegate
extension FlightViewController: NPGBLEDelegate {
    func npgDidConnect(deviceName: String) {
        npgIcon.setSymbol("brain.head.profile"); npgIcon.setText("ON")
        toast("NPG Lite connected!")
    }
    func npgDidDisconnect() {
        npgIcon.setSymbol("brain.head.profile"); npgIcon.setText("—")
        toast("NPG Lite disconnected — rescanning…")
    }
    func npgDidReceiveCommand(_ cmd: String) {
        guard cmd != "__ignored__" else { return }

        switch cmd {
        case "t":
            // Check before flashing — don't show TAKEOFF if already airborne or flying
            guard !isFlying && !isDroneAlreadyAirborne else { return }
            flashNPGCommand(cmd)
            setFlyingState(true)
            TelloSDK.shared.startRC()

        case "u":
            // Block NPG upward command when at height limit
            guard !isAtHeightLimit else { return }
            flashNPGCommand(cmd)

        case "l":
            flashNPGCommand(cmd)
            if isFlying {
                TelloSDK.shared.stopRC()
                TelloSDK.shared.resetRC()
                setFlyingState(false)
            }

        default:
            flashNPGCommand(cmd)
        }
    }
    func npgModeChanged(_ mode: NPGMode) {
        let code: String
        switch mode.displayText {
        case let t where t.contains("Vertical"):  code = "V"
        case let t where t.contains("Rotation"):  code = "R"
        case let t where t.contains("Hold"):      code = "H"
        case let t where t.contains("Fly"):       code = "F"
        default: code = "?"
        }
        npgModePill.setMode(code)
    }
    func npgStatusChanged(_ status: String) {
        if status.contains("✅") || (status.contains("connected") && !status.contains("dis")) {
            npgIcon.setText("ON")
        } else {
            npgIcon.setText("—")
        }
    }
}

// MARK: - SFHUDView
/// Small pill: SF symbol icon + text label side by side
final class SFHUDView: UIView {
    private let iconView = UIImageView()
    private let textLbl  = UILabel()

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.gray.withAlphaComponent(0.4)
        layer.cornerRadius = 6; clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        textLbl.text = text
        textLbl.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        textLbl.textColor = .white
        textLbl.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, textLbl])
        stack.axis = .horizontal; stack.spacing = 4; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ t: String)   { textLbl.text = t }
    func setSymbol(_ s: String) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = UIImage(systemName: s, withConfiguration: cfg)
    }
}

// MARK: - NPGModePillView
/// Compact mode pill showing V / R / H / F with a dot indicator
final class NPGModePillView: UIView {
    private let lbl = UILabel()

    override init(frame: CGRect) {
        super.init(frame: .zero)
        backgroundColor = UIColor.gray.withAlphaComponent(0.4)
        layer.cornerRadius = 6
        layer.borderWidth  = 0.5
        layer.borderColor  = UIColor.gray.withAlphaComponent(0.5).cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        lbl.text = "--"
        lbl.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        lbl.textColor = .white
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            lbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setMode(_ code: String) {
        lbl.text = code
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 1.12, y: 1.12) }) { _ in
            UIView.animate(withDuration: 0.12) { self.transform = .identity }
        }
    }
}

// MARK: - SFCircleButton
/// Round bordered button with an SF Symbol icon or text label
final class SFCircleButton: UIButton {
    private var currentSymbol: String = ""

    convenience init(symbol: String, size: CGFloat) {
        self.init(type: .system)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.gray.withAlphaComponent(0.4)
        tintColor = .white
        layer.cornerRadius = 24
        layer.borderWidth  = 1.5
        layer.borderColor  = UIColor.white.withAlphaComponent(0.75).cgColor
        setSymbol(symbol, size: size)
    }

    /// Solid-background text button (e.g. emergency STOP)
    convenience init(text: String, textSize: CGFloat, background: UIColor) {
        self.init(type: .system)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = background
        tintColor = .white
        layer.cornerRadius = 24
        layer.borderWidth  = 0
        setText(text, size: textSize)
    }

    func setSymbol(_ symbol: String, size: CGFloat = 20) {
        currentSymbol = symbol
        setTitle(nil, for: .normal)
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        setPreferredSymbolConfiguration(cfg, forImageIn: .normal)
        setImage(UIImage(systemName: symbol), for: .normal)
    }

    func setText(_ text: String, size: CGFloat = 13) {
        setImage(nil, for: .normal)
        setTitle(text, for: .normal)
        titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
    }
}
