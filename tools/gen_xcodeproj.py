#!/usr/bin/env python3
"""Generates CellarEscape.xcodeproj (project.pbxproj + shared scheme).

The app target compiles Sources/CellarCore/*.swift and App/CellarEscape/*.swift
directly, and bundles Content/*.json plus any audio overrides in Content/Sounds/.
Re-run after adding or removing source files:  python3 tools/gen_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "CellarEscape.xcodeproj")
BUNDLE_ID = "com.cellarescape.game"
DEPLOYMENT = "16.0"


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def listdir(rel, exts):
    d = os.path.join(ROOT, rel)
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if os.path.splitext(f)[1].lower() in exts)


core = listdir("Sources/CellarCore", {".swift"})
app = listdir("App/CellarEscape", {".swift"})
content = listdir("Content", {".json"})
sounds = listdir("Content/Sounds", {".caf", ".wav", ".m4a", ".aif", ".aiff", ".mp3"})

groups = [
    ("CellarCore", "Sources/CellarCore", core),
    ("CellarEscape", "App/CellarEscape", app + ["Info.plist"]),
    ("Content", "Content", content),
]
if sounds:
    groups.append(("Sounds", "Content/Sounds", sounds))

sources = [("Sources/CellarCore", f) for f in core] + [("App/CellarEscape", f) for f in app]
resources = [("Content", f) for f in content] + [("Content/Sounds", f) for f in sounds]

T = oid("target")
PROJ_ID = oid("project")
MAIN_GROUP = oid("maingroup")
PRODUCTS = oid("products")
PRODUCT = oid("product")
SRC_PHASE, RES_PHASE, FW_PHASE = oid("phase.src"), oid("phase.res"), oid("phase.fw")
PCL, TCL = oid("projconfiglist"), oid("targetconfiglist")
PDEBUG, PRELEASE, TDEBUG, TRELEASE = oid("pdebug"), oid("prelease"), oid("tdebug"), oid("trelease")


def ftype(name):
    ext = os.path.splitext(name)[1].lower()
    return {
        ".swift": "sourcecode.swift", ".json": "text.json", ".plist": "text.plist.xml",
        ".caf": "audio.caf", ".wav": "audio.wav", ".m4a": "audio.mp4", ".aif": "audio.aiff",
        ".aiff": "audio.aiff", ".mp3": "audio.mp3",
    }[ext]


lines = []
w = lines.append
w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")

w("\n/* Begin PBXBuildFile section */")
for d, f in sources:
    w(f"\t\t{oid('build', d, f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('file', d, f)} /* {f} */; }};")
for d, f in resources:
    w(f"\t\t{oid('build', d, f)} /* {f} in Resources */ = {{isa = PBXBuildFile; fileRef = {oid('file', d, f)} /* {f} */; }};")
w("/* End PBXBuildFile section */")

w("\n/* Begin PBXFileReference section */")
for gname, d, files in groups:
    for f in files:
        w(f"\t\t{oid('file', d, f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype(f)}; path = \"{f}\"; sourceTree = \"<group>\"; }};")
w(f"\t\t{PRODUCT} /* CellarEscape.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CellarEscape.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
w("/* End PBXFileReference section */")

w("\n/* Begin PBXFrameworksBuildPhase section */")
w(f"\t\t{FW_PHASE} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXFrameworksBuildPhase section */")

w("\n/* Begin PBXGroup section */")
children = "".join(f"\t\t\t\t{oid('group', g)} /* {g} */,\n" for g, _, _ in groups)
w(f"\t\t{MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
for g, d, files in groups:
    kids = "".join(f"\t\t\t\t{oid('file', d, f)} /* {f} */,\n" for f in files)
    w(f"\t\t{oid('group', g)} /* {g} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\t\t\t);\n\t\t\tname = {g};\n\t\t\tpath = \"{d}\";\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
w(f"\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{PRODUCT} /* CellarEscape.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
w("/* End PBXGroup section */")

w("\n/* Begin PBXNativeTarget section */")
w(f"""\t\t{T} /* CellarEscape */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TCL} /* Build configuration list for PBXNativeTarget "CellarEscape" */;
\t\t\tbuildPhases = (
\t\t\t\t{SRC_PHASE} /* Sources */,
\t\t\t\t{FW_PHASE} /* Frameworks */,
\t\t\t\t{RES_PHASE} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = CellarEscape;
\t\t\tproductName = CellarEscape;
\t\t\tproductReference = {PRODUCT} /* CellarEscape.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")
w("/* End PBXNativeTarget section */")

w("\n/* Begin PBXProject section */")
w(f"""\t\t{PROJ_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{T} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PCL} /* Build configuration list for PBXProject "CellarEscape" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP};
\t\t\tproductRefGroup = {PRODUCTS} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{T} /* CellarEscape */,
\t\t\t);
\t\t}};""")
w("/* End PBXProject section */")

w("\n/* Begin PBXResourcesBuildPhase section */")
res = "".join(f"\t\t\t\t{oid('build', d, f)} /* {f} in Resources */,\n" for d, f in resources)
w(f"\t\t{RES_PHASE} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{res}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXResourcesBuildPhase section */")

w("\n/* Begin PBXSourcesBuildPhase section */")
src = "".join(f"\t\t\t\t{oid('build', d, f)} /* {f} in Sources */,\n" for d, f in sources)
w(f"\t\t{SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{src}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXSourcesBuildPhase section */")


def settings_block(d):
    out = []
    for k, v in d.items():
        if isinstance(v, list):
            items = "".join(f"\t\t\t\t\t\"{x}\",\n" for x in v)
            out.append(f"\t\t\t\t{k} = (\n{items}\t\t\t\t);")
        else:
            out.append(f"\t\t\t\t{k} = {v};")
    return "\n".join(out)


common_proj = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
proj_debug = dict(common_proj, DEBUG_INFORMATION_FORMAT="dwarf", ENABLE_TESTABILITY="YES", GCC_OPTIMIZATION_LEVEL="0",
                  ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG",
                  SWIFT_OPTIMIZATION_LEVEL='"-Onone"')
proj_release = dict(common_proj, DEBUG_INFORMATION_FORMAT='"dwarf-with-dsym"', SWIFT_COMPILATION_MODE="wholemodule",
                    SWIFT_OPTIMIZATION_LEVEL='"-O"', VALIDATE_PRODUCT="YES")
target_common = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": '""',
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "App/CellarEscape/Info.plist",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "LD_RUNPATH_SEARCH_PATHS": ['$(inherited)', '@executable_path/Frameworks'],
    "MARKETING_VERSION": "0.1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
}
# Debug keeps a little optimisation so sound synthesis at launch stays quick.
target_debug = dict(target_common, SWIFT_OPTIMIZATION_LEVEL='"-O"')
target_release = dict(target_common)

