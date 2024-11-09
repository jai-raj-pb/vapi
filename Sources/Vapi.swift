import Combine
import Daily
import Foundation

// Define the nested message structure
struct VapiMessageContent: Encodable {
    public let role: String
    public let content: String
}

// Define the top-level app message structure
public struct VapiMessage: Encodable {
    public let type: String
    let message: VapiMessageContent

    public init(type: String, role: String, content: String) {
        self.type = type
        self.message = VapiMessageContent(role: role, content: content)
    }
}

public final class Vapi: CallClientDelegate {
    
    // MARK: - Supporting Types
    
    /// A configuration that contains the host URL and the client token.
    ///
    /// This configuration is serializable via `Codable`.
    public struct Configuration: Codable, Hashable, Sendable {
        public var host: String
        public var publicKey: String
        fileprivate static let defaultHost = "api.vapi.ai"
        
        init(publicKey: String, host: String) {
            self.host = host
            self.publicKey = publicKey
        }
    }

    public enum Event {
        case callDidStart
        case callDidEnd
        case transcript(Transcript)
        case functionCall(FunctionCall)
        case speechUpdate(SpeechUpdate)
        case metadata(Metadata)
        case conversationUpdate(ConversationUpdate)
        case hang
        case error(Swift.Error)
        case participantJoined(Participant)
        case participantLeft(Participant)
    }
    
    // MARK: - Properties

    public let configuration: Configuration

    fileprivate let eventSubject = PassthroughSubject<Event, Never>()
    
    private let networkManager = NetworkManager()
    public private(set) var call: CallClient?
    
    // MARK: - Computed Properties
    
    private var publicKey: String {
        configuration.publicKey
    }
    
    /// A Combine publisher that clients can subscribe to for API events.
    public var eventPublisher: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    @MainActor public var localAudioLevel: Float? {
        call?.localAudioLevel
    }
    
    @MainActor public var remoteAudioLevel: Float? {
        call?.remoteParticipantsAudioLevel.values.first
    }
    
    @MainActor public var audioDeviceType: AudioDeviceType? {
        call?.audioDevice
    }
    
    // MARK: - Init
    
    public init(configuration: Configuration) {
        self.configuration = configuration
        
        Task { @MainActor in
            do {
                call = CallClient()
                call?.delegate = self
                call?.setInputsEnabled([
                    .camera: true,
                    .microphone: true
                ], completion: nil)
            }
        }
        
        Daily.setLogLevel(.off)
    }
    
    public convenience init(publicKey: String) {
        self.init(configuration: .init(publicKey: publicKey, host: Configuration.defaultHost))
    }
    
    public convenience init(publicKey: String, host: String? = nil) {
        self.init(configuration: .init(publicKey: publicKey, host: host ?? Configuration.defaultHost))
    }
    
    // MARK: - Instance Methods
    
    public func start(
        assistantId: String, metadata: [String: Any] = [:], assistantOverrides: [String: Any] = [:]
    ) async throws -> WebCallResponse {
        guard call != nil else {
            throw VapiError.customError("call not initialized")
        }
        guard await self.call?.callState != .joined else {
            throw VapiError.existingCallInProgress
        }
        
        let body = [
            "assistantId": assistantId, "metadata": metadata, "assistantOverrides": assistantOverrides
        ] as [String: Any]
        
        return try await self.startCall(body: body)
    }
    
    public func start(
        assistant: [String: Any], metadata: [String: Any] = [:], assistantOverrides: [String: Any] = [:]
    ) async throws -> WebCallResponse {
        guard call != nil else {
            throw VapiError.customError("call not initialized")
        }
        guard await self.call?.callState != .joined else {
            throw VapiError.existingCallInProgress
        }
        
        let body = [
            "assistant": assistant, "metadata": metadata, "assistantOverrides": assistantOverrides
        ] as [String: Any]

        return try await self.startCall(body: body)
    }
    
    public func stop() {
        Task {
            do {
                try await call?.leave()
            } catch {
                self.callDidFail(with: error)
            }
        }
    }

    public func send(message: VapiMessage) async throws {
        do {
          // Use JSONEncoder to convert the message to JSON Data
          let jsonData = try JSONEncoder().encode(message)
          
          // Debugging: Print the JSON data to verify its format (optional)
          if let jsonString = String(data: jsonData, encoding: .utf8) {
              print(jsonString)
          }
          
          // Send the JSON data to all targets
          try await self.call?.sendAppMessage(json: jsonData, to: .all)
      } catch {
          // Handle encoding error
          print("Error encoding message to JSON: \(error)")
          throw error // Re-throw the error to be handled by the caller
      }
    }
    
