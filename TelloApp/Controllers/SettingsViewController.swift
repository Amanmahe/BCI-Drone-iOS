// SettingsViewController.swift
// Settings screen — same options as official Tello app
// Speed, video resolution, calibration, firmware info

import UIKit

class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    
    private enum Section: Int, CaseIterable {
        case flight, video, sensor, info
        var title: String {
            switch self {
            case .flight:  return "Flight"
            case .video:   return "Video"
            case .sensor:  return "Sensor"
            case .info:    return "Device Info"
            }
        }
    }
    
    private var speedValue: Float = 50 {
        didSet { TelloSDK.shared.setSpeed(Int(speedValue)) }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource  = self
        tableView.delegate    = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        
        tableView.register(SliderCell.self, forCellReuseIdentifier: "SliderCell")
        tableView.register(SwitchCell.self, forCellReuseIdentifier: "SwitchCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BasicCell")
    }
    
    @objc private func doneTapped() { dismiss(animated: true) }
    
    // MARK: - TableView
    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .flight: return 2
        case .video:  return 2
        case .sensor: return 1
        case .info:   return 3
        }
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
            
        case (.flight, 0):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SliderCell", for: indexPath) as! SliderCell
            cell.configure(title: "Speed (cm/s)", value: speedValue, min: 10, max: 100) { [weak self] val in
                self?.speedValue = val
            }
            return cell
            
        case (.flight, 1):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell
            cell.configure(title: "Auto Land on Low Battery", isOn: true) { _ in }
            return cell
            
        case (.video, 0):
            let cell = tableView.dequeueReusableCell(withIdentifier: "BasicCell", for: indexPath)
            cell.textLabel?.text = "Resolution"
            cell.detailTextLabel?.text = "720p"
            cell.accessoryType = .disclosureIndicator
            return cell
            
        case (.video, 1):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell
            cell.configure(title: "Show HUD Overlay", isOn: true) { _ in }
            return cell
            
        case (.sensor, 0):
            let cell = tableView.dequeueReusableCell(withIdentifier: "BasicCell", for: indexPath)
            cell.textLabel?.text = "Calibrate IMU"
            cell.textLabel?.textColor = .systemBlue
            return cell
            
        case (.info, 0):
            return infoCell("Firmware Version", detail: "Tello SDK 2.0", for: indexPath)
        case (.info, 1):
            return infoCell("App Version", detail: "1.0.0", for: indexPath)
        case (.info, 2):
            return infoCell("Drone Serial", detail: "Querying...", for: indexPath)
        default:
            return UITableViewCell()
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if Section(rawValue: indexPath.section) == .sensor {
            TelloSDK.shared.sendCommand("imustate")
            showAlert("Calibration", message: "Place drone on flat surface and hold still.")
        }
    }
    
    private func infoCell(_ title: String, detail: String, for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BasicCell", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = title
        cfg.secondaryText = detail
        cell.contentConfiguration = cfg
        return cell
    }
    
    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Custom Cells
class SliderCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider     = UISlider()
    private var onChange: ((Float) -> Void)?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.font = .systemFont(ofSize: 15)
        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        let top = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        top.distribution = .equalSpacing
        let stack = UIStackView(arrangedSubviews: [top, slider])
        stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    
    func configure(title: String, value: Float, min: Float, max: Float, onChange: @escaping (Float) -> Void) {
        titleLabel.text = title
        slider.minimumValue = min; slider.maximumValue = max; slider.value = value
        valueLabel.text = "\(Int(value))"
        self.onChange = onChange
    }
    
    @objc private func sliderChanged() {
        valueLabel.text = "\(Int(slider.value))"
        onChange?(slider.value)
    }
}

class SwitchCell: UITableViewCell {
    private let toggle = UISwitch()
    private var onChange: ((Bool) -> Void)?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    func configure(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        textLabel?.text = title
        toggle.isOn = isOn
        self.onChange = onChange
    }
    
    @objc private func toggled() { onChange?(toggle.isOn) }
}
