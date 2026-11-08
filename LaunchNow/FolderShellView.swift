import SwiftUI

struct FolderShellView: View {
    let name: String
    /// 「整体大小」的缩放比例，和 FolderView 的标题一致
    var scale: CGFloat = 1

    private var titlePadding: CGFloat { 16 * scale }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(name)
                    .font(.system(size: 22 * scale))
                    .foregroundColor(.primary)
                    .padding(16 * scale)
                Spacer()
            }
            .padding(.horizontal, titlePadding)

            Spacer()
        }
        .padding(16 * scale)
    }
}
