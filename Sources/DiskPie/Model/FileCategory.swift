import SwiftUI

enum FileCategory: String, CaseIterable, Identifiable {
    case video, audio, images, archives, diskImages, documents, code, apps, other

    var id: Self { self }

    var title: String {
        switch self {
        case .video: "Видео"
        case .audio: "Аудио"
        case .images: "Изображения"
        case .archives: "Архивы"
        case .diskImages: "Образы и установщики"
        case .documents: "Документы"
        case .code: "Код и данные"
        case .apps: "Приложения и пакеты"
        case .other: "Прочее"
        }
    }

    var icon: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .images: "photo"
        case .archives: "archivebox"
        case .diskImages: "opticaldiscdrive"
        case .documents: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .apps: "app"
        case .other: "doc"
        }
    }

    var color: Color {
        switch self {
        case .video: Color(hue: 0.97, saturation: 0.55, brightness: 0.85)
        case .audio: Color(hue: 0.08, saturation: 0.6, brightness: 0.92)
        case .images: Color(hue: 0.14, saturation: 0.6, brightness: 0.9)
        case .archives: Color(hue: 0.3, saturation: 0.5, brightness: 0.75)
        case .diskImages: Color(hue: 0.45, saturation: 0.5, brightness: 0.75)
        case .documents: Color(hue: 0.58, saturation: 0.55, brightness: 0.88)
        case .code: Color(hue: 0.7, saturation: 0.45, brightness: 0.85)
        case .apps: Color(hue: 0.8, saturation: 0.45, brightness: 0.85)
        case .other: Color(white: 0.6)
        }
    }

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = category }
        }
        add(.video, "mp4 mov m4v avi mkv wmv flv webm mpg mpeg 3gp mts m2ts vob prores braw")
        add(.audio, "mp3 m4a aac wav flac aiff aif ogg oga wma alac caf opus mid midi")
        add(.images, "jpg jpeg png gif heic heif tiff tif bmp webp raw cr2 cr3 nef arw dng orf psd psb svg ico icns exr hdr avif")
        add(.archives, "zip rar 7z tar gz tgz bz2 xz zst lz4 lzma cpgz xar sit")
        add(.diskImages, "dmg iso img sparseimage vmdk vdi vhd vhdx qcow2 ipa apk aab xip pkg mpkg ipsw")
        add(.documents, "pdf doc docx xls xlsx ppt pptx key pages numbers txt rtf md epub csv odt ods odp")
        add(.code, "swift m mm h c cc cpp hpp kt kts java js mjs ts tsx jsx py rb go rs json xml yml yaml html css scss php sh sql sqlite db realm o a dylib so class jar dex")
        return map
    }()

    static func of(_ node: FileNode) -> FileCategory {
        if node.kind == .package { return .apps }
        return byExtension[node.fileExtension] ?? .other
    }
}
