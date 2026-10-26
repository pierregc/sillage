import SillageRender

extension LibraryCollection {
    var title: String {
        switch self {
        case .toSort: "À trier"
        case .chosen: "Choisies"
        case .highResolution: "En haute résolution"
        case .toStyle: "Style à choisir"
        case .ready: "Prêtes"
        case .exported: "Exportées"
        case .all: "Toutes"
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
        case .toSort: "Tout est trié"
        case .chosen: "Aucune scène choisie en attente"
        case .highResolution: "Aucun calcul en haute résolution"
        case .toStyle: "Aucun style à choisir"
        case .ready: "Aucune scène prête"
        case .exported: "Aucune vidéo exportée"
        case .all: "Aucune scène ici"
        }
    }

    var emptyDetail: String {
        switch self {
        case .toSort: "Les scènes d'une nuit arrivent ici dès qu'elles sont explorées."
        case .chosen: "Une scène marquée Oui attend ici son calcul en haute résolution."
        case .highResolution: "Les scènes dont le calcul est en file ou en cours."
        case .toStyle: "Une scène calculée en haute résolution attend ici son style."
        case .ready: "Une scène dont le style est choisi attend ici son export."
        case .exported: "Les scènes qui ont au moins une vidéo."
        case .all: "Les scènes apparaissent dès qu'elles arrivent dans le dossier."
        }
    }
}
