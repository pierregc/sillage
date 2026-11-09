import SillageRender

extension LibraryCollection {
    var title: String {
        switch self {
        case .toSort: "To sort"
        case .chosen: "Kept"
        case .highResolution: "In high resolution"
        case .toStyle: "Style to choose"
        case .ready: "Ready"
        case .exported: "Exported"
        case .all: "All"
        }
    }

    var symbol: String {
        switch self {
        case .toSort: "tray"
        case .chosen: "checkmark.circle"
        case .highResolution: "cpu"
        case .toStyle: "paintpalette"
        case .ready: "flag.checkered"
        case .exported: "film.stack"
        case .all: "square.grid.2x2"
        }
    }

    /// What the page says when nothing is in the collection.
    var emptyTitle: String {
        switch self {
        case .toSort: "All sorted"
        case .chosen: "No kept scene waiting"
        case .highResolution: "No high-resolution run"
        case .toStyle: "No style to choose"
        case .ready: "No scene ready"
        case .exported: "No exported video"
        case .all: "No scene here"
        }
    }

    var emptyDetail: String {
        switch self {
        case .toSort: "A night's scenes arrive here as soon as they are explored."
        case .chosen: "A scene marked Yes waits here for its high-resolution run."
        case .highResolution: "Scenes whose run is queued or under way."
        case .toStyle: "A scene computed in high resolution waits here for its style."
        case .ready: "A scene whose style is chosen waits here for its export."
        case .exported: "Scenes with at least one video."
        case .all: "Scenes appear as soon as they reach the folder."
        }
    }
}
