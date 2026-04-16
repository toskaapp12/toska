//
//  FirestoreExtensions.swift
//  toska
//

import Foundation
import FirebaseFirestore

extension DocumentReference {
    func getDocumentAsync() async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.getDocument { snapshot, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let snapshot = snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "FirestoreExtensions",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No snapshot and no error returned"]
                    ))
                }
            }
        }
    }
}

extension Query {
    func getDocumentsAsync() async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.getDocuments { snapshot, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let snapshot = snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "FirestoreExtensions",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No snapshot and no error returned"]
                    ))
                }
            }
        }
    }
}
