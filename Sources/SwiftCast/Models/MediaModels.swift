import Foundation

// MARK: - Enumerations

/// How the receiver should treat a stream.
public enum StreamType: OpenStringEnum {
    case buffered, live, unspecified
    case unknown(String)

    public static let knownCases: [StreamType] = [.buffered, .live, .unspecified]

    public var rawValue: String {
        switch self {
        case .buffered: "BUFFERED"
        case .live: "LIVE"
        case .unspecified: "NONE"
        case .unknown(let value): value
        }
    }
}

/// The receiver's player state.
public enum PlayerState: OpenStringEnum {
    case idle, playing, paused, buffering, loading
    case unknown(String)

    public static let knownCases: [PlayerState] = [.idle, .playing, .paused, .buffering, .loading]

    public var rawValue: String {
        switch self {
        case .idle: "IDLE"
        case .playing: "PLAYING"
        case .paused: "PAUSED"
        case .buffering: "BUFFERING"
        case .loading: "LOADING"
        case .unknown(let value): value
        }
    }
}

/// Why the player became idle.
public enum IdleReason: OpenStringEnum {
    case cancelled, interrupted, finished, error
    case unknown(String)

    public static let knownCases: [IdleReason] = [.cancelled, .interrupted, .finished, .error]

    public var rawValue: String {
        switch self {
        case .cancelled: "CANCELLED"
        case .interrupted: "INTERRUPTED"
        case .finished: "FINISHED"
        case .error: "ERROR"
        case .unknown(let value): value
        }
    }
}

/// Queue repeat behavior.
public enum RepeatMode: OpenStringEnum {
    case off, all, single, allAndShuffle
    case unknown(String)

    public static let knownCases: [RepeatMode] = [.off, .all, .single, .allAndShuffle]

    public var rawValue: String {
        switch self {
        case .off: "REPEAT_OFF"
        case .all: "REPEAT_ALL"
        case .single: "REPEAT_SINGLE"
        case .allAndShuffle: "REPEAT_ALL_AND_SHUFFLE"
        case .unknown(let value): value
        }
    }
}

/// Segment container format for HLS streams.
public enum HLSSegmentFormat: OpenStringEnum {
    case aac, ac3, mp3, ts, tsAAC, eac3, fmp4
    case unknown(String)

    public static let knownCases: [HLSSegmentFormat] = [.aac, .ac3, .mp3, .ts, .tsAAC, .eac3, .fmp4]

    public var rawValue: String {
        switch self {
        case .aac: "aac"
        case .ac3: "ac3"
        case .mp3: "mp3"
        case .ts: "ts"
        case .tsAAC: "ts_aac"
        case .eac3: "e-ac3"
        case .fmp4: "fmp4"
        case .unknown(let value): value
        }
    }
}

/// Video segment container format for HLS streams.
public enum HLSVideoSegmentFormat: OpenStringEnum {
    case mpeg2TS, fmp4
    case unknown(String)

    public static let knownCases: [HLSVideoSegmentFormat] = [.mpeg2TS, .fmp4]

    public var rawValue: String {
        switch self {
        case .mpeg2TS: "mpeg2_ts"
        case .fmp4: "fmp4"
        case .unknown(let value): value
        }
    }
}

/// Where playback should resume after a seek.
public enum ResumeState: OpenStringEnum {
    case playbackStart, playbackPause
    case unknown(String)

    public static let knownCases: [ResumeState] = [.playbackStart, .playbackPause]

    public var rawValue: String {
        switch self {
        case .playbackStart: "PLAYBACK_START"
        case .playbackPause: "PLAYBACK_PAUSE"
        case .unknown(let value): value
        }
    }
}

/// Commands supported by the current media session.
public struct SupportedMediaCommands: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pause = SupportedMediaCommands(rawValue: 1 << 0)
    public static let seek = SupportedMediaCommands(rawValue: 1 << 1)
    public static let streamVolume = SupportedMediaCommands(rawValue: 1 << 2)
    public static let streamMute = SupportedMediaCommands(rawValue: 1 << 3)
    public static let skipForward = SupportedMediaCommands(rawValue: 1 << 4)
    public static let skipBackward = SupportedMediaCommands(rawValue: 1 << 5)
    public static let queueNext = SupportedMediaCommands(rawValue: 1 << 6)
    public static let queuePrevious = SupportedMediaCommands(rawValue: 1 << 7)
    public static let queueShuffle = SupportedMediaCommands(rawValue: 1 << 8)
    public static let skipAd = SupportedMediaCommands(rawValue: 1 << 9)
    public static let queueRepeatAll = SupportedMediaCommands(rawValue: 1 << 10)
    public static let queueRepeatOne = SupportedMediaCommands(rawValue: 1 << 11)
    public static let editTracks = SupportedMediaCommands(rawValue: 1 << 12)
    public static let playbackRate = SupportedMediaCommands(rawValue: 1 << 13)

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Images & metadata

