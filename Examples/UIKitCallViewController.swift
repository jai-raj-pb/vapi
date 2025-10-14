import UIKit
import Vapi
import Combine

class CallViewController: UIViewController {
    private var vapi: Vapi?
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupVapi()
    }

    private func setupVapi() {
        vapi = Vapi(publicKey: "your_public_key", callMode: .video)
        
        vapi?.eventPublisher.sink { [weak self] event in
            switch event {
            case .callDidStart:
                self?.updateUIForCallStart()
            case .callDidEnd:
                self?.updateUIForCallEnd()
            default:
                break
            }
        }.store(in: &cancellables)
    }
    
    private func setupVapiAudioOnly() {
        vapi = Vapi(publicKey: "your_public_key", callMode: .audio)
        
        vapi?.eventPublisher.sink { [weak self] event in
            switch event {
            case .callDidStart:
                self?.updateUIForCallStart()
            case .callDidEnd:
                self?.updateUIForCallEnd()
            default:
                break
            }
        }.store(in: &cancellables)
    }

    @IBAction func startCallPressed(_ sender: UIButton) {
        Task {
            do {
                try await vapi?.start(assistantId: "your_assistant_id")
            } catch {
                print("Error starting call: \(error)")
            }
        }
    }

    @IBAction func stopCallPressed(_ sender: UIButton) {
        vapi?.stop { }
    }

    private func updateUIForCallStart() {
        // Update UI to show call has started
    }

    private func updateUIForCallEnd() {
        // Update UI to show call has ended
    }
}
