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
        let storageManager = VideoStorageManager.shared
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

                // 경로가 절대 경로인지 상대 경로인지 확인
                let videoURL: URL
                let thumbnailURL: URL
                
                if videoPath.hasPrefix("/") {
                    // 절대 경로인 경우: 상대 경로로 변환하여 저장하고, 절대 URL 생성
                    let absoluteURL = URL(fileURLWithPath: videoPath)
                    if let relativePath = storageManager.relativePath(from: absoluteURL) {
                        // 상대 경로로 변환 가능하면 저장
                        object.setValue(relativePath, forKey: "videoPath")
                    }
                    videoURL = absoluteURL
                } else {
                    // 상대 경로인 경우: 절대 URL 생성
                    videoURL = storageManager.absoluteURL(from: videoPath)
                }
                
                if thumbPath.hasPrefix("/") {
                    // 절대 경로인 경우: 상대 경로로 변환하여 저장하고, 절대 URL 생성
                    let absoluteURL = URL(fileURLWithPath: thumbPath)
                    if let relativePath = storageManager.relativePath(from: absoluteURL) {
                        // 상대 경로로 변환 가능하면 저장
                        object.setValue(relativePath, forKey: "thumbnailPath")
                    }
                    thumbnailURL = absoluteURL
                } else {
                    // 상대 경로인 경우: 절대 URL 생성
                    thumbnailURL = storageManager.absoluteURL(from: thumbPath)
                }
                
                // 파일 존재 여부 확인
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: videoURL.path),
                      fileManager.fileExists(atPath: thumbnailURL.path) else {
                    // 파일이 없으면 해당 레코드 삭제
                    context.delete(object)
                    return nil
                }
                
                // 변경사항 저장
                if context.hasChanges {
                    try? context.save()
                }
                
                return ClipMetadata(date: date, videoURL: videoURL, thumbnailURL: thumbnailURL, createdAt: createdAt)
            }
        }
    }

    func upsert(_ metadata: ClipMetadata) async throws {
        let context = self.context
        let storageManager = VideoStorageManager.shared
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
            
            // 상대 경로로 저장 (앱 업데이트 시에도 유지됨)
            let videoRelativePath = storageManager.relativePath(from: metadata.videoURL) ?? metadata.videoURL.path
            let thumbnailRelativePath = storageManager.relativePath(from: metadata.thumbnailURL) ?? metadata.thumbnailURL.path
            
            object.setValue(videoRelativePath, forKey: "videoPath")
            object.setValue(thumbnailRelativePath, forKey: "thumbnailPath")
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

