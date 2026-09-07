import Darwin
import Foundation

struct AtomicArtifactPublisherFailure: Error, CustomStringConvertible {
    let description: String
}

struct AtomicArtifactPublisherInvocation {
    let projectRoot: String
    let stageName: String
    let publicName: String

    init(arguments: [String]) throws {
        guard arguments.count == 3 else {
            try publisherFail(
                "usage: AtomicArtifactPublisher <project-root> <stage-name> dist"
            )
        }

        let projectRoot = arguments[0]
        let stageName = arguments[1]
        let publicName = arguments[2]
        // Foundation rewrites /private/tmp to /tmp even though realpath uses
        // /private/tmp. Validate the actual filesystem path, not URL display form.
        let resolvedRoot = realpath(projectRoot, nil)
        defer { free(resolvedRoot) }
        guard projectRoot.hasPrefix("/"), let resolvedRoot,
            projectRoot == String(cString: resolvedRoot),
            projectRoot != "/"
        else {
            try publisherFail("atomic publisher refused a non-canonical project root")
        }

        let stagePrefix = ".topdrop-dist-stage."
        let stageSuffix = stageName.dropFirst(stagePrefix.count)
        guard stageName.hasPrefix(stagePrefix), !stageSuffix.isEmpty,
            !stageName.contains("/"), stageName != ".", stageName != "..",
            stageSuffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            try publisherFail("atomic publisher refused an invalid stage name")
        }
        guard !publicName.isEmpty, publicName.first != ".",
            publicName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            try publisherFail("atomic publisher requires a safe output directory name")
        }

        self.projectRoot = projectRoot
        self.stageName = stageName
        self.publicName = publicName
    }
}

private enum AtomicArtifactPublisherConstants {
    static let expectedEntries: Set<String> = [
        "TopDrop.app",
        "TopDrop.app.zip",
        "TopDrop-source.zip",
    ]
    static let pathSafetyFlags = UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
}

private func publisherFail(_ message: String) throws -> Never {
    throw AtomicArtifactPublisherFailure(description: message)
}

private func closeAfterUse(_ descriptor: Int32) {
    if descriptor >= 0 {
        _ = Darwin.close(descriptor)
    }
}

private func openedProjectRoot(atPath path: String) throws -> Int32 {
    let descriptor = Darwin.open(
        path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not open project root: "
                + String(cString: strerror(operationError))
        )
    }

    do {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let operationError = errno
            try publisherFail(
                "atomic publisher could not inspect project root: "
                    + String(cString: strerror(operationError))
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            try publisherFail("atomic publisher requires a trusted user-owned project root")
        }
        return descriptor
    } catch {
        closeAfterUse(descriptor)
        throw error
    }
}

private func entryMetadata(
    directoryDescriptor: Int32,
    name: String,
    description: String
) throws -> stat {
    var metadata = stat()
    let status = name.withCString { component in
        fstatat(directoryDescriptor, component, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard status == 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not inspect \(description): "
                + String(cString: strerror(operationError))
        )
    }
    return metadata
}

private func openedStage(
    projectDescriptor: Int32,
    name: String
) throws -> Int32 {
    let descriptor = name.withCString { component in
        openat(
            projectDescriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
    }
    guard descriptor >= 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not open publication stage: "
                + String(cString: strerror(operationError))
        )
    }

    do {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let operationError = errno
            try publisherFail(
                "atomic publisher could not inspect publication stage: "
                    + String(cString: strerror(operationError))
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            try publisherFail("atomic publisher refused an untrusted publication stage")
        }
        return descriptor
    } catch {
        closeAfterUse(descriptor)
        throw error
    }
}

private func directoryEntryNames(descriptor: Int32) throws -> Set<String> {
    let enumerationDescriptor = Darwin.dup(descriptor)
    guard enumerationDescriptor >= 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not duplicate publication stage: "
                + String(cString: strerror(operationError))
        )
    }
    guard let directory = fdopendir(enumerationDescriptor) else {
        let operationError = errno
        closeAfterUse(enumerationDescriptor)
        try publisherFail(
            "atomic publisher could not enumerate publication stage: "
                + String(cString: strerror(operationError))
        )
    }
    defer { closedir(directory) }

    var names = Set<String>()
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXNAMLEN) + 1
            ) {
                String(cString: $0)
            }
        }
        if name != ".", name != ".." {
            names.insert(name)
        }
    }
    guard errno == 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not finish enumerating publication stage: "
                + String(cString: strerror(operationError))
        )
    }
    return names
}

