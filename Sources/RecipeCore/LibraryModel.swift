import CoreData

/// Versioned, queryable local schema. Images remain in managed files, never database blobs.
enum LibraryModel {
  static func current() -> NSManagedObjectModel {
    let model = version10()
    model.entitiesByName["Recipe"]!.properties.append(
      attribute("favouriteChangedAt", .dateAttributeType, optional: true))
    model.entitiesByName["CookEvent"]!.properties.append(
      attribute("deletedAt", .dateAttributeType, optional: true))
    model.versionIdentifiers = ["RecipeLibrary11"]
    return model
  }
  static func version10() -> NSManagedObjectModel {
    let model = version9()
    model.entitiesByName["Recipe"]!.properties.append(
      attribute("reviewedAt", .dateAttributeType, optional: true))
    model.versionIdentifiers = ["RecipeLibrary10"]
    return model
  }
  static func version9() -> NSManagedObjectModel {
    let model = version8()
    model.entitiesByName["Recipe"]!.properties += [
      attribute("setId", .UUIDAttributeType, optional: true),
      attribute("setRelativePath", .stringAttributeType, optional: true)
    ]
    model.versionIdentifiers = ["RecipeLibrary9"]
    return model
  }
  static func version8() -> NSManagedObjectModel {
    let model = version7()
    model.entitiesByName["CookEvent"]!.properties += [
      attribute("finishedAt", .dateAttributeType, optional: true),
      attribute("ingredientWeightGrams", .doubleAttributeType, optional: true),
      attribute("saltGrams", .doubleAttributeType, optional: true),
      attribute("saltPercent", .doubleAttributeType, optional: true),
      attribute("pH", .doubleAttributeType, optional: true),
      attribute("rating", .integer64AttributeType, optional: true),
      attribute("photoPathsData", .binaryDataAttributeType, optional: true)
    ]
    model.versionIdentifiers = ["RecipeLibrary8"]
    return model
  }
  static func version7() -> NSManagedObjectModel {
    let model = version6()
    model.entitiesByName["Recipe"]!.properties += [
      attribute("origin", .stringAttributeType, optional: true),
      attribute("parentRecipeID", .UUIDAttributeType, optional: true)
    ]
    model.versionIdentifiers = ["RecipeLibrary7"]
    return model
  }
  static func version6() -> NSManagedObjectModel {
    let model = version5()
    model.entitiesByName["Recipe"]!.properties += [
      attribute("isRecipe", .booleanAttributeType, optional: true),
      attribute("personalNotes", .stringAttributeType, optional: true)
    ]
    model.versionIdentifiers = ["RecipeLibrary6"]
    return model
  }
  static func version5() -> NSManagedObjectModel {
    let model = version4()
    let category = entity("Category", attributes: [
      attribute("id", .stringAttributeType), attribute("name", .stringAttributeType),
      attribute("section", .stringAttributeType), attribute("parentId", .stringAttributeType, optional: true)
    ], unique: "id")
    relate(model.entitiesByName["Recipe"]!, "categories", to: category, inverse: "recipes", many: true, inverseMany: true)
    model.entities.append(category)
    model.versionIdentifiers = ["RecipeLibrary5"]
    return model
  }
  static func version4() -> NSManagedObjectModel {
    let model = version3()
    model.entitiesByName["Recipe"]!.properties.append(
      attribute("catalogueConfidence", .doubleAttributeType, optional: true))
    model.versionIdentifiers = ["RecipeLibrary4"]
    return model
  }

  static func version3() -> NSManagedObjectModel {
    let model = version2()
    let recipe = model.entitiesByName["Recipe"]!
    recipe.properties += [
      attribute("contentFingerprint", .stringAttributeType, optional: true),
      attribute("sourceFile", .stringAttributeType, optional: true),
    ]
    model.versionIdentifiers = ["RecipeLibrary3"]
    return model
  }

