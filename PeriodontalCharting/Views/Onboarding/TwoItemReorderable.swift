import SwiftUI
import Foundation

struct TwoItemReorderable<Item: Hashable, Content: View>: View {
    @Binding var items: [Item]
    let spacing: CGFloat
    @ViewBuilder let content: (Item, AnyGesture<DragGesture.Value>) -> Content
    
    @State private var itemHeight: CGFloat = 80
    @State private var draggingItem: Item?
    @State private var dragOffset: CGFloat = 0
    @State private var isSwapped: Bool = false
    
    var body: some View {
        VStack(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                let index = items.firstIndex(of: item) ?? 0
                let isDragging = draggingItem == item
                
                let nonDraggingOffset: CGFloat = {
                    if !isDragging && isSwapped {
                        return index == 1 ? -(itemHeight + spacing) : (itemHeight + spacing)
                    }
                    return 0
                }()
                
                let gesture = DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if draggingItem == nil {
                            draggingItem = item
                        }
                        dragOffset = value.translation.height
                        
                        let threshold = itemHeight / 3
                        let currentlySwapped = (index == 0 && dragOffset > threshold) ||
                                               (index == 1 && dragOffset < -threshold)
                        
                        if isSwapped != currentlySwapped {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isSwapped = currentlySwapped
                            }
                        }
                    }
                    .onEnded { value in
                        let finalizeSwap = isSwapped
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if finalizeSwap, items.count == 2 {
                                items.swapAt(0, 1)
                            }
                            draggingItem = nil
                            dragOffset = 0
                            isSwapped = false
                        }
                    }
                
                content(item, AnyGesture(gesture))
                    .offset(y: isDragging ? dragOffset : nonDraggingOffset)
                    .zIndex(isDragging ? 1 : 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    if geo.size.height > 10 { itemHeight = geo.size.height }
                                }
                                .onChange(of: geo.size.height) { newH in
                                    if newH > 10 { itemHeight = newH }
                                }
                        }
                    )
            }
        }
    }
}