/// An image associated with media.
public struct CastImage: Codable, Sendable, Hashable {
    public var url: URL
    public var width: Int?
    public var height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

/// Descriptive metadata for a media item.
///
/// The Cast protocol defines several metadata "types" that share a common
/// JSON object. Set ``kind`` and populate the fields relevant to that kind;
/// `nil` fields are omitted from the wire message.
public struct MediaMetadata: Codable, Sendable, Hashable {
    public enum Kind: Int, Codable, Sendable, Hashable {
        case generic = 0
        case movie = 1
        case tvShow = 2
        case musicTrack = 3
        case photo = 4
        case audiobookChapter = 5
    }

    public var kind: Kind
    public var title: String?
    public var subtitle: String?
    public var images: [CastImage]?
    /// ISO 8601 date string.
    public var releaseDate: String?
    public var studio: String?
    public var seriesTitle: String?
    public var season: Int?
    public var episode: Int?
    /// ISO 8601 date string.
    public var originalAirDate: String?
    public var albumName: String?
    public var albumArtist: String?
    public var artist: String?
    public var composer: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var creationDateTime: String?
    public var location: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        kind: Kind = .generic,
        title: String? = nil,
        subtitle: String? = nil,
        images: [CastImage]? = nil,
        releaseDate: String? = nil,
        studio: String? = nil,
        seriesTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        originalAirDate: String? = nil,
        albumName: String? = nil,
        albumArtist: String? = nil,
        artist: String? = nil,
        composer: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.images = images
        self.releaseDate = releaseDate
        self.studio = studio
        self.seriesTitle = seriesTitle
        self.season = season
        self.episode = episode
        self.originalAirDate = originalAirDate
        self.albumName = albumName
        self.albumArtist = albumArtist
        self.artist = artist
        self.composer = composer
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }

    public static func movie(title: String, subtitle: String? = nil, studio: String? = nil, releaseDate: String? = nil, images: [CastImage]? = nil) -> MediaMetadata {
        MediaMetadata(kind: .movie, title: title, subtitle: subtitle, images: images, releaseDate: releaseDate, studio: studio)
    }

    public static func tvEpisode(title: String, seriesTitle: String?, season: Int?, episode: Int?, originalAirDate: String? = nil, images: [CastImage]? = nil) -> MediaMetadata {
        MediaMetadata(kind: .tvShow, title: title, images: images, seriesTitle: seriesTitle, season: season, episode: episode, originalAirDate: originalAirDate)
    }

    public static func musicTrack(title: String, artist: String? = nil, albumName: String? = nil, albumArtist: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, images: [CastImage]? = nil) -> MediaMetadata {
        MediaMetadata(kind: .musicTrack, title: title, images: images, albumName: albumName, albumArtist: albumArtist, artist: artist, trackNumber: trackNumber, discNumber: discNumber)
    }

    public static func generic(title: String, subtitle: String? = nil, images: [CastImage]? = nil) -> MediaMetadata {
        MediaMetadata(kind: .generic, title: title, subtitle: subtitle, images: images)
    }

    enum CodingKeys: String, CodingKey {
        case kind = "metadataType"
        case title, subtitle, images, releaseDate, studio, seriesTitle, season, episode
        case originalAirDate = "originalAirdate"
        case albumName, albumArtist, artist, composer, trackNumber, discNumber
        case creationDateTime, location, latitude, longitude
    }

