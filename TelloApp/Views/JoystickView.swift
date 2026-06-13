// JoystickView.swift — virtual joystick, spring-return, multi-touch safe
// Styled to match DJI-style dark joystick with arrow indicators inside the ring

import UIKit

class JoystickView: UIView {

    var onValueChanged: ((CGFloat, CGFloat) -> Void)?
    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0

    // MARK: - Base ring (outer dark circle)
    private let baseRing: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        v.layer.borderWidth = 1.5
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Thumb (inner solid gray knob — logo centered inside)
    private let thumb: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.9, alpha: 1.0)
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        v.layer.borderWidth = 1.5
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Logo image inside thumb
    private let thumbLogoView: UIImageView = {
        let iv = UIImageView()
        // Load the BCI Drone / UpsideDownLabs logo from the asset catalog
        if let img = UIImage(named: "BCILogo") {
            iv.image = img
        }
        iv.contentMode = .scaleAspectFit
        iv.tintColor = UIColor.white.withAlphaComponent(0.90)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    // MARK: - Arrow image views (inside ring)
    private let topArrow    = JoystickView.makeArrow(symbol: "chevron.up.2")
    private let bottomArrow = JoystickView.makeArrow(symbol: "chevron.down.2")
    private let leftArrow   = JoystickView.makeArrow(symbol: "chevron.left.2")
    private let rightArrow  = JoystickView.makeArrow(symbol: "chevron.right.2")

    // Public symbol setters — actually applied to arrow image views
    var topSymbol:    String = "chevron.up.2"    { didSet { applyArrow(topSymbol,    to: topArrow)    } }
    var bottomSymbol: String = "chevron.down.2"  { didSet { applyArrow(bottomSymbol, to: bottomArrow) } }
    var leftSymbol:   String = "chevron.left.2"  { didSet { applyArrow(leftSymbol,   to: leftArrow)   } }
    var rightSymbol:  String = "chevron.right.2" { didSet { applyArrow(rightSymbol,  to: rightArrow)  } }

    // Text labels — hidden in this style
    var topText:    String = "" { didSet { } }
    var bottomText: String = "" { didSet { } }
    var leftText:   String = "" { didSet { } }
    var rightText:  String = "" { didSet { } }

    private var thumbX: NSLayoutConstraint!
    private var thumbY: NSLayoutConstraint!
    private let thumbR: CGFloat = 28

    private var npgAnimTimer: Timer?

    override init(frame: CGRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private static func makeArrow(symbol: String) -> UIImageView {
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let iv = UIImageView()
        iv.image = UIImage(systemName: symbol, withConfiguration: cfg)
        iv.tintColor = UIColor.white.withAlphaComponent(0.75)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }

    private func applyArrow(_ name: String, to iv: UIImageView) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iv.image = UIImage(systemName: name, withConfiguration: cfg)
    }

    private func build() {
        backgroundColor = .clear

        // Base ring fills entire view
        addSubview(baseRing)
        NSLayoutConstraint.activate([
            baseRing.topAnchor.constraint(equalTo: topAnchor),
            baseRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            baseRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            baseRing.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Arrows inside ring
        [topArrow, bottomArrow, leftArrow, rightArrow].forEach { baseRing.addSubview($0) }

        // Thumb inside ring
        baseRing.addSubview(thumb)

        // Logo centered inside thumb
        thumb.addSubview(thumbLogoView)
        NSLayoutConstraint.activate([
            thumbLogoView.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            thumbLogoView.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            thumbLogoView.widthAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 0.72),
            thumbLogoView.heightAnchor.constraint(equalTo: thumb.heightAnchor, multiplier: 0.72),
        ])

        thumbX = thumb.centerXAnchor.constraint(equalTo: baseRing.centerXAnchor)
        thumbY = thumb.centerYAnchor.constraint(equalTo: baseRing.centerYAnchor)

        let arrowInset: CGFloat = 14

        NSLayoutConstraint.activate([
            thumbX, thumbY,
            thumb.widthAnchor.constraint(equalToConstant: thumbR * 2),
            thumb.heightAnchor.constraint(equalToConstant: thumbR * 2),

            // Top arrow
            topArrow.centerXAnchor.constraint(equalTo: baseRing.centerXAnchor),
            topArrow.topAnchor.constraint(equalTo: baseRing.topAnchor, constant: arrowInset),
            topArrow.widthAnchor.constraint(equalToConstant: 20),
            topArrow.heightAnchor.constraint(equalToConstant: 20),

            // Bottom arrow
            bottomArrow.centerXAnchor.constraint(equalTo: baseRing.centerXAnchor),
            bottomArrow.bottomAnchor.constraint(equalTo: baseRing.bottomAnchor, constant: -arrowInset),
            bottomArrow.widthAnchor.constraint(equalToConstant: 20),
            bottomArrow.heightAnchor.constraint(equalToConstant: 20),

            // Left arrow
            leftArrow.centerYAnchor.constraint(equalTo: baseRing.centerYAnchor),
            leftArrow.leadingAnchor.constraint(equalTo: baseRing.leadingAnchor, constant: arrowInset),
            leftArrow.widthAnchor.constraint(equalToConstant: 20),
            leftArrow.heightAnchor.constraint(equalToConstant: 20),

            // Right arrow
            rightArrow.centerYAnchor.constraint(equalTo: baseRing.centerYAnchor),
            rightArrow.trailingAnchor.constraint(equalTo: baseRing.trailingAnchor, constant: -arrowInset),
            rightArrow.widthAnchor.constraint(equalToConstant: 20),
            rightArrow.heightAnchor.constraint(equalToConstant: 20),
        ])

        isMultipleTouchEnabled = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        baseRing.layer.cornerRadius = baseRing.bounds.width / 2
        thumb.layer.cornerRadius    = thumbR
    }

    // MARK: - Manual pan
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let radius = baseRing.bounds.width / 2 - thumbR
        switch g.state {
        case .began, .changed:
            let loc = g.location(in: baseRing)
            let cx = baseRing.bounds.midX, cy = baseRing.bounds.midY
            var dx = loc.x - cx, dy = loc.y - cy
            let dist = sqrt(dx*dx + dy*dy)
            if dist > radius { dx = dx/dist*radius; dy = dy/dist*radius }
            thumbX.constant = dx; thumbY.constant = dy
            x = dx / radius; y = dy / radius
            UIView.animate(withDuration: 0.04) { self.baseRing.layoutIfNeeded() }
            onValueChanged?(x, y)

        case .ended, .cancelled:
            springReturn()
            onValueChanged?(0, 0)
        default: break
        }
    }

    // MARK: - NPG-driven animation
    func animateInput(x nx: CGFloat, y ny: CGFloat, duration: TimeInterval = 0.6) {
        npgAnimTimer?.invalidate()
        let radius = baseRing.bounds.width / 2 - thumbR
        guard radius > 0 else { return }
        thumbX.constant = nx * radius
        thumbY.constant = ny * radius
        UIView.animate(withDuration: 0.12, delay: 0, options: .curveEaseOut) {
            self.baseRing.layoutIfNeeded()
        }
        npgAnimTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.springReturn()
        }
    }

    private func springReturn() {
        thumbX.constant = 0; thumbY.constant = 0
        x = 0; y = 0
        UIView.animate(withDuration: 0.25, delay: 0,
                       usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0.5) {
            self.baseRing.layoutIfNeeded()
        }
    }
}
