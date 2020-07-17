/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility
import PackageModel
import PackageGraph
import PackageLoading
import Foundation
import SPMBuildCore

extension BuildParameters {
    /// Returns the directory to be used for module cache.
    public var moduleCache: AbsolutePath {
        // FIXME: We use this hack to let swiftpm's functional test use shared
        // cache so it doesn't become painfully slow.
        if let path = ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"] {
            return AbsolutePath(path)
        }
        return buildPath.appending(component: "ModuleCache")
    }

    /// Checks if stdout stream is tty.
    fileprivate static var isTTY: Bool = {
        guard let stream = stdoutStream.stream as? LocalFileOutputByteStream else {
            return false
        }
        return TerminalController.isTTY(stream)
    }()

    /// Extra flags to pass to Swift compiler.
    public var swiftCompilerFlags: [String] {
        var flags = self.flags.cCompilerFlags.flatMap({ ["-Xcc", $0] })
        flags += self.flags.swiftCompilerFlags
        flags += verbosity.ccArgs
        return flags
    }

    /// Extra flags to pass to linker.
    public var linkerFlags: [String] {
        // Arguments that can be passed directly to the Swift compiler and
        // doesn't require -Xlinker prefix.
        //
        // We do this to avoid sending flags like linker search path at the end
        // of the search list.
        let directSwiftLinkerArgs = ["-L"]

        var flags: [String] = []
        var it = self.flags.linkerFlags.makeIterator()
        while let flag = it.next() {
            if directSwiftLinkerArgs.contains(flag) {
                // `-L <value>` variant.
                flags.append(flag)
                guard let nextFlag = it.next() else {
                    // We expected a flag but don't have one.
                    continue
                }
                flags.append(nextFlag)
            } else if directSwiftLinkerArgs.contains(where: { flag.hasPrefix($0) }) {
                // `-L<value>` variant.
                flags.append(flag)
            } else {
                flags += ["-Xlinker", flag]
            }
        }
        return flags
    }

    /// Returns the compiler arguments for the index store, if enabled.
    fileprivate func indexStoreArguments(for target: ResolvedTarget) -> [String] {
        let addIndexStoreArguments: Bool
        switch indexStoreMode {
        case .on:
            addIndexStoreArguments = true
        case .off:
            addIndexStoreArguments = false
        case .auto:
            if configuration == .debug {
                addIndexStoreArguments = true
            } else if enableTestDiscovery && target.type == .test {
                // Test discovery requires an index store for the test targets
                // to discover the tests
                addIndexStoreArguments = true
            } else {
                addIndexStoreArguments = false
            }
        }

        if addIndexStoreArguments {
            return ["-index-store-path", indexStore.pathString]
        }
        return []
    }

    /// Computes the target triple arguments for a given resolved target.
    public func targetTripleArgs(for target: ResolvedTarget) -> [String] {
        var args = ["-target"]
        // Compute the triple string for Darwin platform using the platform version.
        if triple.isDarwin() {
            guard let macOSSupportedPlatform = target.underlyingTarget.getSupportedPlatform(for: .macOS) else {
                fatalError("the target \(target) doesn't support building for macOS")
            }
            args += [triple.tripleString(forPlatformVersion: macOSSupportedPlatform.version.versionString)]
        } else {
            args += [triple.tripleString]
        }
        return args
    }

    /// Returns the scoped view of build settings for a given target.
    fileprivate func createScope(for target: ResolvedTarget) -> BuildSettings.Scope {
        return BuildSettings.Scope(target.underlyingTarget.buildSettings, environment: buildEnvironment)
    }
}

/// A target description which can either be for a Swift or Clang target.
public enum TargetBuildDescription {

    /// Swift target description.
    case swift(SwiftTargetBuildDescription)

    /// Clang target description.
    case clang(ClangTargetBuildDescription)

    /// The objects in this target.
    var objects: [AbsolutePath] {
        switch self {
        case .swift(let target):
            return target.objects
        case .clang(let target):
            return target.objects
        }
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        switch self {
        case .swift(let target):
            return target.bundlePath
        case .clang(let target):
            return target.bundlePath
        }
    }

    var target: ResolvedTarget {
        switch self {
        case .swift(let target):
            return target.target
        case .clang(let target):
            return target.target
        }
    }

    /// Paths to the binary libraries the target depends on.
    var libraryBinaryPaths: Set<AbsolutePath> {
        switch self {
        case .swift(let target):
            return target.libraryBinaryPaths
        case .clang(let target):
            return target.libraryBinaryPaths
        }
    }

    var resourceBundleInfoPlistPath: AbsolutePath? {
        switch self {
        case .swift(let target):
            return target.resourceBundleInfoPlistPath
        case .clang(let target):
            return target.resourceBundleInfoPlistPath
        }
    }
}

/// Target description for a Clang target i.e. C language family target.
public final class ClangTargetBuildDescription {

    /// The target described by this target.
    public let target: ResolvedTarget

    /// The underlying clang target.
    public var clangTarget: ClangTarget {
        return target.underlyingTarget as! ClangTarget
    }

    /// The build parameters.
    let buildParameters: BuildParameters

