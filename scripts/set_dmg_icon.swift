import AppKit

let arguments = CommandLine.arguments
let cwd = FileManager.default.currentDirectoryPath
let dmgPath = arguments.count > 1 ? arguments[1] : "\(cwd)/SingAR.dmg"
let iconPath = arguments.count > 2 ? arguments[2] : "\(cwd)/scripts/dmg_assets/app_icon.png"

guard FileManager.default.fileExists(atPath: dmgPath) else {
    print("[SetDmgIcon] Error: DMG not found at \(dmgPath)")
    exit(1)
}

guard let image = NSImage(contentsOfFile: iconPath) else {
    print("[SetDmgIcon] Error: Failed to load icon image from \(iconPath)")
    exit(1)
}

let success = NSWorkspace.shared.setIcon(image, forFile: dmgPath, options: [])
if success {
    print("[SetDmgIcon] Successfully set custom icon for \(dmgPath)")
} else {
    print("[SetDmgIcon] Warning: Failed to set custom icon for \(dmgPath)")
}
