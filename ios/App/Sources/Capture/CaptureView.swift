import ARKit
import SwiftUI
import UIKit

struct CaptureView: UIViewControllerRepresentable {
    var onCaptured: (CaptureSessionPackage) -> Void

    func makeUIViewController(context: Context) -> CaptureViewController {
        CaptureViewController(onCaptured: onCaptured)
    }

    func updateUIViewController(_ uiViewController: CaptureViewController, context: Context) {}
}

final class CaptureViewController: UIViewController {
    private let sceneView = ARSCNView(frame: .zero)
    private let coachingOverlay = ARCoachingOverlayView()
    private let recordButton = CameraRecordButton()
    private let closeButton = UIButton(type: .system)
    private let recorder = GSScanRecorder()
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private let onCaptured: (CaptureSessionPackage) -> Void

    private var isRecording = false
    private var isFinishing = false

    init(onCaptured: @escaping (CaptureSessionPackage) -> Void) {
        self.onCaptured = onCaptured
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = [.all]
        extendedLayoutIncludesOpaqueBars = true
        view.backgroundColor = .black
        view.clipsToBounds = true
        configureSceneView()
        configureControls()
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        [.top, .bottom]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startARSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sceneView.frame = fourByThreeAspectFillFrame(in: view.bounds)
        coachingOverlay.frame = view.bounds
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(recordButton)
    }

    private func configureSceneView() {
        sceneView.automaticallyUpdatesLighting = true
        sceneView.session.delegate = self
        view.addSubview(sceneView)

        coachingOverlay.session = sceneView.session
        coachingOverlay.goal = .tracking
        coachingOverlay.activatesAutomatically = true
        view.addSubview(coachingOverlay)
    }

    private func fourByThreeAspectFillFrame(in bounds: CGRect) -> CGRect {
        let ratio: CGFloat = bounds.width <= bounds.height ? 3.0 / 4.0 : 4.0 / 3.0
        var width = bounds.width
        var height = width / ratio

        if height < bounds.height {
            height = bounds.height
            width = height * ratio
        }

        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func configureControls() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = "Close capture"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.accessibilityLabel = "Start recording"
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        view.addSubview(closeButton)
        view.addSubview(recordButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            recordButton.widthAnchor.constraint(equalToConstant: 72),
            recordButton.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func startARSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            recordButton.isEnabled = false
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.videoFormat = Self.preferredFourByThreeVideoFormat()

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private static func preferredFourByThreeVideoFormat() -> ARConfiguration.VideoFormat {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        return formats.min { lhs, rhs in
            let lSize = lhs.imageResolution
            let rSize = rhs.imageResolution
            let lAspect = abs(Double(lSize.width) / Double(lSize.height) - 4.0 / 3.0)
            let rAspect = abs(Double(rSize.width) / Double(rSize.height) - 4.0 / 3.0)
            if abs(lAspect - rAspect) > 0.001 {
                return lAspect < rAspect
            }
            if lhs.framesPerSecond != rhs.framesPerSecond {
                return lhs.framesPerSecond > rhs.framesPerSecond
            }
            return lSize.width * lSize.height > rSize.width * rSize.height
        } ?? ARWorldTrackingConfiguration.supportedVideoFormats[0]
    }

    @objc private func recordTapped() {
        guard !isFinishing else { return }
        isRecording ? finishCapture() : beginCapture()
    }

    @objc private func closeTapped() {
        if isRecording {
            finishCapture()
        } else {
            dismiss(animated: true)
        }
    }

    private func beginCapture() {
        do {
            try recorder.begin()
            isRecording = true
            haptics.prepare()
            recordButton.accessibilityLabel = "Stop recording"
            recordButton.setRecording(true, animated: true)
        } catch {
            recordButton.isEnabled = true
        }
    }

    private func finishCapture() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        recordButton.isEnabled = false
        recordButton.setRecording(false, animated: true)

        do {
            let package = try recorder.finish()
            isFinishing = false
            onCaptured(package)
        } catch {
            isFinishing = false
            recordButton.isEnabled = true
            recordButton.setRecording(true, animated: true)
        }
    }
}

private final class CameraRecordButton: UIControl {
    private let outerRing = UIView()
    private let innerShape = UIView()
    private var isRecording = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        outerRing.isUserInteractionEnabled = false
        outerRing.backgroundColor = .clear
        outerRing.layer.borderColor = UIColor.white.cgColor
        outerRing.layer.borderWidth = 6
        addSubview(outerRing)

        innerShape.isUserInteractionEnabled = false
        innerShape.backgroundColor = .systemRed
        addSubview(innerShape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outerRing.frame = bounds
        outerRing.layer.cornerRadius = bounds.width / 2
        layoutInnerShape()
    }

    func setRecording(_ recording: Bool, animated: Bool) {
        isRecording = recording
        let updates = { self.layoutInnerShape() }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut], animations: updates)
        } else {
            updates()
        }
    }

    private func layoutInnerShape() {
        let size = isRecording ? bounds.width * 0.34 : bounds.width * 0.68
        innerShape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        innerShape.center = CGPoint(x: bounds.midX, y: bounds.midY)
        innerShape.layer.cornerRadius = isRecording ? 5 : size / 2
    }
}

extension CaptureViewController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, !isFinishing else { return }

        let result = recorder.ingest(frame: frame)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if result.didAcceptKeyframe {
                self.haptics.impactOccurred()
                self.haptics.prepare()
            }
        }
    }
}
