import Foundation

/// A JSON value decoded leniently from an arbitrary router payload.
///
/// Router payloads evolve ahead of Cortex releases: a field can switch from a
/// number to a string, or gain a shape Cortex does not model yet. Decoding here
/// stays total — an exotic leaf becomes `.null` rather than failing the read and
/// hiding the whole item (contract honesty: an item must never be lost).
public enum RouterJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([RouterJSONValue])
    case object([String: RouterJSONValue])

    /// One-line human rendering for a detail row / tooltip: string as-is, number
    /// trimmed of a trailing ".0", bool "true"/"false", null blank, a non-scalar
    /// array as "[n]", and an object as its sorted "k=v, …" pairs.
    public var displayText: String {
        switch self {
        case .string(let text):
            text
        case .number(let value):
            {
                var text = String(value)
                if text.hasSuffix(".0") { text.removeLast(2) }
                return text
            }()
        case .bool(let flag):
            flag ? "true" : "false"
        case .null:
            ""
        case .array(let elements):
            "[\(elements.count)]"
        case .object(let fields):
            fields.keys.sorted()
                .map { "\($0)=\(fields[$0]?.displayText ?? "")" }
                .joined(separator: ", ")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Bool before number: Foundation never decodes a JSON number as Bool, so
        // `true` cannot be mistaken for 1 and `2` stays a number.
        if let flag = try? container.decode(Bool.self) { self = .bool(flag); return }
        if let text = try? container.decode(String.self) { self = .string(text); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let elements = try? container.decode([RouterJSONValue].self) { self = .array(elements); return }
        if let fields = try? container.decode([String: RouterJSONValue].self) { self = .object(fields); return }
        // A leaf shape the router adds later is unknown, not lost: `.null` keeps
        // the enclosing object decodable.
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let value): try container.encode(value)
        case .bool(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        case .array(let elements): try container.encode(elements)
        case .object(let fields): try container.encode(fields)
        }
    }
}

/// Router severity, ordered. `rank` puts the most urgent first so the feed can
/// sort on it without a second lookup table.
public enum RouterAttentionSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low

    /// 0 for `high`, 1 for `medium`, 2 for `low`.
    public var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }

    /// French display label.
    public var label: String {
        switch self {
        case .high: "haute"
        case .medium: "moyenne"
        case .low: "basse"
        }
    }

    /// An unrecognized severity ranks last (`.low`) rather than inventing an
    /// alarm the router never raised — the item itself is still surfaced.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RouterAttentionSeverity(rawValue: raw) ?? .low
    }
}

/// What the `llm-router attention` feed reports.
///
/// Unknown raw values are KEPT as `.unknown`, never dropped: a newer router that
/// adds a kind must not have its item silently disappear from Cortex.
public enum RouterAttentionKind: Sendable, Equatable, Hashable, Codable {
    case launchDivergence
    case accountReconnect
    case resultToValidate
    case receiptAwaited
    case unknown(String)

    /// The router's stable wire value (also the storage key).
    public var rawValue: String {
        switch self {
        case .launchDivergence: "launch_divergence"
        case .accountReconnect: "account_reconnect"
        case .resultToValidate: "result_to_validate"
        case .receiptAwaited: "receipt_awaited"
        case .unknown(let raw): raw
        }
    }

    /// French display label, e.g. "divergence de lancement".
    public var label: String {
        switch self {
        case .launchDivergence: "divergence de lancement"
        case .accountReconnect: "reconnexion de compte"
        case .resultToValidate: "résultat à valider"
        case .receiptAwaited: "reçu attendu"
        case .unknown(let raw): raw
        }
    }

    /// One honest sentence about what the item means, in the router's own terms:
    /// a rc=0 validates nothing, and a requested binding is not an observed one.
    public var summary: String {
        switch self {
        case .launchDivergence:
            "Ce qui a été lancé ne correspond pas à la recommandation : une décision est attendue."
        case .accountReconnect:
            "Le compte doit être reconnecté pour redevenir routable."
        case .resultToValidate:
            "Un code de sortie 0 ne valide rien : le résultat doit être évalué explicitement."
        case .receiptAwaited:
            "Un reçu attendu n'est pas un reçu observé : une liaison demandée ne prouve pas l'exécution."
        case .unknown:
            "Type d'attention inconnu de cette version de Cortex : affiché tel quel."
        }
    }

