import Foundation

struct LibrarySnapshot: Codable {
    var projects: [Project]
    var papers: [Paper]
}

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var paperIDs: [UUID]
    let createdAt: Date
}

struct Paper: Codable, Identifiable, Hashable {
    let id: UUID
    let projectID: UUID
    var title: String
    var authors: [String]
    var venue: String?
    var year: Int?
    var doi: String?
    var arxivID: String?
    var abstractText: String?
    var pdfRelativePath: String
    var sourceFilename: String
    let addedAt: Date
    var metadataStatus: MetadataStatus
    var metadataSource: String?
    var metadataError: String?
}

enum MetadataStatus: String, Codable {
    case pending
    case resolved
    case failed
}

struct ResolvedMetadata {
    var title: String
    var authors: [String]
    var venue: String?
    var year: Int?
    var doi: String?
    var arxivID: String?
    var abstractText: String?
    var source: String
}
