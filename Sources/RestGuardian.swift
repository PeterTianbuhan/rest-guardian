import Cocoa
import Foundation

private enum GuardianMode: String {
    case work
    case rest
}

private struct GuardianStoredSettings: Codable {
    static let hardMaxWorkMinutes = 50

    var workMinutes: Int
    var restMinutes: Int
    var maxWorkMinutes: Int

    static let defaults = GuardianStoredSettings(
        workMinutes: 25,
        restMinutes: 5,
        maxWorkMinutes: 50
    )

    var normalized: GuardianStoredSettings {
        let work = min(Self.hardMaxWorkMinutes, max(1, workMinutes))
        let rest = min(120, max(1, restMinutes))
        let maxWork = min(Self.hardMaxWorkMinutes, max(work, maxWorkMinutes))
        return GuardianStoredSettings(workMinutes: work, restMinutes: rest, maxWorkMinutes: maxWork)
    }
}

private struct GuardianConfig {
    let workMinutes: Int
    let restMinutes: Int
    let maxWorkMinutes: Int
    let workSeconds: Int
    let restSeconds: Int
    let maxWorkSeconds: Int
    let logURL: URL
    let settingsURL: URL

    static func fromArguments() -> GuardianConfig {
        let settingsURL = defaultSettingsURL()
        let storedSettings = loadStoredSettings(from: settingsURL)
        let workMinutes = argumentMinutes(named: "--work-minutes") ?? storedSettings.workMinutes
        let restMinutes = argumentMinutes(named: "--rest-minutes") ?? storedSettings.restMinutes
        let maxWorkMinutes = argumentMinutes(named: "--max-work-minutes") ?? storedSettings.maxWorkMinutes

        return GuardianConfig(
            settings: GuardianStoredSettings(
                workMinutes: workMinutes,
                restMinutes: restMinutes,
                maxWorkMinutes: maxWorkMinutes
            ),
            logURL: defaultLogURL(),
            settingsURL: settingsURL
        )
    }

    init(settings: GuardianStoredSettings, logURL: URL, settingsURL: URL) {
        let normalized = settings.normalized
        self.workMinutes = normalized.workMinutes
        self.restMinutes = normalized.restMinutes
        self.maxWorkMinutes = normalized.maxWorkMinutes
        self.workSeconds = normalized.workMinutes * 60
        self.restSeconds = normalized.restMinutes * 60
        self.maxWorkSeconds = normalized.maxWorkMinutes * 60
        self.logURL = logURL
        self.settingsURL = settingsURL
    }

    private static func argumentMinutes(named name: String) -> Int? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else {
            return nil
        }
        return Int(args[index + 1])
    }

    static func saveSettings(_ settings: GuardianStoredSettings, to url: URL) throws {
        let data = try JSONEncoder().encode(settings.normalized)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func loadStoredSettings(from url: URL) -> GuardianStoredSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(GuardianStoredSettings.self, from: data) else {
            return GuardianStoredSettings.defaults
        }
        return settings.normalized
    }

    private static func defaultLogURL() -> URL {
        localDataDirectory().appendingPathComponent("rest-guardian-log.jsonl")
    }

    private static func defaultSettingsURL() -> URL {
        localDataDirectory().appendingPathComponent("rest-guardian-settings.json")
    }

    private static func localDataDirectory() -> URL {
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            let projectDir = bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if projectDir.lastPathComponent == "rest-guardian" {
                return projectDir
            }
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rest Guardian", isDirectory: true)
    }
}

private struct GuardianLogEvent: Codable {
    let timestamp: String
    let event: String
    let mode: String
    let remainingSeconds: Int
    let details: [String: String]
}

