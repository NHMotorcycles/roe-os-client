#!/usr/bin/env python3
# Join a Ring of Elysium 2022 server (roe_server) as a player, on Linux through Steam's Proton.
#
# The Linux counterpart of join.cmd: run it (python3 join.py). It asks for
#   - the game folder (the last one is the default),
#   - the server (arrow keys and Enter; the servers joined before by name and address, the most
#     recently used on top, on the first start roe-os.de; the last entry asks for another address),
#   - the account to play with (arrow keys and Enter; the most recently used on top, the last
#     entry creates a new one),
# then logs in to the server and starts the game with Proton. Answers are remembered in
# ~/.config/roe-join.json (the servers with their name and last use in "servers"). --game, --server and
# --name answer the questions up front (--name picks the saved account of that name, or claims the
# name for a new one).
#
# Accounts work as with join.cmd: a new account gets a secret key from the server, kept in
# ~/.config/roe-join/<server>/accounts.json with the account's current name (the same file as
# %APPDATA%\roe-join on Windows: copy the folder to play with the same accounts on another
# computer). With first-login on, the server names a new account (newaccount and 4 digits) and
# the game asks for the real name; otherwise join.py asks for it. The server's certificate is
# remembered on first contact (server.pin) and a different one is refused.
#
# Proton, the first that exists of:
#   1. --proton PATH or PROTON=PATH (the proton script or its folder),
#   2. the Proton that last ran the game's prefix (compatdata/<app id>/version), so the prefix
#      is not upgraded behind the player's back,
#   3. the newest GE-Proton in compatibilitytools.d,
#   4. the newest Valve Proton (steamapps/common/Proton*) in any Steam library,
#   5. any other tool in compatibilitytools.d,
# else wine. The prefix is the game's own (compatdata/<app id>, --compat PATH picks another);
# a missing one is created with "proton run wineboot -u".
#
# --dry-run (or ROE_JOIN_DRY_RUN=1) prints what it would do: no server contact, no files written.
#
# Voice chat (on by default, asked once, --voice on|off changes it): our GCloudVoice.dll replaces
# the game's while the game runs. It comes from voice/ next to this file, or from the folder the
# player gave (asked when it is missing and by --voice on; saved as voice_dll, then used without
# asking). The original is kept with its hash in
# ~/.config/roe-join/voice-backup/ and put back when the game exits, or at the next start after a
# crash.
#
# Unlike join.cmd there is no firewall step: the game can reach the internet. The addresses the
# server names for the game besides its own (ADDRESSES: other machines with its matches) are only
# shown. The server can name the oldest version of this script it takes (VERSION); an older one
# stops before the game starts and says where to get the new one.
#
# Account backup: --export [FILE] writes every server's accounts (their keys), certificate pin and
# name into one file (default roe-join-accounts.json here); --import FILE merges one into this
# computer. join.cmd reads and writes the same file (join.cmd export, join.cmd import).
#
# GM accounts: --admin (with --server and --name as for a join) opens the server's admin page in the
# browser with a one-time login link, as join.cmd admin.
#
# Nothing else in the game folder is changed. Needs Python 3.8 or newer, nothing else.
import os
import sys

# Import only from Python itself, never from the folder this file was downloaded to.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if p and os.path.abspath(p) != _HERE]

import argparse
import contextlib
import hashlib
import ipaddress
import json
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import time
import urllib.parse
from pathlib import Path

# This script's version; the server can ask for a newer one (VERSION). The same number as join.cmd's
# and roe_server's (src/lobby/accounts.hpp kJoinScriptVersion).
JOIN_VERSION = '1.0'
JOIN_URL = 'https://github.com/mschnati/roe-os-client'
EXPECTED_SHA = {'2dca9b1e122e21363e14eeeb2372598c773205a907ed8d2b2d54a7229ad6ba18',   # root folder (DX11)
                'e076dddcab4b48d52b920a84bbee125c8b452900ae90cea2f190f2e3654ff81d'}   # XVersion (DX12)
STEAM_APP_ID = '755790'
GAME_DIR = 'Ring of Elysium'
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
SETTINGS = CONFIG / 'roe-join.json'
ROOT_PATHS = ('.local/share/Steam', '.steam/steam', '.steam/root', '.steam/debian-installation',
              '.var/app/com.valvesoftware.Steam/.local/share/Steam',   # Flatpak
              'snap/steam/common/.local/share/Steam')                    # Snap
SYSTEM_TOOLS = (Path('/usr/share/steam/compatibilitytools.d'),)


class Failure(Exception):
    pass


# --- Steam -------------------------------------------------------------------------------------
def steam_roots(home):
    """Existing Steam installs, symlinks resolved, each once."""
    roots = []
    for relative in ROOT_PATHS:
        try:
            root = (Path(home) / relative).resolve()
        except (OSError, RuntimeError):
            continue
        if root.is_dir() and root not in roots:
            roots.append(root)
    return roots


def libraries(roots):
    """steamapps folders: each root's own plus the "path" entries of libraryfolders.vdf."""
    found = []

    def add(folder):
        try:
            steamapps = (Path(folder) / 'steamapps').resolve()
        except (OSError, RuntimeError):
            return
        if steamapps.is_dir() and steamapps not in found:
            found.append(steamapps)

    for root in roots:
        add(root)
        for vdf in (root / 'steamapps/libraryfolders.vdf', root / 'config/libraryfolders.vdf'):
            try:
                text = vdf.read_text(encoding='utf-8', errors='replace')
            except OSError:
                continue
            for m in re.finditer(r'"path"\s+"((?:[^"\\]|\\.)*)"', text):
                add(re.sub(r'\\(.)', r'\1', m.group(1)))
    return found


def library_of(client):
    """(steamapps folder, install folder name) of a game inside a Steam library, else (None, None).
    XVersion sits inside the main folder, so the parents are searched."""
    path = Path(client).resolve()
    for folder in [path] + list(path.parents):
        if folder.parent.name == 'common' and folder.parent.parent.name == 'steamapps':
            return folder.parent.parent, folder.name
    return None, None


def find_game(libs):
    return next((str(lib / 'common' / GAME_DIR) for lib in libs if is_client(lib / 'common' / GAME_DIR)), '')


def app_id(client):
    library, installdir = library_of(client)
    if library and installdir:
        for manifest in sorted(library.glob('appmanifest_*.acf')):
            text = manifest.read_text(encoding='utf-8', errors='replace')
            if re.search(r'"installdir"\s+"' + re.escape(installdir) + '"', text, re.I):
                found = re.search(r'"appid"\s+"(\d+)"', text)
                if found:
                    return found.group(1)
    return STEAM_APP_ID


def find_prefix(client, libs, app):
    """The game's Proton prefix: in its own library, else where one exists, else the first library."""
    library, _ = library_of(client)
    if library:
        return library / 'compatdata' / app
    existing = next((lib / 'compatdata' / app for lib in libs if (lib / 'compatdata' / app).is_dir()), None)
    if existing:
        return existing
    if libs:
        return libs[0] / 'compatdata' / app
    return Path.home() / '.local/share/roe-join/compatdata' / app


def prefix_version(prefix):
    try:
        return (Path(prefix) / 'version').read_text(encoding='utf-8', errors='replace').strip()
    except OSError:
        return ''


def prefix_ready(prefix):
    return (Path(prefix) / 'pfx/drive_c/users/steamuser').is_dir()


# --- Proton ------------------------------------------------------------------------------------
def natural_key(name):
    """GE-Proton10-1 after GE-Proton9-20: numbers compare as numbers."""
    return [(0, int(part)) if part.isdigit() else (1, part.lower()) for part in re.findall(r'\d+|\D+', name)]


def is_ge(name):
    return bool(re.search(r'(^|[-_ .])GE([-_ .]|$)', name))


class Tool:
    def __init__(self, proton, kind):
        self.proton = Path(proton)
        self.name = self.proton.parent.name
        self.kind = kind   # 'ge', 'valve' or 'custom'

    def prefix_version(self):
        """The version Proton writes into the prefixes it runs (CURRENT_PREFIX_VERSION)."""
        try:
            text = self.proton.read_text(encoding='utf-8', errors='replace')
        except OSError:
            return ''
        m = re.search(r'^CURRENT_PREFIX_VERSION\s*=\s*["\']([^"\']+)["\']', text, re.M)
        return m.group(1) if m else ''

    def __repr__(self):
        return f'Tool({self.name!r}, {self.kind})'