w("\n/* Begin XCBuildConfiguration section */")
for cid, name, d in [(PDEBUG, "Debug", proj_debug), (PRELEASE, "Release", proj_release),
                     (TDEBUG, "Debug", target_debug), (TRELEASE, "Release", target_release)]:
    w(f"\t\t{cid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(d)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")
w("/* End XCBuildConfiguration section */")

w("\n/* Begin XCConfigurationList section */")
for lid, label, a, b in [(PCL, 'PBXProject "CellarEscape"', PDEBUG, PRELEASE),
                         (TCL, 'PBXNativeTarget "CellarEscape"', TDEBUG, TRELEASE)]:
    w(f"\t\t{lid} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{a} /* Debug */,\n\t\t\t\t{b} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
w("/* End XCConfigurationList section */")

w("\t};")
w(f"\trootObject = {PROJ_ID} /* Project object */;")
w("}")

os.makedirs(os.path.join(PROJ, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines) + "\n")

ref = f"""<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{T}"
               BuildableName = "CellarEscape.app"
               BlueprintName = "CellarEscape"
               ReferencedContainer = "container:CellarEscape.xcodeproj">
            </BuildableReference>"""
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
      <CommandLineArguments>
         <CommandLineArgument
            argument = "-selftest"
            isEnabled = "NO">
         </CommandLineArgument>
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(PROJ, "xcshareddata", "xcschemes", "CellarEscape.xcscheme"), "w") as f:
    f.write(scheme)
print(f"Wrote {PROJ}: {len(sources)} sources, {len(resources)} resources")
