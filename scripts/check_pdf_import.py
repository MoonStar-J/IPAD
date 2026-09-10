"""Run PDF integration checks in a separate simulator-only app (requires Xcode)."""
from pathlib import Path
import argparse
import json
import uuid
import xml.etree.ElementTree as ET
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.notemargin.integrationcheck'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('device', nargs='?', help='Available iPad simulator UUID')
parser.add_argument('--live-ui', action='store_true', help='Exercise real touch strokes with XCUITest')
parser.add_argument('--only-testing', action='append', default=[], help='UI test class or method, e.g. CanvasLiveInkTests/StrokeEraserVisualTests')
args = parser.parse_args()

available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))
ipads = [d for devices in available['devices'].values() for d in devices if 'iPad' in d['name']]
if not ipads:
    sys.exit('Install an iPad simulator runtime in Xcode first.')
device = next((d for d in ipads if d['udid'] == args.device), None) if args.device else next((d for d in ipads if d['state'] == 'Booted'), ipads[0])
if device is None:
    sys.exit('The supplied device ID is not an available iPad simulator.')
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', device['udid'])

with tempfile.TemporaryDirectory(prefix='NoteMarginPDFChecks-') as temporary:
    work = Path(temporary)
    for name in ['NoteMargin', 'NoteMargin.xcodeproj']:
        shutil.copytree(ROOT / name, work / name, ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate'))
    shutil.copy(ROOT / 'scripts/pdf_integration_app.swift', work / 'NoteMargin/App/NoteMarginApp.swift')
    project = work / 'NoteMargin.xcodeproj/project.pbxproj'
    settings = json.loads(run('plutil', '-convert', 'json', '-o', '-', str(project)))
    for obj in settings['objects'].values():
        if 'PRODUCT_BUNDLE_IDENTIFIER' in obj.get('buildSettings', {}):
            obj['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE
    if args.live_ui:
        shutil.copy(ROOT / 'scripts/canvas_ui_checks.swift', work / 'CanvasLiveInkTests.swift')
        objects = settings['objects']
        project_object = objects[settings['rootObject']]
        app_target = project_object['targets'][0]
        ids = {key: uuid.uuid4().hex[:24].upper() for key in ['file', 'build', 'sources', 'product', 'target', 'debug', 'release', 'config', 'dependency']}
        objects[ids['file']] = dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path='CanvasLiveInkTests.swift', sourceTree='<group>')
        objects[project_object['mainGroup']]['children'].append(ids['file'])
        objects[ids['build']] = dict(isa='PBXBuildFile', fileRef=ids['file'])
        objects[ids['sources']] = dict(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=[ids['build']], runOnlyForDeploymentPostprocessing='0')
        objects[ids['product']] = dict(isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='CanvasLiveInkTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
        objects[project_object['productRefGroup']]['children'].append(ids['product'])
        for mode in ['debug', 'release']:
            objects[ids[mode]] = dict(isa='XCBuildConfiguration', name=mode.title(), buildSettings={
                'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE + '.uitests',
                'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_VERSION': '5.0', 'TARGETED_DEVICE_FAMILY': '2',
                'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos', 'TEST_TARGET_NAME': 'NoteMargin',
                'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']})
        objects[ids['config']] = dict(isa='XCConfigurationList', buildConfigurations=[ids['debug'], ids['release']], defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
        objects[ids['dependency']] = dict(isa='PBXTargetDependency', target=app_target)
        objects[ids['target']] = dict(isa='PBXNativeTarget', name='CanvasLiveInkTests', productName='CanvasLiveInkTests',
            buildConfigurationList=ids['config'], buildPhases=[ids['sources']], buildRules=[], dependencies=[ids['dependency']],
            productReference=ids['product'], productType='com.apple.product-type.bundle.ui-testing')
        project_object['targets'].append(ids['target'])
        project_object.setdefault('attributes', {}).setdefault('TargetAttributes', {})[ids['target']] = {'TestTargetID': app_target}
        scheme = work / 'NoteMargin.xcodeproj/xcshareddata/xcschemes/NoteMargin.xcscheme'
        tree = ET.parse(scheme)
        testable = ET.SubElement(tree.find('TestAction/Testables'), 'TestableReference', skipped='NO')
        ET.SubElement(testable, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=ids['target'],
                      BuildableName='CanvasLiveInkTests.xctest', BlueprintName='CanvasLiveInkTests', ReferencedContainer='container:NoteMargin.xcodeproj')
        tree.write(scheme, encoding='utf-8', xml_declaration=True)
    project.write_text(json.dumps(settings))
    run('plutil', '-convert', 'xml1', str(project))
    if args.live_ui:
        result_bundle = Path(tempfile.gettempdir()) / ('NoteMarginLiveInk-' + uuid.uuid4().hex + '.xcresult')
        print('UI test results:', result_bundle, flush=True)
        result = subprocess.run(['xcodebuild', '-quiet', '-project', str(project.parent), '-scheme', 'NoteMargin',
            '-destination', 'id=' + device['udid'], '-derivedDataPath', str(work / 'build'),
            '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result_bundle),
            *['-only-testing:' + name for name in args.only_testing], 'CODE_SIGNING_ALLOWED=NO', 'test'])
        sys.exit(result.returncode)
    run('xcodebuild', '-quiet', '-project', str(project.parent), '-scheme', 'NoteMargin', '-configuration', 'Debug',
        '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(work / 'build'), 'CODE_SIGNING_ALLOWED=NO', 'build')
    subprocess.run(['xcrun', 'simctl', 'terminate', device['udid'], BUNDLE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('xcrun', 'simctl', 'install', device['udid'], str(work / 'build/Build/Products/Debug-iphonesimulator/NoteMargin.app'))
    # Only the disposable test app's data is cleared; the real app uses a different identifier.
    container = Path(run('xcrun', 'simctl', 'get_app_container', device['udid'], BUNDLE, 'data'))
    results = container / 'Documents/results.txt'
    results.unlink(missing_ok=True)
    run('xcrun', 'simctl', 'launch', device['udid'], BUNDLE)
    for _ in range(60):
        if results.exists():
            message = results.read_text()
            print(message)
            print('Artifacts:', results.parent)
            sys.exit(0 if message.startswith('PASS:') else 1)
        time.sleep(0.5)
    sys.exit('The integration test app did not report a result within 30 seconds.')
