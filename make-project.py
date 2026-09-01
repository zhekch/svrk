#!/usr/bin/env python3
"""
Generate SwissTransit.xcodeproj.

Hand-maintaining a project.pbxproj is a bad trade: it is a 1970s plist full of
24-hex-digit object ids, and every new source file means editing four places
correctly. Generating it means adding a file is `python3 make-project.py`.

Object ids are derived from the thing they identify (md5 of a stable key), so
regenerating produces a byte-identical project rather than a diff of shuffled
identifiers.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = "SwissTransit"
WATCH_APP = "SwissTransitWatch"
WATCH_TARGET = "SwissTransit Watch App"
UI_TESTS = "SwissTransitUITests"
UI_TEST_TARGET = "SwissTransitUITests"
BUNDLE_ID = "com.kexts.swisstransit"
DEPLOYMENT = "17.0"
WATCH_DEPLOYMENT = "10.0"


def oid(key: str) -> str:
    """A stable 24-hex-character object id."""
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def swift_sources(directory: str) -> list[str]:
    found = []
    for base, dirs, files in os.walk(os.path.join(ROOT, directory)):
        dirs[:] = [d for d in dirs if d != "Resources"]
        for name in sorted(files):
            if name.endswith(".swift"):
                found.append(os.path.relpath(os.path.join(base, name), ROOT))
    return sorted(found)


IOS_SOURCES = swift_sources(APP)
# Only the packed-file reader and route matcher are shared with the phone. Compile these
# dependency-free files directly into the watch executable instead of linking
# the full TransitCore package, whose formation, disruption, geometry and
# vehicle-model services have no place on a watch.
WATCH_CORE_ROOT = "Packages/TransitCore/Sources/TransitCore"
WATCH_CORE_SOURCES = [
    f"{WATCH_CORE_ROOT}/BinaryFormat.swift",
    f"{WATCH_CORE_ROOT}/Categories.swift",
    f"{WATCH_CORE_ROOT}/Geo.swift",
    f"{WATCH_CORE_ROOT}/Models.swift",
    f"{WATCH_CORE_ROOT}/RelationProjection.swift",
    f"{WATCH_CORE_ROOT}/RelationSpatialIndex.swift",
    f"{WATCH_CORE_ROOT}/RouteRelations.swift",
    f"{WATCH_CORE_ROOT}/StopRegister.swift",
    f"{WATCH_CORE_ROOT}/TimetableStore.swift",
]
WATCH_SOURCES = sorted(swift_sources(WATCH_APP) + WATCH_CORE_SOURCES)
UI_TEST_SOURCES = swift_sources(UI_TESTS)
ALL_SOURCES = sorted(set(IOS_SOURCES + WATCH_SOURCES + UI_TEST_SOURCES))
if not IOS_SOURCES:
    sys.exit("no Swift sources found")

# Resources: the packed data as a folder reference (so it lands as Data/ in the
# bundle, which is what Fleet.load expects), and the generated secrets plist.
RESOURCES = [
    (f"{APP}/Resources/Data", "folder"),
    (f"{APP}/Resources/Secrets.plist", "text.plist.xml"),
    # What the app already knew about train formations when it was built.
    # Its own file rather than a member of Data/, which the packing script in
    # the repository root rewrites wholesale — a seed dropped in there would be
    # deleted by the next `pack-ios-data`. Copy the device's own copy over this
    # one (Settings has a share button for it) to carry what it has learned
    # into the next build.
    (f"{APP}/Resources/vehicle-layouts.json", "text.json"),
    # The phone icon is target-local so changing it cannot alter the watch app.
    (f"{APP}/Resources/AppIcon.icon", "folder.iconcomposer.icon"),
]
WATCH_RESOURCES = [
    # A sub-1 MB, pre-simplified derivative of the existing OSM railway graph.
    # Keeping it in the app makes the overlay reliable offline without loading
    # the 17 MB routing graph (and its much larger in-memory index) on the watch.
    (f"{WATCH_APP}/Resources/watch-rail-overlay-v1.bin", "file"),
    # Ordered OSM service paths, simplified to watch resolution and stripped of
    # way ids. Memory-mapped on demand so visible vehicles can follow train,
    # tram, bus and ferry routes without MapKit routing requests.
    (f"{WATCH_APP}/Resources/watch-route-relations-v1.bin", "file"),
    # A separate Icon Composer package, compiled only into the watch bundle.
    (f"{WATCH_APP}/Resources/AppIcon_watch.icon", "folder.iconcomposer.icon"),
]
ALL_RESOURCES = RESOURCES + WATCH_RESOURCES

PACKAGES = [
    ("TransitCore", "Packages/TransitCore"),
    ("MapboxMaps", "Vendor/mapbox-maps-ios"),
]
WATCH_PACKAGES = []

out = []
w = out.append

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {};")
w("\tobjectVersion = 60;")
w("\tobjects = {")

# ---------------------------------------------------------------- build files
w("\n/* Begin PBXBuildFile section */")
for path in IOS_SOURCES:
    w(f"\t\t{oid('bf:' + path)} /* {os.path.basename(path)} in Sources */ = "
      f"{{isa = PBXBuildFile; fileRef = {oid('fr:' + path)} /* {os.path.basename(path)} */; }};")
for path in WATCH_SOURCES:
    w(f"\t\t{oid('bf:watch:' + path)} /* {os.path.basename(path)} in Sources */ = "
      f"{{isa = PBXBuildFile; fileRef = {oid('fr:' + path)} /* {os.path.basename(path)} */; }};")
for path in UI_TEST_SOURCES:
    w(f"\t\t{oid('bf:ui-test:' + path)} /* {os.path.basename(path)} in Sources */ = "
      f"{{isa = PBXBuildFile; fileRef = {oid('fr:' + path)} /* {os.path.basename(path)} */; }};")
for path, _ in RESOURCES:
    w(f"\t\t{oid('bf:' + path)} /* {os.path.basename(path)} in Resources */ = "
      f"{{isa = PBXBuildFile; fileRef = {oid('fr:' + path)} /* {os.path.basename(path)} */; }};")
for path, _ in WATCH_RESOURCES:
    w(f"\t\t{oid('bf:watch:resource:' + path)} /* {os.path.basename(path)} in Resources */ = "
      f"{{isa = PBXBuildFile; fileRef = {oid('fr:' + path)} /* {os.path.basename(path)} */; }};")
for product, _ in PACKAGES:
    w(f"\t\t{oid('bf:pkg:' + product)} /* {product} in Frameworks */ = "
      f"{{isa = PBXBuildFile; productRef = {oid('prod:' + product)} /* {product} */; }};")
for product in WATCH_PACKAGES:
    w(f"\t\t{oid('bf:watch:pkg:' + product)} /* {product} in Frameworks */ = "
      f"{{isa = PBXBuildFile; productRef = {oid('prod:' + product)} /* {product} */; }};")
w(f"\t\t{oid('bf:embed:watch')} /* {WATCH_TARGET}.app in Embed Watch Content */ = "
  f"{{isa = PBXBuildFile; fileRef = {oid('product:watch')} /* {WATCH_TARGET}.app */; "
  "settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };")
w("/* End PBXBuildFile section */")

# ------------------------------------------------------------ file references
w("\n/* Begin PBXFileReference section */")
w(f"\t\t{oid('product')} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = "
  f'wrapper.application; includeInIndex = 0; path = "{APP}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
w(f"\t\t{oid('product:watch')} /* {WATCH_TARGET}.app */ = {{isa = PBXFileReference; "
  f'explicitFileType = wrapper.application; includeInIndex = 0; path = "{WATCH_TARGET}.app"; '
  'sourceTree = BUILT_PRODUCTS_DIR; };')
w(f"\t\t{oid('product:ui-tests')} /* {UI_TEST_TARGET}.xctest */ = {{isa = PBXFileReference; "
  f'explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{UI_TEST_TARGET}.xctest"; '
  'sourceTree = BUILT_PRODUCTS_DIR; };')
for path in ALL_SOURCES:
    w(f"\t\t{oid('fr:' + path)} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; "
      f"lastKnownFileType = sourcecode.swift; path = {os.path.basename(path)}; sourceTree = \"<group>\"; }};")
for path, kind in ALL_RESOURCES:
    key = "lastKnownFileType"
    w(f"\t\t{oid('fr:' + path)} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; "
      f"{key} = {kind}; path = {os.path.basename(path)}; sourceTree = \"<group>\"; }};")
w("/* End PBXFileReference section */")

# -------------------------------------------------------------------- groups
by_dir: dict[str, list[str]] = {}
for path in ALL_SOURCES:
    by_dir.setdefault(os.path.dirname(path), []).append(path)
for path, _ in ALL_RESOURCES:
    by_dir.setdefault(os.path.dirname(path), []).append(path)

w("\n/* Begin PBXGroup section */")

# Root.
children = [
    f"\t\t\t\t{oid('group:' + APP)} /* {APP} */,",
    f"\t\t\t\t{oid('group:' + WATCH_APP)} /* {WATCH_APP} */,",
    f"\t\t\t\t{oid('group:' + UI_TESTS)} /* {UI_TESTS} */,",
    f"\t\t\t\t{oid('group:watch-core')} /* Watch Archive Core */,",
    f"\t\t\t\t{oid('group:products')} /* Products */,",
]
w(f"\t\t{oid('group:root')} = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
out.extend(children)
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w(f"\t\t{oid('group:products')} /* Products */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{oid('product')} /* {APP}.app */,")
w(f"\t\t\t\t{oid('product:watch')} /* {WATCH_TARGET}.app */,")
w(f"\t\t\t\t{oid('product:ui-tests')} /* {UI_TEST_TARGET}.xctest */,")
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w(f"\t\t{oid('group:watch-core')} /* Watch Archive Core */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for path in WATCH_CORE_SOURCES:
    w(f"\t\t\t\t{oid('fr:' + path)} /* {os.path.basename(path)} */,")
w("\t\t\t);")
w(f"\t\t\tpath = {WATCH_CORE_ROOT};")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

# One group per directory under each application source root.
for source_root in (APP, WATCH_APP, UI_TESTS):
    subdirs = sorted(
        d for d in by_dir
        if d != source_root and d.startswith(source_root + os.sep)
    )
    w(f"\t\t{oid('group:' + source_root)} /* {source_root} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for d in subdirs:
        w(f"\t\t\t\t{oid('group:' + d)} /* {os.path.basename(d)} */,")
    for path in sorted(by_dir.get(source_root, [])):
        w(f"\t\t\t\t{oid('fr:' + path)} /* {os.path.basename(path)} */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = {source_root};")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    for d in subdirs:
        w(f"\t\t{oid('group:' + d)} /* {os.path.basename(d)} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for path in sorted(by_dir[d]):
            w(f"\t\t\t\t{oid('fr:' + path)} /* {os.path.basename(path)} */,")
        w("\t\t\t);")
        w(f"\t\t\tpath = {os.path.basename(d)};")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")
w("/* End PBXGroup section */")

# ------------------------------------------------------------- build phases
w("\n/* Begin PBXSourcesBuildPhase section */")
w(f"\t\t{oid('phase:sources')} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for path in IOS_SOURCES:
    w(f"\t\t\t\t{oid('bf:' + path)} /* {os.path.basename(path)} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w(f"\t\t{oid('phase:watch:sources')} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for path in WATCH_SOURCES:
    w(f"\t\t\t\t{oid('bf:watch:' + path)} /* {os.path.basename(path)} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w(f"\t\t{oid('phase:ui-tests:sources')} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for path in UI_TEST_SOURCES:
    w(f"\t\t\t\t{oid('bf:ui-test:' + path)} /* {os.path.basename(path)} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")

w("\n/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{oid('phase:resources')} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for path, _ in RESOURCES:
    w(f"\t\t\t\t{oid('bf:' + path)} /* {os.path.basename(path)} in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w(f"\t\t{oid('phase:watch:resources')} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for path, _ in WATCH_RESOURCES:
    w(f"\t\t\t\t{oid('bf:watch:resource:' + path)} /* {os.path.basename(path)} in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")

w("\n/* Begin PBXFrameworksBuildPhase section */")
w(f"\t\t{oid('phase:frameworks')} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for product, _ in PACKAGES:
    w(f"\t\t\t\t{oid('bf:pkg:' + product)} /* {product} in Frameworks */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w(f"\t\t{oid('phase:watch:frameworks')} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for product in WATCH_PACKAGES:
    w(f"\t\t\t\t{oid('bf:watch:pkg:' + product)} /* {product} in Frameworks */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w(f"\t\t{oid('phase:ui-tests:frameworks')} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = ();")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")

# The companion app owns installation. Its Watch/ directory contains this
# product, and the target dependency makes sure that product exists first.
w("\n/* Begin PBXContainerItemProxy section */")
w(f"\t\t{oid('proxy:watch')} /* PBXContainerItemProxy */ = {{")
w("\t\t\tisa = PBXContainerItemProxy;")
w(f"\t\t\tcontainerPortal = {oid('project')} /* Project object */;")
w("\t\t\tproxyType = 1;")
w(f"\t\t\tremoteGlobalIDString = {oid('target:watch')};")
w(f"\t\t\tremoteInfo = \"{WATCH_TARGET}\";")
w("\t\t};")
w(f"\t\t{oid('proxy:ui-tests:app')} /* PBXContainerItemProxy */ = {{")
w("\t\t\tisa = PBXContainerItemProxy;")
w(f"\t\t\tcontainerPortal = {oid('project')} /* Project object */;")
w("\t\t\tproxyType = 1;")
w(f"\t\t\tremoteGlobalIDString = {oid('target')};")
w(f"\t\t\tremoteInfo = {APP};")
w("\t\t};")
w("/* End PBXContainerItemProxy section */")

w("\n/* Begin PBXCopyFilesBuildPhase section */")
w(f"\t\t{oid('phase:embed:watch')} /* Embed Watch Content */ = {{")
w("\t\t\tisa = PBXCopyFilesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";")
w("\t\t\tdstSubfolderSpec = 16;")
w("\t\t\tfiles = (")
w(f"\t\t\t\t{oid('bf:embed:watch')} /* {WATCH_TARGET}.app in Embed Watch Content */,")
w("\t\t\t);")
w("\t\t\tname = \"Embed Watch Content\";")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXCopyFilesBuildPhase section */")

# -------------------------------------------------------------------- target
w("\n/* Begin PBXNativeTarget section */")
w(f"\t\t{oid('target')} /* {APP} */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {oid('conflist:target')};")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{oid('phase:sources')} /* Sources */,")
w(f"\t\t\t\t{oid('phase:frameworks')} /* Frameworks */,")
w(f"\t\t\t\t{oid('phase:resources')} /* Resources */,")
w(f"\t\t\t\t{oid('phase:embed:watch')} /* Embed Watch Content */,")
w("\t\t\t);")
w("\t\t\tbuildRules = ();")
w("\t\t\tdependencies = (")
w(f"\t\t\t\t{oid('dependency:watch')} /* PBXTargetDependency */,")
w("\t\t\t);")
w(f"\t\t\tname = {APP};")
w("\t\t\tpackageProductDependencies = (")
for product, _ in PACKAGES:
    w(f"\t\t\t\t{oid('prod:' + product)} /* {product} */,")
w("\t\t\t);")
w(f"\t\t\tproductName = {APP};")
w(f"\t\t\tproductReference = {oid('product')} /* {APP}.app */;")
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")
w(f"\t\t{oid('target:watch')} /* {WATCH_TARGET} */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {oid('conflist:watch')};")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{oid('phase:watch:sources')} /* Sources */,")
w(f"\t\t\t\t{oid('phase:watch:frameworks')} /* Frameworks */,")
w(f"\t\t\t\t{oid('phase:watch:resources')} /* Resources */,")
w("\t\t\t);")
w("\t\t\tbuildRules = ();")
w("\t\t\tdependencies = ();")
w(f"\t\t\tname = \"{WATCH_TARGET}\";")
w("\t\t\tpackageProductDependencies = (")
for product in WATCH_PACKAGES:
    w(f"\t\t\t\t{oid('prod:' + product)} /* {product} */,")
w("\t\t\t);")
w(f"\t\t\tproductName = \"{WATCH_TARGET}\";")
w(f"\t\t\tproductReference = {oid('product:watch')} /* {WATCH_TARGET}.app */;")
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")
w(f"\t\t{oid('target:ui-tests')} /* {UI_TEST_TARGET} */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {oid('conflist:ui-tests')};")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{oid('phase:ui-tests:sources')} /* Sources */,")
w(f"\t\t\t\t{oid('phase:ui-tests:frameworks')} /* Frameworks */,")
w("\t\t\t);")
w("\t\t\tbuildRules = ();")
w("\t\t\tdependencies = (")
w(f"\t\t\t\t{oid('dependency:ui-tests:app')} /* PBXTargetDependency */,")
w("\t\t\t);")
w(f"\t\t\tname = {UI_TEST_TARGET};")
w("\t\t\tpackageProductDependencies = ();")
w(f"\t\t\tproductName = {UI_TEST_TARGET};")
w(f"\t\t\tproductReference = {oid('product:ui-tests')} /* {UI_TEST_TARGET}.xctest */;")
w("\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";")
w("\t\t};")
w("/* End PBXNativeTarget section */")

w("\n/* Begin PBXTargetDependency section */")
w(f"\t\t{oid('dependency:watch')} /* PBXTargetDependency */ = {{")
w("\t\t\tisa = PBXTargetDependency;")
w(f"\t\t\ttarget = {oid('target:watch')} /* {WATCH_TARGET} */;")
w(f"\t\t\ttargetProxy = {oid('proxy:watch')} /* PBXContainerItemProxy */;")
w("\t\t};")
w(f"\t\t{oid('dependency:ui-tests:app')} /* PBXTargetDependency */ = {{")
w("\t\t\tisa = PBXTargetDependency;")
w(f"\t\t\ttarget = {oid('target')} /* {APP} */;")
w(f"\t\t\ttargetProxy = {oid('proxy:ui-tests:app')} /* PBXContainerItemProxy */;")
w("\t\t};")
w("/* End PBXTargetDependency section */")

# ------------------------------------------------------------------- project
w("\n/* Begin PBXProject section */")
w(f"\t\t{oid('project')} /* Project object */ = {{")
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 2700;")
w("\t\t\t\tLastUpgradeCheck = 2700;")
w("\t\t\t\tTargetAttributes = {")
w(f"\t\t\t\t\t{oid('target')} = {{ CreatedOnToolsVersion = 27.0; }};")
w(f"\t\t\t\t\t{oid('target:watch')} = {{ CreatedOnToolsVersion = 27.0; }};")
w(f"\t\t\t\t\t{oid('target:ui-tests')} = {{ CreatedOnToolsVersion = 27.0; TestTargetID = {oid('target')}; }};")
w("\t\t\t\t};")
w("\t\t\t};")
w(f"\t\t\tbuildConfigurationList = {oid('conflist:project')};")
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = ( en, Base );")
w(f"\t\t\tmainGroup = {oid('group:root')};")
w("\t\t\tpackageReferences = (")
for product, path in PACKAGES:
    w(f"\t\t\t\t{oid('pkgref:' + path)} /* XCLocalSwiftPackageReference \"{path}\" */,")
w("\t\t\t);")
w(f"\t\t\tproductRefGroup = {oid('group:products')} /* Products */;")
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w(f"\t\t\t\t{oid('target')} /* {APP} */,")
w(f"\t\t\t\t{oid('target:watch')} /* {WATCH_TARGET} */,")
w(f"\t\t\t\t{oid('target:ui-tests')} /* {UI_TEST_TARGET} */,")
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")

# ------------------------------------------------------------------ packages
w("\n/* Begin XCLocalSwiftPackageReference section */")
for product, path in PACKAGES:
    w(f"\t\t{oid('pkgref:' + path)} /* XCLocalSwiftPackageReference \"{path}\" */ = {{")
    w("\t\t\tisa = XCLocalSwiftPackageReference;")
    w(f"\t\t\trelativePath = {path};")
    w("\t\t};")
w("/* End XCLocalSwiftPackageReference section */")

w("\n/* Begin XCSwiftPackageProductDependency section */")
for product, _ in PACKAGES:
    w(f"\t\t{oid('prod:' + product)} /* {product} */ = {{")
    w("\t\t\tisa = XCSwiftPackageProductDependency;")
    w(f"\t\t\tproductName = {product};")
    w("\t\t};")
w("/* End XCSwiftPackageProductDependency section */")

# ------------------------------------------------------------ configurations
PROJECT_SETTINGS = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    # The domain module is deliberately Swift 5 mode; matching it here keeps one
    # concurrency story across the app rather than two.
    "SWIFT_STRICT_CONCURRENCY": "minimal",
}
DEBUG_ONLY = {
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
}
RELEASE_ONLY = {
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
    "VALIDATE_PRODUCT": "YES",
}
TARGET_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "6",
    "DEVELOPMENT_TEAM": "K83N2TZ5G3",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UIStatusBarStyle": "UIStatusBarStyleLightContent",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":
        '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown '
        'UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
        '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft '
        'UIInterfaceOrientationLandscapeRight"',
    "INFOPLIST_KEY_NSLocationWhenInUseUsageDescription":
        '"Shows where you are on the map, so you can see what is coming towards '
        'your stop, and works out which service you are on while you are moving."',
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": "1.0.5",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}
WATCH_TARGET_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon_watch",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "6",
    "DEVELOPMENT_TEAM": "K83N2TZ5G3",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": APP,
    "INFOPLIST_KEY_NSLocationWhenInUseUsageDescription":
        '"Uses one foreground location fix to show nearby transit vehicles. '
        'Location is not tracked in the background."',
    "INFOPLIST_KEY_UISupportedInterfaceOrientations":
        '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"',
    "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": BUNDLE_ID,
    "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp": "YES",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": "1.0.5",
    "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.watchkitapp",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SDKROOT": "watchos",
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "4",
    "WATCHOS_DEPLOYMENT_TARGET": WATCH_DEPLOYMENT,
}
UI_TEST_TARGET_SETTINGS = {
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "K83N2TZ5G3",
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.uitests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
    "TEST_TARGET_NAME": APP,
}

def config(key, name, settings):
    w(f"\t\t{oid(key)} /* {name} */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    for setting, value in sorted(settings.items()):
        w(f"\t\t\t\t{setting} = {value};")
    w("\t\t\t};")
    w(f"\t\t\tname = {name};")
    w("\t\t};")

w("\n/* Begin XCBuildConfiguration section */")
config("conf:project:debug", "Debug", {**PROJECT_SETTINGS, **DEBUG_ONLY})
config("conf:project:release", "Release", {**PROJECT_SETTINGS, **RELEASE_ONLY})
config("conf:target:debug", "Debug", TARGET_SETTINGS)
config("conf:target:release", "Release", TARGET_SETTINGS)
config("conf:watch:debug", "Debug", WATCH_TARGET_SETTINGS)
config("conf:watch:release", "Release", WATCH_TARGET_SETTINGS)
config("conf:ui-tests:debug", "Debug", UI_TEST_TARGET_SETTINGS)
config("conf:ui-tests:release", "Release", UI_TEST_TARGET_SETTINGS)
w("/* End XCBuildConfiguration section */")

def conflist(key, debug, release, name):
    w(f"\t\t{oid(key)} /* Build configuration list for {name} */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{oid(debug)} /* Debug */,")
    w(f"\t\t\t\t{oid(release)} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")

w("\n/* Begin XCConfigurationList section */")
conflist("conflist:project", "conf:project:debug", "conf:project:release", "PBXProject")
conflist("conflist:target", "conf:target:debug", "conf:target:release", "PBXNativeTarget")
conflist(
    "conflist:watch", "conf:watch:debug", "conf:watch:release",
    f'PBXNativeTarget "{WATCH_TARGET}"'
)
conflist(
    "conflist:ui-tests", "conf:ui-tests:debug", "conf:ui-tests:release",
    f'PBXNativeTarget "{UI_TEST_TARGET}"'
)
w("/* End XCConfigurationList section */")

w("\t};")
w(f"\trootObject = {oid('project')} /* Project object */;")
w("}")

project_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
os.makedirs(project_dir, exist_ok=True)
with open(os.path.join(project_dir, "project.pbxproj"), "w") as handle:
    handle.write("\n".join(out) + "\n")

# A shared scheme, so `xcodebuild -scheme SwissTransit` works without opening the app.
schemes = os.path.join(project_dir, "xcshareddata", "xcschemes")
os.makedirs(schemes, exist_ok=True)
with open(os.path.join(schemes, f"{APP}.xcscheme"), "w") as handle:
    handle.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{oid('target')}"
               BuildableName = "{APP}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{oid('target:ui-tests')}"
               BuildableName = "{UI_TEST_TARGET}.xctest"
               BlueprintName = "{UI_TEST_TARGET}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES" shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{oid('target:ui-tests')}"
               BuildableName = "{UI_TEST_TARGET}.xctest"
               BlueprintName = "{UI_TEST_TARGET}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{oid('target')}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")

with open(os.path.join(schemes, f"{WATCH_TARGET}.xcscheme"), "w") as handle:
    handle.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{oid('target:watch')}"
               BuildableName="{WATCH_TARGET}.app"
               BlueprintName="{WATCH_TARGET}"
               ReferencedContainer="container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" shouldAutocreateTestPlan="YES">
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{oid('target:watch')}"
            BuildableName="{WATCH_TARGET}.app"
            BlueprintName="{WATCH_TARGET}"
            ReferencedContainer="container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{oid('target:watch')}"
            BuildableName="{WATCH_TARGET}.app"
            BlueprintName="{WATCH_TARGET}"
            ReferencedContainer="container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
""")

print(f"wrote {project_dir}")
print(
    f"  iOS: {len(IOS_SOURCES)} Swift sources, "
    f"{len(RESOURCES)} resources, {len(PACKAGES)} packages"
)
print(
    f"  watchOS: {len(WATCH_SOURCES)} Swift sources, "
    f"{len(WATCH_RESOURCES)} resources, "
    f"{len(WATCH_PACKAGES)} packages"
)
