import Foundation

public struct CookingSession {
  public private(set) var checked = Set<Int>()
  public private(set) var currentBlock: Int?
  public var keepAwake = true
  public var active = true
  public var foreground = true
  public var shouldPreventSleep: Bool { active && foreground && keepAwake }
  public init() {}
  public mutating func toggleIngredient(_ id: Int) {
    if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
  }
  public mutating func highlight(_ id: Int) { currentBlock = id }
  public mutating func finish() { active = false }
}