    /// The capital-D air date key from Google's media messages reference, read but never written.
    ///
    /// Encoding emits only `originalAirdate`, matching `chrome.cast.media.TvShowMediaMetadata`
    /// and the default media receiver. A custom receiver written against the media messages
    /// reference, which spells the key `originalAirDate`, needs to read the lowercase key.
    private enum LegacyCodingKeys: String, CodingKey {
        case originalAirDate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .generic
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        images = try? c.decodeIfPresent([CastImage].self, forKey: .images)
        releaseDate = try? c.decodeIfPresent(String.self, forKey: .releaseDate)
        studio = try? c.decodeIfPresent(String.self, forKey: .studio)
        seriesTitle = try? c.decodeIfPresent(String.self, forKey: .seriesTitle)
        season = try? c.decodeIfPresent(Int.self, forKey: .season)
        episode = try? c.decodeIfPresent(Int.self, forKey: .episode)
        originalAirDate = (try? c.decodeIfPresent(String.self, forKey: .originalAirDate))
            ?? (try? decoder.container(keyedBy: LegacyCodingKeys.self).decodeIfPresent(String.self, forKey: .originalAirDate))
        albumName = try? c.decodeIfPresent(String.self, forKey: .albumName)
        albumArtist = try? c.decodeIfPresent(String.self, forKey: .albumArtist)
        artist = try? c.decodeIfPresent(String.self, forKey: .artist)
        composer = try? c.decodeIfPresent(String.self, forKey: .composer)
        trackNumber = try? c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try? c.decodeIfPresent(Int.self, forKey: .discNumber)
        creationDateTime = try? c.decodeIfPresent(String.self, forKey: .creationDateTime)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
    }
}

// MARK: - Tracks

/// A text, audio or video track of a media item.
public struct MediaTrack: Codable, Sendable, Hashable, Identifiable {
    public enum TrackType: OpenStringEnum {
        case text, audio, video
        case unknown(String)
        public static let knownCases: [TrackType] = [.text, .audio, .video]
        public var rawValue: String {
            switch self {
            case .text: "TEXT"
            case .audio: "AUDIO"
            case .video: "VIDEO"
            case .unknown(let value): value
            }
        }
    }

    public enum TextSubtype: OpenStringEnum {
        case subtitles, captions, descriptions, chapters, metadata
        case unknown(String)
        public static let knownCases: [TextSubtype] = [.subtitles, .captions, .descriptions, .chapters, .metadata]
        public var rawValue: String {
            switch self {
            case .subtitles: "SUBTITLES"
            case .captions: "CAPTIONS"
            case .descriptions: "DESCRIPTIONS"
            case .chapters: "CHAPTERS"
            case .metadata: "METADATA"
            case .unknown(let value): value
            }
        }
    }

    public var trackId: Int
    public var type: TrackType
    /// URL of the track (e.g. a WebVTT file for out-of-band subtitles).
    public var trackContentId: String?
    /// MIME type of the track, e.g. `text/vtt`.
    public var trackContentType: String?
    public var subtype: TextSubtype?
    public var name: String?
    /// RFC 5646 language tag, e.g. `en-US`.
    public var language: String?
    public var customData: JSONValue?

    public var id: Int { trackId }

    public init(
        trackId: Int,
        type: TrackType,
        trackContentId: String? = nil,
        trackContentType: String? = nil,
        subtype: TextSubtype? = nil,
        name: String? = nil,
        language: String? = nil,
        customData: JSONValue? = nil
    ) {
        self.trackId = trackId
        self.type = type
        self.trackContentId = trackContentId
        self.trackContentType = trackContentType
        self.subtype = subtype
        self.name = name
        self.language = language
        self.customData = customData
    }

    /// An out-of-band WebVTT subtitle track.
    public static func webVTTSubtitles(id: Int, url: URL, name: String? = nil, language: String? = nil) -> MediaTrack {
        MediaTrack(trackId: id, type: .text, trackContentId: url.absoluteString, trackContentType: "text/vtt", subtype: .subtitles, name: name, language: language)
    }
}

/// Styling for text tracks on the receiver.
public struct TextTrackStyle: Codable, Sendable, Hashable {
    public enum EdgeType: String, Codable, Sendable, Hashable {
        case none = "NONE", outline = "OUTLINE", dropShadow = "DROP_SHADOW", raised = "RAISED", depressed = "DEPRESSED"
    }

    public enum WindowType: String, Codable, Sendable, Hashable {
        case none = "NONE", normal = "NORMAL", roundedCorners = "ROUNDED_CORNERS"
    }

    public enum FontGenericFamily: String, Codable, Sendable, Hashable {
        case sansSerif = "SANS_SERIF", monospacedSansSerif = "MONOSPACED_SANS_SERIF", serif = "SERIF"
        case monospacedSerif = "MONOSPACED_SERIF", casual = "CASUAL", cursive = "CURSIVE", smallCapitals = "SMALL_CAPITALS"
    }

    public enum FontStyle: String, Codable, Sendable, Hashable {
        case normal = "NORMAL", bold = "BOLD", boldItalic = "BOLD_ITALIC", italic = "ITALIC"
    }

