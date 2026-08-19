import SwiftUI

struct NumberPadPopoverView: View {
    @Binding var isPresented: Bool
    var currentValue: Int
    var onValueSelected: (Int) -> Void
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    @State private var typedValue: String = ""
    
    var body: some View {
        VStack(spacing: 12) {
            // Dismiss button at top right
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
            }
            
            HStack {
                Text(typedValue.isEmpty ? "\(currentValue)" : typedValue)
                    .font(.title2.bold())
                    .foregroundStyle(typedValue.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                Button {
                    if !typedValue.isEmpty {
                        typedValue.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                }
            }
            
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...9, id: \.self) { num in
                    numButton("\(num)")
                }
                
                // Replaced Cancel with Negative sign
                numButton("-")
                
                numButton("0")
                
                Button {
                    if let val = Int(typedValue) {
                        onValueSelected(val)
                    }
                    isPresented = false
                } label: {
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .frame(width: 270, height: 420) // Made the body taller and slightly wider
    }
    
    @ViewBuilder
    private func numButton(_ text: String) -> some View {
        Button {
            typedValue += text
        } label: {
            Text(text)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