    private var isMicrophoneMuted: Bool = false

    public func setMuted(_ muted: Bool) async throws {
        guard let call else { return }
        guard await call.callState == .joined else {
            throw VapiError.noCallInProgress
        }
        
        do {
            try await call.setInputEnabled(.microphone, !muted)
            self.isMicrophoneMuted = muted
            if muted {
                print("Audio muted")
            } else {
                print("Audio unmuted")
            }
        } catch {
            print("Failed to set mute state: \(error)")
            throw error
        }
    }

    public func isMuted() async throws {
        guard let call else { return }
        guard await call.callState == .joined else {
            throw VapiError.noCallInProgress
        }
        
        let shouldBeMuted = !self.isMicrophoneMuted
        
        do {
            try await call.setInputEnabled(.microphone, !shouldBeMuted)
            self.isMicrophoneMuted = shouldBeMuted
            if shouldBeMuted {
                print("Audio muted")
            } else {
                print("Audio unmuted")
            }
        } catch {
            print("Failed to toggle mute state: \(error)")
            throw error
        }
    }
    
    /// This method sets the `AudioDeviceType` of the current called to the passed one if it's not the same as the current one
    /// - Parameter audioDeviceType: can either be `bluetooth`, `speakerphone`, `wired` or `earpiece`
    public func setAudioDeviceType(_ audioDeviceType: AudioDeviceType) async throws {
        guard let call else { return }
        guard await call.callState == .joined else {
            throw VapiError.noCallInProgress
        }
        
        guard await self.audioDeviceType != audioDeviceType else {
            print("Not updating AudioDeviceType because it is the same")
            return
        }
        
        do {
            try await call.setPreferredAudioDevice(audioDeviceType)
        } catch {
            print("Failed to change the AudioDeviceType with error: \(error)")
        }
    }

    private func joinCall(url: URL, recordVideo: Bool) {
        Task { @MainActor in
            do {
                guard let call else { return }
                guard call.callState != .joined || call.callState != .joining else {
                    throw VapiError.existingCallInProgress
                }
                
                _ = try await call.join(
                    url: url,
                    settings: .init(
                        inputs: .set(
                            camera: .set(.enabled(recordVideo)),
                            microphone: .set(.enabled(true))
                        )
                    )
                )
                
                if(!recordVideo) {
                    return
                }
                    
                _ = try await call.startRecording(
                    streamingSettings: .init(
                        video: .init(
                            width:1280,
                            height:720,
                            backgroundColor: "#FF1F2D3D"
                        )
                    )
                )
            } catch {
                callDidFail(with: error)
            }
        }
    }
    
    private func makeURL(for path: String) -> URL? {
        var components = URLComponents()
        // Check if the host is localhost, set the scheme to http and port to 3001; otherwise, set the scheme to https
        if configuration.host == "localhost" {
            components.scheme = "http"
            components.port = 3001
        } else {
            components.scheme = "https"
        }
        components.host = configuration.host
        components.path = path
        return components.url
    }
    
    private func makeURLRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    private func startCall(body: [String: Any]) async throws -> WebCallResponse {
        guard let url = makeURL(for: "/call/web") else {
            callDidFail(with: VapiError.invalidURL)
            throw VapiError.customError("Unable to create web call")
        }
        
        var request = makeURLRequest(for: url)
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            self.callDidFail(with: error)
            throw VapiError.customError(error.localizedDescription)
        }
        