    /// Colors are `#RRGGBBAA` hex strings.
    public var foregroundColor: String?
    public var backgroundColor: String?
    public var edgeType: EdgeType?
    public var edgeColor: String?
    public var windowType: WindowType?
    public var windowColor: String?
    public var windowRoundedCornerRadius: Int?
    public var fontScale: Double?
    public var fontFamily: String?
    public var fontGenericFamily: FontGenericFamily?
    public var fontStyle: FontStyle?

    public init(
        foregroundColor: String? = nil,
        backgroundColor: String? = nil,
        edgeType: EdgeType? = nil,
        edgeColor: String? = nil,
        windowType: WindowType? = nil,
        windowColor: String? = nil,
        windowRoundedCornerRadius: Int? = nil,
        fontScale: Double? = nil,
        fontFamily: String? = nil,
        fontGenericFamily: FontGenericFamily? = nil,
        fontStyle: FontStyle? = nil
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.edgeType = edgeType
        self.edgeColor = edgeColor
        self.windowType = windowType
        self.windowColor = windowColor
        self.windowRoundedCornerRadius = windowRoundedCornerRadius
        self.fontScale = fontScale
        self.fontFamily = fontFamily
        self.fontGenericFamily = fontGenericFamily
        self.fontStyle = fontStyle
    }
}

// MARK: - Media information

/// Describes a piece of media to load on the receiver.
public struct MediaInformation: Codable, Sendable, Hashable {
    /// Identifier of the content. For the Default Media Receiver this is the
    /// URL of the media unless ``contentURL`` is set.
    public var contentId: String
    /// URL of the media; takes precedence over ``contentId`` on modern receivers.
    public var contentURL: URL?
    public var streamType: StreamType
    /// MIME type, e.g. `video/mp4`, `application/x-mpegurl`.
    public var contentType: String
    public var metadata: MediaMetadata?
    /// Duration in seconds.
    public var duration: Double?
    public var tracks: [MediaTrack]?
    public var textTrackStyle: TextTrackStyle?
    public var hlsSegmentFormat: HLSSegmentFormat?
    public var hlsVideoSegmentFormat: HLSVideoSegmentFormat?
    public var entity: String?
    public var customData: JSONValue?

    public init(
        contentId: String,
        contentURL: URL? = nil,
        streamType: StreamType = .buffered,
        contentType: String,
        metadata: MediaMetadata? = nil,
        duration: Double? = nil,
        tracks: [MediaTrack]? = nil,
        textTrackStyle: TextTrackStyle? = nil,
        hlsSegmentFormat: HLSSegmentFormat? = nil,
        hlsVideoSegmentFormat: HLSVideoSegmentFormat? = nil,
        entity: String? = nil,
        customData: JSONValue? = nil
    ) {
        self.contentId = contentId
        self.contentURL = contentURL
        self.streamType = streamType
        self.contentType = contentType
        self.metadata = metadata
        self.duration = duration
        self.tracks = tracks
        self.textTrackStyle = textTrackStyle
        self.hlsSegmentFormat = hlsSegmentFormat
        self.hlsVideoSegmentFormat = hlsVideoSegmentFormat
        self.entity = entity
        self.customData = customData
    }

    /// Convenience initializer for media identified by URL.
    public init(
        url: URL,
        contentType: String,
        streamType: StreamType = .buffered,
        metadata: MediaMetadata? = nil,
        duration: Double? = nil,
        tracks: [MediaTrack]? = nil
    ) {
        self.init(
            contentId: url.absoluteString,
            contentURL: url,
            streamType: streamType,
            contentType: contentType,
            metadata: metadata,
            duration: duration,
            tracks: tracks
        )
    }

    enum CodingKeys: String, CodingKey {
        case contentId, contentURL = "contentUrl", streamType, contentType, metadata, duration, tracks
        case textTrackStyle, hlsSegmentFormat, hlsVideoSegmentFormat, entity, customData
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decodeIfPresent(String.self, forKey: .contentId) ?? ""
        contentURL = try? c.decodeIfPresent(URL.self, forKey: .contentURL)
        streamType = try c.decodeIfPresent(StreamType.self, forKey: .streamType) ?? .buffered
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        metadata = try? c.decodeIfPresent(MediaMetadata.self, forKey: .metadata)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        tracks = try? c.decodeIfPresent([MediaTrack].self, forKey: .tracks)
        textTrackStyle = try? c.decodeIfPresent(TextTrackStyle.self, forKey: .textTrackStyle)
        hlsSegmentFormat = try? c.decodeIfPresent(HLSSegmentFormat.self, forKey: .hlsSegmentFormat)
        hlsVideoSegmentFormat = try? c.decodeIfPresent(HLSVideoSegmentFormat.self, forKey: .hlsVideoSegmentFormat)
        entity = try? c.decodeIfPresent(String.self, forKey: .entity)
        customData = try? c.decodeIfPresent(JSONValue.self, forKey: .customData)
    }
}