    /// True for the two kinds that need a human decision.
    public var isDecision: Bool {
        switch self {
        case .launchDivergence, .resultToValidate: true
        case .accountReconnect, .receiptAwaited, .unknown: false
        }
    }

    /// `nil` only for an empty raw value; anything else becomes `.unknown`.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        switch rawValue {
        case "launch_divergence": self = .launchDivergence
        case "account_reconnect": self = .accountReconnect
        case "result_to_validate": self = .resultToValidate
        case "receipt_awaited": self = .receiptAwaited
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RouterAttentionKind(rawValue: raw) ?? .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One row of the `llm-router attention` feed.
///
/// `requested` vs `observed` is the router's own honesty split: what was asked
/// for is not what ran. Cortex keeps both so a divergence is shown, not inferred.
public struct RouterAttentionItem: Codable, Sendable, Equatable, Identifiable {
    public let kind: RouterAttentionKind
    public let severity: RouterAttentionSeverity
    public let missionId: String?
    public let accountId: String?
    public let provider: String?
    public let model: String?
    public let detail: String
    public let requested: [String: RouterJSONValue]
    public let observed: [String: RouterJSONValue]

    /// Stable, unique row identity.
    ///
    /// One mission legitimately appears several times in the same feed: e.g.
    /// `launch_divergence`, `result_to_validate` and `receipt_awaited` all key on
    /// the same `mission_id`. Keying the identity on the mission alone therefore
    /// collides and hands `ForEach` duplicate ids (undefined diffing). So the
    /// `kind` is always part of the identity, and for `account_reconnect` the
    /// provider is too (the same account id can be reported once per provider).
    ///
    /// The identity is derived ONLY from stable payload fields (kind, provider,
    /// mission/account id, detail) — never a list index and never a random UUID —
    /// so the same row keeps the same id across refreshes and the list does not
    /// jump.
    public var id: String {
        let anchor = missionId ?? accountId ?? detail
        if kind == .accountReconnect {
            // A reconnect row has no mission; the account alone is ambiguous
            // across providers, so the provider qualifies it.
            return "\(kind.rawValue):\(provider ?? ""):\(anchor)"
        }
        return "\(kind.rawValue):\(anchor)"
    }

    /// missionId ?? accountId — what the row is about.
    public var target: String? {
        missionId ?? accountId
    }

    /// Cortex id for `provider`, nil when unmapped (never a guessed identity,
    /// RouterProviderIdMap).
    public var cortexProviderId: String? {
        provider.flatMap(RouterProviderIdMap.cortexId(forRouter:))
    }

