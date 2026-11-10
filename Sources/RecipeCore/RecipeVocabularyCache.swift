import CoreData

/// Import-scoped, and only accessed on its owning context's queue.
final class RecipeVocabularyCache {
  private var tables: [String: [String: NSManagedObject]]?
  private(set) var fetchCount = 0
  init(context: NSManagedObjectContext) throws { try load(context) }

  private func load(_ context: NSManagedObjectContext) throws {
    var loaded: [String: [String: NSManagedObject]] = [:]
    for (entity, key) in [("Category", "id"), ("Tag", "name"), ("Ingredient", "name")] {
      let request = NSFetchRequest<NSManagedObject>(entityName: entity)
      var table: [String: NSManagedObject] = [:]
      for record in try context.fetch(request) {
        if let name = record.value(forKey: key) as? String { table[name] = record }
      }
      fetchCount += 1
      loaded[entity] = table
    }
    tables = loaded
  }

  func record(entity: String, key: String, name: String, context: NSManagedObjectContext) throws -> NSManagedObject {
    if tables == nil { try load(context) }
    if let existing = tables?[entity]?[name] { return existing }
    let record = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
    record.setValue(name, forKey: key)
    tables?[entity]?[name] = record
    return record
  }

  /// Rolled-back inserts must not survive in a cache used by the next recipe.
  func invalidateAfterRollback() { tables = nil }
}
