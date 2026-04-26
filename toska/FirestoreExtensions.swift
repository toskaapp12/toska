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

/// Validates that a string looks like a Firestore document ID.
///
/// Used at every ID boundary sourced from outside the app — push payload
/// userInfo, universal-link URL path, deep-link callbacks. Without this,
/// a crafted notification or link can route the app to arbitrary screens
/// or crash views that assume a well-formed ID.
///
/// Firestore doc IDs are 1–1500 bytes and exclude "/", "." patterns, but
/// in practice our IDs are either Firestore auto-IDs (20 alphanumerics)
/// or handle-derived composites. A generous allow-list keeps both working.
///
/// `nonisolated` so the nonisolated UNUserNotificationCenter delegate in
/// PushNotificationManager can call this without await — the function is
/// pure and has no shared state.
nonisolated func isValidFirestoreDocId(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else { return false }
    return id.allSatisfy { ch in
        ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
    }
}

/// Thrown by `withTimeout` when the operation exceeds its budget.
struct TimeoutError: Error {
    let seconds: TimeInterval
}

/// Races an async operation against a timer. If the operation finishes
/// first, its result (or error) is returned. If the timer wins, the
/// operation is cancelled cooperatively and `TimeoutError` is thrown.
///
/// Use this anywhere a network-bound async call could legitimately hang
/// — auth sign-in, sign-up handle generation, password reset — so the UI
/// can show a "timed out, try again" path instead of spinning forever.
///
/// The operation closure receives Task cancellation, so any await point
/// inside it that participates in cooperative cancellation (Firebase's
/// async APIs do) will throw CancellationError on timeout. If the
/// underlying call ignores cancellation, the orphan Task lingers until
/// the system eventually completes it — that's acceptable; the *user-
/// facing* hang is bounded by the timeout regardless.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        return result
    }
}