    public init(
        kind: RouterAttentionKind,
        severity: RouterAttentionSeverity,
        missionId: String? = nil,
        accountId: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        detail: String,
        requested: [String: RouterJSONValue] = [:],
        observed: [String: RouterJSONValue] = [:]
    ) {
        self.kind = kind
        self.severity = severity
        self.missionId = missionId
        self.accountId = accountId
        self.provider = provider
        self.model = model
        self.detail = detail
        self.requested = requested
        self.observed = observed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `kind` and `detail` are the two fields that make a row meaningful; a
        // malformed other field is nil-ed, never allowed to fail the decode.
        let rawKind = try container.decode(String.self, forKey: .kind)
        kind = RouterAttentionKind(rawValue: rawKind) ?? .unknown(rawKind)
        severity = (try? container.decode(RouterAttentionSeverity.self, forKey: .severity)) ?? .low
        missionId = try? container.decodeIfPresent(String.self, forKey: .missionId)
        accountId = try? container.decodeIfPresent(String.self, forKey: .accountId)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        detail = try container.decode(String.self, forKey: .detail)
        requested = (try? container.decodeIfPresent([String: RouterJSONValue].self, forKey: .requested)) ?? [:]
        observed = (try? container.decodeIfPresent([String: RouterJSONValue].self, forKey: .observed)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(missionId, forKey: .missionId)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(detail, forKey: .detail)
        try container.encode(requested, forKey: .requested)
        try container.encode(observed, forKey: .observed)
    }

    enum CodingKeys: String, CodingKey {
        case kind, severity, provider, model, detail, requested, observed
        case missionId = "mission_id"
        case accountId = "account_id"
    }
}

fileprivate extension RouterAttentionItem {
    /// Decodes one raw item, salvaging a row whose strict decode failed as long
    /// as it still carries a `kind` — the one field that identifies it. Every
    /// other field falls back to nil/empty so a single malformed value can never
    /// drop an item from the feed.
    static func decodeLenient(_ raw: RouterJSONValue) -> RouterAttentionItem? {
        guard case .object(let fields) = raw else { return nil }
        if let data = try? JSONEncoder().encode(raw),
           let item = try? JSONDecoder().decode(RouterAttentionItem.self, from: data) {
            return item
        }
        guard case .string(let rawKind)? = fields["kind"] else { return nil }
        let kind = RouterAttentionKind(rawValue: rawKind) ?? .unknown(rawKind)
        let severity = fields["severity"]?.stringValue
            .flatMap(RouterAttentionSeverity.init(rawValue:)) ?? .low
        return RouterAttentionItem(
            kind: kind,
            severity: severity,
            missionId: fields["mission_id"]?.stringValue,
            accountId: fields["account_id"]?.stringValue,
            provider: fields["provider"]?.stringValue,
            model: fields["model"]?.stringValue,
            detail: fields["detail"]?.displayText ?? "",
            requested: fields["requested"]?.objectValue ?? [:],
            observed: fields["observed"]?.objectValue ?? [:]
        )
    }
}

/// The whole feed: `{"count": N, "items": [...]}`.
public struct RouterAttentionFeed: Codable, Sendable, Equatable {
    public let items: [RouterAttentionItem]
    /// The router's own declared `count` when the envelope carried one, `nil`
    /// when it did not (never invented).
    public let declaredCount: Int?
    /// How many item objects the router's `items` array held BEFORE lenient
    /// decoding. Always `>= items.count`; the difference is what decoding dropped.
    public let rawItemCount: Int

    /// The router's own count when present, else the decoded count. Crucially
    /// this is never zeroed just because decoding dropped every item: a protocol
    /// drift that announces items but yields none keeps the router's own number,
    /// so the view cannot dress it as the honest "rien à traiter" zero.
    public var count: Int { declaredCount ?? items.count }