  static func version2() -> NSManagedObjectModel {
    let recipe = entity(
      "Recipe",
      attributes: [
        attribute("id", .UUIDAttributeType),
        attribute("title", .stringAttributeType),
        attribute("notebook", .stringAttributeType),
        attribute("category", .stringAttributeType, defaultValue: ""),
        attribute("cuisine", .stringAttributeType, optional: true),
        attribute("mainIngredient", .stringAttributeType, optional: true),
        attribute("sourceURL", .stringAttributeType, optional: true),
        attribute("markdown", .stringAttributeType),
        attribute("blocksData", .binaryDataAttributeType),
        attribute("warningsData", .binaryDataAttributeType),
        attribute("fingerprint", .stringAttributeType),
        attribute("importedAt", .dateAttributeType),
        attribute("createdText", .stringAttributeType, optional: true),
        attribute("updatedText", .stringAttributeType, optional: true),
        attribute("deletedAt", .dateAttributeType, optional: true),
        attribute("isFavourite", .booleanAttributeType, defaultValue: false),
        attribute("viewCount", .integer64AttributeType, defaultValue: 0),
        attribute("lastViewedAt", .dateAttributeType, optional: true),
        attribute("searchText", .stringAttributeType, defaultValue: ""),
        attribute("heroAssetPath", .stringAttributeType, optional: true),
        attribute("thumbnailPath", .stringAttributeType, optional: true),
      ], unique: "id")
    let tag = entity("Tag", attributes: [attribute("name", .stringAttributeType)], unique: "name")
    let ingredient = entity(
      "Ingredient", attributes: [attribute("name", .stringAttributeType)], unique: "name")
    tag.managedObjectClassName = NSStringFromClass(CanonicalNameRecord.self)
    ingredient.managedObjectClassName = NSStringFromClass(CanonicalNameRecord.self)
    let cookEvent = entity(
      "CookEvent",
      attributes: [
        attribute("id", .UUIDAttributeType),
        attribute("date", .dateAttributeType),
        attribute("note", .stringAttributeType, optional: true),
      ], unique: "id")
    let asset = entity(
      "Asset",
      attributes: [
        attribute("id", .UUIDAttributeType),
        attribute("relativePath", .stringAttributeType),
        attribute("mediaType", .stringAttributeType),
        attribute("checksum", .stringAttributeType),
        attribute("position", .integer64AttributeType, defaultValue: 0),
      ], unique: "id")
    relate(recipe, "tags", to: tag, inverse: "recipes", many: true, inverseMany: true)
    relate(recipe, "ingredients", to: ingredient, inverse: "recipes", many: true, inverseMany: true)
    relate(
      recipe, "cookEvents", to: cookEvent, inverse: "recipe", many: true, inverseMany: false,
      rule: .cascadeDeleteRule)
    relate(
      recipe, "assets", to: asset, inverse: "recipe", many: true, inverseMany: false,
      rule: .cascadeDeleteRule)
    let model = NSManagedObjectModel()
    model.entities = [recipe, tag, ingredient, cookEvent, asset]
    model.versionIdentifiers = ["RecipeLibrary2"]
    return model
  }

  /// Must remain identical to the shipped v0.1.4 model, including optionality/constraints.
  static func legacy() -> NSManagedObjectModel {
    let storedRecipe = entity(
      "StoredRecipe",
      attributes: [
        attribute("id", .UUIDAttributeType),
        attribute("payload", .binaryDataAttributeType),
      ], unique: "id")
    let model = NSManagedObjectModel()
    model.entities = [storedRecipe]
    return model
  }

  private static func entity(_ name: String, attributes: [NSAttributeDescription], unique: String)
    -> NSEntityDescription
  {
    let entity = NSEntityDescription()
    entity.name = name
    entity.managedObjectClassName = "NSManagedObject"
    entity.properties = attributes
    entity.uniquenessConstraints = [[unique]]
    return entity
  }

  private static func attribute(
    _ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil
  ) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = optional
    attribute.defaultValue = defaultValue
    return attribute
  }

  private static func relate(
    _ source: NSEntityDescription, _ name: String, to destination: NSEntityDescription,
    inverse: String, many: Bool, inverseMany: Bool, rule: NSDeleteRule = .nullifyDeleteRule
  ) {
    let forward = NSRelationshipDescription()
    forward.name = name
    forward.destinationEntity = destination
    forward.maxCount = many ? 0 : 1
    forward.isOptional = true
    forward.deleteRule = rule
    let backward = NSRelationshipDescription()
    backward.name = inverse
    backward.destinationEntity = source
    backward.maxCount = inverseMany ? 0 : 1
    backward.isOptional = true
    backward.deleteRule = .nullifyDeleteRule
    forward.inverseRelationship = backward
    backward.inverseRelationship = forward
    source.properties.append(forward)
    destination.properties.append(backward)
  }
}

/// Normalises dictionary names before their unique constraints are evaluated.
@objc(RecipeCanonicalNameRecord)
final class CanonicalNameRecord: NSManagedObject {
  override func willSave() {
    super.willSave()
    guard !isDeleted, let name = value(forKey: "name") as? String else { return }
    var normalised = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(
        separator: " ")
    if entity.name == "Tag" {
      normalised = normalised.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        .replacingOccurrences(of: " ", with: "-")
    }
    if normalised != name { setPrimitiveValue(normalised, forKey: "name") }
  }
}