    /// The build environment.
    var buildEnvironment: BuildEnvironment {
        buildParameters.buildEnvironment
    }

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        buildParameters.bundlePath(for: target)
    }

    /// The modulemap file for this target, if any.
    public private(set) var moduleMap: AbsolutePath?

    /// Path to the temporary directory for this target.
    var tempsPath: AbsolutePath

    /// The directory containing derived sources of this target.
    ///
    /// These are the source files generated during the build.
    private var derivedSources: Sources

    /// Path to the resource accessor header file, if generated.
    public private(set) var resourceAccessorHeaderFile: AbsolutePath?

    /// Path to the resource Info.plist file, if generated.
    public private(set) var resourceBundleInfoPlistPath: AbsolutePath?

    /// The objects in this target.
    public var objects: [AbsolutePath] {
        return compilePaths().map({ $0.object })
    }

    /// Paths to the binary libraries the target depends on.
    fileprivate(set) var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Any addition flags to be added. These flags are expected to be computed during build planning.
    fileprivate var additionalFlags: [String] = []

    /// The filesystem to operate on.
    let fileSystem: FileSystem

    /// If this target is a test target.
    public var isTestTarget: Bool {
        return target.type == .test
    }

    /// Create a new target description with target and build parameters.
    init(target: ResolvedTarget, buildParameters: BuildParameters, fileSystem: FileSystem = localFileSystem) throws {
        assert(target.underlyingTarget is ClangTarget, "underlying target type mismatch \(target)")
        self.fileSystem = fileSystem
        self.target = target
        self.buildParameters = buildParameters
        self.tempsPath = buildParameters.buildPath.appending(component: target.c99name + ".build")
        self.derivedSources = Sources(paths: [], root: tempsPath.appending(component: "DerivedSources"))

        // Try computing modulemap path for a C library.
        if target.type == .library {
            self.moduleMap = try computeModulemapPath()
        }

        // Do nothing if we're not generating a bundle.
        if bundlePath != nil {
            try self.generateResourceAccessor()

            let infoPlistPath = tempsPath.appending(component: "Info.plist")
            if try generateResourceInfoPlist(for: target, to: infoPlistPath) {
                resourceBundleInfoPlistPath = infoPlistPath
            }
        }
    }

    /// An array of tuple containing filename, source, object and dependency path for each of the source in this target.
    public func compilePaths()
        -> [(filename: RelativePath, source: AbsolutePath, object: AbsolutePath, deps: AbsolutePath)]
    {
        let sources = [
            target.sources.root: target.sources.relativePaths,
            derivedSources.root: derivedSources.relativePaths,
        ]

        return sources.flatMap { (root, relativePaths) in
            relativePaths.map { source in
                let path = root.appending(source)
                let object = tempsPath.appending(RelativePath("\(source.pathString).o"))
                let deps = tempsPath.appending(RelativePath("\(source.pathString).d"))
                return (source, path, object, deps)
            }
        }
    }

    /// Builds up basic compilation arguments for this target.
    public func basicArguments() -> [String] {
        var args = [String]()
        // Only enable ARC on macOS.
        if buildParameters.triple.isDarwin() {
            args += ["-fobjc-arc"]
        }
        args += buildParameters.targetTripleArgs(for: target)
        args += buildParameters.toolchain.extraCCFlags
        args += ["-g"]
        if buildParameters.triple.isWindows() {
            args += ["-gcodeview"]
        }
        args += optimizationArguments
        args += activeCompilationConditions
        args += ["-fblocks"]

        // Enable index store, if appropriate.
        //
        // This feature is not widely available in OSS clang. So, we only enable
        // index store for Apple's clang or if explicitly asked to.
        if ProcessEnv.vars.keys.contains("SWIFTPM_ENABLE_CLANG_INDEX_STORE") {
            args += buildParameters.indexStoreArguments(for: target)
        } else if buildParameters.triple.isDarwin(), (try? buildParameters.toolchain._isClangCompilerVendorApple()) == true {
            args += buildParameters.indexStoreArguments(for: target)
        }

        if !buildParameters.triple.isWindows() && !buildParameters.triple.isAndroid() {
            // Using modules currently conflicts with the Windows and Android SDKs.
            args += ["-fmodules", "-fmodule-name=" + target.c99name]
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !libraryBinaryPaths.isEmpty {
            args += ["-F", buildParameters.buildPath.pathString]
        }

        args += ["-I", clangTarget.includeDir.pathString]
        args += additionalFlags
        if !buildParameters.triple.isWindows() && !buildParameters.triple.isAndroid() {
            args += moduleCacheArgs
        }
        args += buildParameters.sanitizers.compileCFlags()

        // Add agruments from declared build settings.
        args += self.buildSettingsFlags()

        if let resourceAccessorHeaderFile = self.resourceAccessorHeaderFile {
            args += ["-include", resourceAccessorHeaderFile.pathString]
        }

        // User arguments (from -Xcc and -Xcxx below) should follow generated arguments to allow user overrides
        args += buildParameters.flags.cCompilerFlags

        // Add extra C++ flags if this target contains C++ files.
        if clangTarget.isCXX {
            args += self.buildParameters.flags.cxxCompilerFlags
        }
        return args
    }

    /// Returns the build flags from the declared build settings.
    private func buildSettingsFlags() -> [String] {
        let scope = buildParameters.createScope(for: target)
        var flags: [String] = []

        // C defines.
        let cDefines = scope.evaluate(.GCC_PREPROCESSOR_DEFINITIONS)
        flags += cDefines.map({ "-D" + $0 })

        // Header search paths.
        let headerSearchPaths = scope.evaluate(.HEADER_SEARCH_PATHS)
        flags += headerSearchPaths.map({
            "-I\(target.sources.root.appending(RelativePath($0)).pathString)"
        })

        // Frameworks.
        let frameworks = scope.evaluate(.LINK_FRAMEWORKS)
        flags += frameworks.flatMap({ ["-framework", $0] })

        // Other C flags.
        flags += scope.evaluate(.OTHER_CFLAGS)

        // Other CXX flags.
        flags += scope.evaluate(.OTHER_CPLUSPLUSFLAGS)

        return flags
    }

    /// Optimization arguments according to the build configuration.
    private var optimizationArguments: [String] {
        switch buildParameters.configuration {
        case .debug:
            return ["-O0"]
        case .release:
            return ["-O2"]
        }
    }

    /// A list of compilation conditions to enable for conditional compilation expressions.
    private var activeCompilationConditions: [String] {
        var compilationConditions = ["-DSWIFT_PACKAGE=1"]

        switch buildParameters.configuration {
        case .debug:
            compilationConditions += ["-DDEBUG=1"]
        case .release:
            break
        }

        return compilationConditions
    }


    /// Helper function to compute the modulemap path.
    ///
    /// This function either returns path to user provided modulemap or tries to automatically generates it.
    private func computeModulemapPath() throws -> AbsolutePath {
        // If user provided the modulemap, we're done.
        if fileSystem.isFile(clangTarget.moduleMapPath) {
            return clangTarget.moduleMapPath
        } else {
            // Otherwise try to generate one.
            var moduleMapGenerator = ModuleMapGenerator(for: clangTarget, fileSystem: fileSystem)
            // FIXME: We should probably only warn if we're unable to generate the modulemap
            // because the clang target is still a valid, it just can't be imported from Swift targets.
            try moduleMapGenerator.generateModuleMap(inDir: tempsPath)
            return tempsPath.appending(component: moduleMapFilename)
        }
    }

    /// Module cache arguments.
    private var moduleCacheArgs: [String] {
        return ["-fmodules-cache-path=\(buildParameters.moduleCache.pathString)"]
    }

    /// Generate the resource bundle accessor, if appropriate.
    private func generateResourceAccessor() throws {
        // Only generate access when we have a bundle and ObjC files.
        guard let bundlePath = self.bundlePath, clangTarget.sources.containsObjcFiles else { return }

        // Compute the basename of the bundle.
        let bundleBasename = bundlePath.basename

        let implFileStream = BufferedOutputByteStream()
        implFileStream <<< """
        #import <Foundation/Foundation.h>

        NSBundle* \(target.c99name)_SWIFTPM_MODULE_BUNDLE() {
            NSURL *bundleURL = [[[NSBundle mainBundle] bundleURL] URLByAppendingPathComponent:@"\(bundleBasename)"];
            return [NSBundle bundleWithURL:bundleURL];
        }
        """

        let implFileSubpath = RelativePath("resource_bundle_accessor.m")

        // Add the file to the dervied sources.
        derivedSources.relativePaths.append(implFileSubpath)

        // Write this file out.
        // FIXME: We should generate this file during the actual build.
        try fileSystem.writeIfChanged(
            path: derivedSources.root.appending(implFileSubpath),
            bytes: implFileStream.bytes
        )

        let headerFileStream = BufferedOutputByteStream()
        headerFileStream <<< """
        #import <Foundation/Foundation.h>

        NSBundle* \(target.c99name)_SWIFTPM_MODULE_BUNDLE(void);

        #define SWIFTPM_MODULE_BUNDLE \(target.c99name)_SWIFTPM_MODULE_BUNDLE()
        """
        let headerFile = derivedSources.root.appending(component: "resource_bundle_accessor.h")
        self.resourceAccessorHeaderFile = headerFile

        try fileSystem.writeIfChanged(
            path: headerFile,
            bytes: headerFileStream.bytes
        )
    }
}

/// Target description for a Swift target.
public final class SwiftTargetBuildDescription {

    /// The target described by this target.
    public let target: ResolvedTarget

    /// The build parameters.
    let buildParameters: BuildParameters

    /// Path to the temporary directory for this target.
    let tempsPath: AbsolutePath

    /// The directory containing derived sources of this target.
    ///
    /// These are the source files generated during the build.
    private var derivedSources: Sources

    /// Path to the bundle generated for this module (if any).
    var bundlePath: AbsolutePath? {
        buildParameters.bundlePath(for: target)
    }

    /// The list of all source files in the target, including the derived ones.
    public var sources: [AbsolutePath] { target.sources.paths + derivedSources.paths }

    /// The objects in this target.
    public var objects: [AbsolutePath] {
        let relativePaths = target.sources.relativePaths + derivedSources.relativePaths
        return relativePaths.map{ tempsPath.appending(RelativePath("\($0.pathString).o")) }
    }

    /// The path to the swiftmodule file after compilation.
    var moduleOutputPath: AbsolutePath {
        return buildParameters.buildPath.appending(component: target.c99name + ".swiftmodule")
    }

