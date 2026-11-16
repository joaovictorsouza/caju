import Foundation

/// Entrada individual de asset no manifesto gerado por `caju-tools manifest`.
public struct ManifestEntry: Sendable, Equatable {
    /// Caminho relativo com separador `/`.
    public let path: String
    /// Tamanho do arquivo em bytes.
    public let size: Int
    /// Resumo SHA-256 em hexadecimal minúsculo.
    public let sha256: String
}

/// Construtor determinístico de manifesto de assets (ordem estável, chaves ordenadas, sem timestamps).
public enum ManifestBuilder {
    /// Percorre `directoryURL` de forma determinística e calcula tamanho e SHA-256 dos arquivos regulares.
    public static func build(
        directoryURL: URL,
        limits: ToolsLimits = .default
    ) throws(CajuToolsError) -> [ManifestEntry] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDir) else {
            throw .io(path: directoryURL.path, reason: "diretório não encontrado")
        }
        guard isDir.boolValue else {
            throw .io(path: directoryURL.path, reason: "caminho não é um diretório")
        }

        var entries: [ManifestEntry] = []
        try collectFiles(
            rootURL: directoryURL,
            currentURL: directoryURL,
            relativePrefix: "",
            entries: &entries,
            limits: limits
        )

        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return entries
    }

    /// Serializa a lista de entradas como JSON determinístico com chaves ordenadas.
    public static func formatJSON(_ entries: [ManifestEntry]) -> String {
        let assetObjects: [DeterministicJSON] = entries.map { entry in
            .object([
                ("path", .string(entry.path)),
                ("sha256", .string(entry.sha256)),
                ("size", .int(entry.size)),
            ])
        }
        let root: DeterministicJSON = .object([
            ("assets", .array(assetObjects)),
            ("version", .int(1)),
        ])
        return root.format()
    }

    private static func collectFiles(
        rootURL: URL,
        currentURL: URL,
        relativePrefix: String,
        entries: inout [ManifestEntry],
        limits: ToolsLimits
    ) throws(CajuToolsError) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch {
            throw .io(path: currentURL.path, reason: error.localizedDescription)
        }

        let sortedChildren = children.sorted {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
        }

        for child in sortedChildren {
            let name = child.lastPathComponent
            if name == ".DS_Store" || name == ".git" {
                continue
            }

            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: Set(keys))
            } catch {
                throw .io(path: child.path, reason: error.localizedDescription)
            }

            if values.isSymbolicLink == true {
                continue
            }

            let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"

            if values.isDirectory == true {
                try collectFiles(
                    rootURL: rootURL,
                    currentURL: child,
                    relativePrefix: relPath,
                    entries: &entries,
                    limits: limits
                )
            } else if values.isRegularFile == true {
                let nextCount = try checkedAdd(entries.count, 1, "manifest.entries")
                try checkLimit(nextCount, limits.maxElements, "manifest.entries")
                let bytes = try readFileBytes(atPath: child.path, limits: limits)
                let digest = ToolsSHA256.hexDigest(bytes)
                entries.append(ManifestEntry(path: relPath, size: bytes.count, sha256: digest))
            }
        }
    }
}

/// Executor do subcomando `manifest`.
public enum ManifestCommand {
    public static let helpText = """
        uso: caju-tools manifest <diretorio> [-o <saida.json>]

        opções:
          -o, --output <arquivo>   grava o manifesto JSON em arquivo (padrão: stdout)
          -h, --help               exibe esta ajuda
        """

    public static func run(arguments: [String]) throws(CajuToolsError) -> String {
        var dirPath: String?
        var outputPath: String?

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < arguments.count else {
                    throw .usage("opção '\(arg)' exige caminho de saída")
                }
                outputPath = arguments[i + 1]
                i += 2
            default:
                if arg.hasPrefix("-") {
                    throw .usage("opção desconhecida '\(arg)'")
                }
                guard dirPath == nil else {
                    throw .usage("argumento posicional inesperado '\(arg)'")
                }
                dirPath = arg
                i += 1
            }
        }

        guard let dirPath else {
            throw .usage("caminho do diretório de assets obrigatório")
        }

        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        let entries = try ManifestBuilder.build(directoryURL: dirURL, limits: .default)
        let json = ManifestBuilder.formatJSON(entries)

        if let outputPath {
            try writeUTF8Text(json, toPath: outputPath)
            return "OK manifest entries=\(entries.count)\n"
        }
        return json
    }
}