private final class RestGuardianApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let protectedRestSeconds = 5 * 60

    private var config = GuardianConfig.fromArguments()
    private let dateFormatter = ISO8601DateFormatter()

    private var mode: GuardianMode = .work
    private var remainingSeconds = 0
    private var sessionTotalSeconds = 0
    private var continuousWorkSeconds = 0
    private var restElapsedSeconds = 0
    private var timer: Timer?

    private var timerWindow: NSPanel!
    private var modeLabel: NSTextField!
    private var countdownLabel: NSTextField!
    private var addOneMinuteButton: NSButton!
    private var restWindow: NSWindow?
    private var restCountdownLabel: NSTextField?
    private var restSuggestionLabel: NSTextField?
    private var returnToWorkButton: NSButton?
    private var manualRestUndoButton: NSButton?
    private var manualRestUndoSeconds = 0
    private var pausedWorkSecondsBeforeManualRest = 0
    private var pausedContinuousWorkSecondsBeforeManualRest = 0
    private var settingsWindow: NSWindow?
    private var workMinutesField: NSTextField?
    private var restMinutesField: NSTextField?
    private var maxWorkMinutesField: NSTextField?
    private var reminderWindow: NSPanel?
    private var reminderHideTimer: Timer?
    private var workReminderIndex = 0
    private var restSuggestionIndex = 0

    private let workExtensionMessages = [
        "好，借你一分钟。椅子先记账。",
        "续一小口可以，别把休息鸽太久。",
        "这一分钟是加班券，用完要还给身体。",
        "可以，再敲一分钟，眼睛已经在旁边记小本了。",
        "加时成功，但腰背申请稍后开会。",
        "一分钟而已，但别让它变成连续剧。",
        "行，再冲一下。到点就别和休息讨价还价了。",
        "屏幕说还能顶，身体说你最好想清楚。",
        "加一。请珍惜这张临时通行证。",
        "这一分钟属于特别审批，不是无限续杯。"
    ]

    private let restSuggestions = [
        "离开屏幕，去当五分钟线下人类。",
        "给水杯一个被使用的机会。",
        "去厕所也算高质量中断。",
        "抬头看远处，别让眼睛继续加班。",
        "站起来伸个懒腰，身体不是外设。",
        "什么都不做也可以，大脑需要清缓存。",
        "在房间里走一圈，证明你还会离开椅子。",
        "把肩膀放下来，别一直端着。",
        "去窗边看看，外面的世界还在加载。",
        "起身晃两步，给血液一点存在感。",
        "摸一下水杯，它可能已经等你很久了。",
        "离开键盘，双手也想下班五分钟。",
        "看远一点，别把世界缩成这块屏幕。",
        "站起来，椅子也需要私人空间。",
        "去接点水，顺便刷新一下自己。",
        "闭眼十秒，假装系统正在维护。",
        "走到门口再回来，算一次短途旅行。",
        "给脖子转个弯，它不是固定支架。",
        "别急着回去，灵感通常不住在屏幕里。",
        "现在的任务：不操作任何电子设备。",
        "喝水、走路、发呆，任选一个低配幸福。",
        "让眼睛看看真实分辨率的世界。"
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildTimerWindow()
        startWork(seconds: config.workSeconds, reason: "app_started")
        log("app_started")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else {
            return
        }

        settingsWindow = nil
        workMinutesField = nil
        restMinutesField = nil
        maxWorkMinutesField = nil
    }

    private func buildTimerWindow() {
        let width: CGFloat = 342
        let height: CGFloat = 38
        let frame = topWindowFrame(width: width, height: height)

        timerWindow = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        timerWindow.level = .floating
        timerWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        timerWindow.isFloatingPanel = true
        timerWindow.hidesOnDeactivate = false
        timerWindow.backgroundColor = .clear
        timerWindow.isOpaque = false
        timerWindow.hasShadow = true

        let shell = NSVisualEffectView()
        shell.material = .hudWindow
        shell.blendingMode = .behindWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 18

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        modeLabel = label("工作", size: 12, weight: .semibold, color: NSColor.systemOrange)
        countdownLabel = label("25:00", size: 18, weight: .bold, color: .white)
        countdownLabel.monospacedDigit()

        stack.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(countdownLabel)
        stack.addArrangedSubview(spacer())
        addOneMinuteButton = smallButton("+1", action: #selector(addOneMinuteWork))
        stack.addArrangedSubview(addOneMinuteButton)
        stack.addArrangedSubview(smallButton("休息", action: #selector(startRestNow)))
        stack.addArrangedSubview(smallButton("设置", action: #selector(showSettingsPanel)))
        stack.addArrangedSubview(smallButton("×", action: #selector(quitApp)))

        shell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            stack.topAnchor.constraint(equalTo: shell.topAnchor),
            stack.bottomAnchor.constraint(equalTo: shell.bottomAnchor)
        ])

        timerWindow.contentView = shell
        timerWindow.orderFrontRegardless()
    }

    private func topWindowFrame(width: CGFloat, height: CGFloat) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height - 8,
            width: width,
            height: height
        )
    }

    private func startWork(seconds: Int, reason: String) {
        let allowedSeconds = max(0, config.maxWorkSeconds - continuousWorkSeconds)
        guard allowedSeconds > 0 else {
            log("work_start_blocked_max_reached", details: ["reason": reason])
            startRest(reason: "max_work_reached")
            return
        }

        let actualSeconds = min(seconds, allowedSeconds)
        closeRestWindow()
        mode = .work
        remainingSeconds = actualSeconds
        sessionTotalSeconds = actualSeconds
        startTicker()
        updateTimerWindow()
        log("work_started", details: [
            "reason": reason,
            "seconds": "\(actualSeconds)",
            "continuousWorkSeconds": "\(continuousWorkSeconds)",
            "maxWorkSeconds": "\(config.maxWorkSeconds)"
        ])
    }

    private func startRest(reason: String) {
        let previousContinuousWorkSeconds = continuousWorkSeconds
        let isManualRest = reason == "manual"
        pausedWorkSecondsBeforeManualRest = isManualRest ? remainingSeconds : 0
        pausedContinuousWorkSecondsBeforeManualRest = isManualRest ? previousContinuousWorkSeconds : 0
        manualRestUndoSeconds = isManualRest ? 10 : 0
        restSuggestionIndex = 0
        restElapsedSeconds = 0
        continuousWorkSeconds = 0
        mode = .rest
        remainingSeconds = config.restSeconds
        sessionTotalSeconds = config.restSeconds
        showRestWindow()
        startTicker()
        updateTimerWindow()
        log("rest_started", details: [
            "reason": reason,
            "seconds": "\(config.restSeconds)",
            "previousContinuousWorkSeconds": "\(previousContinuousWorkSeconds)"
        ])
    }

    private func startTicker() {
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        if mode == .work {
            continuousWorkSeconds = min(config.maxWorkSeconds, continuousWorkSeconds + 1)
        }

        remainingSeconds = max(0, remainingSeconds - 1)
        if mode == .rest {
            restElapsedSeconds += 1
        }
        if mode == .rest && manualRestUndoSeconds > 0 {
            manualRestUndoSeconds -= 1
            updateManualRestUndoButton()
        }
        if mode == .rest && remainingSeconds > 0 && remainingSeconds % 6 == 0 {
            updateRestSuggestion(advance: true)
        }
        updateTimerWindow()
        restCountdownLabel?.stringValue = formatTime(remainingSeconds)
        updateReturnToWorkButton()

        if mode == .work && continuousWorkSeconds >= config.maxWorkSeconds {
            timer?.invalidate()
            timer = nil
            log("max_work_reached", details: ["maxWorkSeconds": "\(config.maxWorkSeconds)"])
            startRest(reason: "max_work_reached")
            return
        }

        guard remainingSeconds == 0 else {
            return
        }

        timer?.invalidate()
        timer = nil

        switch mode {
        case .work:
            log("work_timer_finished", details: [
                "seconds": "\(sessionTotalSeconds)",
                "continuousWorkSeconds": "\(continuousWorkSeconds)",
                "remainingAllowanceSeconds": "\(remainingWorkAllowance)"
            ])
            startRest(reason: "work_timer_finished")
        case .rest:
            log("rest_completed", details: ["seconds": "\(sessionTotalSeconds)"])
            startWork(seconds: config.workSeconds, reason: "rest_completed")
        }
    }

    private func updateTimerWindow() {
        switch mode {
        case .work:
            modeLabel.stringValue = "工作"
            modeLabel.textColor = NSColor.systemOrange
        case .rest:
            modeLabel.stringValue = "休息"
            modeLabel.textColor = NSColor.systemGreen
        }
        countdownLabel.stringValue = formatTime(remainingSeconds)
        addOneMinuteButton?.isEnabled = mode == .work && workExtensionHeadroom >= 60
    }

    private func showRestWindow() {
        closeRestWindow()

        let window = overlayWindow(alpha: 0.84)
        let card = overlayCard(width: 420)

        let title = label("休息中", size: 32, weight: .bold, color: .white)
        restCountdownLabel = label(formatTime(remainingSeconds), size: 54, weight: .bold, color: NSColor.systemGreen)
        restCountdownLabel?.monospacedDigit()
        restSuggestionLabel = label("", size: 16, weight: .semibold, color: NSColor.systemCyan)
        restSuggestionLabel?.maximumNumberOfLines = 0
        restSuggestionLabel?.alignment = .center
        updateRestSuggestion(advance: false)
        returnToWorkButton = largeButton("已休息够，回到工作", action: #selector(returnToWorkAfterEnoughRest))
        updateReturnToWorkButton()

        let stack = verticalStack(spacing: 18)
        stack.alignment = .centerX
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(restCountdownLabel!)
        stack.addArrangedSubview(restSuggestionLabel!)
        stack.addArrangedSubview(largeButton("没休息够？再来五分钟！", action: #selector(extendRestFiveMinutes)))
        stack.addArrangedSubview(returnToWorkButton!)
        if manualRestUndoSeconds > 0 {
            manualRestUndoButton = smallQuietButton("", action: #selector(undoManualRest))
            updateManualRestUndoButton()
            stack.addArrangedSubview(manualRestUndoButton!)
        }
        card.addSubview(stack)
        pin(stack, to: card, inset: 28)
        window.contentView?.addSubview(card)
        center(card, in: window.contentView!)

        restWindow = window
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func overlayWindow(alpha: CGFloat) -> NSWindow {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false

        let root = NSView(frame: screenFrame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        window.contentView = root
        return window
    }

    private func overlayCard(width: CGFloat) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        card.layer?.borderWidth = 1
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        return card
    }

    private func closeRestWindow() {
        restWindow?.orderOut(nil)
        restWindow = nil
        restCountdownLabel = nil
        restSuggestionLabel = nil
        returnToWorkButton = nil
        manualRestUndoButton = nil
        manualRestUndoSeconds = 0
        restElapsedSeconds = 0
    }

    @objc private func startRestNow() {
        log("manual_rest_requested")
        startRest(reason: "manual")
    }

    @objc private func undoManualRest() {
        guard manualRestUndoSeconds > 0, pausedWorkSecondsBeforeManualRest > 0 else {
            return
        }

        let restoredRemainingSeconds = pausedWorkSecondsBeforeManualRest
        continuousWorkSeconds = pausedContinuousWorkSecondsBeforeManualRest
        pausedWorkSecondsBeforeManualRest = 0
        pausedContinuousWorkSecondsBeforeManualRest = 0
        manualRestUndoSeconds = 0
        log("manual_rest_undone", details: [
            "restoredRemainingSeconds": "\(restoredRemainingSeconds)",
            "restoredContinuousWorkSeconds": "\(continuousWorkSeconds)"
        ])
        startWork(seconds: restoredRemainingSeconds, reason: "manual_rest_undo")
    }

    @objc private func extendRestFiveMinutes() {
        guard mode == .rest else {
            return
        }

        remainingSeconds += 5 * 60
        sessionTotalSeconds += 5 * 60
        restCountdownLabel?.stringValue = formatTime(remainingSeconds)
        updateRestSuggestion(advance: true)
        updateReturnToWorkButton()
        log("rest_extended_five_minutes", details: [
            "remainingSeconds": "\(remainingSeconds)",
            "restElapsedSeconds": "\(restElapsedSeconds)"
        ])
    }

    @objc private func returnToWorkAfterEnoughRest() {
        guard mode == .rest, restElapsedSeconds >= Self.protectedRestSeconds else {
            return
        }

        log("rest_return_to_work_after_enough_rest", details: [
            "remainingSeconds": "\(remainingSeconds)",
            "restElapsedSeconds": "\(restElapsedSeconds)"
        ])
        startWork(seconds: config.workSeconds, reason: "rest_return_to_work")
    }

    @objc private func addOneMinuteWork() {
        guard mode == .work else {
            return
        }

        guard workExtensionHeadroom >= 60 else {
            showReminder("已经接近连续工作上限了，到点就休息。")
            log("work_add_one_blocked_max_reached")
            return
        }

        remainingSeconds += 60
        sessionTotalSeconds += 60
        updateTimerWindow()

        let message = workExtensionMessages[workReminderIndex % workExtensionMessages.count]
        workReminderIndex += 1
        showReminder(message)
        log("work_added_one_minute", details: [
            "remainingSeconds": "\(remainingSeconds)",
            "continuousWorkSeconds": "\(continuousWorkSeconds)",
            "maxWorkSeconds": "\(config.maxWorkSeconds)"
        ])
    }

    @objc private func showSettingsPanel() {
        if let settingsWindow {
            settingsWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rest Guardian 设置"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .active

        let stack = verticalStack(spacing: 16)
        stack.alignment = .leading

        let title = label("休息监督设置", size: 22, weight: .bold, color: .labelColor)
        title.alignment = .left
        let subtitle = label("保存只影响后续计时，不会重置当前工作轮。连续工作上限最高固定为 50 分钟，且不能小于每轮工作时间。", size: 13, weight: .regular, color: .secondaryLabelColor)
        subtitle.alignment = .left
        subtitle.maximumNumberOfLines = 0

        workMinutesField = minutesField(config.workMinutes)
        restMinutesField = minutesField(config.restMinutes)
        maxWorkMinutesField = minutesField(config.maxWorkMinutes)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(settingsRow(title: "每轮工作", field: workMinutesField!))
        stack.addArrangedSubview(settingsRow(title: "每轮休息", field: restMinutesField!))
        stack.addArrangedSubview(settingsRow(title: "连续工作上限", field: maxWorkMinutesField!))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(spacer())
        buttonRow.addArrangedSubview(largeButton("取消", action: #selector(closeSettingsPanel)))
        buttonRow.addArrangedSubview(largeButton("保存", action: #selector(saveSettings)))
        stack.addArrangedSubview(buttonRow)

        root.addSubview(stack)
        pin(stack, to: root, inset: 24)
        window.contentView = root
        window.delegate = self
        settingsWindow = window
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        log("settings_opened")
    }

    @objc private func closeSettingsPanel() {
        settingsWindow?.orderOut(nil)
        settingsWindow = nil
        workMinutesField = nil
        restMinutesField = nil
        maxWorkMinutesField = nil
    }

    @objc private func saveSettings() {
        guard let work = readMinutes(workMinutesField),
              let rest = readMinutes(restMinutesField),
              let maxWork = readMinutes(maxWorkMinutesField) else {
            showSettingsAlert("请输入有效的分钟数。")
            return
        }

        guard work <= GuardianStoredSettings.hardMaxWorkMinutes,
              maxWork <= GuardianStoredSettings.hardMaxWorkMinutes else {
            showSettingsAlert("工作时间和连续工作上限都不能超过 50 分钟。")
            return
        }

        guard maxWork >= work else {
            showSettingsAlert("连续工作上限不能小于每轮工作时间。")
            return
        }

        let settings = GuardianStoredSettings(
            workMinutes: work,
            restMinutes: rest,
            maxWorkMinutes: maxWork
        ).normalized

        do {
            try GuardianConfig.saveSettings(settings, to: config.settingsURL)
        } catch {
            showSettingsAlert("保存失败：\(error.localizedDescription)")
            return
        }

        config = GuardianConfig(settings: settings, logURL: config.logURL, settingsURL: config.settingsURL)
        closeSettingsPanel()
        log("settings_saved", details: [
            "workMinutes": "\(settings.workMinutes)",
            "restMinutes": "\(settings.restMinutes)",
            "maxWorkMinutes": "\(settings.maxWorkMinutes)",
            "mode": mode.rawValue,
            "remainingSeconds": "\(remainingSeconds)",
            "continuousWorkSeconds": "\(continuousWorkSeconds)"
        ])
        updateTimerWindow()
        updateReturnToWorkButton()

        if mode == .work && continuousWorkSeconds >= config.maxWorkSeconds {
            log("settings_saved_max_reached", details: ["maxWorkSeconds": "\(config.maxWorkSeconds)"])
            startRest(reason: "settings_saved_max_reached")
        }
    }

    @objc private func quitApp() {
        log("app_quit")
        NSApp.terminate(nil)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        return button
    }

    private func largeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        return button
    }

    private func minutesField(_ minutes: Int) -> NSTextField {
        let field = NSTextField(string: "\(minutes)")
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return field
    }

    private func settingsRow(title: String, field: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = label(title, size: 15, weight: .semibold, color: .labelColor)
        titleLabel.alignment = .left
        titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let unitLabel = label("分钟", size: 13, weight: .regular, color: .secondaryLabelColor)
        unitLabel.alignment = .left

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(field)
        row.addArrangedSubview(unitLabel)
        row.addArrangedSubview(spacer())
        return row
    }

    private func readMinutes(_ field: NSTextField?) -> Int? {
        guard let value = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let minutes = Int(value),
              minutes >= 1,
              minutes <= 240 else {
            return nil
        }
        return minutes
    }

    private func showSettingsAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "设置没有保存"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        if let settingsWindow {
            alert.beginSheetModal(for: settingsWindow)
        } else {
            alert.runModal()
        }
    }

    private func showReminder(_ message: String) {
        reminderHideTimer?.invalidate()
        reminderWindow?.orderOut(nil)

        let width: CGFloat = 390
        let height: CGFloat = 52
        let timerFrame = timerWindow.frame
        let frame = NSRect(
            x: timerFrame.midX - width / 2,
            y: timerFrame.minY - height - 8,
            width: width,
            height: height
        )

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        let shell = NSVisualEffectView()
        shell.material = .hudWindow
        shell.blendingMode = .behindWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 14

        let text = label(message, size: 13, weight: .semibold, color: NSColor.white.withAlphaComponent(0.9))
        text.maximumNumberOfLines = 2
        text.alignment = .center
        shell.addSubview(text)
        pin(text, to: shell, inset: 10)

        window.contentView = shell
        reminderWindow = window
        window.orderFrontRegardless()

        reminderHideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.reminderWindow?.orderOut(nil)
            self?.reminderWindow = nil
            self?.reminderHideTimer = nil
        }
    }

    private func smallQuietButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.58)
        return button
    }

    private func updateManualRestUndoButton() {
        guard let button = manualRestUndoButton else { return }
        if manualRestUndoSeconds > 0 {
            button.isHidden = false
            button.title = "误触，回到工作（\(manualRestUndoSeconds)s）"
        } else {
            button.isHidden = true
            pausedWorkSecondsBeforeManualRest = 0
            pausedContinuousWorkSecondsBeforeManualRest = 0
            log("manual_rest_undo_expired")
        }
    }

    private func updateRestSuggestion(advance: Bool) {
        guard let restSuggestionLabel else {
            return
        }

        if advance {
            restSuggestionIndex = (restSuggestionIndex + 1) % restSuggestions.count
        }
        restSuggestionLabel.stringValue = restSuggestions[restSuggestionIndex]
    }

    private func updateReturnToWorkButton() {
        guard let button = returnToWorkButton else {
            return
        }

        let remainingProtectedSeconds = max(0, Self.protectedRestSeconds - restElapsedSeconds)
        if remainingProtectedSeconds == 0 {
            button.isHidden = false
            button.isEnabled = true
            button.title = "已休息够，回到工作"
        } else {
            button.isHidden = false
            button.isEnabled = false
            button.title = "再休息 \(formatTime(remainingProtectedSeconds)) 后可回到工作"
        }
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func center(_ child: NSView, in parent: NSView) {
        NSLayoutConstraint.activate([
            child.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            child.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        ])
    }

    private func formatTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        return "\(minutes) 分钟"
    }

    private var remainingWorkAllowance: Int {
        max(0, config.maxWorkSeconds - continuousWorkSeconds)
    }

    private var workExtensionHeadroom: Int {
        max(0, config.maxWorkSeconds - continuousWorkSeconds - remainingSeconds)
    }

    private func log(_ event: String, details: [String: String] = [:]) {
        let logEvent = GuardianLogEvent(
            timestamp: dateFormatter.string(from: Date()),
            event: event,
            mode: mode.rawValue,
            remainingSeconds: remainingSeconds,
            details: details
        )

        do {
            let data = try JSONEncoder().encode(logEvent)
            try FileManager.default.createDirectory(at: config.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: config.logURL.path) {
                FileManager.default.createFile(atPath: config.logURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: config.logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        } catch {
            NSLog("Rest Guardian log failed: \(error.localizedDescription)")
        }
    }
}

private extension NSTextField {
    func monospacedDigit() {
        guard let currentFont = font else { return }
        font = NSFont.monospacedDigitSystemFont(ofSize: currentFont.pointSize, weight: .bold)
    }
}

private let startupConfig = GuardianConfig.fromArguments()
if CommandLine.arguments.contains("--print-config") {
    print("workSeconds=\(startupConfig.workSeconds)")
    print("restSeconds=\(startupConfig.restSeconds)")
    print("maxWorkSeconds=\(startupConfig.maxWorkSeconds)")
    print("logURL=\(startupConfig.logURL.path)")
    print("settingsURL=\(startupConfig.settingsURL.path)")
} else {
    let app = NSApplication.shared
    let delegate = RestGuardianApp()
    app.delegate = delegate
    app.run()
}