    /// The path to the wrapped swift module which is created using the modulewrap tool. This is required
    /// for supporting debugging on non-Darwin platforms (On Darwin, we just pass the swiftmodule to the linker
    /// using the `-add_ast_path` flag).
    var wrappedModuleOutputPath: AbsolutePath {
        return tempsPath.appending(component: target.c99name + ".swiftmodule.o")
    }

    /// The path to the swifinterface file after compilation.
    var parseableModuleInterfaceOutputPath: AbsolutePath {
        return buildParameters.buildPath.appending(component: target.c99name + ".swiftinterface")
    }

    /// Path to the resource Info.plist file, if generated.
    public private(set) var resourceBundleInfoPlistPath: AbsolutePath?

    /// Paths to the binary libraries the target depends on.
    fileprivate(set) var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Any addition flags to be added. These flags are expected to be computed during build planning.
    fileprivate var additionalFlags: [String] = []

    /// The swift version for this target.
    var swiftVersion: SwiftLanguageVersion {
        return (target.underlyingTarget as! SwiftTarget).swiftVersion
    }

    /// If this target is a test target.
    public let isTestTarget: Bool

    /// True if this is the test discovery target.
    public let testDiscoveryTarget: Bool

    /// The filesystem to operate on.
    let fs: FileSystem

    /// The modulemap file for this target, if any.
    private(set) var moduleMap: AbsolutePath?

    /// Create a new target description with target and build parameters.
    init(
        target: ResolvedTarget,
        buildParameters: BuildParameters,
        isTestTarget: Bool? = nil,
        testDiscoveryTarget: Bool = false,
        fs: FileSystem = localFileSystem
    ) throws {
        assert(target.underlyingTarget is SwiftTarget, "underlying target type mismatch \(target)")
        self.target = target
        self.buildParameters = buildParameters
        // Unless mentioned explicitly, use the target type to determine if this is a test target.
        self.isTestTarget = isTestTarget ?? (target.type == .test)
        self.testDiscoveryTarget = testDiscoveryTarget
        self.fs = fs
        self.tempsPath = buildParameters.buildPath.appending(component: target.c99name + ".build")
        self.derivedSources = Sources(paths: [], root: tempsPath.appending(component: "DerivedSources"))

        if shouldEmitObjCCompatibilityHeader {
            self.moduleMap = try self.generateModuleMap()
        }

        // Do nothing if we're not generating a bundle.
        if bundlePath != nil {
            try self.generateResourceAccessor()

            let infoPlistPath = tempsPath.appending(component: "Info.plist")
            if try generateResourceInfoPlist(for: target, to: infoPlistPath) {
                resourceBundleInfoPlistPath = infoPlistPath
            }
        }
    }

    /// Generate the resource bundle accessor, if appropriate.
    private func generateResourceAccessor() throws {
        // Do nothing if we're not generating a bundle.
        guard let bundlePath = self.bundlePath else { return }
      
        let pathToModule = isTestTarget ? bundlePath : "Bundle.main.bundlePath/\(bundlePath.basename)"
      
        let stream = BufferedOutputByteStream()
        stream <<< """
        import class Foundation.Bundle

        extension Foundation.Bundle {
            static var module: Bundle = {
                let bundlePath = "\(pathToModule)"
                guard let bundle = Bundle(path: bundlePath) else {
                    fatalError("could not load resource bundle: \\(bundlePath)")
                }
                return bundle
            }()
        }
        """

        let subpath = RelativePath("resource_bundle_accessor.swift")

        // Add the file to the dervied sources.
        derivedSources.relativePaths.append(subpath)

        // Write this file out.
        // FIXME: We should generate this file during the actual build.
        let path = derivedSources.root.appending(subpath)
        try fs.writeIfChanged(path: path, bytes: stream.bytes)
    }

    /// The arguments needed to compile this target.
    public func compileArguments() -> [String] {
        var args = [String]()
        args += buildParameters.targetTripleArgs(for: target)
        args += ["-swift-version", swiftVersion.rawValue]

        // Enable batch mode in debug mode.
        //
        // Technically, it should be enabled whenever WMO is off but we
        // don't currently make that distinction in SwiftPM
        switch buildParameters.configuration {
        case .debug:
            args += ["-enable-batch-mode"]
        case .release: break
        }

        args += buildParameters.indexStoreArguments(for: target)
        args += buildParameters.toolchain.extraSwiftCFlags
        args += optimizationArguments
        args += testingArguments
        args += ["-g"]
        args += ["-j\(buildParameters.jobs)"]
        args += activeCompilationConditions
        args += additionalFlags
        args += moduleCacheArgs
        args += buildParameters.sanitizers.compileSwiftFlags()
        args += ["-parseable-output"]

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !libraryBinaryPaths.isEmpty {
            args += ["-F", buildParameters.buildPath.pathString]
        }

        // Emit the ObjC compatibility header if enabled.
        if shouldEmitObjCCompatibilityHeader {
            args += ["-emit-objc-header", "-emit-objc-header-path", objCompatibilityHeaderPath.pathString]
        }

        // Add arguments needed for code coverage if it is enabled.
        if buildParameters.enableCodeCoverage {
            args += ["-profile-coverage-mapping", "-profile-generate"]
        }

        // Add arguments to colorize output if stdout is tty
        if BuildParameters.isTTY {
            args += ["-color-diagnostics"]
        }

        // Add the output for the `.swiftinterface`, if requested.
        if buildParameters.enableParseableModuleInterfaces {
            args += ["-emit-parseable-module-interface-path", parseableModuleInterfaceOutputPath.pathString]
        }

        // Add agruments from declared build settings.
        args += self.buildSettingsFlags()

        // User arguments (from -Xswiftc) should follow generated arguments to allow user overrides
        args += buildParameters.swiftCompilerFlags
        return args
    }

    public func emitCommandLine() -> [String] {
        var result: [String] = []
        result.append(buildParameters.toolchain.swiftCompiler.pathString)

        result.append("-module-name")
        result.append(target.c99name)

        result.append("-emit-dependencies")

        // FIXME: Do we always have a module?
        result.append("-emit-module")
        result.append("-emit-module-path")
        result.append(moduleOutputPath.pathString)

        result.append("-output-file-map")
        // FIXME: Eliminate side effect.
        result.append(try! writeOutputFileMap().pathString)

        switch target.type {
        case .library, .test:
            result.append("-parse-as-library")

        case .executable, .systemModule, .binary:
            do { }
        }

        if buildParameters.useWholeModuleOptimization {
            result.append("-whole-module-optimization")
            result.append("-num-threads")
            result.append(String(ProcessInfo.processInfo.activeProcessorCount))
        } else {
            result.append("-incremental")
        }

        result.append("-c")
        result.append(contentsOf: target.sources.paths.map { $0.pathString })

        result.append("-I")
        result.append(buildParameters.buildPath.pathString)

        result += compileArguments()
        return result
     }

    /// Command-line for emitting just the Swift module.
    public func emitModuleCommandLine() -> [String] {
        assert(buildParameters.emitSwiftModuleSeparately)

        var result: [String] = []
        result.append(buildParameters.toolchain.swiftCompiler.pathString)

        result.append("-module-name")
        result.append(target.c99name)
        result.append("-emit-module")
        result.append("-emit-module-path")
        result.append(moduleOutputPath.pathString)
        result += buildParameters.toolchain.extraSwiftCFlags

        result.append("-Xfrontend")
        result.append("-experimental-skip-non-inlinable-function-bodies")
        result.append("-force-single-frontend-invocation")

        if target.type == .library || target.type == .test {
            result.append("-parse-as-library")
        }

        // FIXME: Handle WMO

        for source in target.sources.paths {
            result.append(source.pathString)
        }

        result.append("-I")
        result.append(buildParameters.buildPath.pathString)

        // FIXME: Maybe refactor these into "common args".
        result += buildParameters.targetTripleArgs(for: target)
        result += ["-swift-version", swiftVersion.rawValue]
        result += optimizationArguments
        result += testingArguments
        result += ["-g"]
        result += ["-j\(buildParameters.jobs)"]
        result += activeCompilationConditions
        result += additionalFlags
        result += moduleCacheArgs
        result += self.buildSettingsFlags()

        return result
    }