// MARK: - Queue

/// An item in a media queue.
public struct QueueItem: Codable, Sendable, Hashable {
    /// Assigned by the receiver; leave `nil` when creating items.
    public var itemId: Int?
    public var media: MediaInformation?
    public var autoplay: Bool?
    /// Seconds from the start of the media to begin playback.
    public var startTime: Double?
    /// Seconds before the end of the previous item to start preloading.
    public var preloadTime: Double?
    public var activeTrackIds: [Int]?
    public var customData: JSONValue?

    public init(media: MediaInformation, autoplay: Bool = true, startTime: Double? = nil, preloadTime: Double? = nil, activeTrackIds: [Int]? = nil, customData: JSONValue? = nil) {
        self.media = media
        self.autoplay = autoplay
        self.startTime = startTime
        self.preloadTime = preloadTime
        self.activeTrackIds = activeTrackIds
        self.customData = customData
    }
}

// MARK: - Status

/// The status of a media session on the receiver.
public struct MediaStatus: Codable, Sendable, Hashable {
    public var mediaSessionId: Int
    public var playbackRate: Double?
    public var playerState: PlayerState
    public var idleReason: IdleReason?
    /// Playback position in seconds at the time the status was generated.
    public var currentTime: Double?
    public var supportedMediaCommands: SupportedMediaCommands?
    public var volume: CastVolume?
    /// Omitted by receivers when unchanged; ``MediaController`` fills it in
    /// from the most recent status that included it.
    public var media: MediaInformation?
    public var activeTrackIds: [Int]?
    public var currentItemId: Int?
    public var loadingItemId: Int?
    public var preloadedItemId: Int?
    public var items: [QueueItem]?
    public var repeatMode: RepeatMode?
    public var customData: JSONValue?

    public init(mediaSessionId: Int, playerState: PlayerState, currentTime: Double? = nil, playbackRate: Double? = nil, media: MediaInformation? = nil) {
        self.mediaSessionId = mediaSessionId
        self.playerState = playerState
        self.currentTime = currentTime
        self.playbackRate = playbackRate
        self.media = media
    }

    enum CodingKeys: String, CodingKey {
        case mediaSessionId, playbackRate, playerState, idleReason, currentTime, supportedMediaCommands, volume
        case media, activeTrackIds, currentItemId, loadingItemId, preloadedItemId, items, repeatMode, customData
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaSessionId = try c.decode(Int.self, forKey: .mediaSessionId)
        playerState = try c.decodeIfPresent(PlayerState.self, forKey: .playerState) ?? .idle
        playbackRate = try? c.decodeIfPresent(Double.self, forKey: .playbackRate)
        idleReason = try? c.decodeIfPresent(IdleReason.self, forKey: .idleReason)
        currentTime = try? c.decodeIfPresent(Double.self, forKey: .currentTime)
        supportedMediaCommands = try? c.decodeIfPresent(SupportedMediaCommands.self, forKey: .supportedMediaCommands)
        volume = try? c.decodeIfPresent(CastVolume.self, forKey: .volume)
        media = try? c.decodeIfPresent(MediaInformation.self, forKey: .media)
        activeTrackIds = try? c.decodeIfPresent([Int].self, forKey: .activeTrackIds)
        currentItemId = try? c.decodeIfPresent(Int.self, forKey: .currentItemId)
        loadingItemId = try? c.decodeIfPresent(Int.self, forKey: .loadingItemId)
        preloadedItemId = try? c.decodeIfPresent(Int.self, forKey: .preloadedItemId)
        items = try? c.decodeIfPresent([QueueItem].self, forKey: .items)
        repeatMode = try? c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode)
        customData = try? c.decodeIfPresent(JSONValue.self, forKey: .customData)
    }

    /// Whether playback has ended or never started.
    public var isIdle: Bool { playerState == .idle }

    /// Estimates the playback position `elapsed` seconds after this status
    /// was received, accounting for playback rate and player state.
    public func estimatedTime(after elapsed: TimeInterval) -> Double? {
        guard let currentTime else { return nil }
        guard playerState == .playing else { return currentTime }
        let estimate = currentTime + elapsed * (playbackRate ?? 1)
        if let duration = media?.duration, duration > 0, media?.streamType != .live {
            return min(max(0, estimate), duration)
        }
        return max(0, estimate)
    }
}
