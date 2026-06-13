// HomeViewController.swift — connect screen (landscape)

import UIKit

class HomeViewController: UIViewController {

    private let grad = CAGradientLayer()

    // SF Symbol drone icon
    private let droneIcon: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let iv = UIImageView(image: UIImage(systemName: "drone.fill", withConfiguration: cfg))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLbl: UILabel = {
        let l = UILabel()
        l.text = "BCI Drone"
        l.font = .systemFont(ofSize: 36, weight: .thin)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // "Upside Down Labs" badge below BCI Drone
    private let brandLbl: UILabel = {
        let l = UILabel()
        l.text = "Upside Down Labs"
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = UIColor.black
        l.textAlignment = .center
        l.backgroundColor = UIColor.white.withAlphaComponent(0.90)
        l.layer.cornerRadius = 8
        l.layer.borderWidth = 1.0
        l.layer.borderColor = UIColor.black.withAlphaComponent(0.30).cgColor
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Tello instructions label (attributed text set in setupUI)
    private let telloInstructionLbl: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // NPG instructions label (attributed text set in setupUI)
    private let npgInstructionLbl: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let startBtn: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("START FLYING", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(red: 0.0, green: 0.6, blue: 0.3, alpha: 1)
        b.layer.cornerRadius = 28
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let wifiBtn: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Open WiFi Settings →", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.setTitleColor(UIColor(red: 0.4, green: 0.75, blue: 1, alpha: 1), for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGradient()
        setupUI()
        animateDrone()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grad.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        grad.frame = UIScreen.main.bounds
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Setup

    private func setupGradient() {
        grad.colors = [
            UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1).cgColor,
            UIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1).cgColor
        ]
        view.layer.insertSublayer(grad, at: 0)
        view.insetsLayoutMarginsFromSafeArea = false
    }

    /// Builds an attributed string with a large bold header and regular-weight steps below.
    private func makeInstructionText(header: String, steps: String) -> NSAttributedString {
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.90)
        ]
        let stepsAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.65)
        ]
        let result = NSMutableAttributedString(string: header + "\n", attributes: headerAttributes)
        result.append(NSAttributedString(string: steps, attributes: stepsAttributes))
        return result
    }

    private func setupUI() {
        // Apply attributed text to instruction labels
        telloInstructionLbl.attributedText = makeInstructionText(
            header: "Tello Setup",
            steps: "1. Power on your Tello drone\n2. Connect iPhone to TELLO\n     -XXXXXX WiFi\n3. Tap Start Flying"
        )

        npgInstructionLbl.attributedText = makeInstructionText(
            header: "NPG Lite Setup",
            steps: "1. Flash the correct firmware\n2. Turn on your NPG device\n3. Wait for BLE connection"
        )

        // ── Left column: drone icon + BCI Drone title + Upside Down Labs badge ──
        let logoStack = UIStackView(arrangedSubviews: [droneIcon, titleLbl, brandLbl])
        logoStack.axis = .vertical
        logoStack.spacing = 8
        logoStack.alignment = .center
        logoStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Instructions: Tello and NPG stacked vertically ──
        let instructionsRow = UIStackView(arrangedSubviews: [telloInstructionLbl, npgInstructionLbl])
        instructionsRow.axis = .vertical
        instructionsRow.spacing = 16
        instructionsRow.alignment = .center
        instructionsRow.distribution = .fillEqually
        instructionsRow.translatesAutoresizingMaskIntoConstraints = false

        // ── Right column: logo + buttons ──
        let rightStack = UIStackView(arrangedSubviews: [logoStack, startBtn, wifiBtn])
        rightStack.axis = .vertical
        rightStack.spacing = 16
        rightStack.alignment = .center
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Outer horizontal stack ──
        let hStack = UIStackView(arrangedSubviews: [instructionsRow, rightStack])
        hStack.axis = .horizontal
        hStack.distribution = .fillEqually
        hStack.alignment = .center
        hStack.spacing = 0
        hStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hStack)

        let safeArea = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: safeArea.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            hStack.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),

            brandLbl.widthAnchor.constraint(equalToConstant: 160),
            brandLbl.heightAnchor.constraint(equalToConstant: 26),

            startBtn.widthAnchor.constraint(equalToConstant: 180),
            startBtn.heightAnchor.constraint(equalToConstant: 52),

            telloInstructionLbl.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            npgInstructionLbl.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        startBtn.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        wifiBtn.addTarget(self,  action: #selector(wifiTapped),  for: .touchUpInside)
    }

    // MARK: - Animation

    private func animateDrone() {
        UIView.animate(withDuration: 1.8, delay: 0,
                       options: [.autoreverse, .repeat, .curveEaseInOut]) {
            self.droneIcon.transform = CGAffineTransform(translationX: 0, y: -10)
        }
    }

    // MARK: - Actions

    @objc private func startTapped() {
        let vc = FlightViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle   = .crossDissolve
        present(vc, animated: true)
    }

    @objc private func wifiTapped() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