    /// Command-line for emitting the object files.
    ///
    /// Note: This doesn't emit the module.
    public func emitObjectsCommandLine() -> [String] {
        assert(buildParameters.emitSwiftModuleSeparately)

        var result: [String] = []
        result.append(buildParameters.toolchain.swiftCompiler.pathString)

        result.append("-module-name")
        result.append(target.c99name)
        result.append("-incremental")
        result.append("-emit-dependencies")

        result.append("-output-file-map")
        // FIXME: Eliminate side effect.
        result.append(try! writeOutputFileMap().pathString)

        if target.type == .library || target.type == .test {
            result.append("-parse-as-library")
        }
        // FIXME: Handle WMO

        result.append("-c")
        for source in target.sources.paths {
            result.append(source.pathString)
        }

        result.append("-I")
        result.append(buildParameters.buildPath.pathString)

        result += buildParameters.targetTripleArgs(for: target)
        result += ["-swift-version", swiftVersion.rawValue]

        result += buildParameters.indexStoreArguments(for: target)
        result += buildParameters.toolchain.extraSwiftCFlags
        result += optimizationArguments
        result += testingArguments
        result += ["-g"]
        result += ["-j\(buildParameters.jobs)"]
        result += activeCompilationConditions
        result += additionalFlags
        result += moduleCacheArgs
        result += buildParameters.sanitizers.compileSwiftFlags()
        result += ["-parseable-output"]
        result += self.buildSettingsFlags()
        result += buildParameters.swiftCompilerFlags
        return result
    }

    /// Returns true if ObjC compatibility header should be emitted.
    private var shouldEmitObjCCompatibilityHeader: Bool {
        return buildParameters.triple.isDarwin() && target.type == .library
    }

    private func writeOutputFileMap() throws -> AbsolutePath {
        let path = tempsPath.appending(component: "output-file-map.json")
        let stream = BufferedOutputByteStream()

        stream <<< "{\n"

        let masterDepsPath = tempsPath.appending(component: "master.swiftdeps")
        stream <<< "  \"\": {\n"
        if buildParameters.useWholeModuleOptimization {
            let moduleName = target.c99name
            stream <<< "    \"dependencies\": \"" <<< tempsPath.appending(component: moduleName + ".d") <<< "\",\n"
            // FIXME: Need to record this deps file for processing it later.
            stream <<< "    \"object\": \"" <<< tempsPath.appending(component: moduleName + ".o") <<< "\",\n"
        }
        stream <<< "    \"swift-dependencies\": \"" <<< masterDepsPath.pathString <<< "\"\n"

        stream <<< "  },\n"

        // Write out the entries for each source file.
        let sources = target.sources.paths
        for (idx, source) in sources.enumerated() {
            let object = objects[idx]
            let objectDir = object.parentDirectory

            let sourceFileName = source.basenameWithoutExt

            let swiftDepsPath = objectDir.appending(component: sourceFileName + ".swiftdeps")

            stream <<< "  \"" <<< source.pathString <<< "\": {\n"

            if (!buildParameters.useWholeModuleOptimization) {
                let depsPath = objectDir.appending(component: sourceFileName + ".d")
                stream <<< "    \"dependencies\": \"" <<< depsPath.pathString <<< "\",\n"
                // FIXME: Need to record this deps file for processing it later.
            }

            stream <<< "    \"object\": \"" <<< object.pathString <<< "\",\n"

            let partialModulePath = objectDir.appending(component: sourceFileName + "~partial.swiftmodule")
            stream <<< "    \"swiftmodule\": \"" <<< partialModulePath.pathString <<< "\",\n"
            stream <<< "    \"swift-dependencies\": \"" <<< swiftDepsPath.pathString <<< "\"\n"
            stream <<< "  }" <<< ((idx + 1) < sources.count ? "," : "") <<< "\n"
        }

        stream <<< "}\n"

        try fs.createDirectory(path.parentDirectory, recursive: true)
        try fs.writeFileContents(path, bytes: stream.bytes)
        return path
    }

    /// Generates the module map for the Swift target and returns its path.
    private func generateModuleMap() throws -> AbsolutePath {
        let path = tempsPath.appending(component: moduleMapFilename)

        let stream = BufferedOutputByteStream()
        stream <<< "module \(target.c99name) {\n"
        stream <<< "    header \"" <<< objCompatibilityHeaderPath.pathString <<< "\"\n"
        stream <<< "    requires objc\n"
        stream <<< "}\n"

        // Return early if the contents are identical.
        if fs.isFile(path), try fs.readFileContents(path) == stream.bytes {
            return path
        }

        try fs.createDirectory(path.parentDirectory, recursive: true)
        try fs.writeFileContents(path, bytes: stream.bytes)

        return path
    }

    /// Returns the path to the ObjC compatibility header for this Swift target.
    var objCompatibilityHeaderPath: AbsolutePath {
        return tempsPath.appending(component: "\(target.name)-Swift.h")
    }

    /// Returns the build flags from the declared build settings.
    private func buildSettingsFlags() -> [String] {
        let scope = buildParameters.createScope(for: target)
        var flags: [String] = []

        // Swift defines.
        let swiftDefines = scope.evaluate(.SWIFT_ACTIVE_COMPILATION_CONDITIONS)
        flags += swiftDefines.map({ "-D" + $0 })

        // Frameworks.
        let frameworks = scope.evaluate(.LINK_FRAMEWORKS)
        flags += frameworks.flatMap({ ["-framework", $0] })

        // Other Swift flags.
        flags += scope.evaluate(.OTHER_SWIFT_FLAGS)

        // Add C flags by prefixing them with -Xcc.
        //
        // C defines.
        let cDefines = scope.evaluate(.GCC_PREPROCESSOR_DEFINITIONS)
        flags += cDefines.flatMap({ ["-Xcc", "-D" + $0] })

        // Header search paths.
        let headerSearchPaths = scope.evaluate(.HEADER_SEARCH_PATHS)
        flags += headerSearchPaths.flatMap({ path -> [String] in
            return ["-Xcc", "-I\(target.sources.root.appending(RelativePath(path)).pathString)"]
        })

        // Other C flags.
        flags += scope.evaluate(.OTHER_CFLAGS).flatMap({ ["-Xcc", $0] })

        return flags
    }

    /// A list of compilation conditions to enable for conditional compilation expressions.
    private var activeCompilationConditions: [String] {
        var compilationConditions = ["-DSWIFT_PACKAGE"]

        switch buildParameters.configuration {
        case .debug:
            compilationConditions += ["-DDEBUG"]
        case .release:
            break
        }

        return compilationConditions
    }

    /// Optimization arguments according to the build configuration.
    private var optimizationArguments: [String] {
        switch buildParameters.configuration {
        case .debug:
            return ["-Onone"]
        case .release:
            return ["-O"]
        }
    }

    /// Testing arguments according to the build configuration.
    private var testingArguments: [String] {
        switch buildParameters.configuration {
        case .debug:
            return ["-enable-testing"]
        case .release:
            if self.buildParameters.enableTestDiscovery {
                return ["-enable-testing"]
            } else {
                return []
            }
        }
    }

    /// Module cache arguments.
    private var moduleCacheArgs: [String] {
        return ["-module-cache-path", buildParameters.moduleCache.pathString]
    }
}

/// The build description for a product.
public final class ProductBuildDescription {

    /// The reference to the product.
    public let product: ResolvedProduct

    /// The build parameters.
    let buildParameters: BuildParameters

    /// The file system reference.
    let fs: FileSystem