def find_tools(roots, libs, system_tools=SYSTEM_TOOLS):
    tools, seen = [], set()

    def add(proton, kind):
        try:
            resolved = proton.resolve()
        except (OSError, RuntimeError):
            return
        if proton.is_file() and resolved not in seen:
            seen.add(resolved)
            tools.append(Tool(proton, kind))

    for folder in [root / 'compatibilitytools.d' for root in roots] + list(system_tools):
        for proton in sorted(Path(folder).glob('*/proton')):
            add(proton, 'ge' if is_ge(proton.parent.name) else 'custom')
    for lib in libs:
        for proton in sorted(lib.glob('common/Proton*/proton')):
            add(proton, 'valve')
    return tools


def newest(tools):
    # Numbered releases before Experimental or Hotfix (no number in the name).
    return max(tools, key=lambda t: (bool(re.search(r'\d', t.name)), natural_key(t.name)), default=None)


def choose_proton(tools, version):
    """(tool, why) by the order in the header, (None, '') when there is none."""
    if version:
        same = [t for t in tools if t.name == version or t.prefix_version() == version]
        if same:
            return newest(same), f'last ran this prefix ({version})'
    for kind, why in (('ge', 'newest GE-Proton'), ('valve', 'newest Valve Proton'), ('custom', 'compatibility tool')):
        tool = newest([t for t in tools if t.kind == kind])
        if tool:
            note = f'; the prefix was last run by {version}, which is not installed' if version else ''
            return tool, why + note
    return None, ''


def given_proton(path):
    path = Path(os.path.expanduser(path))
    if path.is_dir():
        path = path / 'proton'
    if not path.is_file():
        raise Failure(f'No Proton at {path}. Pass --proton with the "proton" script of a Proton folder.')
    return Tool(path, 'given')


# --- Game start --------------------------------------------------------------------------------
def plan_start(client, arguments, options, home=None, system_tools=SYSTEM_TOOLS):
    """What starting the game takes: a dict with command, env (the added variables), prefix, ..."""
    home = Path(home or Path.home())
    roots = steam_roots(home)
    libs = libraries(roots)
    exe = str(Path(client) / 'Europa_Client.exe')
    plan = {'roots': roots, 'libraries': libs, 'env': {}, 'prefix': None, 'init': False, 'tool': None, 'why': ''}
    app = app_id(client)
    prefix = Path(os.path.expanduser(options.compat)).resolve() if options.compat else find_prefix(client, libs, app)
    version = prefix_version(prefix)
    if options.proton:
        tool, why = given_proton(options.proton), 'given'
    else:
        tool, why = choose_proton(find_tools(roots, libs, system_tools), version)
    if tool:
        library, installdir = library_of(client)
        steam = next((r for r in roots if (r / 'steamapps').is_dir()), roots[0] if roots else home / '.steam/steam')
        install_path = client
        if library and installdir:
            install_path = str(library / 'common' / installdir)
        plan.update(tool=tool, why=why, prefix=prefix, version=version, init=not prefix_ready(prefix))
        # SteamAppId/SteamGameId: Proton and GE's protonfixes pick per-game settings by them; the
        # client itself does not need Steam (it logs in with -uid).
        plan['env'] = {'STEAM_COMPAT_DATA_PATH': str(prefix),
                       'STEAM_COMPAT_CLIENT_INSTALL_PATH': str(steam),
                       'STEAM_COMPAT_INSTALL_PATH': install_path,
                       'SteamAppId': app,
                       'SteamGameId': app,
                       'PROTON_USE_XALIA': '0'}   # Xalia crashes some games
        plan['command'] = [str(tool.proton), 'run', exe] + arguments
    elif shutil.which('wine'):
        plan['command'] = ['wine', exe] + arguments
    else:
        raise Failure('No Proton found (and no wine). Install GE-Proton, for example with ProtonUp-Qt, or any Proton in '
                      'Steam (Library > Tools), or pass --proton /path/to/proton.')
    return plan


def show_plan(plan):
    print('Steam folders: ' + (', '.join(map(str, plan['roots'])) or 'none'))
    print('Steam libraries: ' + (', '.join(map(str, plan['libraries'])) or 'none'))
    tool = plan['tool']
    if tool:
        print(f'Proton: {tool.name} ({plan["why"]}): {tool.proton}')
        print(f'Prefix: {plan["prefix"]}' + (' (to be created)' if plan['init'] else ''))
    else:
        print('No Proton found; starting with wine.')


def environment(plan):
    env = dict(os.environ)
    for key, value in plan['env'].items():
        env.setdefault(key, value)   # the player's own settings win
    return env


def start_game(client, arguments, options, watch=None):
    plan = plan_start(client, arguments, options)
    show_plan(plan)
    env = environment(plan)
    if options.dry_run:
        for key in plan['env']:
            print(f'Would set {key}={env[key]}')
        if plan['init']:
            print('Would create the prefix: ' + ' '.join(shlex.quote(c) for c in [str(plan['tool'].proton), 'run', 'wineboot', '-u']))
        print('Would run (in the game folder): ' + ' '.join(shlex.quote(c) for c in plan['command']))
        return 0
    if plan['init']:
        print('Creating the Proton prefix (once, takes a minute) ...')
        plan['prefix'].mkdir(parents=True, exist_ok=True)
        subprocess.call([str(plan['tool'].proton), 'run', 'wineboot', '-u'], cwd=client, env=env)
        if not prefix_ready(plan['prefix']):
            raise Failure(f'Proton could not set up the prefix {plan["prefix"]}. Start Ring of Elysium once from Steam '
                          '(it sets up the prefix; quit at the login screen), then run join.py again.')
    game = subprocess.Popen(plan['command'], cwd=client, env=env)
    # While it runs, `watch` is called every 30 s (the server's numbers).
    while True:
        try:
            code = game.wait(timeout=30 if watch else None)
            break
        except subprocess.TimeoutExpired:
            watch()
    if watch:
        print()
    return code


# --- Voice chat --------------------------------------------------------------------------------
VOICE_FILE = 'GCloudVoice.dll'
VOICE_SOURCE = Path(_HERE) / 'voice'
SCRIPT_FOLDER = Path(_HERE)


def default_voice_dll():
    """Where our DLL is looked for without asking: next to join.py, then in its voice folder."""
    for folder in (SCRIPT_FOLDER, VOICE_SOURCE):
        if (folder / VOICE_FILE).is_file():
            return folder / VOICE_FILE
    return SCRIPT_FOLDER / VOICE_FILE
VOICE_DOWNLOAD = 'https://github.com/mschnati/roe-os-client/raw/main/voice/GCloudVoice.dll'
VERIFY = 'Steam: Ring of Elysium > Properties > Installed Files > Verify integrity of game files'


def voice_backups():
    return CONFIG / 'roe-join' / 'voice-backup'


def voice_backup_dir(backups, client):
    return Path(backups) / hashlib.sha256(str(client).encode()).hexdigest()[:12]


VOICE_BACKUP = 'roe-join-backup'   # in the game folder: the original DLL


def voice_readme(client):
    text = (f"The game's original {VOICE_FILE}, saved by join.py before it put in the one for voice chat.\n"
            f"join.py puts it back when the game exits. To do it by hand: copy {VOICE_FILE} from this folder into\n"
            f"{client}\n(replace the file there). Or in Steam: Ring of Elysium > Properties > Installed Files > "
            "Verify integrity of game files.\n")
    try:
        (Path(client) / VOICE_BACKUP / 'README.txt').write_text(text, encoding='ascii', errors='replace')
    except OSError:
        pass


def voice_original(client):
    """The original DLL, kept in the game folder (roe-join-backup/GCloudVoice.dll), where players find it;
    the record with the hashes stays in the config folder."""
    return Path(client) / VOICE_BACKUP / VOICE_FILE


