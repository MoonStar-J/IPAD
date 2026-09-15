"""Generate a dependency-free Xcode project from the checked-in Swift files."""
from pathlib import Path
import hashlib
import json
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, help="Write the generated project to a separate directory")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = args.output or ROOT
(OUTPUT / "NoteMargin.xcodeproj/xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)
objects = {}

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(name, body):
    key = uid(name)
    objects[key] = body
    return key

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

def array(items):
    return "(" + ", ".join(items) + ")"

sources = []
resources = []
personal_name_resources = []

def group(path):
    children = []
    for child in sorted(path.iterdir()):
        relative = str(child.relative_to(ROOT))
        if child.suffix == ".lproj":
            continue
        if child.is_dir() and child.suffix != ".xcassets":
            children.append(group(child))
            continue
        types = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcprivacy": "text.xml", ".xcassets": "folder.assetcatalog"}
        if child.suffix not in types:
            continue
        ref = add("file:" + relative, f"isa = PBXFileReference; lastKnownFileType = {types[child.suffix]}; path = {quote(child.name)}; sourceTree = \"<group>\";")
        children.append(ref)
        if child.suffix in [".swift", ".xcassets", ".xcprivacy"]:
            build = add("build:" + relative, f"isa = PBXBuildFile; fileRef = {ref};")
            (sources if child.suffix == ".swift" else resources).append(build)
    localized_names = sorted({p.name for p in path.glob("*.lproj/*.strings")})
    for name in localized_names:
        translations = []
        for translation in sorted(path.glob("*.lproj/" + name)):
            relative = str(translation.relative_to(path))
            translations.append(add("localized:" + str(translation.relative_to(ROOT)),
                f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {quote(translation.parent.stem)}; path = {quote(relative)}; sourceTree = "<group>";'))
        variant_key = name if path == ROOT / "NoteMargin" else str(path.relative_to(ROOT)) + "/" + name
        variant = add("variant:" + variant_key,
            f'isa = PBXVariantGroup; children = {array(translations)}; name = {quote(name)}; sourceTree = "<group>";')
        children.append(variant)
        (personal_name_resources if path.name == "PersonalResources" else resources).append(add("build:localized:" + variant_key, f"isa = PBXBuildFile; fileRef = {variant};"))
    return add("group:" + str(path.relative_to(ROOT)), f"isa = PBXGroup; children = {array(children)}; path = {quote(path.name)}; sourceTree = \"<group>\";")

app_group = group(ROOT / "NoteMargin")
product = add("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NoteMargin.app; sourceTree = BUILT_PRODUCTS_DIR;')
personal_product = add("personal-product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NoteMarginPersonal.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add("products", f'isa = PBXGroup; children = ({product}, {personal_product}); name = Products; sourceTree = "<group>";')
main_group = add("main", f'isa = PBXGroup; children = ({app_group}, {products}); sourceTree = "<group>";')
source_phase = add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(sources)}; runOnlyForDeploymentPostprocessing = 0;")
resource_phase = add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;")
framework_phase = add("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")

def configs(prefix, settings):
    ids = []
    for mode in ["Debug", "Release"]:
        current = dict(settings)
        current.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"})
        if mode == "Debug":
            current["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG " + current.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "$(inherited)")
            current["ENABLE_TESTABILITY"] = "YES"
        values = " ".join(f"{key} = {quote(value)};" for key, value in current.items())
        ids.append(add(prefix + mode, f"isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {mode};"))
    return add(prefix + "configs", f"isa = XCConfigurationList; buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

project_configs = configs("project", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted"})
app_settings = {
    # An app's identifier is its upgrade identity, independent of its displayed name.
    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.yeobaek.notes",
    "INFOPLIST_FILE": "NoteMargin/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0.0",
    "TARGETED_DEVICE_FAMILY": "2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "SWIFT_EMIT_LOC_STRINGS": "YES"
}
target_configs = configs("target", app_settings)
target = add("target", f'isa = PBXNativeTarget; buildConfigurationList = {target_configs}; buildPhases = ({source_phase}, {framework_phase}, {resource_phase}); buildRules = (); dependencies = (); name = NoteMargin; productName = NoteMargin; productReference = {product}; productType = "com.apple.product-type.application";')
personal_settings = dict(app_settings)
personal_settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "com.yeobaek.notes.personal", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "PERSONAL_CHATGPT $(inherited)"})
personal_configs = configs("personal-target", personal_settings)
# Build files and phases belong to one target; file references are shared.
def personal_phase(name, original_files, isa):
    copied = []
    for build_id in original_files:
        copied.append(add("personal-build:" + build_id, objects[build_id]))
    return add("personal-" + name, f"isa = {isa}; buildActionMask = 2147483647; files = {array(copied)}; runOnlyForDeploymentPostprocessing = 0;")
personal_sources = personal_phase("sources", sources, "PBXSourcesBuildPhase")
personal_resources = personal_phase("resources", [r for r in resources if r != uid("build:localized:InfoPlist.strings")] + personal_name_resources, "PBXResourcesBuildPhase")
personal_frameworks = personal_phase("frameworks", [], "PBXFrameworksBuildPhase")
personal_target = add("personal-target", f'isa = PBXNativeTarget; buildConfigurationList = {personal_configs}; buildPhases = ({personal_sources}, {personal_frameworks}, {personal_resources}); buildRules = (); dependencies = (); name = NoteMarginPersonal; productName = NoteMarginPersonal; productReference = {personal_product}; productType = "com.apple.product-type.application";')
project = add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (ko, en, Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target}, {personal_target});')

output = '// !$*UTF8*$!\n{\n archiveVersion = 1;\n classes = {};\n objectVersion = 56;\n objects = {\n'
output += "\n".join(f"  {key} = {{ {value} }};" for key, value in objects.items())
output += f"\n }};\n rootObject = {project};\n}}\n"
(OUTPUT / "NoteMargin.xcodeproj/project.pbxproj").write_text(output)

ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NoteMargin.app" BlueprintName="NoteMargin" ReferencedContainer="container:NoteMargin.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(OUTPUT / "NoteMargin.xcodeproj/xcshareddata/xcschemes/NoteMargin.xcscheme").write_text(scheme)
print(f"Generated NoteMargin.xcodeproj: {len(sources)} Swift files, {len(resources)} resources")

personal_scheme = scheme.replace(target, personal_target).replace("NoteMargin.app", "NoteMarginPersonal.app").replace('BlueprintName="NoteMargin"', 'BlueprintName="NoteMarginPersonal"')
(OUTPUT / "NoteMargin.xcodeproj/xcshareddata/xcschemes/NoteMarginPersonal.xcscheme").write_text(personal_scheme)