    /// The path to the product binary produced.
    public var binary: AbsolutePath {
        return buildParameters.binaryPath(for: product)
    }

    /// The objects in this product.
    ///
    // Computed during build planning.
    public fileprivate(set) var objects = SortedArray<AbsolutePath>()

    /// The dynamic libraries this product needs to link with.
    // Computed during build planning.
    fileprivate(set) var dylibs: [ProductBuildDescription] = []

    /// Any additional flags to be added. These flags are expected to be computed during build planning.
    fileprivate var additionalFlags: [String] = []

    /// The list of targets that are going to be linked statically in this product.
    fileprivate var staticTargets: [ResolvedTarget] = []

    /// The list of Swift modules that should be passed to the linker. This is required for debugging to work.
    fileprivate var swiftASTs: SortedArray<AbsolutePath> = .init()

    /// Paths to the binary libraries the product depends on.
    fileprivate var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Path to the temporary directory for this product.
    var tempsPath: AbsolutePath {
        return buildParameters.buildPath.appending(component: product.name + ".product")
    }

    /// Path to the link filelist file.
    var linkFileListPath: AbsolutePath {
        return tempsPath.appending(component: "Objects.LinkFileList")
    }

    /// Diagnostics Engine for emitting diagnostics.
    let diagnostics: DiagnosticsEngine

    /// Create a build description for a product.
    init(product: ResolvedProduct, buildParameters: BuildParameters, fs: FileSystem, diagnostics: DiagnosticsEngine) {
        assert(product.type != .library(.automatic), "Automatic type libraries should not be described.")
        self.product = product
        self.buildParameters = buildParameters
        self.fs = fs
        self.diagnostics = diagnostics
    }

    /// Strips the arguments which should *never* be passed to Swift compiler
    /// when we're linking the product.
    ///
    /// We might want to get rid of this method once Swift driver can strip the
    /// flags itself, <rdar://problem/31215562>.
    private func stripInvalidArguments(_ args: [String]) -> [String] {
        let invalidArguments: Set<String> = ["-wmo", "-whole-module-optimization"]
        return args.filter({ !invalidArguments.contains($0) })
    }

    /// The arguments to link and create this product.
    public func linkArguments() -> [String] {
        var args = [buildParameters.toolchain.swiftCompiler.pathString]
        args += buildParameters.toolchain.extraSwiftCFlags
        args += buildParameters.sanitizers.linkSwiftFlags()
        args += additionalFlags

        // Pass `-g` during a *release* build so the Swift driver emits a dSYM file for the binary.
        if buildParameters.configuration == .release {
            if buildParameters.triple.isWindows() {
                args += ["-Xlinker", "-debug"]
            } else {
                args += ["-g"]
            }
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !libraryBinaryPaths.isEmpty {
            args += ["-F", buildParameters.buildPath.pathString]
        }

        args += ["-L", buildParameters.buildPath.pathString]
        args += ["-o", binary.pathString]
        args += ["-module-name", product.name.spm_mangledToC99ExtendedIdentifier()]
        args += dylibs.map({ "-l" + $0.product.name })

        // Add arguments needed for code coverage if it is enabled.
        if buildParameters.enableCodeCoverage {
            args += ["-profile-coverage-mapping", "-profile-generate"]
        }

        let containsSwiftTargets = product.containsSwiftTargets

        switch product.type {
        case .library(.automatic):
            fatalError()
        case .library(.static):
            // No arguments for static libraries.
            return []
        case .test:
            // Test products are bundle on macOS, executable on linux.
            if buildParameters.triple.isDarwin() {
                args += ["-Xlinker", "-bundle"]
            } else {
                args += ["-emit-executable"]
            }
        case .library(.dynamic):
            args += ["-emit-library"]
            if buildParameters.triple.isDarwin() {
                let relativePath = "@rpath/\(buildParameters.binaryRelativePath(for: product).pathString)"
                args += ["-Xlinker", "-install_name", "-Xlinker", relativePath]
            }
        case .executable:
            // Link the Swift stdlib statically, if requested.
            //
            // FIXME: This does not work for linux yet (SR-648).
            if buildParameters.shouldLinkStaticSwiftStdlib {
                if buildParameters.triple.isDarwin() {
                    diagnostics.emit(.swiftBackDeployError)
                }
            }
            args += ["-emit-executable"]
        }

        // Set rpath such that dynamic libraries are looked up
        // adjacent to the product.
        if buildParameters.triple.isLinux() {
            args += ["-Xlinker", "-rpath=$ORIGIN"]
        } else if buildParameters.triple.isDarwin() {
            let rpath = product.type == .test ? "@loader_path/../../../" : "@loader_path"
            args += ["-Xlinker", "-rpath", "-Xlinker", rpath]
        }
        args += ["@\(linkFileListPath.pathString)"]

        // Embed the swift stdlib library path inside tests and executables on Darwin.
        if containsSwiftTargets {
          switch product.type {
          case .library: break
          case .test, .executable:
              if buildParameters.triple.isDarwin() {
                  let stdlib = buildParameters.toolchain.macosSwiftStdlib
                  args += ["-Xlinker", "-rpath", "-Xlinker", stdlib.pathString]
              }
          }
        }

        // Don't link runtime compatibility patch libraries if there are no
        // Swift sources in the target.
        if !containsSwiftTargets {
          args += ["-runtime-compatibility-version", "none"]
        }

        // Add the target triple from the first target in the product.
        //
        // We can just use the first target of the product because the deployment target
        // setting is the package-level right now. We might need to figure out a better
        // answer for libraries if/when we support specifying deployment target at the
        // target-level.
        args += buildParameters.targetTripleArgs(for: product.targets[0])

        // Add arguments from declared build settings.
        args += self.buildSettingsFlags()

        // Add AST paths to make the product debuggable. This array is only populated when we're
        // building for Darwin in debug configuration.
        args += swiftASTs.flatMap{ ["-Xlinker", "-add_ast_path", "-Xlinker", $0.pathString] }

        // User arguments (from -Xlinker and -Xswiftc) should follow generated arguments to allow user overrides
        args += buildParameters.linkerFlags
        args += stripInvalidArguments(buildParameters.swiftCompilerFlags)

        // Add toolchain's libdir at the very end (even after the user -Xlinker arguments).
        //
        // This will allow linking to libraries shipped in the toolchain.
        let toolchainLibDir = buildParameters.toolchain.toolchainLibDir
        if fs.isDirectory(toolchainLibDir) {
            args += ["-L", toolchainLibDir.pathString]
        }

        return args
    }

    /// Writes link filelist to the filesystem.
    func writeLinkFilelist(_ fs: FileSystem) throws {
        let stream = BufferedOutputByteStream()

        for object in objects {
            stream <<< object.pathString.spm_shellEscaped() <<< "\n"
        }

        try fs.createDirectory(linkFileListPath.parentDirectory, recursive: true)
        try fs.writeFileContents(linkFileListPath, bytes: stream.bytes)
    }

    /// Returns the build flags from the declared build settings.
    private func buildSettingsFlags() -> [String] {
        var flags: [String] = []

        // Linked libraries.
        let libraries = OrderedSet(staticTargets.reduce([]) {
            $0 + buildParameters.createScope(for: $1).evaluate(.LINK_LIBRARIES)
        })
        flags += libraries.map({ "-l" + $0 })

        // Linked frameworks.
        let frameworks = OrderedSet(staticTargets.reduce([]) {
            $0 + buildParameters.createScope(for: $1).evaluate(.LINK_FRAMEWORKS)
        })
        flags += frameworks.flatMap({ ["-framework", $0] })

        // Other linker flags.
        for target in staticTargets {
            let scope = buildParameters.createScope(for: target)
            flags += scope.evaluate(.OTHER_LDFLAGS)
        }

        return flags
    }
}

/// A build plan for a package graph.
public class BuildPlan {

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// The linux main file is missing.
        case missingLinuxMain

