import SwiftUI
import UIKit
import Combine

class HostingWrapper<Content: View>: ObservableObject {
    @Published var content: Content
    init(content: Content) {
        self.content = content
    }
}

struct RootWrapperView<Content: View>: View {
    @ObservedObject var wrapper: HostingWrapper<Content>
    var body: some View {
        wrapper.content
            .ignoresSafeArea()
    }
}

struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    @Binding var zoomScale: CGFloat
    @Binding var targetRect: CGRect?
    var showAIMode: Bool
    var content: () -> Content

    init(zoomScale: Binding<CGFloat>, targetRect: Binding<CGRect?>, showAIMode: Bool, @ViewBuilder content: @escaping () -> Content) {
        self._zoomScale = zoomScale
        self._targetRect = targetRect
        self.showAIMode = showAIMode
        self.content = content
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 3.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.contentInsetAdjustmentBehavior = .never
        
        let wrapper = HostingWrapper(content: content())
        context.coordinator.wrapper = wrapper
        
        let hostingController = UIHostingController(rootView: RootWrapperView(wrapper: wrapper))
        hostingController.view.backgroundColor = .clear
        
        // Disable Auto Layout! Let UIScrollView manage the transform on this view natively.
        hostingController.view.translatesAutoresizingMaskIntoConstraints = true
        hostingController.view.autoresizingMask = [] // Do NOT auto-resize when contentSize changes!
        
        // Initial sizing
        let targetSize = hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        hostingController.view.frame = CGRect(origin: .zero, size: targetSize)
        scrollView.contentSize = targetSize
        scrollView.addSubview(hostingController.view)
        
        context.coordinator.hostingController = hostingController
        
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        
        let newContent = content()
        DispatchQueue.main.async {
            context.coordinator.wrapper?.content = newContent
        }
        
        // Keep bounds updated if SwiftUI content changes intrinsic size (e.g. 1 column vs 2 columns)
        if let hostView = context.coordinator.hostingController?.view {
            let targetSize = context.coordinator.hostingController?.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
            if hostView.bounds.size != targetSize {
                hostView.bounds = CGRect(origin: .zero, size: targetSize)
                hostView.center = CGPoint(x: targetSize.width / 2.0, y: targetSize.height / 2.0)
                scrollView.contentSize = CGSize(width: targetSize.width * scrollView.zoomScale, height: targetSize.height * scrollView.zoomScale)
            }
        }
        
        if context.coordinator.isUpdatingFromCoordinator { return }
        
        if abs(scrollView.zoomScale - zoomScale) > 0.01 && !showAIMode {
            scrollView.setZoomScale(zoomScale, animated: true)
        }
        
        if showAIMode != context.coordinator.lastShowAIMode || targetRect != context.coordinator.lastTargetRect {
            
            if showAIMode, let target = targetRect {
                let zoomBinding = _zoomScale
                
                DispatchQueue.main.async {
                    let targetScale = scrollView.maximumZoomScale
                    let visibleWidth = scrollView.bounds.width
                    let visibleHeight = scrollView.bounds.height
                    
                    // Massive insets completely prevent any edge clamping when panning.
                    // Because we manually set contentOffset, large insets do not break the math.
                    scrollView.contentInset = UIEdgeInsets(
                        top: visibleHeight,
                        left: visibleWidth,
                        bottom: visibleHeight,
                        right: visibleWidth
                    )
                    
                    let scaledCenterX = target.midX * targetScale
                    let scaledCenterY = target.midY * targetScale
                    
                    // Offset horizontally to exactly 30% from the left edge of the screen
                    let offsetX = scaledCenterX - (0.3 * visibleWidth)
                    // Offset vertically to perfectly center it
                    let offsetY = scaledCenterY - (0.5 * visibleHeight)
                    
                    // Set zoom scale outside the animation block to prevent UIScrollView from intercepting and overriding the layout bounds!
                    if scrollView.zoomScale != targetScale {
                        scrollView.zoomScale = targetScale
                    }
                    
                    UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                        scrollView.contentOffset = CGPoint(x: offsetX, y: offsetY)
                    }
                    
                    zoomBinding.wrappedValue = targetScale
                }
            } else if !showAIMode {
                // Restore insets when exiting AI Mode
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.3) {
                        scrollView.contentInset = .zero
                    }
                }
            }
            
            context.coordinator.lastShowAIMode = showAIMode
            context.coordinator.lastTargetRect = targetRect
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var hostingController: UIHostingController<RootWrapperView<Content>>?
        var wrapper: HostingWrapper<Content>?
        var isUpdatingFromCoordinator = false
        var lastShowAIMode: Bool = false
        var lastTargetRect: CGRect? = nil

        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return hostingController?.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isUpdatingFromCoordinator = true
            parent.zoomScale = scrollView.zoomScale
            isUpdatingFromCoordinator = false
        }
    }
}
