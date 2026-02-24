import Cocoa
import StandupReminderLib

// Create the application and set up the delegate.
// LSUIElement=true in Info.plist keeps us out of the Dock.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
