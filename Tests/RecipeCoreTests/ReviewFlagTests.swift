import CoreData
import XCTest
@testable import RecipeCore

final class ReviewFlagTests: XCTestCase {
  func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:url) }
    return url
  }
  func testReviewMarkersAndConfidencePersistAndFilter() throws {
    let root = try root()
    let source = root.appendingPathComponent("Notebook")
    try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
    for (name,confidence,body) in [("Low",0.79,"# Low\n- beans"),("Boundary",0.8,"# Boundary\n- rice"),("Marked",0.95,"# Marked\n- [check] salt")] {
      let file = source.appendingPathComponent(name+".md")
      try body.write(to:file,atomically:true,encoding:.utf8)
      try JSONSerialization.data(withJSONObject:["sourceFile":"Notebook/"+name+".md","confidence":confidence]).write(to:file.deletingPathExtension().appendingPathExtension("catalogue.json"))
    }
    var store: LibraryStore? = try LibraryStore(directory:root.appendingPathComponent("Library"))
    XCTAssertEqual(try store!.importURLs([source]).imported,3)
    XCTAssertEqual(Set(try store!.recipes().filter(\.needsReview).map(\.title)),["Low","Marked"])
    let before = try store!.recipes();store = nil
    let reopened = try LibraryStore(directory:root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipes(),before)
    XCTAssertEqual(try reopened.importURLs([source]).skipped,3)
    XCTAssertEqual(Set(try reopened.recipes().filter(\.needsReview).map(\.title)),["Low","Marked"])
  }
  func testVersionThreeStoreMigratesWithoutInventingConfidence() throws {
    let root = try root();let folder = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel:LibraryModel.version3())
    let persistent = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:folder.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
    let id = UUID()
    try context.performAndWait {
      let object = NSEntityDescription.insertNewObject(forEntityName:"Recipe",into:context)
      object.setValue(id,forKey:"id");object.setValue("Old",forKey:"title");object.setValue("Notebook",forKey:"notebook")
      object.setValue("# Old\n[check] quantity",forKey:"markdown")
      object.setValue(try JSONEncoder().encode([RecipeBlock]()),forKey:"blocksData")
      object.setValue(try JSONEncoder().encode([String]()),forKey:"warningsData")
      object.setValue("old",forKey:"fingerprint");object.setValue(Date(),forKey:"importedAt")
      try context.save()
    }
    try coordinator.remove(persistent)
    let store = try LibraryStore(directory:root)
    let recipe = try XCTUnwrap(store.recipe(id:id))
    XCTAssertNil(recipe.catalogueConfidence);XCTAssertTrue(recipe.needsReview)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("MigrationBackups").path).isEmpty)
    let legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(recipe)) as! [String:Any]
    XCTAssertNil(legacy["catalogueConfidence"])
    XCTAssertNil(try JSONDecoder().decode(Recipe.self,from:JSONSerialization.data(withJSONObject:legacy)).catalogueConfidence)
  }
  func testVersionNineStoreMigratesAndMarkReviewedClearsFlag() throws {
    let root = try root();let folder = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel:LibraryModel.version9())
    let persistent = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:folder.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
    let id = UUID()
    try context.performAndWait {
      let object = NSEntityDescription.insertNewObject(forEntityName:"Recipe",into:context)
      object.setValue(id,forKey:"id");object.setValue("Old",forKey:"title");object.setValue("Notebook",forKey:"notebook")
      object.setValue("# Old\n[check] quantity",forKey:"markdown")
      object.setValue(try JSONEncoder().encode([RecipeBlock]()),forKey:"blocksData")
      object.setValue(try JSONEncoder().encode([String]()),forKey:"warningsData")
      object.setValue("old",forKey:"fingerprint");object.setValue(Date(),forKey:"importedAt")
      try context.save()
    }
    try coordinator.remove(persistent)
    var store: LibraryStore? = try LibraryStore(directory:root)
    let migrated = try XCTUnwrap(store!.recipe(id:id))
    XCTAssertNil(migrated.reviewedAt);XCTAssertTrue(migrated.needsReview)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("MigrationBackups").path).isEmpty)
    try store!.markReviewed(id)
    XCTAssertNotNil(try XCTUnwrap(store!.recipe(id:id)).reviewedAt)
    XCTAssertFalse(try XCTUnwrap(store!.recipe(id:id)).needsReview)
    store = nil
    let reopened = try LibraryStore(directory:root)
    XCTAssertNotNil(try XCTUnwrap(reopened.recipe(id:id)).reviewedAt)
    XCTAssertFalse(try XCTUnwrap(reopened.recipe(id:id)).needsReview)
    try reopened.markReviewed(id,reviewed:false)
    XCTAssertTrue(try XCTUnwrap(reopened.recipe(id:id)).needsReview)
  }
  func testVersionFourStoreMigratesWithBackup() throws {
    let root = try root();let folder = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel:LibraryModel.version4())
    let persistent = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:folder.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
    let id = UUID()
    try context.performAndWait {
      let object = NSEntityDescription.insertNewObject(forEntityName:"Recipe",into:context)
      object.setValue(id,forKey:"id");object.setValue("Old",forKey:"title");object.setValue("Notebook",forKey:"notebook")
      object.setValue("# Old\n[check] quantity",forKey:"markdown")
      object.setValue(try JSONEncoder().encode([RecipeBlock]()),forKey:"blocksData")
      object.setValue(try JSONEncoder().encode([String]()),forKey:"warningsData")
      object.setValue("old",forKey:"fingerprint");object.setValue(Date(),forKey:"importedAt")
      try context.save()
    }
    try coordinator.remove(persistent)
    let store = try LibraryStore(directory:root)
    let recipe = try XCTUnwrap(store.recipe(id:id))
    XCTAssertNil(recipe.catalogueConfidence);XCTAssertTrue(recipe.needsReview)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("MigrationBackups").path).isEmpty)
    let legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(recipe)) as! [String:Any]
    XCTAssertNil(legacy["catalogueConfidence"])
    XCTAssertNil(try JSONDecoder().decode(Recipe.self,from:JSONSerialization.data(withJSONObject:legacy)).catalogueConfidence)
  }
}
