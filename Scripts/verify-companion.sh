#!/bin/zsh
set -euo pipefail

(( $# == 1 )) || { print -u2 -- "Usage: Scripts/verify-companion.sh /path/to/YIOS-KIT\ Companion.app"; exit 64; }
companion_path="$1"
/usr/bin/python3 - "$companion_path" <<'PY'
import datetime
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

def reject(message):
    raise ValueError(message)

def run(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    if result.returncode != 0:
        reject('A companion signature or provisioning verification command failed.')
    return result.stdout

try:
    app = pathlib.Path(sys.argv[1])
    if not app.is_absolute():
        app = pathlib.Path.cwd() / app
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        reject('The companion must be a regular .app directory.')
    files = list(app.rglob('*'))
    if len(files) > 2000 or any(p.is_symlink() for p in files):
        reject('The companion contains unsupported links or too many files.')
    if sum(p.stat().st_size for p in files if p.is_file()) > 100 * 1024 * 1024:
        reject('The companion exceeds the allowed payload size.')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle_id = 'local.minthanhtut.YIOSKitCompanion'
    if info.get('CFBundleIdentifier') != bundle_id or info.get('CFBundlePackageType') != 'APPL':
        reject('The app is not the YIOS-KIT iPhone companion.')
    if info.get('DTPlatformName') != 'iphoneos' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        reject('Only an iPhone device build can be embedded; simulator and Mac builds are rejected.')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(info.get('CFBundleShortVersionString', ''))):
        reject('The companion has an invalid version.')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(info.get('CFBundleVersion', ''))):
        reject('The companion has an invalid build number.')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or pathlib.Path(executable).name != executable:
        reject('The companion executable name is invalid.')
    executable_path = app / executable
    if not executable_path.is_file():
        reject('The companion executable is missing.')
    description = run(['/usr/bin/file', '-b', str(executable_path)]).decode('utf-8', 'replace')
    if 'Mach-O' not in description or 'arm64' not in description:
        reject('The companion must contain native arm64 code.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures',
         '-R', '=anchor apple generic', str(app)])
    profile = plistlib.loads(run(['/usr/bin/security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]))
    expiry = profile.get('ExpirationDate')
    now = datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(expiry, datetime.datetime):
        reject('The companion provisioning expiry is unavailable.')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if expiry <= now + datetime.timedelta(hours=1):
        reject('The companion provisioning profile is expired or expires in less than an hour.')
    devices = profile.get('ProvisionedDevices')
    if not isinstance(devices, list) or not devices or not all(isinstance(d, str) and d for d in devices):
        reject('The companion needs a development or ad hoc profile covering its registered iPhone.')
    if profile.get('ProvisionsAllDevices'):
        reject('Enterprise-wide companion profiles are not accepted by this personal installer.')
    teams = profile.get('TeamIdentifier')
    if not isinstance(teams, list) or len(teams) != 1 or not re.fullmatch(r'[A-Z0-9]{10}', teams[0]):
        reject('The companion provisioning team is invalid.')
    entitlements_result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    if entitlements_result.returncode != 0:
        reject('The companion signed entitlements are unavailable.')
    signed_entitlements = plistlib.loads(entitlements_result.stdout)
    profile_entitlements = profile.get('Entitlements', {})
    application_id = signed_entitlements.get('application-identifier')
    if not isinstance(application_id, str) or application_id != teams[0] + '.' + bundle_id:
        reject('The companion app identity does not match its signing team.')
    profile_application_id = profile_entitlements.get('application-identifier')
    if profile_application_id not in (application_id, teams[0] + '.*'):
        reject('The companion app identity does not match its provisioning profile.')
    if signed_entitlements.get('com.apple.developer.team-identifier') != teams[0]:
        reject('The companion signed team does not match its provisioning profile.')
    with tempfile.TemporaryDirectory(prefix='yios-companion-cert-') as scratch:
        prefix = pathlib.Path(scratch) / 'cert'
        run(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), str(app)])
        leaf = pathlib.Path(str(prefix) + '0').read_bytes()
        if leaf not in profile.get('DeveloperCertificates', []):
            reject('The companion signing certificate is not authorized by its provisioning profile.')
    print('Companion verified: signed iPhone app, matching profile and certificate.')
    print('Version: ' + info['CFBundleShortVersionString'] + ' (' + str(info['CFBundleVersion']) + ')')
    print('Provisioning expires: ' + expiry.strftime('%Y-%m-%d UTC'))
except Exception as error:
    # Do not echo command output, certificates, team IDs, device IDs or account names.
    message = str(error) if isinstance(error, ValueError) else 'The companion could not be verified.'
    print('Companion verification failed: ' + message, file=sys.stderr)
    sys.exit(1)
PY
