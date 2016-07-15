/*
 This source file is part of the Swift.org open source project
 
 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basic
import Get
import PackageModel
import PackageLoading

// FIXME: This doesn't belong here.
import func POSIX.exit

enum PackageGraphError: Swift.Error {
    case duplicateModule(String)
}

extension PackageGraphError: FixableError {
    var error: String {
        switch self {
        case .duplicateModule(let name):
            return "multiple modules with the name \(name) found"
        }
    }

    var fix: String? {
        switch self {
        case .duplicateModule(_):
            return "modules should have a unique name across dependencies"
        }
    }
}

/// A helper class for loading a package graph.
public struct PackageGraphLoader {
    /// The manifest loader.
    public let manifestLoader: ManifestLoader
    
    /// Create a package loader.
    public init(manifestLoader: ManifestLoader) {
        self.manifestLoader = manifestLoader
    }

    /// Load the package graph for the given package path.
    ///
    /// - Parameters:
    ///   - ignoreDependencies: If true, then skip resolution (and loading) of the package dependencies.
    public func loadPackage(at path: AbsolutePath, ignoreDependencies: Bool) throws -> PackageGraph {
        // Create the packages directory container.
        let packagesDirectory = PackagesDirectory(root: path, manifestLoader: manifestLoader)

        // Fetch and load the manifets.
        let (rootManifest, externalManifests) = try packagesDirectory.loadManifests(ignoreDependencies: ignoreDependencies)

        // Create the packages.
        let rootPackage = Package(manifest: rootManifest)
        let externalPackages = externalManifests.map{ Package(manifest: $0) }

        // Load all of the package dependencies.
        //
        // FIXME: Do this concurrently with creating the packages so we can create immutable ones.
        let pkgs = externalPackages + [rootPackage]
        for pkg in pkgs {
            // FIXME: This is inefficient.
            pkg.dependencies = pkg.manifest.package.dependencies.map{ dep in pkgs.pick{ dep.url == $0.url }! }
        }

        // Convert to modules.
        //
        // FIXME: This needs to be torn about, the module conversion should be
        // done on an individual package basis.
        let (modules, externalModules, products) = try createModules(rootPackage, externalPackages: externalPackages)

        return PackageGraph(rootPackage: rootPackage, modules: modules, externalModules: Set(externalModules), products: products)
    }
}

/// Load packages into a complete set of modules and products.
private func createModules(_ rootPackage: Package, externalPackages: [Package]) throws -> (modules: [Module], externalModules: [Module], products: [Product]) {
    var products: [Product] = []
    var map: [Package: [Module]] = [:]
    
    let packages = externalPackages + [rootPackage]

    for package in packages {
        var modules: [Module]
        do {
            modules = try package.modules()
        } catch ModuleError.noModules(let pkg) where pkg === rootPackage {
            // Ignore and print warning if root package doesn't contain any sources.
            print("warning: root package '\(pkg)' does not contain any sources")
            if packages.count == 1 { exit(0) } //Exit now if there is no more packages 
            modules = []
        }

        if package == rootPackage {
            // TODO: allow testing of external package tests.
            modules += try package.testModules(modules: modules)
        }

        map[package] = modules
        products += try package.products(modules)
    }

    // ensure modules depend on the modules of any dependent packages
    fillModuleGraph(packages, modulesForPackage: { map[$0]! })

    let modules = try recursiveDependencies(packages.flatMap{ map[$0] ?? [] })
    let externalModules = try recursiveDependencies(externalPackages.flatMap{ map[$0] ?? [] })

    return (modules, externalModules, products)
}

/// Add inter-package dependencies.
///
/// This function will add cross-package dependencies between a module and all
/// of the modules produced by any package in the transitive closure of its
/// containing package's dependencies.
private func fillModuleGraph(_ packages: [Package], modulesForPackage: (Package) -> [Module]) {
    for package in packages {
        let packageModules = modulesForPackage(package)
        let dependencies = try! topologicalSort(package.dependencies, successors: { $0.dependencies })
        for dep in dependencies {
            let depModules = modulesForPackage(dep).filter{
                guard !$0.isTest else { return false }

                switch $0 {
                case let module as SwiftModule where module.type == .library:
                    return true
                case is CModule:
                    return true
                default:
                    return false
                }
            }
            for module in packageModules {
                // FIXME: This is inefficient.
                module.dependencies.insert(contentsOf: depModules, at: 0)
            }
        }
    }
}

private func recursiveDependencies(_ modules: [Module]) throws -> [Module] {
    // FIXME: Refactor this to a common algorithm.
    var stack = modules
    var set = Set<Module>()
    var rv = [Module]()

    while stack.count > 0 {
        let top = stack.removeFirst()
        if !set.contains(top) {
            rv.append(top)
            set.insert(top)
            stack += top.dependencies
        } else {
            // See if the module in the set is actually the same.
            guard let index = set.index(of: top),
                  top.sources.root != set[index].sources.root else {
                continue;
            }

            throw PackageGraphError.duplicateModule(top.name)
        }
    }

    return rv
}
