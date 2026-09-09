"""Run PDF integration checks in a separate simulator-only app (requires Xcode)."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.notemargin.integrationcheck'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))
ipads = [d for devices in available['devices'].values() for d in devices if 'iPad' in d['name']]
if not ipads:
    sys.exit('Install an iPad simulator runtime in Xcode first.')
device = next((d for d in ipads if d['udid'] == sys.argv[1]), None) if len(sys.argv) > 1 else next((d for d in ipads if d['state'] == 'Booted'), ipads[0])
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
    project.write_text(json.dumps(settings))
    run('plutil', '-convert', 'xml1', str(project))
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
