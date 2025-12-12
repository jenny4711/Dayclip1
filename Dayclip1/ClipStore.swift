import Foundation
import CoreData

struct ClipMetadata: Equatable {
    let date: Date
    let videoURL: URL
    let thumbnailURL: URL
    let createdAt: Date
}

actor ClipStore {
    static let shared = ClipStore()

    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private init() {
        let model = ClipStore.makeModel()
        container = NSPersistentContainer(name: "DayclipStore", managedObjectModel: model)
        container.viewContext.automaticallyMergesChangesFromParent = true

        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Failed to load persistent store: \(error)")
            }
        }

        context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func fetchAll() async throws -> [ClipMetadata] {
        let context = self.context
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            let results = try context.fetch(request)
            return results.compactMap { object in
                guard
                    let date = object.value(forKey: "date") as? Date,
                    let videoPath = object.value(forKey: "videoPath") as? String,
                    let thumbPath = object.value(forKey: "thumbnailPath") as? String,
                    let createdAt = object.value(forKey: "createdAt") as? Date
                else {
                    return nil
                }

                let videoURL = URL(fileURLWithPath: videoPath)
                let thumbnailURL = URL(fileURLWithPath: thumbPath)
                return ClipMetadata(date: date, videoURL: videoURL, thumbnailURL: thumbnailURL, createdAt: createdAt)
            }
        }
    }

    func upsert(_ metadata: ClipMetadata) async throws {
        let context = self.context
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipEntity")
            request.predicate = NSPredicate(format: "date == %@", metadata.date as NSDate)
            request.fetchLimit = 1

            let object: NSManagedObject
            if let existing = try context.fetch(request).first {
                object = existing
            } else {
                let entity = NSEntityDescription.entity(forEntityName: "ClipEntity", in: context)!
                object = NSManagedObject(entity: entity, insertInto: context)
            }

            object.setValue(metadata.date, forKey: "date")
            object.setValue(metadata.videoURL.path, forKey: "videoPath")
            object.setValue(metadata.thumbnailURL.path, forKey: "thumbnailPath")
            object.setValue(metadata.createdAt, forKey: "createdAt")

            if context.hasChanges {
                try context.save()
            }
        }
    }

    func deleteClip(for date: Date) async throws {
        let normalized = normalize(date)

        let context = self.context
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ClipEntity")
            request.predicate = NSPredicate(format: "date == %@", normalized as NSDate)
            let results = try context.fetch(request)
            results.forEach { context.delete($0) }

            if context.hasChanges {
                try context.save()
            }
        }
    }

    private func normalize(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "ClipEntity"
        entity.managedObjectClassName = "NSManagedObject"

        let dateAttribute = NSAttributeDescription()
        dateAttribute.name = "date"
        dateAttribute.attributeType = .dateAttributeType
        dateAttribute.isOptional = false

        let videoPathAttribute = NSAttributeDescription()
        videoPathAttribute.name = "videoPath"
        videoPathAttribute.attributeType = .stringAttributeType
        videoPathAttribute.isOptional = false

        let thumbnailPathAttribute = NSAttributeDescription()
        thumbnailPathAttribute.name = "thumbnailPath"
        thumbnailPathAttribute.attributeType = .stringAttributeType
        thumbnailPathAttribute.isOptional = false

        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = false

        entity.properties = [
            dateAttribute,
            videoPathAttribute,
            thumbnailPathAttribute,
            createdAtAttribute
        ]
        entity.uniquenessConstraints = [["date"]]

        model.entities = [entity]
        return model
    }
}

