import Foundation

/// Chooses the adjacent-chapter source without ever synchronously waiting for a main-actor
/// network loader. DZMeBookRead's original sample used a blocking branch here; Legado's
/// loader resumes on the main actor, so blocking that actor prevented the next chapter from
/// being appended to the continuous scroll table.
enum DZMAdjacentChapterRequest {
    static func request(
        isPersisted: Bool,
        sourceType: DZMBookSourceType,
        loadPersistedOrLocal: @escaping () -> DZMReadChapterModel?,
        loadRemote: @escaping (@escaping (DZMReadChapterModel?) -> Void) -> Void,
        completion: @escaping (DZMReadChapterModel?) -> Void
    ) {
        if isPersisted || sourceType == .local {
            DispatchQueue.global().async {
                completion(loadPersistedOrLocal())
            }
            return
        }

        loadRemote(completion)
    }
}