        /// There is no buildable target in the graph.
        case noBuildableTarget

        public var description: String {
            switch self {
            case .missingLinuxMain:
                return "missing LinuxMain.swift file in the Tests directory"
            case .noBuildableTarget:
                return "the package does not contain a buildable target"
            }
        }
    }

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// The build environment.
    private var buildEnvironment: BuildEnvironment {
        buildParameters.buildEnvironment
    }

    /// The package graph.
    public let graph: PackageGraph

    /// The target build description map.
    public let targetMap: [ResolvedTarget: TargetBuildDescription]

    /// The product build description map.
    public let productMap: [ResolvedProduct: ProductBuildDescription]

    /// The build targets.
    public var targets: AnySequence<TargetBuildDescription> {
        return AnySequence(targetMap.values)
    }

    /// The products in this plan.
    public var buildProducts: AnySequence<ProductBuildDescription> {
        return AnySequence(productMap.values)
    }

    /// The filesystem to operate on.
    let fileSystem: FileSystem

    /// Diagnostics Engine for emitting diagnostics.
    let diagnostics: DiagnosticsEngine

    private static func planLinuxMain(
        _ buildParameters: BuildParameters,
        _ graph: PackageGraph
    ) throws -> [(ResolvedProduct, SwiftTargetBuildDescription)] {
        guard !buildParameters.triple.isDarwin() else {
            return []
        }

        var result: [(ResolvedProduct, SwiftTargetBuildDescription)] = []

        for testProduct in graph.allProducts where testProduct.type == .test {
            // Create the target description from the linux main if test discovery is off.
            if !buildParameters.enableTestDiscovery {
                guard let linuxMainTarget = testProduct.linuxMainTarget else {
                    throw Error.missingLinuxMain
                }

                let desc = try SwiftTargetBuildDescription(
                    target: linuxMainTarget,
                    buildParameters: buildParameters,
                    isTestTarget: true
                )

                result.append((testProduct, desc))
                continue
            }

            // We'll generate sources containing the test names as part of the build process.
            let derivedTestListDir = buildParameters.buildPath.appending(components: "\(testProduct.name)Testlist.derived")
            let mainFile = derivedTestListDir.appending(component: "main.swift")

            var paths: [AbsolutePath] = []
            paths.append(mainFile)
            for testTarget in testProduct.targets {
                let path = derivedTestListDir.appending(components: testTarget.name + ".swift")
                paths.append(path)
            }

            let src = Sources(paths: paths, root: derivedTestListDir)

            let swiftTarget = SwiftTarget(
                testDiscoverySrc: src,
                name: testProduct.name,
                dependencies: testProduct.underlyingProduct.targets.map { .target($0, conditions: []) }
            )
            let linuxMainTarget = ResolvedTarget(
                target: swiftTarget,
                dependencies: testProduct.targets.map { .target($0, conditions: []) }
            )

            let target = try SwiftTargetBuildDescription(
                target: linuxMainTarget,
                buildParameters: buildParameters,
                isTestTarget: true,
                testDiscoveryTarget: true
            )

            result.append((testProduct, target))
        }
        return result
    }

    /// Create a build plan with build parameters and a package graph.
    public init(
        buildParameters: BuildParameters,
        graph: PackageGraph,
        diagnostics: DiagnosticsEngine,
        fileSystem: FileSystem = localFileSystem
    ) throws {
        self.buildParameters = buildParameters
        self.graph = graph
        self.diagnostics = diagnostics
        self.fileSystem = fileSystem

        // Create build target description for each target which we need to plan.
        var targetMap = [ResolvedTarget: TargetBuildDescription]()
        for target in graph.allTargets {

            // Validate the product dependencies of this target.
            for dependency in target.dependencies {
                switch dependency {
                case .target: break
                case .product(let product, _):
                    if buildParameters.triple.isDarwin() {
                        BuildPlan.validateDeploymentVersionOfProductDependency(
                            product, forTarget: target, diagnostics: diagnostics)
                    }
                }
            }

            switch target.underlyingTarget {
            case is SwiftTarget:
                targetMap[target] = try .swift(SwiftTargetBuildDescription(target: target, buildParameters: buildParameters, fs: fileSystem))
            case is ClangTarget:
                targetMap[target] = try .clang(ClangTargetBuildDescription(
                    target: target,
                    buildParameters: buildParameters,
                    fileSystem: fileSystem))
            case is SystemLibraryTarget, is BinaryTarget:
                 break
            default:
                 fatalError("unhandled \(target.underlyingTarget)")
            }
        }

        /// Ensure we have at least one buildable target.
        guard !targetMap.isEmpty else {
            throw Error.noBuildableTarget
        }

        // Abort now if we have any diagnostics at this point.
        guard !diagnostics.hasErrors else {
            throw Diagnostics.fatalError
        }

        // Plan the linux main target.
        let results = try Self.planLinuxMain(buildParameters, graph)
        for result in results {
            targetMap[result.1.target] = .swift(result.1)
            linuxMainMap[result.0] = result.1.target
        }

        var productMap: [ResolvedProduct: ProductBuildDescription] = [:]
        // Create product description for each product we have in the package graph except
        // for automatic libraries because they don't produce any output.
        for product in graph.allProducts where product.type != .library(.automatic) {
            productMap[product] = ProductBuildDescription(
                product: product, buildParameters: buildParameters,
                fs: fileSystem,
                diagnostics: diagnostics
            )
        }

        self.productMap = productMap
        self.targetMap = targetMap
        // Finally plan these targets.
        try plan()
    }

    private var linuxMainMap: [ResolvedProduct: ResolvedTarget] = [:]

    static func validateDeploymentVersionOfProductDependency(
        _ product: ResolvedProduct,
        forTarget target: ResolvedTarget,
        diagnostics: DiagnosticsEngine
    ) {
        // Get the first target as supported platforms are on the top-level.
        // This will need to become a bit complicated once we have target-level platform support.
        let productTarget = product.underlyingProduct.targets[0]

        guard let productPlatform = productTarget.getSupportedPlatform(for: .macOS) else {
            fatalError("Expected supported platform macOS in product target \(productTarget)")
        }
        guard let targetPlatform = target.underlyingTarget.getSupportedPlatform(for: .macOS) else {
            fatalError("Expected supported platform macOS in target \(target)")
        }

        // Check if the version requirement is satisfied.
        //
        // If the product's platform version is greater than ours, then it is incompatible.
        if productPlatform.version > targetPlatform.version {
            diagnostics.emit(.productRequiresHigherPlatformVersion(
                target: target,
                targetPlatform: targetPlatform,
                product: product.name,
                productPlatform: productPlatform
            ))
        }
    }

    /// Plan the targets and products.
    private func plan() throws {
        // Plan targets.
        for buildTarget in targets {
            switch buildTarget {
            case .swift(let target):
                try plan(swiftTarget: target)
            case .clang(let target):
                plan(clangTarget: target)
            }
        }

        // Plan products.
        for buildProduct in buildProducts {
            try plan(buildProduct)
        }
        // FIXME: We need to find out if any product has a target on which it depends
        // both static and dynamically and then issue a suitable diagnostic or auto
        // handle that situation.
    }