private func validateArtifactGenerationContents(
    descriptor: Int32,
    description: String
) throws {
    let names = try directoryEntryNames(descriptor: descriptor)
    guard names == AtomicArtifactPublisherConstants.expectedEntries else {
        try publisherFail(
            "atomic publisher requires the exact three-artifact set in \(description)"
        )
    }

    let appMetadata = try entryMetadata(
        directoryDescriptor: descriptor,
        name: "TopDrop.app",
        description: "\(description) TopDrop app"
    )
    guard appMetadata.st_mode & S_IFMT == S_IFDIR,
        appMetadata.st_uid == geteuid(),
        appMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
        try publisherFail("atomic publisher refused an invalid \(description) TopDrop app")
    }

    for zipName in ["TopDrop.app.zip", "TopDrop-source.zip"] {
        let zipMetadata = try entryMetadata(
            directoryDescriptor: descriptor,
            name: zipName,
            description: "\(description) \(zipName)"
        )
        guard zipMetadata.st_mode & S_IFMT == S_IFREG,
            zipMetadata.st_size > 0,
            zipMetadata.st_uid == geteuid(),
            zipMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            try publisherFail("atomic publisher refused invalid \(description) \(zipName)")
        }
    }
}

private func openedPublicTargetIfPresent(
    projectDescriptor: Int32,
    name: String
) throws -> Int32? {
    let descriptor = name.withCString { component in
        openat(
            projectDescriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
    }
    if descriptor < 0 {
        let operationError = errno
        if operationError == ENOENT {
            return nil
        }
        try publisherFail(
            "atomic publisher could not open public dist: "
                + String(cString: strerror(operationError))
        )
    }

    do {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let operationError = errno
            try publisherFail(
                "atomic publisher could not inspect public dist: "
                    + String(cString: strerror(operationError))
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            try publisherFail("atomic publisher refused an untrusted public dist target")
        }
        try validateArtifactGenerationContents(
            descriptor: descriptor,
            description: "existing public dist"
        )
        return descriptor
    } catch {
        closeAfterUse(descriptor)
        throw error
    }
}

private func publishArtifactSet(_ invocation: AtomicArtifactPublisherInvocation) throws {
    let projectDescriptor = try openedProjectRoot(atPath: invocation.projectRoot)
    defer { closeAfterUse(projectDescriptor) }
    let stageDescriptor = try openedStage(
        projectDescriptor: projectDescriptor,
        name: invocation.stageName
    )
    defer { closeAfterUse(stageDescriptor) }

    try validateArtifactGenerationContents(
        descriptor: stageDescriptor,
        description: "publication stage"
    )
    let publicDescriptor = try openedPublicTargetIfPresent(
        projectDescriptor: projectDescriptor,
        name: invocation.publicName
    )
    defer {
        if let publicDescriptor {
            closeAfterUse(publicDescriptor)
        }
    }
    let operationFlag = publicDescriptor == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
    let renameFlags = operationFlag | AtomicArtifactPublisherConstants.pathSafetyFlags
    let status = invocation.stageName.withCString { stageComponent in
        invocation.publicName.withCString { publicComponent in
            renameatx_np(
                projectDescriptor,
                stageComponent,
                projectDescriptor,
                publicComponent,
                renameFlags
            )
        }
    }
    guard status == 0 else {
        let operationError = errno
        try publisherFail(
            "atomic publisher could not commit the artifact generation: "
                + String(cString: strerror(operationError))
        )
    }
}

do {
    let invocation = try AtomicArtifactPublisherInvocation(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    try publishArtifactSet(invocation)
    print("Published validated TopDrop artifact generation")
} catch {
    fputs("TopDrop atomic publication error: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