    /// Announced rows that did not survive decoding. `> 0` means the feed is
    /// partial (or wholly unreadable) and must NOT be rendered as a clean empty.
    public var droppedCount: Int {
        max(0, (declaredCount ?? rawItemCount) - items.count)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Items where `kind.isDecision` — the ones a human must look at.
    public var decisionCount: Int {
        items.filter { $0.kind.isDecision }.count
    }

    /// The most urgent severity present, nil when the feed is empty.
    public var highestSeverity: RouterAttentionSeverity? {
        items.map(\.severity).min { $0.rank < $1.rank }
    }

    public init(items: [RouterAttentionItem], count: Int? = nil) {
        self.items = items
        self.declaredCount = count
        self.rawItemCount = items.count
    }

    /// Stable ordering: severity rank ascending (high first), then id, so the
    /// list does not jump around between refreshes.
    public static func sorted(_ items: [RouterAttentionItem]) -> [RouterAttentionItem] {
        items.sorted { lhs, rhs in
            lhs.severity.rank != rhs.severity.rank
                ? lhs.severity.rank < rhs.severity.rank
                : lhs.id < rhs.id
        }
    }

    /// Decodes the `{"count": …, "items": […]}` envelope. A successful read with
    /// no items yields an empty feed with `count == 0`.
    public static func parse(_ data: Data) throws -> RouterAttentionFeed {
        try JSONDecoder().decode(RouterAttentionFeed.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawItems = (try? container.decodeIfPresent([RouterJSONValue].self, forKey: .items)) ?? []
        self.items = rawItems.compactMap(RouterAttentionItem.decodeLenient)
        self.rawItemCount = rawItems.count
        // Preserve the router's declared count even when every item failed to
        // decode, so a protocol drift is distinguishable from a genuine empty.
        self.declaredCount = Self.declaredCount(in: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(items, forKey: .items)
    }

    /// The router's declared count, accepting a bare number or a numeric string.
    /// A non-finite or out-of-`Int`-range number is treated as absent rather than
    /// trapped on (`Int(value)` traps outside `Int`'s range).
    private static func declaredCount(in container: KeyedDecodingContainer<CodingKeys>) -> Int? {
        switch try? container.decodeIfPresent(RouterJSONValue.self, forKey: .count) {
        case .number(let value)?:
            guard value.isFinite, value.magnitude <= 9_007_199_254_740_992.0 else { return nil }
            return Int(value)
        case .string(let text)?:
            return Int(text)
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case count, items
    }
}

/// The `llm-router mission inspect <id>` chain: recommandé → exécuté → vérifié.
///
/// The booleans at the bottom are the whole point: a recommendation that was
/// never executed, and a process that exited without an evaluation, are surfaced
/// as gaps rather than folded into a success.
public struct MissionInspection: Codable, Sendable, Equatable {
    public struct Recommendation: Codable, Sendable, Equatable {
        public let provider: String?
        public let model: String?
        public let score: Double?
        public let account: [String: RouterJSONValue]?
        public let reasons: [String]

        init(
            provider: String? = nil,
            model: String? = nil,
            score: Double? = nil,
            account: [String: RouterJSONValue]? = nil,
            reasons: [String] = []
        ) {
            self.provider = provider
            self.model = model
            self.score = score
            self.account = account
            self.reasons = reasons
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
            score = try? container.decodeIfPresent(Double.self, forKey: .score)
            account = try? container.decodeIfPresent([String: RouterJSONValue].self, forKey: .account)
            reasons = (try? container.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case provider, model, score, account, reasons
        }
    }

    /// Verified is NOT "the process exited": only an explicit evaluation counts.
    public enum ReceiptState: Sendable, Equatable {
        case confirmed
        case unconfirmed
        case divergent
        case unknown

        /// Maps `receipt_state`; any unrecognized or absent value is `.unknown`.
        init(routerValue raw: String?) {
            switch raw {
            case "confirmed": self = .confirmed
            case "unconfirmed": self = .unconfirmed
            case "divergent": self = .divergent
            default: self = .unknown
            }
        }

        /// The router wire value, for the encode side of `Codable`.
        var wireValue: String {
            switch self {
            case .confirmed: "confirmed"
            case .unconfirmed: "unconfirmed"
            case .divergent: "divergent"
            case .unknown: "unknown"
            }
        }
    }

    public struct ResultStage: Codable, Sendable, Equatable {
        public let resultState: String
        public let success: Bool?
        public let closed: Bool
        public let processNotes: String?

        public var isVerified: Bool { success == true }
        public var isFailed: Bool { success == false }
        /// True when the mission is closed but no evaluation exists — the honest
        /// gap the UI must show instead of a green tick.
        public var isUnverifiedClose: Bool { closed && success == nil }

        init(
            resultState: String = "",
            success: Bool? = nil,
            closed: Bool = false,
            processNotes: String? = nil
        ) {
            self.resultState = resultState
            self.success = success
            self.closed = closed
            self.processNotes = processNotes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resultState = (try? container.decodeIfPresent(String.self, forKey: .resultState)) ?? ""
            success = Self.success(in: container)
            closed = (try? container.decodeIfPresent(Bool.self, forKey: .closed)) ?? false
            processNotes = try? container.decodeIfPresent(String.self, forKey: .processNotes)
        }

        /// The router emits `success` as `0`/`1` or null, never a bool; accept
        /// int and bool so the evaluated / never-evaluated split survives.
        private static func success(in container: KeyedDecodingContainer<CodingKeys>) -> Bool? {
            if let flag = try? container.decodeIfPresent(Bool.self, forKey: .success) { return flag }
            if let value = try? container.decodeIfPresent(Int.self, forKey: .success) { return value != 0 }
            if let value = try? container.decodeIfPresent(Double.self, forKey: .success) { return value != 0 }
            return nil
        }

        enum CodingKeys: String, CodingKey {
            case success, closed
            case resultState = "result_state"
            case processNotes = "process_notes"
        }
    }

    public struct Metrics: Codable, Sendable, Equatable {
        public let durationSeconds: Double?
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let testsPassed: Double?
        public let estimatedCost: Double?

        /// True only when the router reported no metric at all.
        public var isEmpty: Bool {
            durationSeconds == nil && inputTokens == nil && outputTokens == nil
                && testsPassed == nil && estimatedCost == nil
        }

        init(
            durationSeconds: Double? = nil,
            inputTokens: Double? = nil,
            outputTokens: Double? = nil,
            testsPassed: Double? = nil,
            estimatedCost: Double? = nil
        ) {
            self.durationSeconds = durationSeconds
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.testsPassed = testsPassed
            self.estimatedCost = estimatedCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            durationSeconds = try? container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            inputTokens = try? container.decodeIfPresent(Double.self, forKey: .inputTokens)
            outputTokens = try? container.decodeIfPresent(Double.self, forKey: .outputTokens)
            testsPassed = try? container.decodeIfPresent(Double.self, forKey: .testsPassed)
            estimatedCost = try? container.decodeIfPresent(Double.self, forKey: .estimatedCost)
        }

        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_s"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case testsPassed = "tests_passed"
            case estimatedCost = "estimated_cost"
        }
    }

    public let missionId: String
    public let recommended: Recommendation
    public let requested: [String: RouterJSONValue]
    public let observed: [String: RouterJSONValue]
    public let receiptState: ReceiptState
    public let divergence: String?
    public let result: ResultStage
    public let metrics: Metrics

    /// Cortex id for the recommended provider, nil when unmapped.
    public var cortexProviderId: String? {
        recommended.provider.flatMap(RouterProviderIdMap.cortexId(forRouter:))
    }

    /// The three honesty booleans the UI drives its chips from.
    /// A recommendation is "known" when the router named a provider or a model.
    public var hasRecommendation: Bool {
        recommended.provider != nil || recommended.model != nil
    }

    public var isExecutionConfirmed: Bool { receiptState == .confirmed }

    public var isVerified: Bool { result.isVerified }

    init(
        missionId: String = "",
        recommended: Recommendation = Recommendation(),
        requested: [String: RouterJSONValue] = [:],
        observed: [String: RouterJSONValue] = [:],
        receiptState: ReceiptState = .unknown,
        divergence: String? = nil,
        result: ResultStage = ResultStage(),
        metrics: Metrics = Metrics()
    ) {
        self.missionId = missionId
        self.recommended = recommended
        self.requested = requested
        self.observed = observed
        self.receiptState = receiptState
        self.divergence = divergence
        self.result = result
        self.metrics = metrics
    }

    /// Decodes the `mission_view` dict. Never throws on a missing optional field:
    /// an absent stage is an honest gap, not a decode failure.
    public static func parse(_ data: Data) throws -> MissionInspection {
        try JSONDecoder().decode(MissionInspection.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        missionId = (try? container.decodeIfPresent(String.self, forKey: .missionId)) ?? ""
        recommended = (try? container.decodeIfPresent(Recommendation.self, forKey: .recommended)) ?? Recommendation()
        requested = (try? container.decodeIfPresent([String: RouterJSONValue].self, forKey: .requested)) ?? [:]
        observed = (try? container.decodeIfPresent([String: RouterJSONValue].self, forKey: .observed)) ?? [:]
        receiptState = ReceiptState(routerValue: try? container.decodeIfPresent(String.self, forKey: .receiptState))
        divergence = try? container.decodeIfPresent(String.self, forKey: .divergence)
        result = (try? container.decodeIfPresent(ResultStage.self, forKey: .result)) ?? ResultStage()
        metrics = (try? container.decodeIfPresent(Metrics.self, forKey: .metrics)) ?? Metrics()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(missionId, forKey: .missionId)
        try container.encode(recommended, forKey: .recommended)
        try container.encode(requested, forKey: .requested)
        try container.encode(observed, forKey: .observed)
        try container.encode(receiptState.wireValue, forKey: .receiptState)
        try container.encodeIfPresent(divergence, forKey: .divergence)
        try container.encode(result, forKey: .result)
        try container.encode(metrics, forKey: .metrics)
    }

    enum CodingKeys: String, CodingKey {
        case recommended, requested, observed, divergence, result, metrics
        case missionId = "mission_id"
        case receiptState = "receipt_state"
    }
}

fileprivate extension RouterJSONValue {
    /// The string payload, nil for any other case.
    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The object payload, nil for any other case.
    var objectValue: [String: RouterJSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