    /// Plan a product.
    private func plan(_ buildProduct: ProductBuildDescription) throws {
        // Compute the product's dependency.
        let dependencies = computeDependencies(of: buildProduct.product)

        // Add flags for system targets.
        for systemModule in dependencies.systemModules {
            guard case let target as SystemLibraryTarget = systemModule.underlyingTarget else {
                fatalError("This should not be possible.")
            }
            // Add pkgConfig libs arguments.
            buildProduct.additionalFlags += pkgConfig(for: target).libs
        }

        // Add flags for binary dependencies.
        for binaryPath in dependencies.libraryBinaryPaths {
            if binaryPath.extension == "framework" {
                buildProduct.additionalFlags += ["-framework", binaryPath.basenameWithoutExt]
            } else if binaryPath.basename.starts(with: "lib") {
                buildProduct.additionalFlags += ["-l\(binaryPath.basenameWithoutExt.dropFirst(3))"]
            } else {
                diagnostics.emit(error: "unexpected binary framework")
            }
        }

        // Link C++ if needed.
        // Note: This will come from build settings in future.
        for target in dependencies.staticTargets {
            if case let target as ClangTarget = target.underlyingTarget, target.isCXX {
                buildProduct.additionalFlags += self.buildParameters.toolchain.extraCPPFlags
                break
            }
        }

        for target in dependencies.staticTargets {
            switch target.underlyingTarget {
            case is SwiftTarget:
                // Swift targets are guaranteed to have a corresponding Swift description.
                guard case .swift(let description) = targetMap[target]! else { fatalError() }

                // Based on the debugging strategy, we either need to pass swiftmodule paths to the
                // product or link in the wrapped module object. This is required for properly debugging
                // Swift products. Debugging statergy is computed based on the current platform we're
                // building for and is nil for the release configuration.
                switch buildParameters.debuggingStrategy {
                case .swiftAST:
                    buildProduct.swiftASTs.insert(description.moduleOutputPath)
                case .modulewrap:
                    buildProduct.objects += [description.wrappedModuleOutputPath]
                case nil:
                    break
                }
            default: break
            }
        }

        buildProduct.staticTargets = dependencies.staticTargets
        buildProduct.dylibs = dependencies.dylibs.map({ productMap[$0]! })
        buildProduct.objects += dependencies.staticTargets.flatMap({ targetMap[$0]!.objects })
        buildProduct.libraryBinaryPaths = dependencies.libraryBinaryPaths

        // Write the link filelist file.
        //
        // FIXME: We should write this as a custom llbuild task once we adopt it
        // as a library.
        try buildProduct.writeLinkFilelist(fileSystem)
    }

    /// Computes the dependencies of a product.
    private func computeDependencies(
        of product: ResolvedProduct
    ) -> (
        dylibs: [ResolvedProduct],
        staticTargets: [ResolvedTarget],
        systemModules: [ResolvedTarget],
        libraryBinaryPaths: Set<AbsolutePath>
    ) {

        // Sort the product targets in topological order.
        let nodes: [ResolvedTarget.Dependency] = product.targets.map { .target($0, conditions: []) }
        let allTargets = try! topologicalSort(nodes, successors: { dependency in
            switch dependency {
            // Include all the depenencies of a target.
            case .target(let target, _):
                return target.dependencies.filter { $0.satisfies(self.buildEnvironment) }

            // For a product dependency, we only include its content only if we
            // need to statically link it.
            case .product(let product, _):
                switch product.type {
                case .library(.automatic), .library(.static):
                    return product.targets.map { .target($0, conditions: []) }
                case .library(.dynamic), .test, .executable:
                    return []
                }
            }
        })

        // Create empty arrays to collect our results.
        var linkLibraries = [ResolvedProduct]()
        var staticTargets = [ResolvedTarget]()
        var systemModules = [ResolvedTarget]()
        var libraryBinaryPaths: Set<AbsolutePath> = []

        for dependency in allTargets {
            switch dependency {
            case .target(let target, _):
                switch target.type {
                // Include executable and tests only if they're top level contents
                // of the product. Otherwise they are just build time dependency.
                case .executable, .test:
                    if product.targets.contains(target) {
                        staticTargets.append(target)
                    }
                // Library targets should always be included.
                case .library:
                    staticTargets.append(target)
                // Add system target to system targets array.
                case .systemModule:
                    systemModules.append(target)
                // Add binary to binary paths set.
                case .binary:
                    guard let binaryTarget = target.underlyingTarget as? BinaryTarget else {
                        fatalError("should not happen")
                    }
                    if let library = xcFrameworkLibrary(for: binaryTarget) {
                        libraryBinaryPaths.insert(library.binaryPath)
                    }
                }

            case .product(let product, _):
                // Add the dynamic products to array of libraries to link.
                if product.type == .library(.dynamic) {
                    linkLibraries.append(product)
                }
            }
        }

        if !buildParameters.triple.isDarwin() {
            if product.type == .test {
                linuxMainMap[product].map{ staticTargets.append($0) }
            }
        }

        return (linkLibraries, staticTargets, systemModules, libraryBinaryPaths)
    }

