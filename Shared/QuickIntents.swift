import Foundation
import AppIntents
import WidgetKit

struct TimbrePresetEntity: AppEntity, Codable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "EQ preset"
    static var defaultQuery = TimbrePresetQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct TimbrePresetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TimbrePresetEntity] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [TimbrePresetEntity] { TimbreQuickSnapshot.load().presets }
}
struct TimbreQuickSnapshot: Codable {
    var eq = true
    var spatial = false
    var reverb = false
    var gain: Double = 0
    var presets: [TimbrePresetEntity] = []
    static func load() -> Self {
        guard let data = SharedStore.defaults?.data(forKey: "quickControls"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { SharedStore.defaults?.set(data, forKey: "quickControls") }
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}
@available(iOS 17.0, *) struct TimbreQuickIntent: LiveActivityIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Timbre Quick Action"
    @Parameter(title: "Command") var command: String
    init() { command = "eq" }
    init(_ command: String) { self.command = command }
    func perform() async throws -> some IntentResult {
        await CommandBus.send(command)
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        return .result()
    }
}
@available(iOS 18.0, *) struct TimbreSwitchIntent: SetValueIntent, LiveActivityIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set Timbre Effect"
    @Parameter(title: "Effect") var effect: String
    @Parameter(title: "Enabled") var value: Bool
    init() { effect = "eq" }
    init(_ effect: String) { self.effect = effect }
    func perform() async throws -> some IntentResult {
        await CommandBus.send("\(effect):\(value ? "on" : "off")")
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}
@available(iOS 18.0, *) struct TimbrePresetConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "EQ preset"
    @Parameter(title: "Preset") var preset: TimbrePresetEntity?
}