def game_running(client):
    """True when a process runs this folder's Europa_Client.exe (also under wine, as C:\\...\\Europa_Client.exe)."""
    client = Path(client).resolve()
    exe = client / 'Europa_Client.exe'
    try:
        pids = [p for p in os.listdir('/proc') if p.isdigit() and int(p) != os.getpid()]
    except OSError:
        return False
    for pid in pids:
        try:
            args = Path('/proc', pid, 'cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        for arg in args:
            text = arg.decode('utf-8', 'replace')
            if not text.lower().endswith('europa_client.exe'):
                continue
            text = re.sub(r'^[zZ]:\\', '/', text)   # wine's Z: is /
            if text.startswith('/'):
                if Path(text.replace('\\', '/')).resolve() == exe:
                    return True
                continue
            parts = re.split(r'[\\/]', text)
            if len(parts) > 1:
                if parts[-2].lower() == client.name.lower():   # another drive letter: compare the folder name
                    return True
            else:
                try:
                    if Path('/proc', pid, 'cwd').resolve() == client:
                        return True
                except OSError:
                    pass
    return False


def copy_checked(source, target, expected):
    """Copies source over target through a temporary file; '' when target then has the expected hash, else why not."""
    target = Path(target)
    temp = target.with_name(target.name + '.roe-join')
    try:
        shutil.copyfile(source, temp)
        if sha256(temp) != expected:
            raise OSError('the copy differs')
        os.replace(temp, target)
        return ''
    except OSError as error:
        try:
            temp.unlink()
        except OSError:
            pass
        return str(error)


def voice_restore(client, backups, running=game_running, wait=0, retries=5):
    """Puts the original DLL back where ours is in place. False when it could not."""
    folder = voice_backup_dir(backups, client)
    try:
        record = json.loads((folder / 'backup.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return True
    target = Path(client) / VOICE_FILE
    try:
        current = sha256(target)
    except FileNotFoundError:
        # No DLL at all (deleted by hand): the game cannot start without one, so the original goes back.
        current = record.get('installed')
    except OSError as error:
        print(f'Voice chat: cannot read {target} ({error}). Close the game and run join.py again, or: {VERIFY}.')
        return False
    if current != record.get('installed'):
        return True   # the original is back, or Steam replaced the file
    deadline = time.monotonic() + wait
    while running(client):
        if time.monotonic() >= deadline:
            print(f'Voice chat: the game in {client} runs; its original {VOICE_FILE} is put back at the next start.')
            return False
        time.sleep(1)
    saved = voice_original(client)
    try:
        good = sha256(saved) == record.get('original')
    except OSError:
        good = False
    if not good:
        print(f'Voice chat: the backup of the original {VOICE_FILE} ({saved}) is missing or damaged, so {target} '
              f'is still ours. To get the original back: {VERIFY}.')
        return False
    error = ''
    for attempt in range(retries):
        error = copy_checked(saved, target, record['original'])
        if not error:
            print(f'Voice chat: the original {VOICE_FILE} is back in {client}.')
            return True
        time.sleep(1)
    print(f'Voice chat: could not put the original {VOICE_FILE} back in {client} ({error}). Close the game and run '
          f'join.py again (it puts it back first), or: {VERIFY}.')
    return False


def voice_restore_all(backups, running=game_running):
    """At every start: the original back wherever ours was left (a crash or a closed terminal)."""
    for path in sorted(Path(backups).glob('*/backup.json')):
        try:
            client = json.loads(path.read_text(encoding='utf-8'))['folder']
        except (OSError, ValueError, KeyError, TypeError):
            continue
        voice_restore(client, backups, running)


def is_dll64(data):
    """A 64-bit (x64) Windows DLL: MZ, PE, machine 0x8664, the DLL flag."""
    if len(data) < 64 or data[:2] != b'MZ':
        return False
    pe = int.from_bytes(data[0x3c:0x40], 'little')
    return (pe + 24 <= len(data) and data[pe:pe + 4] == b'PE\0\0'
            and int.from_bytes(data[pe + 4:pe + 6], 'little') == 0x8664
            and bool(int.from_bytes(data[pe + 22:pe + 24], 'little') & 0x2000))


def voice_problem(dll, client, backups):
    """Why dll cannot be our voice DLL for client, '' when it can."""
    dll = Path(dll)
    if not dll.is_file():
        return f'{dll} is not found'
    if is_client(str(dll.parent)):
        return f'{dll} is in a game folder; use ours from the server package'
    try:
        data = dll.read_bytes()
    except OSError as error:
        return f'cannot read {dll} ({error.strerror or error})'
    if not is_dll64(data):
        return f'{dll} is not a 64-bit Windows DLL'
    if b'GetVoiceEngine' not in data:
        return f'{dll} has no GetVoiceEngine, so it is no {VOICE_FILE}'
    digest = hashlib.sha256(data).hexdigest()
    original = f"{dll} is the game's original {VOICE_FILE}, not ours"
    try:
        record = json.loads((voice_backup_dir(backups, client) / 'backup.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        record = {}
    record = record if isinstance(record, dict) else {}
    if digest == record.get('original'):
        return original
    # The game's own file, unless we put it there.
    try:
        current = sha256(Path(client) / VOICE_FILE)
    except OSError:
        current = None
    if digest == current and digest != record.get('installed'):
        return original
    return ''


def voice_path(answer):
    """An answer to the DLL question as a path: a folder means its GCloudVoice.dll."""
    path = Path(os.path.expanduser(answer.strip().strip('"').strip("'")))
    if path.is_dir():
        path = path / VOICE_FILE
    return path.resolve()


def voice_setup(settings, client, backups, ask_path=False, question=None):
    """Our DLL and its hash, asking for its folder where needed: (dll, hash), or (None, None) for
    no voice this time. A DLL found goes into settings as voice_dll (its full path)."""
    question = question or ask
    # The saved DLL, or when it is gone (or none is saved) the one next to join.py.
    saved = settings.get('voice_dll')
    dll = Path(saved) if saved and Path(saved).is_file() else default_voice_dll()
    offer = ''
    if ask_path:
        offer = str(dll) if dll.is_file() else ''
    else:
        problem = voice_problem(dll, client, backups)
        if problem:
            print(f'Voice chat: our {VOICE_FILE} is not at {dll}.' if not dll.is_file() else f'Voice chat: {problem}.')
            ask_path = True
    if ask_path:
        print(f'Our {VOICE_FILE} is a separate download: {VOICE_DOWNLOAD} (or the voice folder of the server package).')
    while ask_path:
        try:
            answer = question(f'Folder with our {VOICE_FILE} (or the file itself; Enter: no voice this time)', offer)
        except Failure:
            answer = ''
        if not answer:
            print('Starting without voice chat this time.')
            return None, None
        path = voice_path(answer)
        problem = voice_problem(path, client, backups)
        if not problem:
            dll = path
            break
        print(f'Voice chat: {problem}.')
        offer = ''
    dll = Path(dll).resolve()
    settings['voice_dll'] = str(dll)
    return dll, sha256(dll)


# --- Voice chat prompt (begin) ---
def voice_choice(settings, client, backups, option=None, question=None):
    """Voice chat for this start: (voice to save, dll, hash). On by default: asked once (Enter:
    yes). A yes with a DLL found (saved as voice_dll, then used without asking) and a no are kept;
    a yes without a DLL asks again next start. option: --voice on|off (on asks for the DLL again)."""
    question = question or ask
    voice = settings.get('voice')
    asked = False
    if option:
        voice = option == 'on'
    elif voice is None:
        print()
        print(f'Voice chat needs our {VOICE_FILE} in the game folder while the game runs (the original is put back afterwards).')
        voice = question('Use voice chat? (y/n)', 'y').lower().startswith('y')
        asked = True
        print('Change it later with: join.py --voice on|off')
    if not voice:
        return False, None, None
    dll, digest = voice_setup(settings, client, backups, ask_path=option == 'on', question=question)
    if dll is None and asked:
        return None, None, None
    return True, dll, digest
# --- Voice chat prompt (end) ---


def voice_install(client, backups, dll, expected=None, running=game_running):
    """Backs up the game's DLL and puts ours in (dll; expected: its hash when it was chosen, so a
    file changed since is not used). True when ours is in place."""
    ours = Path(dll)
    try:
        actual = sha256(ours)
    except OSError:
        actual = None
    if expected is None:
        expected = actual
    if not expected or actual != expected:
        print(f'Voice chat: {ours} is missing or changed since it was chosen, so it is not used. Starting without voice chat.')
        return False
    problem = voice_problem(ours, client, backups)
    if problem:
        print(f'Voice chat: {problem}; starting without voice chat.')
        return False
    target = Path(client) / VOICE_FILE
    if running(client):
        print(f'Voice chat: the game in {client} runs already; its {VOICE_FILE} stays as it is.')
        return False
    folder = voice_backup_dir(backups, client)
    if not target.is_file():
        # The game's DLL is gone: ours goes in. A good backup of the original stays and comes back
        # when the game exits; without one ours stays (the game cannot start without a GCloudVoice.dll).
        try:
            record = json.loads((folder / 'backup.json').read_text(encoding='utf-8'))
            good = sha256(voice_original(client)) == record.get('original')
        except (OSError, ValueError, AttributeError):
            record, good = None, False
        if good and record.get('installed') != expected:
            try:
                temp = folder / 'backup.json.tmp'
                temp.write_text(json.dumps({'folder': str(client), 'original': record['original'], 'installed': expected},
                                           indent=2), encoding='utf-8')
                os.replace(temp, folder / 'backup.json')
            except OSError:
                good = False
        error = copy_checked(ours, target, expected)
        if error:
            print(f'Voice chat: could not put our {VOICE_FILE} into {client} ({error}); starting without voice chat.')
            return False
        if good:
            print(f'Voice chat: on ({VOICE_FILE} was missing in {client}). The original is saved in '
                  f'{voice_original(client).parent} and put back when the game exits.')
        else:
            print(f'Voice chat: on ({VOICE_FILE} was missing in {client} and there is no backup of the original, so ours '
                  f'stays there. To get the original: {VERIFY}).')
        return True
    current = sha256(target)
    if current == expected:
        # Ours is never backed up, so a second start keeps the original's backup.
        try:
            record = json.loads((folder / 'backup.json').read_text(encoding='utf-8'))
            good = record.get('installed') == expected and sha256(voice_original(client)) == record.get('original')
        except (OSError, ValueError, AttributeError):
            good = False
        if not good:
            print(f'Voice chat: our {VOICE_FILE} is in {client} already, but there is no good backup of the original. '
                  f'To get the original back later: {VERIFY}.')
        return True
    error = ''
    try:
        folder.mkdir(parents=True, exist_ok=True)
    except OSError as failure:
        error = str(failure)
    original = Path(client) / VOICE_BACKUP / VOICE_FILE
    if not error:
        try:
            original.parent.mkdir(parents=True, exist_ok=True)
        except OSError as failure:
            error = str(failure)
    error = error or copy_checked(target, original, current)
    if not error:
        voice_readme(client)
    if not error:
        record = folder / 'backup.json.tmp'
        try:
            record.write_text(json.dumps({'folder': str(client), 'original': current, 'installed': expected}, indent=2),
                              encoding='utf-8')
            os.replace(record, folder / 'backup.json')
        except OSError as failure:
            error = str(failure)
    if error:
        print(f'Voice chat: could not back up {target} ({error}); starting without voice chat.')
        return False
    error = copy_checked(ours, target, expected)
    if error:
        print(f'Voice chat: could not put our {VOICE_FILE} into {client} ({error}); starting without voice chat.')
        return False
    print(f"Voice chat: on. The game's original {VOICE_FILE} is saved in {original.parent} and put back when the game "
          f'exits (to do it by hand: copy it from there into {client}).')
    return True


def play(client, arguments, options, watch=None, dll=None, expected=None, backups=None, running=game_running):
    """start_game with our voice DLL (dll) in place while the game runs."""
    backups = backups or voice_backups()
    installed = False
    if dll and options.dry_run:
        print(f'Would put our {VOICE_FILE} ({dll}) into {client} (the original kept in {Path(client) / VOICE_BACKUP})')
    elif dll:
        installed = voice_install(client, backups, dll, expected, running)
    try:
        return start_game(client, arguments, options, watch)
    finally:
        if installed:
            voice_restore(client, backups, running, wait=15)


# --- Questions and the account service ---------------------------------------------------------
def ask(question, default=''):
    suffix = f' [{default}]' if default else ''
    try:
        answer = input(question + suffix + ': ').strip().strip('"')
    except EOFError:
        if default:
            print()
            return default
        raise Failure('No answer (end of input).')
    return answer or default


def valid_name(name):
    return bool(name) and len(name) <= 24 and not re.search(r'[\x00-\x1f]', name)


def ask_name(default):
    while True:
        name = ask('Your name (1 to 24 characters)', default)
        if valid_name(name):
            return name
        print('That name is empty, too long or has control characters.')
        default = ''


# --- Account menu ------------------------------------------------------------------------------
NEW_ACCOUNT = 'Create a new account'


def menu_step(index, key, count):
    """The menu after one key: (selected index, chosen)."""
    if key == 'enter':
        return index, True
    if key == 'up':
        return (index - 1) % count, False
    if key == 'down':
        return (index + 1) % count, False
    if key == 'home':
        return 0, False
    if key == 'end':
        return count - 1, False
    return index, False


def can_read_keys():
    return (os.name == 'posix' and sys.stdin.isatty() and sys.stdout.isatty()
            and os.environ.get('TERM', 'dumb') not in ('', 'dumb'))


def terminal_key(fd):
    """The next key from a terminal in cbreak mode: 'up', 'down', 'home', 'end', 'enter' or the character."""
    import select
    c = os.read(fd, 1)
    if c in (b'\r', b'\n'):
        return 'enter'
    if c == b'\x04':
        raise EOFError
    if c != b'\x1b':
        return {b'k': 'up', b'j': 'down'}.get(c, c.decode('latin-1'))
    seq = b''
    while len(seq) < 3 and select.select([fd], [], [], 0.05)[0]:
        seq += os.read(fd, 1)
        if seq[-1:].isalpha() or seq[-1:] == b'~':
            break
    return {b'[A': 'up', b'OA': 'up', b'[B': 'down', b'OB': 'down', b'[H': 'home', b'OH': 'home',
            b'[1~': 'home', b'[F': 'end', b'OF': 'end', b'[4~': 'end'}.get(seq, 'escape')


def pick_with_keys(entries, read_key, write, default=0):
    """Arrow keys and Enter; the selected entry is highlighted. Returns its index."""
    index = default
    write('\033[?25l')   # no cursor while choosing
    try:
        drawn = False
        while True:
            if drawn:
                write(f'\033[{len(entries)}A')
            for i, entry in enumerate(entries):
                line = f'> {entry}' if i == index else f'  {entry}'
                write('\r\033[K' + ('\033[7m' + line + '\033[0m' if i == index else line) + '\n')
            drawn = True
            index, chosen = menu_step(index, read_key(), len(entries))
            if chosen:
                return index
    finally:
        write('\033[?25h')


def pick_numbered(entries, answer=None, default=0):
    """A numbered list and a typed number (no key reader: redirected input, dumb terminal)."""
    answer = answer or ask
    for i, entry in enumerate(entries, 1):
        print(f'  {i}. {entry}')
    while True:
        text = answer('Number', str(default + 1))
        if text.isdigit() and 1 <= int(text) <= len(entries):
            return int(text) - 1
        print(f'Enter a number from 1 to {len(entries)}.')


def pick(entries, default=0):
    if can_read_keys():
        import termios
        import tty
        fd = sys.stdin.fileno()
        try:
            saved = termios.tcgetattr(fd)
        except termios.error:
            saved = None
        if saved is not None:
            print('(arrow keys, then Enter)')
            try:
                tty.setcbreak(fd)
                return pick_with_keys(entries, lambda: terminal_key(fd), lambda text: print(text, end='', flush=True), default)
            except EOFError:
                raise Failure('No answer (end of input).')
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    return pick_numbered(entries, default=default)


# --- Saved accounts of a server (accounts.json) ------------------------------------------------
def load_accounts(folder):
    """The saved accounts of a server, the most recently used first: [{name, token, last_used}]."""
    accounts = []
    try:
        data = json.loads((folder / 'accounts.json').read_text(encoding='utf-8-sig'))
        for entry in data.get('accounts', []) if isinstance(data, dict) else []:
            token = str(entry.get('token') or '') if isinstance(entry, dict) else None
            # No key: a name for a server without an account service (play.cmd's own server).
            if token is not None and (re.fullmatch(r'[0-9a-f]{64}', token) or (not token and entry.get('name'))):
                accounts.append({'name': str(entry.get('name') or '?'), 'token': entry['token'],
                                 'last_used': int(entry.get('last_used') or 0)})
    except (OSError, ValueError, TypeError):
        pass
    accounts.sort(key=lambda entry: -entry['last_used'])
    return accounts


def save_accounts(folder, accounts):
    """accounts.json, readable only by the user."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'accounts.json'
    temp = folder / 'accounts.json.tmp'
    with contextlib.suppress(FileNotFoundError):
        temp.unlink()
    with os.fdopen(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as f:
        json.dump({'accounts': accounts}, f, indent=2)
    os.replace(temp, path)
    return path


def refresh_names(accounts, request):
    """The current names from the server (renamed in the game); True when one changed."""
    changed = False
    for entry in [entry for entry in accounts if entry['token']]:
        reply = request(f'NAME {entry["token"]}')
        if reply is None or not reply.startswith(('OK ', 'DENIED')):
            break   # no answer or the limit
        if reply.startswith('OK ') and reply[3:] and reply[3:] != entry['name']:
            entry['name'] = reply[3:]
            changed = True
    return changed


def choose_account(accounts, name=None, choose=pick):
    """The saved account to log in with, or None for a new one. `name` picks without the menu."""
    if name:
        return next((entry for entry in accounts if entry['name'].lower() == name.lower()), None)
    if not accounts:
        return None
    print('Account:')
    index = choose([entry['name'] for entry in accounts] + [NEW_ACCOUNT])
    return accounts[index] if index < len(accounts) else None


# --- Saved servers -----------------------------------------------------------------------------
NEW_SERVER = 'Enter another server (IP or domain)'
SERVER_QUESTION = 'Server address (IP or domain)'


def server_folder_name(address):
    return re.sub(r'[^a-z0-9._-]', '_', address.lower())


def saved_servers(settings):
    """The servers joined before (the settings' "servers"), the most recently used first:
    [{address, last_used[, name]}]."""
    found = {}
    servers = settings.get('servers')
    for entry in servers if isinstance(servers, list) else []:
        if isinstance(entry, dict) and isinstance(entry.get('address'), str) and entry['address'].strip():
            key = server_folder_name(entry['address'])
            if key not in found:
                try:
                    last = int(entry.get('last_used') or 0)
                except (TypeError, ValueError):
                    last = 0
                found[key] = {'address': entry['address'].strip(), 'last_used': last}
                if isinstance(entry.get('name'), str) and clean_server_name(entry['name']):
                    found[key]['name'] = clean_server_name(entry['name'])
    return sorted(found.values(), key=lambda s: -s['last_used'])


# The servers a first start offers (none saved yet), so a new player only picks one and plays.
DEFAULT_SERVERS = [{'address': 'roe-os.de', 'name': 'ROE-OS'}]


def offered_servers(settings):
    """The servers to offer: the saved ones, else DEFAULT_SERVERS."""
    return saved_servers(settings) or [dict(s, last_used=0) for s in DEFAULT_SERVERS]


def remember_server(servers, address, now=None):
    """The list with address used now, on top (its saved name kept)."""
    key = server_folder_name(address)
    rest = [s for s in servers if server_folder_name(s['address']) != key]
    entry = {'address': address, 'last_used': int(time.time() if now is None else now)}
    entry.update({'name': s['name'] for s in servers if server_folder_name(s['address']) == key and s.get('name')})
    return [entry] + rest


def clean_server_name(text):
    """A server name fit to show: no control characters, at most 40 characters."""
    return ''.join(c for c in text if c.isprintable())[:40].strip()


def info_server_name(reply):
    """The server name in an INFO answer, '' for none."""
    m = re.search(r'(?:^| )name=(\S*)$', reply or '')
    if not m:
        return ''
    return clean_server_name(urllib.parse.unquote(m.group(1), errors='replace'))


def name_server(servers, address, name):
    """The saved name of address set to name ('' removes it); True when it changed."""
    key = server_folder_name(address)
    for entry in servers:
        if server_folder_name(entry['address']) == key and entry.get('name', '') != name:
            if name:
                entry['name'] = name
            else:
                entry.pop('name', None)
            return True
    return False


def server_label(entry):
    return f"{entry['name']} ({entry['address']})" if entry.get('name') else entry['address']


def choose_server(servers, given=None, choose=pick, question=ask):
    """The server address: given (--server), else the menu of saved servers; the first start asks."""
    if given:
        return given
    if not servers:
        return question(SERVER_QUESTION, '')
    print('Server:')
    index = choose([server_label(s) for s in servers] + [NEW_SERVER])
    if index < len(servers):
        return servers[index]['address']
    return question(SERVER_QUESTION, '')


def refused(reply, name=''):
    if reply == 'LIMIT':
        raise Failure('Too many attempts from this address. Try again in a few minutes.')
    if reply == 'BANNED':
        who = f'The name {name} or your address' if name else 'Your address'
        raise Failure(f'{who} is banned on this server. Ask the server admin if you think this is a mistake.')
    raise Failure(f'The account service answered: {reply}')


def create_account(request, folder, accounts, name=None, name_question=ask_name):
    """A new account, saved; None when the server has no account service. Without a name the
    server names it (first-login on: the game asks for the real one); else the player picks it."""
    if not name:
        reply = request('NEW')
        if reply is None:
            return None
        if (m := re.fullmatch(r'OK ([0-9a-f]{64}) (.+)', reply)):
            entry = {'name': m.group(2), 'token': m.group(1), 'last_used': int(time.time())}
            accounts.insert(0, entry)
            path = save_accounts(folder, accounts)
            print(f'New account created; you choose its name in the game. Its key is saved in {path}')
            return entry
        if reply != 'NAME-REQUIRED':
            refused(reply)
        name = name_question('')
    while True:
        reply = request(f'CLAIM {name}')
        if reply is None:
            return None
        if (m := re.fullmatch(r'OK ([0-9a-f]{64})', reply)):
            entry = {'name': name, 'token': m.group(1), 'last_used': int(time.time())}
            accounts.insert(0, entry)
            path = save_accounts(folder, accounts)
            print(f'The name {name} is yours on this server. Its key is saved in {path}')
            return entry
        if reply in ('TAKEN', 'INVALID'):
            print(f'The name {name} is taken on this server or not allowed. Choose another one.')
            name = name_question('')
            continue
        refused(reply, name)


def save_plain_name(folder, accounts, name):
    """A server without an account service takes a plain name: kept in accounts.json without a
    key, so the menu offers it next time."""
    entry = next((e for e in accounts if not e['token'] and e['name'] == name), None)
    if entry is None:
        entry = {'name': name, 'token': '', 'last_used': 0}
        accounts.insert(0, entry)
    entry['last_used'] = int(time.time())
    accounts.sort(key=lambda e: -e['last_used'])
    save_accounts(folder, accounts)


def login(request, plain, folder, accounts, entry, name=None, name_question=ask_name):
    """(the one-time ticket the game passes on as its -uid, the account's name)."""
    if entry is not None and not entry['token']:
        # A saved name without a key: an account under that name once the server has a service.
        named = entry
        entry = create_account(request, folder, accounts, named['name'], name_question)
        if entry is None:
            save_plain_name(folder, accounts, named['name'])
            plain(named['name'])
            return '1', named['name']
        accounts.remove(named)
        save_accounts(folder, accounts)
    if entry is None:
        entry = create_account(request, folder, accounts, name, name_question)
        if entry is None:   # no account service: the name for the next client from this address
            name = name or name_question('')
            save_plain_name(folder, accounts, name)
            plain(name)
            return '1', name
    reclaimed = False
    while True:
        reply = request(f'LOGIN2 {entry["token"]}')
        if reply is None:
            plain(entry['name'])
            return '1', entry['name']
        if reply == 'DENIED' and not reclaimed:
            # A name the admin released can be claimed again (it keeps its picks and statistics).
            claim = request(f'CLAIM {entry["name"]}')
            if not (claim and (m := re.fullmatch(r'OK ([0-9a-f]{64})', claim))):
                raise Failure(f'The server does not accept the saved key for {entry["name"]}. If it was lost, ask the server '
                              f'admin to run: roe_server account reset "{entry["name"]}"')
            entry['token'] = m.group(1)
            save_accounts(folder, accounts)
            reclaimed = True
            continue
        if (m := re.fullmatch(r'OK ([0-9]+) (.+)', reply)):
            entry['name'] = m.group(2)
            entry['last_used'] = int(time.time())
            accounts.sort(key=lambda e: -e['last_used'])
            save_accounts(folder, accounts)
            print(f'Logged in as {entry["name"]}')
            return m.group(1), entry['name']
        refused(reply, entry['name'])


def is_client(folder):
    return bool(folder) and (Path(folder) / 'Europa_Client.exe').is_file()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def account(ip, port, folder, line):
    """One request to the account service (TLS); None when it does not answer."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # self-signed: checked by its pin below
    try:
        raw = socket.create_connection((ip, port), timeout=5)
    except OSError:
        return None
    with raw, context.wrap_socket(raw, server_hostname='roe_server') as tls:
        cert = tls.getpeercert(binary_form=True)
        if cert is None:
            raise Failure('The server did not provide a TLS certificate.')
        pin = hashlib.sha256(cert).hexdigest()
        pin_path = folder / 'server.pin'
        if pin_path.exists():
            if pin_path.read_text(encoding='ascii').strip() != pin:
                raise Failure("The server's certificate is not the one seen on the first join. Someone may be in between, or "
                              f'the server was set up again. If the server admin confirms a new certificate, delete {pin_path} '
                              'and start again.')
        else:
            folder.mkdir(parents=True, exist_ok=True)
            pin_path.write_text(pin + '\n', encoding='ascii')
            print('First contact; remembered the server certificate ' + pin)
        tls.sendall((line + '\n').encode())
        reply = b''
        while not reply.endswith(b'\n'):
            chunk = tls.recv(512)
            if not chunk:
                break
            reply += chunk
        return reply.decode('utf-8', 'replace').strip()


def plain_name(ip, port, name):
    """Servers without accounts: the name for the next client from this address."""
    try:
        with socket.create_connection((ip, port), timeout=5) as s:
            s.sendall(f'ROE-NAME {name}\n'.encode())
            try:
                reply = s.recv(128).decode('utf-8', 'replace').strip()
            except OSError:
                reply = ''
    except OSError:
        raise Failure(f'No server answers at {ip}:{port}. Check the address, that the server runs with --bind 0.0.0.0, and the '
                      f"host's firewall (TCP {port} and {port + 1}, UDP 18001, and the ports above it on a server with several maps or match processes).")
    if reply == 'OK':
        print(f'Name registered: {name}')
    elif reply:
        print(f'The server did not accept the name ({reply}). You will play under the default name.')
    else:
        print('This server does not take names. You will play under the default name.')


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description='Join a Ring of Elysium 2022 server (roe_server) on Linux.')
    parser.add_argument('--game', help='game folder (the one with Europa_Client.exe; XVersion works too)')
    parser.add_argument('--server', help='server address (IP or domain, saved as typed and resolved again at every join)')
    parser.add_argument('--name', help='the saved account of this name, or a new account claiming it (no menu)')
    parser.add_argument('--proton', default=os.environ.get('PROTON') or None,
                        help='the proton script (or its folder) to start the game with; also PROTON=...')
    parser.add_argument('--compat', help="Proton prefix folder (default: the game's compatdata/<app id>)")
    parser.add_argument('--voice', choices=('on', 'off'),
                        help='voice chat: our GCloudVoice.dll in the game folder while the game runs (asked once); '
                             'on also asks for the folder of our DLL')
    backup = parser.add_mutually_exclusive_group()
    backup.add_argument('--export', nargs='?', const='', metavar='FILE',
                        help=f'write every server\'s accounts (their keys!) into one file ({BACKUP_FILE} by default) for another computer')
    backup.add_argument('--import', dest='import_', metavar='FILE', help='merge such a file (also from join.cmd export) into this computer')
    parser.add_argument('--admin', action='store_true',
                        help="GM accounts: open the server's admin page in the browser (with --server and --name as for a join)")
    parser.add_argument('--dry-run', action='store_true', default=bool(os.environ.get('ROE_JOIN_DRY_RUN')),
                        help='print what would be done: no server contact, no files written; also ROE_JOIN_DRY_RUN=1')
    return parser.parse_args(argv)


# --- The admin page (GM accounts) ---------------------------------------------------------------
def account_role(reply):
    """'gm' or 'player' from the answer to ROLE; '' for an unknown key, an older server or no answer."""
    return {'OK gm': 'gm', 'OK player': 'player'}.get(reply or '', '')


def domain_host(host):
    """A domain (not an IP address): its admin page is https://admin.<domain> unless the server names another."""
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        return bool(re.fullmatch(r'[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+', host or ''))


def admin_link(reply, host):
    """(the admin page's one-time login link, None) from the answer to WEB, or (None, why there is none)."""
    problems = {'DENIED': 'This account has no GM rights on this server.', 'NONE': 'This server has no admin page.',
                'INVALID': 'This server has no admin page.', 'LIMIT': 'Too many attempts from this address. Try again in a minute.',
                'BANNED': 'This account or your address is banned on this server.'}
    if not reply or reply in problems:
        return None, problems.get(reply or 'NONE')
    m = re.fullmatch(r'OK ([0-9a-f]{64}) (\S+)', reply)
    if not m:
        return None, f'The account service answered: {reply}'
    ticket, base = m.groups()
    if base == '-':
        if not domain_host(host):
            return None, 'This server has no admin page address (its admin can set one: roe_server set admin-url URL).'
        base = f'https://admin.{host.lower()}'
    else:
        base = urllib.parse.unquote(base)
        if len(base) > 200 or not re.fullmatch(r'https?://[!-~]+', base):
            return None, 'The server names no valid admin page address.'
        base = base.rstrip('/')
    return f'{base}/login?ticket={ticket}', None


def admin_page(request, entry, host):
    """The login link for a saved account (its role first: a player's account asks for no ticket)."""
    if not entry or not entry.get('token'):
        return None, 'Choose a saved account of this server (one with a key).'
    if account_role(request(f'ROLE {entry["token"]}')) == 'player':
        return None, 'This account has no GM rights on this server.'
    return admin_link(request(f'WEB {entry["token"]}'), host)


MAX_ADDRESSES = 64


def server_addresses(reply):
    """The ADDRESSES answer as canonical IPv4 and IPv6 addresses (not loopback), each once, at most
    MAX_ADDRESSES; None without an OK (no answer or the limit). Other words are skipped."""
    if not reply or not (reply == 'OK' or reply.startswith('OK ')):
        return None
    found = []
    for word in reply[3:].split():
        if not re.fullmatch(r'[0-9a-fA-F.:]{2,45}', word) or (':' not in word and not re.fullmatch(r'\d{1,3}(\.\d{1,3}){3}', word)):
            continue
        try:
            address = ipaddress.ip_address(word)
        except ValueError:
            continue
        if address.version == 6 and address.ipv4_mapped:
            address = address.ipv4_mapped
        if address.is_loopback or address.is_unspecified or address.is_multicast or str(address) == '255.255.255.255':
            continue
        if str(address) not in found and len(found) < MAX_ADDRESSES:
            found.append(str(address))
    return found


def version_key(version):
    """A dotted version ("0.9") as four numbers to compare; None when it is no version."""
    if not re.fullmatch(r'\d{1,6}(\.\d{1,6}){0,3}', version or ''):
        return None
    parts = [int(part) for part in version.split('.')]
    return tuple(parts + [0] * (4 - len(parts)))


def script_versions(reply):
    """The VERSION answer: {'min', 'current', 'url'} (versions as text, '0' when missing); None
    without an OK (no answer or the limit)."""
    if not reply or not reply.startswith('OK '):
        return None
    values = dict(pair.split('=', 1) for pair in reply[3:].split() if '=' in pair)
    found = {}
    for key in ('min', 'current'):
        found[key] = values[key] if version_key(values.get(key)) else '0'
    url = ''.join(c for c in urllib.parse.unquote(values.get('url', ''), errors='replace') if c.isprintable() and not c.isspace())[:200]
    found['url'] = url if re.match(r'https?://.', url) else JOIN_URL
    return found


def version_notice(reply, have=JOIN_VERSION, script='join.py'):
    """Raises Failure when this script is older than the server needs; a line when a newer one
    exists, else None."""
    versions = script_versions(reply)
    if not versions:
        return None
    if version_key(have) < version_key(versions['min']):
        raise Failure(f"This {script} is version {have}; the server needs version {versions['min']} or newer. "
                      f"Download the new {script} from {versions['url']} and start it again.")
    if version_key(have) < version_key(versions['current']):
        return f"A newer {script} (version {versions['current']}) is at {versions['url']}; this one (version {have}) still works."
    return None


def format_stats(reply):
    """The account service's STATS answer as one line, a part per region:
    "EU (normal): 12 online, 3 searching, 2 matches | AS (duel): ...". '' from an older server."""
    if reply != 'OK' and not (reply or '').startswith('OK '):
        return ''
    parts = []
    for word in reply.split()[1:]:
        fields = word.split(',')
        if len(fields) < 6 or not fields[0].isdigit() or not re.fullmatch(r'[a-z]{1,12}', fields[1]) or not all(f.isdigit() for f in fields[2:5]):
            continue
        name = ''.join(c for c in urllib.parse.unquote(fields[5], errors='replace') if c.isprintable())[:40]
        name = re.sub(r'\s+SERVER$', '', name).strip() or f'zone {fields[0]}'
        online, searching, matches = (int(f) for f in fields[2:5])
        parts.append(f"{name} ({fields[1]}): {online} online, {searching} searching, {matches} match{'' if matches == 1 else 'es'}")
    return ' | '.join(parts)


def server_now(info, stats):
    """What runs on the server now, for the line after the login and while the game runs: every
    region with its numbers (STATS), the INFO line only from a server without STATS; INFO's
    restart notice either way."""
    regions = format_stats(stats)
    if not regions:
        return server_info(info)
    text = f'On the server now: {regions}.'
    if re.search(r'(^| )restarting=[1-9]', info or ''):
        text += ' It restarts for an update soon; new searches are refused until then.'
    return text


def server_info(reply):
    """The account service's INFO answer as one line for the player."""
    values, queues = {}, []
    for pair in reply[3:].split():
        m = re.fullmatch(r'queue\.([^=]+)=(\d+),(\d+)', pair)
        if m:
            queues.append(f'{m.group(1)} {m.group(2)} for up to {m.group(3)} s')
            continue
        m = re.fullmatch(r'([a-z_]+)=(\d+)', pair)
        if m:
            values[m.group(1)] = int(m.group(2))
    players, matches = values.get('players', 0), values.get('matches', 0)
    text = (f"On the server now: {players} player{'' if players == 1 else 's'} online, {matches} match{'' if matches == 1 else 'es'} running, "
            f"{values.get('waiting', 0)} searching")
    if queues:
        text += ' (' + ', '.join(queues) + ')'
    text += '.'
    if values.get('restarting'):
        text += ' It restarts for an update soon; new searches are refused until then.'
    return text


# --- Account backup ----------------------------------------------------------------------------
# One JSON file with every server's accounts (names, keys, last use), certificate pin, address and
# name, the same for join.py and join.cmd: {"format": "roe-join-accounts", "version": 1,
# "servers": [{"address", "name", "pin", "accounts": [{"name", "token", "last_used"}]}]}.
BACKUP_FORMAT = 'roe-join-accounts'
BACKUP_WARNING = 'The file holds your account keys: anyone who has it can play as you. Keep it private.'
BACKUP_FILE = 'roe-join-accounts.json'


def backup_address(address):
    """A saved server address fit for a folder name: no path, at most 255 characters."""
    return isinstance(address, str) and 0 < len(address) <= 255 and bool(re.fullmatch(r'[A-Za-z0-9._:\[\]-]+', address)) \
        and not re.fullmatch(r'\.+', address)


def read_pin(folder):
    try:
        return (folder / 'server.pin').read_text(encoding='ascii').strip()
    except (OSError, ValueError):
        return ''


def account_backup(root, settings):
    """The backup of every server in root (the roe-join folder) and the settings' servers."""
    rows = []
    for server in saved_servers(settings):
        folder = Path(root) / server_folder_name(server['address'])
        pin = read_pin(folder)
        accounts = [{'name': a['name'], 'token': a['token'], 'last_used': a['last_used']} for a in load_accounts(folder)]
        if accounts or pin:
            rows.append({'address': server['address'], 'name': server.get('name', ''), 'pin': pin, 'accounts': accounts})
    return {'format': BACKUP_FORMAT, 'version': 1, 'servers': rows}


def export_accounts(root, settings, path):
    """Writes the backup to path (readable only by the user): (servers, accounts)."""
    backup = account_backup(root, settings)
    path = Path(path)
    with contextlib.suppress(FileNotFoundError):
        path.unlink()
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as f:
        json.dump(backup, f, indent=2)
    return len(backup['servers']), sum(len(s['accounts']) for s in backup['servers'])


def import_accounts(root, settings, path, question=ask):
    """Merges a backup into root: new accounts are added, one already there (same key or name)
    keeps whichever was used last; a different certificate pin is replaced only when the player
    says so (else that server is skipped). Returns {servers, added, updated, skipped}, servers
    being the settings' list with the new servers."""
    try:
        backup = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        backup = None
    if not isinstance(backup, dict) or backup.get('format') != BACKUP_FORMAT or not isinstance(backup.get('version'), int) \
            or isinstance(backup.get('version'), bool) or backup['version'] < 1:
        raise Failure(f'{path} is no account backup of join.py or join.cmd.')
    result = {'servers': saved_servers(settings), 'added': 0, 'updated': 0, 'skipped': []}
    for server in backup.get('servers') if isinstance(backup.get('servers'), list) else []:
        if not isinstance(server, dict):
            continue
        address = str(server.get('address') or '').strip()
        if not backup_address(address):
            continue
        folder = Path(root) / server_folder_name(address)
        pin = str(server.get('pin') or '').strip().lower()
        if not re.fullmatch(r'[0-9a-f]{64}', pin):
            pin = ''
        mine = read_pin(folder)
        if pin and mine and mine != pin:
            print(f'The backup has another server certificate for {address} than this computer ({mine}).')
            print('Replace it only if the server was set up again; otherwise someone may be in between.')
            if not question(f"Take the backup's certificate and accounts for {address}? (y/n)", 'n').lower().startswith('y'):
                result['skipped'].append(address)
                continue
        accounts = load_accounts(folder)
        changed = False
        for entry in server.get('accounts') if isinstance(server.get('accounts'), list) else []:
            if not isinstance(entry, dict) or not re.fullmatch(r'[0-9a-f]{64}', str(entry.get('token') or '')):
                continue
            name = entry.get('name') if isinstance(entry.get('name'), str) and valid_name(entry['name']) else '?'
            try:
                last = int(entry.get('last_used') or 0)
            except (TypeError, ValueError):
                last = 0
            new = {'name': name, 'token': entry['token'], 'last_used': last}
            same = [a for a in accounts if a['token'] == new['token'] or (name != '?' and a['name'].lower() == name.lower())]
            if not same:
                accounts.append(new)
                result['added'] += 1
                changed = True
            elif same[0]['last_used'] < last:
                accounts[accounts.index(same[0])] = new
                result['updated'] += 1
                changed = True
        if changed:
            accounts.sort(key=lambda a: -a['last_used'])
            save_accounts(folder, accounts)
        if pin:
            folder.mkdir(parents=True, exist_ok=True)
            (folder / 'server.pin').write_text(pin + '\n', encoding='ascii')
        key = server_folder_name(address)
        entry = next((s for s in result['servers'] if server_folder_name(s['address']) == key), None)
        name = clean_server_name(server['name']) if isinstance(server.get('name'), str) else ''
        if entry is None:
            entry = {'address': address, 'last_used': max((a['last_used'] for a in accounts), default=0)}
            result['servers'].append(entry)
        if name and not entry.get('name'):
            entry['name'] = name
    return result


def backup_command(options, settings, root=None, question=ask):
    """--export [FILE] and --import FILE."""
    root = Path(root or CONFIG / 'roe-join')
    if options.export is not None:
        path = Path(options.export or BACKUP_FILE).expanduser().resolve()
        if path.exists() and not question(f'{path} exists. Overwrite it? (y/n)', 'n').lower().startswith('y'):
            raise Failure('Cancelled.')
        servers, accounts = export_accounts(root, settings, path)
        print(f'Saved {accounts} accounts of {servers} servers in {path}.')
        print(BACKUP_WARNING)
        print('On the other computer: python3 join.py --import <file> (or join.cmd import <file>).')
        return 0
    path = Path(options.import_).expanduser()
    if not path.is_file():
        raise Failure(f'No file: {path}')
    print(BACKUP_WARNING)
    done = import_accounts(root, settings, path, question)
    settings = dict(settings, servers=done['servers'])
    CONFIG.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(settings, indent=2), encoding='utf-8')
    print(f"Imported: {done['added']} new accounts, {done['updated']} updated (used more recently in the backup).")
    if done['skipped']:
        print('Skipped (another certificate): ' + ', '.join(done['skipped']) + '.')
    print('You may delete the backup file now.')
    return 0


def admin_command(options, settings, opener=None):
    """--admin: the server and the account as for a join, then the browser at the admin page."""
    servers = offered_servers(settings)
    server = choose_server(servers, options.server).strip()
    if not server:
        raise Failure('A server address is needed.')
    host = server
    if (m := re.fullmatch(r'(.+):(\d{1,5})', server)):
        host = m.group(1)
    try:
        ip = socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0]
    except OSError:
        raise Failure(f'Cannot resolve {host} to an IPv4 address.')
    folder = CONFIG / 'roe-join' / server_folder_name(server)
    accounts = [entry for entry in load_accounts(folder) if entry.get('token')]
    if not accounts:
        raise Failure('No saved account of this server. Join it once with your GM account first.')
    entry = choose_account(accounts, options.name)
    if not entry:
        raise Failure(f'No saved account named {options.name} for this server.' if options.name else
                      'Choose a saved account: the admin page is for existing GM accounts.')
    url, problem = admin_page(lambda line: account(ip, 8002, folder, line), entry, host)
    if problem:
        raise Failure(problem)
    print(f'Opening the admin page for {entry["name"]} in your browser (the link works once, for one minute).')
    if opener is None:
        import webbrowser
        opener = webbrowser.open
    if not opener(url):
        print(f'Open this in your browser within a minute: {url}')
    return 0


def main(argv=None):
    options = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        settings = json.loads(SETTINGS.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        settings = {}
    if isinstance(settings, dict):
        settings.pop('voice_dll_sha256', None)  # no longer used
    if options.export is not None or options.import_:
        return backup_command(options, settings)
    if options.admin:
        return admin_command(options, settings)
    print('Ring of Elysium 2022: join a server' + (' (dry run)' if options.dry_run else ''))
    print()
    if not options.dry_run:
        voice_restore_all(voice_backups())   # ours left by a crash: the original back first
    problems = []

    # 1. The game.
    if options.game:
        client = options.game
    else:
        guess = settings.get('client', '')
        if not is_client(guess):
            guess = find_game(libraries(steam_roots(Path.home())))
            if not guess:
                print('Ring of Elysium was not found in a Steam library. Enter its folder, or pass --game.')
        client = ask('Game folder (the one with Europa_Client.exe)', guess)
    client = os.path.expanduser(client)
    if not is_client(client):
        raise Failure(f'No Europa_Client.exe in: {client or "(nothing entered)"}. Pass the game folder with '
                      '--game "/path/to/steamapps/common/Ring of Elysium".')
    client = str(Path(client).resolve())
    if sha256(Path(client) / 'Europa_Client.exe') not in EXPECTED_SHA:
        message = ('This is a different game build. The server needs 2022-0.2.989.0 x64: the Europa_Client.exe of the main '
                   'game folder or of XVersion. Let Steam repair it: Ring of Elysium > Properties > Installed Files > '
                   'Verify integrity of game files.')
        if not options.dry_run:
            raise Failure(message)
        problems.append(message)
        print('Would stop here: ' + message)

    # 2. Server and name. The game only connects to lobby port 8001, so a second server needs its own address.
    servers = offered_servers(settings)
    server = choose_server(servers, options.server).strip()
    if not server:
        raise Failure('A server address is needed.')
    host, lobby_port = server, 8001
    if (m := re.fullmatch(r'(.+):(\d{1,5})', server)):
        if int(m.group(2)) != 8001:
            raise Failure(f'The game only connects to port 8001. Enter the server address without :{m.group(2)} '
                          '(a second server runs on its own address).')
        host = m.group(1)
    account_port = lobby_port + 1
    if options.name is not None and not valid_name(options.name):
        raise Failure('The name must be 1 to 24 characters without control characters.')
    voice, dll, expected = voice_choice(settings, client, voice_backups(), options.voice)

    def save():
        if options.dry_run:
            return
        CONFIG.mkdir(parents=True, exist_ok=True)
        values = {'client': client, 'voice': voice, 'servers': servers}
        if settings.get('voice_dll'):
            values['voice_dll'] = settings['voice_dll']
        SETTINGS.write_text(json.dumps(values, indent=2), encoding='utf-8')
    servers = remember_server(servers, server)
    save()
    try:
        ip = socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0]
    except OSError:
        if not options.dry_run:
            raise Failure(f'Cannot resolve {host} to an IPv4 address.')
        ip = host
        print(f'Would stop here: cannot resolve {host} to an IPv4 address.')
        problems.append('address')

    # 3. The account and the login.
    print()
    folder = CONFIG / 'roe-join' / server_folder_name(server)
    accounts = load_accounts(folder)

    def request(line):
        return account(ip, account_port, folder, line)

    last_stats = {}

    def stats():
        # STATS for the line of what runs now, at most every 10 s (the server allows more; this
        # keeps its load low); None when it fails (an older server, a timeout).
        if last_stats and time.monotonic() - last_stats['at'] < 10:
            return last_stats['reply']
        try:
            reply = request('STATS')
        except Exception:
            reply = None
        last_stats.update(at=time.monotonic(), reply=reply)
        return reply
    if options.dry_run:
        entry = choose_account(accounts, options.name)
        who = entry['name'] if entry else options.name or 'a new account'
        print(f'Would log in to {ip}:{account_port} as {who} (accounts in {folder / "accounts.json"})')
        uid = '<ticket>'
    else:
        print(f'Contacting {ip} ...')
        # The server's name (INFO).
        reply = request('INFO')
        if reply and reply.startswith('OK '):
            if name_server(servers, server, info_server_name(reply)):
                save()
            if servers[0].get('name'):
                print(f'Connected to {server_label(servers[0])}')
        # Too old for the server: stop before the game starts.
        note = version_notice(request('VERSION'))
        if note:
            print(note)
        # Where else the game goes for this server (other machines with its matches); shown only.
        extra = [a for a in server_addresses(request('ADDRESSES')) or [] if a != ip]
        if extra:
            print('The game also connects to: ' + ', '.join(extra))
        # Who plays where (counts per region; an older server answers nothing to show).
        try:
            regions = format_stats(stats())
        except Exception:
            regions = ''
        if regions:
            print(regions)
        if accounts and not options.name and refresh_names(accounts, request):
            save_accounts(folder, accounts)
        entry = choose_account(accounts, options.name)
        uid, _ = login(request, lambda name: plain_name(ip, lobby_port, name), folder, accounts, entry, options.name)
        # What runs on the server now (counts only, no names).
        try:
            info = account(ip, account_port, folder, 'INFO')
        except Exception:
            info = None
        if info and info.startswith('OK '):
            print(server_now(info, stats()))
        width = [0]

        def watch():
            # Every 30 s while the game runs, on one line that is written over each time.
            try:
                info = account(ip, account_port, folder, 'INFO')
            except Exception:
                return
            if info and info.startswith('OK '):
                text = time.strftime('[%H:%M] ') + server_now(info, stats())
                if not width[0]:
                    print()  # set apart from the lines above
                color, reset = ('\033[36m', '\033[0m') if sys.stdout.isatty() else ('', '')
                print('\r' + color + text.ljust(width[0]) + reset, end='', flush=True)
                width[0] = max(width[0], len(text))

    # 4. The game.
    print()
    if not options.dry_run:
        print('Starting the game.')
    result = play(client, ['-language=en', '-garena', f'-uid={uid}', f'-server={ip}:{lobby_port}'], options,
                  None if options.dry_run else watch, dll=dll, expected=expected)
    return 1 if problems else result


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Failure as error:
        print()
        print(f'Could not join: {error}')
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