    /// Plan a Clang target.
    private func plan(clangTarget: ClangTargetBuildDescription) {
        for case .target(let dependency, _) in clangTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case is SwiftTarget:
                if case let .swift(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }

            case let target as ClangTarget where target.type == .library:
                // Setup search paths for C dependencies:
                clangTarget.additionalFlags += ["-I", target.includeDir.pathString]

                // Add the modulemap of the dependency if it has one.
                if case let .clang(dependencyTargetDescription)? = targetMap[dependency] {
                    if let moduleMap = dependencyTargetDescription.moduleMap {
                        clangTarget.additionalFlags += ["-fmodule-map-file=\(moduleMap.pathString)"]
                    }
                }
            case let target as SystemLibraryTarget:
                clangTarget.additionalFlags += ["-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                clangTarget.additionalFlags += pkgConfig(for: target).cFlags
            case let target as BinaryTarget:
                if let library = xcFrameworkLibrary(for: target) {
                    if let headersPath = library.headersPath {
                        clangTarget.additionalFlags += ["-I", headersPath.pathString]
                    }
                    clangTarget.libraryBinaryPaths.insert(library.binaryPath)
                }
            default: continue
            }
        }
    }

    /// Plan a Swift target.
    private func plan(swiftTarget: SwiftTargetBuildDescription) throws {
        // We need to iterate recursive dependencies because Swift compiler needs to see all the targets a target
        // depends on.
        for case .target(let dependency, _) in swiftTarget.target.recursiveDependencies(satisfying: buildEnvironment) {
            switch dependency.underlyingTarget {
            case let underlyingTarget as ClangTarget where underlyingTarget.type == .library:
                guard case let .clang(target)? = targetMap[dependency] else {
                    fatalError("unexpected clang target \(underlyingTarget)")
                }
                // Add the path to modulemap of the dependency. Currently we require that all Clang targets have a
                // modulemap but we may want to remove that requirement since it is valid for a target to exist without
                // one. However, in that case it will not be importable in Swift targets. We may want to emit a warning
                // in that case from here.
                guard let moduleMap = target.moduleMap else { break }
                swiftTarget.additionalFlags += [
                    "-Xcc", "-fmodule-map-file=\(moduleMap.pathString)",
                    "-I", target.clangTarget.includeDir.pathString,
                ]
            case let target as SystemLibraryTarget:
                swiftTarget.additionalFlags += ["-Xcc", "-fmodule-map-file=\(target.moduleMapPath.pathString)"]
                swiftTarget.additionalFlags += pkgConfig(for: target).cFlags
            case let target as BinaryTarget:
                if let library = xcFrameworkLibrary(for: target) {
                    if let headersPath = library.headersPath {
                        swiftTarget.additionalFlags += ["-I", headersPath.pathString]
                    }
                    swiftTarget.libraryBinaryPaths.insert(library.binaryPath)
                }
            default:
                break
            }
        }
    }

    public func createAPIDigesterArgs() -> [String] {
        let buildPath = buildParameters.buildPath.pathString
        var arguments = ["-I", buildPath]

        arguments += buildParameters.toolchain.extraSwiftCFlags

        // Add the search path to the directory containing the modulemap file.
        for target in targets {
            switch target {
            case .swift: break
            case .clang(let targetDescription):
                if let includeDir = targetDescription.moduleMap?.parentDirectory {
                    arguments += ["-I", includeDir.pathString]
                }
            }
        }

        // Add search paths from the system library targets.
        for target in graph.reachableTargets {
            if let systemLib = target.underlyingTarget as? SystemLibraryTarget {
                for flag in self.pkgConfig(for: systemLib).cFlags {
                    // The api-digester tool doesn't like `-I<Foo>` style for some reason.
                    if flag.hasPrefix("-I") && flag.count > 2 {
                        arguments += ["-I", String(flag.dropFirst(2))]
                    } else {
                        arguments.append(flag)
                    }
                }
                // Add the path to the module map.
                arguments += ["-I", systemLib.moduleMapPath.parentDirectory.pathString]
            }
        }

        return arguments
    }

    /// Creates arguments required to launch the Swift REPL that will allow
    /// importing the modules in the package graph.
    public func createREPLArguments() -> [String] {
        let buildPath = buildParameters.buildPath.pathString
        var arguments = ["-I" + buildPath, "-L" + buildPath]

        // Link the special REPL product that contains all of the library targets.
        let replProductName = graph.rootPackages[0].manifest.name + Product.replProductSuffix
        arguments.append("-l" + replProductName)

        // The graph should have the REPL product.
        assert(graph.allProducts.first(where: { $0.name == replProductName }) != nil)

        // Add the search path to the directory containing the modulemap file.
        for target in targets {
            switch target {
                case .swift: break
            case .clang(let targetDescription):
                if let includeDir = targetDescription.moduleMap?.parentDirectory {
                    arguments += ["-I\(includeDir.pathString)"]
                }
            }
        }

        // Add search paths from the system library targets.
        for target in graph.reachableTargets {
            if let systemLib = target.underlyingTarget as? SystemLibraryTarget {
                arguments += self.pkgConfig(for: systemLib).cFlags
            }
        }

        return arguments
    }

    /// Get pkgConfig arguments for a system library target.
    private func pkgConfig(for target: SystemLibraryTarget) -> (cFlags: [String], libs: [String]) {
        // If we already have these flags, we're done.
        if let flags = pkgConfigCache[target] {
            return flags
        }
        // Otherwise, get the result and cache it.
        guard let result = pkgConfigArgs(for: target, diagnostics: diagnostics) else {
            pkgConfigCache[target] = ([], [])
            return pkgConfigCache[target]!
        }
        // If there is no pc file on system and we have an available provider, emit a warning.
        if let provider = result.provider, result.couldNotFindConfigFile {
            diagnostics.emit(.pkgConfigHint(pkgConfigName: result.pkgConfigName, installText: provider.installText))
        } else if let error = result.error {
            diagnostics.emit(
                .warning(PkgConfigGenericDiagnostic(error: "\(error)")),
                location: PkgConfigDiagnosticLocation(pcFile: result.pkgConfigName, target: target.name)
            )
        }
        pkgConfigCache[target] = (result.cFlags, result.libs)
        return pkgConfigCache[target]!
    }

    /// Extracts the library to building against from a XCFramework.
    private func xcFrameworkLibrary(for target: BinaryTarget) -> LibraryInfo? {
        func calculateLibraryInfo() -> LibraryInfo? {
            // Parse the XCFramework's Info.plist.
            let infoPath = target.artifactPath.appending(component: "Info.plist")
            guard let info = XCFrameworkInfo(path: infoPath, diagnostics: diagnostics, fileSystem: fileSystem) else {
                return nil
            }

            // Check that it supports the target platform and architecture.
            guard let library = info.libraries.first(where: {
                return $0.platform == buildParameters.triple.os.asXCFrameworkPlatformString && $0.architectures.contains(buildParameters.triple.arch.rawValue)
            }) else {
                diagnostics.emit(error: """
                    artifact '\(target.name)' does not support the target platform and architecture \
                    ('\(buildParameters.triple)')
                    """)
                return nil
            }

            let libraryDirectory = target.artifactPath.appending(component: library.libraryIdentifier)
            let binaryPath = libraryDirectory.appending(component: library.libraryPath)
            let headersPath = library.headersPath.map({ libraryDirectory.appending(component: $0) })
            return LibraryInfo(binaryPath: binaryPath, headersPath: headersPath)
        }

        // If we don't have the library information yet, calculate it.
        if !xcFrameworkCache.keys.contains(target) {
            xcFrameworkCache[target] = calculateLibraryInfo()
        }

        return xcFrameworkCache[target]!
    }

    /// Cache for pkgConfig flags.
    private var pkgConfigCache = [SystemLibraryTarget: (cFlags: [String], libs: [String])]()

    /// Cache for xcframework library information.
    private var xcFrameworkCache = [BinaryTarget: LibraryInfo?]()
}

/// Information about a library.
private struct LibraryInfo: Equatable {

    /// The path to the binary.
    let binaryPath: AbsolutePath

    /// The path to the headers directory, if one exists.
    let headersPath: AbsolutePath?
}

private extension Diagnostic.Message {
    static var swiftBackDeployError: Diagnostic.Message {
        .warning("Swift compiler no longer supports statically linking the Swift libraries. They're included in the OS by default starting with macOS Mojave 10.14.4 beta 3. For macOS Mojave 10.14.3 and earlier, there's an optional Swift library package that can be downloaded from \"More Downloads\" for Apple Developers at https://developer.apple.com/download/more/")
    }

    static func productRequiresHigherPlatformVersion(
        target: ResolvedTarget,
        targetPlatform: SupportedPlatform,
        product: String,
        productPlatform: SupportedPlatform
    ) -> Diagnostic.Message {
        .error("""
            the \(target.type.rawValue) '\(target.name)' requires \
            \(targetPlatform.platform.name) \(targetPlatform.version.versionString), \
            but depends on the product '\(product)' which requires \
            \(productPlatform.platform.name) \(productPlatform.version.versionString); \
            consider changing the \(target.type.rawValue) '\(target.name)' to require \
            \(productPlatform.platform.name) \(productPlatform.version.versionString) or later, \
            or the product '\(product)' to require \
            \(targetPlatform.platform.name) \(targetPlatform.version.versionString) or earlier.
            """)
    }

    static func pkgConfigHint(pkgConfigName: String, installText: String) -> Diagnostic.Message {
        .warning(PkgConfigHintDiagnostic(pkgConfigName: pkgConfigName, installText: installText))
    }

    static func binaryTargetsNotSupported() -> Diagnostic.Message {
        .error("binary targets are not supported on this platform")
    }
}

extension BuildParameters {
    /// Returns a target's bundle path inside the build directory.
    fileprivate func bundlePath(for target: ResolvedTarget) -> AbsolutePath? {
        target.underlyingTarget.bundleName
        .map{ $0 + triple.nsbundleExtension }
        .map(buildPath.appending(component:))
    }
}

extension FileSystem {
    /// Write bytes to the path if the given contents are different.
    func writeIfChanged(path: AbsolutePath, bytes: ByteString) throws {
        try createDirectory(path.parentDirectory, recursive: true)

        // Return if the contents are same.
        if isFile(path), try readFileContents(path) == bytes {
            return
        }

        try writeFileContents(path, bytes: bytes)
    }
}

/// Generate the resource bundle Info.plist.
private func generateResourceInfoPlist(
    for target: ResolvedTarget,
    to path: AbsolutePath,
    fileSystem: FileSystem = localFileSystem
) throws -> Bool {
    guard let defaultLocalization = target.underlyingTarget.defaultLocalization else {
        return false
    }

    let stream = BufferedOutputByteStream()
    stream <<< """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>\(defaultLocalization)</string>
        </dict>
        </plist>
        """

    try fileSystem.writeIfChanged(path: path, bytes: stream.bytes)
    return true
}

fileprivate extension Triple.OS {
    /// Returns a representation of the receiver that can be compared with platform strings declared in an XCFramework.
    var asXCFrameworkPlatformString: String? {
        switch self {
        case .darwin, .linux, .wasi, .windows:
            return nil // XCFrameworks do not support any of these platforms today.
        case .macOS:
            return "macos"
        }
    }
}