        do {
            let response: WebCallResponse = try await networkManager.perform(request: request)
            let isVideoRecordingEnabled = response.artifactPlan?.videoRecordingEnabled ?? false
            joinCall(url: response.webCallUrl, recordVideo: isVideoRecordingEnabled)
            return response
        } catch {
            callDidFail(with: error)
            throw VapiError.customError(error.localizedDescription)
        }
    }
    
    private func unescapeAppMessage(_ jsonData: Data) -> (Data, String?) {
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            return (jsonData, nil)
        }

        // Remove the leading and trailing double quotes
        let trimmedString = jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // Replace escaped backslashes
        let unescapedString = trimmedString.replacingOccurrences(of: "\\\\", with: "\\")
        // Replace escaped double quotes
        let unescapedJSON = unescapedString.replacingOccurrences(of: "\\\"", with: "\"")

        let unescapedData = unescapedJSON.data(using: .utf8) ?? jsonData

        return (unescapedData, unescapedJSON)
    }
    
    public func startLocalAudioLevelObserver() async throws {
        do {
            try await call?.startLocalAudioLevelObserver()
        } catch {
            throw error
        }
    }
    
    public func startRemoteParticipantsAudioLevelObserver() async throws {
        do {
            try await call?.startRemoteParticipantsAudioLevelObserver()
        } catch {
            throw error
        }
    }
    
    // MARK: - CallClientDelegate
    
    func callDidJoin() {
        print("Successfully joined call.")
        // Note: the call start event will be sent once the assistant has joined and is listening
    }
    
    func callDidLeave() {
        print("Successfully left call.")
        
        self.eventSubject.send(.callDidEnd)
        self.call = nil
    }
    
    func callDidFail(with error: Swift.Error) {
        print("Got error while joining/leaving call: \(error).")
        
        self.eventSubject.send(.error(error))
        self.call = nil
    }
    
    public func callClient(_ callClient: CallClient, participantJoined participant: Participant) {
        eventSubject.send(.participantJoined(participant))
    }
    
    public func callClient(_ callClient: CallClient, participantLeft participant: Participant, withReason reason: ParticipantLeftReason) {
        eventSubject.send(.participantLeft(participant))
    }
    
    public func callClient(_ callClient: CallClient, participantUpdated participant: Participant) {
        let isPlayable = participant.media?.microphone.state == Daily.MediaState.playable
        let isVapiSpeaker = participant.info.username == "Vapi Speaker"
        let shouldSendAppMessage = isPlayable && isVapiSpeaker
        
        guard shouldSendAppMessage else {
            return
        }
        
        do {
            let message: [String: Any] = ["message": "playable"]
            let jsonData = try JSONSerialization.data(withJSONObject: message, options: [])
            
            Task {
                try await call?.sendAppMessage(json: jsonData, to: .all)
            }
        } catch {
            print("Error sending message: \(error.localizedDescription)")
        }
    }
    
    public func callClient(_ callClient: CallClient, callStateUpdated state: CallState) {
        switch (state) {
        case CallState.left:
            self.callDidLeave()
            break
        case CallState.joined:
            self.callDidJoin()
            break
        default:
            break
        }
    }
    
    public func callClient(_ callClient: Daily.CallClient, appMessageAsJson jsonData: Data, from participantID: Daily.ParticipantID) {
        do {
            let (unescapedData, unescapedString) = unescapeAppMessage(jsonData)
            
            // Detect listening message first since it's a string rather than JSON
            guard unescapedString != "listening" else {
                eventSubject.send(.callDidStart)
                return
            }
            
            // Parse the JSON data generically to determine the type of event
            let decoder = JSONDecoder()
            let appMessage = try decoder.decode(AppMessage.self, from: unescapedData)
            // Parse the JSON data again, this time using the specific type
            let event: Event
            switch appMessage.type {
            case .functionCall:
                guard let messageDictionary = try JSONSerialization.jsonObject(with: unescapedData, options: []) as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message isn't a valid JSON object")
                }
                
                guard let functionCallDictionary = messageDictionary["functionCall"] as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message missing functionCall")
                }
                
                guard let name = functionCallDictionary[FunctionCall.CodingKeys.name.stringValue] as? String else {
                    throw VapiError.decodingError(message: "App message missing name")
                }
                
                guard let parameters = functionCallDictionary[FunctionCall.CodingKeys.parameters.stringValue] as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message missing parameters")
                }
                
                
                let functionCall = FunctionCall(name: name, parameters: parameters)
                event = Event.functionCall(functionCall)
            case .hang:
                event = Event.hang
            case .transcript:
                let transcript = try decoder.decode(Transcript.self, from: unescapedData)
                event = Event.transcript(transcript)
            case .speechUpdate:
                let speechUpdate = try decoder.decode(SpeechUpdate.self, from: unescapedData)
                event = Event.speechUpdate(speechUpdate)
            case .metadata:
                let metadata = try decoder.decode(Metadata.self, from: unescapedData)
                event = Event.metadata(metadata)
            case .conversationUpdate:
                let conv = try decoder.decode(ConversationUpdate.self, from: unescapedData)
                event = Event.conversationUpdate(conv)
            }
            eventSubject.send(event)
        } catch {
            let messageText = String(data: jsonData, encoding: .utf8)
            print("Error parsing app message \"\(messageText ?? "")\": \(error.localizedDescription)")
        }
    }
}
