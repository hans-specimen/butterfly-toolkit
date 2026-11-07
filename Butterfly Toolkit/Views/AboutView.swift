import SwiftUI

// 关于页面
struct AboutView: View {

    // ==========================
    // 自动读取 App 版本号
    // ==========================
    // 由 Config/Version.xcconfig 写入构建产物
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    // ==========================
    // 自动读取 Build 号
    // ==========================
    // 与应用版本共用同一份配置
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
    }

    var body: some View {

        VStack(spacing: 18) {

            Spacer()

            //--------------------------------------------------
            // App 图标
            //--------------------------------------------------
            // 自动读取 Assets 中设置的 AppIcon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()          // 可以缩放
                .scaledToFit()        // 保持比例
                .frame(width: 110, height: 110)

            //--------------------------------------------------
            // App 名称
            //--------------------------------------------------
            Text("Butterfly Toolkit")
                .font(.system(size: 28, weight: .bold))

            //--------------------------------------------------
            // 简介
            //--------------------------------------------------
            Text("蝴蝶图片批量处理工具")
                .font(.title3)
                .foregroundStyle(.secondary)

            //--------------------------------------------------
            // 版本信息
            //--------------------------------------------------
            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            //--------------------------------------------------
            // 分隔线
            //--------------------------------------------------
            Divider()
                .frame(width: 320)

            //--------------------------------------------------
            // 功能介绍
            //--------------------------------------------------
            VStack(alignment: .leading, spacing: 15) {

                FeatureRow(
                    icon: "character.cursor.ibeam",
                    title: "批量重命名",
                    description: "快速整理图片文件名称"
                )

                FeatureRow(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "图片压缩",
                    description: "批量压缩到指定文件大小"
                )

                FeatureRow(
                    icon: "rotate.right",
                    title: "批量旋转",
                    description: "支持 90°、180°、270° 旋转"
                )

                FeatureRow(
                    icon: "crop",
                    title: "智能裁剪",
                    description: "识别蝴蝶主体，自动扶正并统一比例"
                )

                FeatureRow(
                    icon: "photo.badge.plus",
                    title: "闲鱼产品图",
                    description: "批量生成灰底、投影和水印商品图"
                )

                FeatureRow(
                    icon: "doc.badge.arrow.up",
                    title: "PSD 批量导出",
                    description: "保持目录结构，批量导出 JPG 或 PNG"
                )

                FeatureRow(
                    icon: "crop",
                    title: "透明 PNG 裁切",
                    description: "移除透明边缘并保留蝴蝶主体"
                )
            }
            .frame(maxWidth: 430)

            Spacer()

            //--------------------------------------------------
            // 底部版权
            //--------------------------------------------------
            Text("© 2026 Juntao Dai")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 720)
    }
}


//============================================================
// 每一项功能介绍
//============================================================
struct FeatureRow: View {

    // SF Symbol 图标名称
    let icon: String

    // 功能名称
    let title: String

    // 功能说明
    let description: String

    var body: some View {

        HStack(spacing: 15) {

            //--------------------------------------------
            // 左侧图标
            //--------------------------------------------
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 30)

            //--------------------------------------------
            // 中间文字
            //--------------------------------------------
            VStack(alignment: .leading, spacing: 3) {

                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}


//============================================================
// SwiftUI 预览
//============================================================
#Preview {
    AboutView()
}
