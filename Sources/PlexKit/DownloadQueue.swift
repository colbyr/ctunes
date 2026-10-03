import Foundation

/// What the server's download queue needs to transcode one track: where the
/// queue is, with the identity and token as headers, and what to ask for.
/// Measured in `notes/transcoded-downloads.md`.
public struct DownloadQueueJob: Sendable, Hashable {
    /// `POST /downloadQueue` on the server, headers included. Every other
    /// request the queue takes is built from it.
    public let request: URLRequest
    public let ratingKey: String
    /// The cap, in kbps. The server encodes VBR MP3 under it.
    public let bitrate: Int

    public init(request: URLRequest, ratingKey: String, bitrate: Int) {
        self.request = request
        self.ratingKey = ratingKey
        self.bitrate = bitrate
    }
}

/// The request that fetches a finished item's file, and the one that
/// removes the item from the queue afterwards. Items stay listed until
/// deleted, so the caller always sends `delete`, success or not.
public struct PreparedDownload: Sendable, Hashable {
    public let media: URLRequest
    public let delete: URLRequest
}

/// Drives `/downloadQueue`, the background transcoder behind Plex's own
/// Downloads feature (PMS ≥ 1.41.9): add the item, poll until the server
/// has transcoded it into its download cache, hand back the request that
/// fetches the file. The job runs with `context: "static"` and never
/// touches the one live music transcode the account gets, so a stream can
/// play through it. Everything here is a `URLSession` path, so the token
/// rides in a header.
///
/// One queue per client identifier, looked up once per server and kept.
/// The first look also deletes whatever the queue still lists: items a
/// previous run of the app queued and never collected.
public actor DownloadQueueClient {
    private let session: URLSession
    /// Queue id by the queue URL (one per server).
    private var queueIDs: [URL: Int] = [:]
    var pollInterval: Duration = .seconds(1)
    /// How long an item may sit with its status and progress unchanged
    /// before the fetch counts as failed. A 7-minute track takes about 5s
    /// on an Apple silicon server; a slow one keeps `progress` moving.
    var idleLimit: TimeInterval = 60

    public init(session: URLSession) {
        self.session = session
    }

    public enum Failure: Error, Equatable {
        /// The queue refused or doesn't exist: no endpoint on an older
        /// server, or a token the feature is gated for. The original file
        /// is the fallback.
        case unavailable(status: Int)
        case badResponse(status: Int)
        /// The server's own `error` on the item (`decisionError`, …).
        case failed(String)
        case timedOut(status: String)
    }

    func setPollInterval(_ interval: Duration) { pollInterval = interval }

    // MARK: - The protocol

    /// Queues the track and waits for the file. The caller downloads
    /// `media` itself so the temp file is moved in its own actor turn, and
    /// sends `delete` when done. Cancellation and every failure past the
    /// add delete the item here.
    public func prepare(_ job: DownloadQueueJob) async throws -> PreparedDownload {
        let queueID = try await queueID(for: job)
        let itemID = try await add(job, queueID: queueID)
        let delete = request(job, "DELETE", path: "\(queueID)/items/\(itemID)")
        do {
            try await waitUntilAvailable(job, queueID: queueID, itemID: itemID)
        } catch {
            // A cancelled task can't await the delete; a detached one can.
            let session = session
            Task.detached { _ = try? await session.data(for: delete) }
            throw error
        }
        return PreparedDownload(
            media: request(job, "GET", path: "\(queueID)/item/\(itemID)/media"),
            delete: delete
        )
    }

    private func queueID(for job: DownloadQueueJob) async throws -> Int {
        guard let url = job.request.url else { throw Failure.badResponse(status: 0) }
        if let known = queueIDs[url] { return known }
        let container: Container<QueueEntry> = try await decode(job.request, as: "DownloadQueue")
        guard let id = container.items.first?.id else { throw Failure.badResponse(status: 200) }
        queueIDs[url] = id
        await sweep(job, queueID: id)
        return id
    }

    /// Deletes every item the queue lists: leftovers from a run that was
    /// suspended mid-fetch. Best effort.
    private func sweep(_ job: DownloadQueueJob, queueID: Int) async {
        guard let listed: Container<Item> = try? await decode(
            request(job, "GET", path: "\(queueID)/items"), as: "DownloadQueueItem"
        ) else { return }
        for item in listed.items {
            _ = try? await session.data(for: request(job, "DELETE", path: "\(queueID)/items/\(item.id)"))
        }
    }

    private func add(_ job: DownloadQueueJob, queueID: Int) async throws -> Int {
        let items: [URLQueryItem] = [
            .init(name: "keys", value: "/library/metadata/\(job.ratingKey)"),
            .init(name: "protocol", value: "http"),
            // Always the transcoder's MP3, never the server's own decision:
            // one add, one file name. With direct play allowed the server
            // hands back the original when it fits under the cap and
            // re-encodes a 320 kbps MP3 under a 320 cap, so the result
            // would need the decision read back to be named.
            .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "0"),
            .init(name: "mediaIndex", value: "0"),
            .init(name: "partIndex", value: "0"),
            .init(name: "musicBitrate", value: String(job.bitrate)),
            // Without a music transcode target the iOS profile has none
            // and the decision fails. MP4 and M4A targets come back as the
            // same MP3 bytes, so ask for what it gives.
            .init(
                name: "X-Plex-Client-Profile-Extra",
                value: "add-transcode-target(type=musicProfile&context=streaming"
                    + "&protocol=http&container=mp3&audioCodec=mp3)"
            ),
        ]
        let query = items.map { "\(PlexLibrary.encode($0.name))=\(PlexLibrary.encode($0.value ?? ""))" }
            .joined(separator: "&")
        let added: Container<AddedItem> = try await decode(
            request(job, "POST", path: "\(queueID)/add?\(query)"), as: "AddedQueueItems"
        )
        guard let id = added.items.first?.id else { throw Failure.badResponse(status: 200) }
        return id
    }

    private func waitUntilAvailable(_ job: DownloadQueueJob, queueID: Int, itemID: Int) async throws {
        let poll = request(job, "GET", path: "\(queueID)/items/\(itemID)")
        var last: (status: String, progress: Double) = ("", -1)
        var changedAt = Date()
        while true {
            let container: Container<Item> = try await decode(poll, as: "DownloadQueueItem")
            guard let item = container.items.first else { throw Failure.badResponse(status: 200) }
            switch item.status {
            case "available":
                return
            case "error", "expired":
                throw Failure.failed(item.error ?? item.decision?.generalDecisionText ?? item.status)
            default:
                break
            }
            let progress = item.transcode?.progress ?? -1
            if item.status != last.status || progress != last.progress {
                last = (item.status, progress)
                changedAt = Date()
            } else if Date().timeIntervalSince(changedAt) > idleLimit {
                throw Failure.timedOut(status: item.status)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - Requests

    /// `job.request` with its method and a path under the queue URL.
    private func request(_ job: DownloadQueueJob, _ method: String, path: String) -> URLRequest {
        var request = job.request
        request.httpMethod = method
        if let base = job.request.url {
            request.url = URL(string: base.absoluteString + "/" + path)
        }
        return request
    }

    /// Decodes `{"MediaContainer":{"<key>":[…]}}`. A 401, 403 or 404 on
    /// any queue request is the queue not being there for this token.
    private func decode<Item: Decodable & Sendable>(
        _ request: URLRequest, as key: String
    ) async throws -> Container<Item> {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403, 404: throw Failure.unavailable(status: status)
        default: throw Failure.badResponse(status: status)
        }
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[Container<Item>.key] = key
            return try decoder.decode(Container<Item>.self, from: data)
        } catch {
            throw Failure.badResponse(status: status)
        }
    }

    // MARK: - Shapes

    /// `MediaContainer` with one array under a key chosen at decode time;
    /// the array is absent when the queue is empty.
    private struct Container<Item: Decodable>: Decodable {
        static var key: CodingUserInfoKey { CodingUserInfoKey(rawValue: "key")! }
        let items: [Item]

        private struct Dynamic: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let outer = try decoder.container(keyedBy: Dynamic.self)
            let inner = try outer.nestedContainer(keyedBy: Dynamic.self, forKey: Dynamic(stringValue: "MediaContainer"))
            let key = decoder.userInfo[Self.key] as? String ?? ""
            items = try inner.decodeIfPresent([Item].self, forKey: Dynamic(stringValue: key)) ?? []
        }
    }

    private struct QueueEntry: Decodable { let id: Int }
    private struct AddedItem: Decodable { let id: Int }

    struct Item: Decodable, Sendable {
        let id: Int
        let status: String
        let error: String?
        let decision: Decision?
        let transcode: Transcode?

        enum CodingKeys: String, CodingKey {
            case id, status, error, transcode
            case decision = "DecisionResult"
        }

        struct Decision: Decodable, Sendable {
            let generalDecisionText: String?
        }

        struct Transcode: Decodable, Sendable {
            let progress: Double?

            /// The field has been a number; a string would be a surprise
            /// worth surviving.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let number = try? container.decodeIfPresent(Double.self, forKey: .progress) {
                    progress = number
                } else if let text = try? container.decodeIfPresent(String.self, forKey: .progress) {
                    progress = Double(text)
                } else {
                    progress = nil
                }
            }

            enum CodingKeys: String, CodingKey { case progress }
        }
    }
}
