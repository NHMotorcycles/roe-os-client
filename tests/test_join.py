"""join.py against fake Steam trees and game folders: roots, libraries, game, prefix, the Proton choice, the voice DLL and the
account and server menus; join.cmd's voice DLL, account and server functions through powershell.exe."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

JOIN = Path(__file__).resolve().parents[1] / 'join.py'
spec = importlib.util.spec_from_file_location('join', JOIN)
join = importlib.util.module_from_spec(spec)
spec.loader.exec_module(join)


def touch(path, text=''):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def fake_dll(text, machine=0x8664, flags=0x2022):
    """A minimal PE file: MZ, e_lfanew 0x40, PE, machine, flags, then text."""
    return (b'MZ' + bytes(0x3a) + (0x40).to_bytes(4, 'little') + b'PE\0\0' + machine.to_bytes(2, 'little')
            + bytes(16) + flags.to_bytes(2, 'little') + bytes(8) + text)


def proton(folder, prefix_version=''):
    return touch(folder / 'proton', f'#!/usr/bin/env python3\nCURRENT_PREFIX_VERSION="{prefix_version}"\n')


class FakeSteam(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.home = base / 'home'
        self.root = self.home / '.local/share/Steam'
        self.lib = base / 'games/SteamLibrary'
        (self.root / 'steamapps').mkdir(parents=True)
        (self.home / '.steam').mkdir()
        os.symlink(self.root, self.home / '.steam/steam')   # the same install twice
        touch(self.root / 'steamapps/libraryfolders.vdf',
              f'"libraryfolders"\n{{\n "0"\n {{\n  "path"  "{self.root}"\n }}\n "1"\n {{\n  "path"  "{self.lib}"\n }}\n}}\n')
        self.game = self.lib / 'steamapps/common/Ring of Elysium'
        touch(self.game / 'Europa_Client.exe', 'not the game')
        touch(self.game / 'XVersion/Europa_Client.exe', 'not the game')
        touch(self.lib / 'steamapps/appmanifest_755790.acf', '"AppState"\n{\n "appid" "755790"\n "installdir" "Ring of Elysium"\n}\n')
        self.prefix = self.lib / 'steamapps/compatdata/755790'
        self.tools_dir = self.root / 'compatibilitytools.d'
        proton(self.tools_dir / 'GE-Proton9-20', 'GE-Proton9-20')
        proton(self.tools_dir / 'GE-Proton10-3', 'GE-Proton10-3')
        common = self.root / 'steamapps/common'
        proton(common / 'Proton 9.0', '9.0-102')
        proton(common / 'Proton 8.0', '8.0-104')
        proton(common / 'Proton - Experimental', '9.0-200')

    def tearDown(self):
        self.tmp.cleanup()

    def tools(self):
        roots = join.steam_roots(self.home)
        return join.find_tools(roots, join.libraries(roots), system_tools=())

    def choose(self, version=''):
        tool, why = join.choose_proton(self.tools(), version)
        return tool.name if tool else None

    def test_roots_and_libraries(self):
        roots = join.steam_roots(self.home)
        self.assertEqual(roots, [self.root.resolve()])
        libs = join.libraries(roots)
        self.assertEqual(libs, [(self.root / 'steamapps').resolve(), (self.lib / 'steamapps').resolve()])
        self.assertEqual(join.find_game(libs), str(self.game.resolve()))

    def test_game_library_prefix_and_app_id(self):
        for client in (self.game, self.game / 'XVersion'):
            library, installdir = join.library_of(client)
            self.assertEqual((library, installdir), ((self.lib / 'steamapps').resolve(), 'Ring of Elysium'))
            self.assertEqual(join.app_id(client), '755790')
            self.assertEqual(join.find_prefix(client, [], '755790'), self.prefix.resolve())

    def test_newest_ge_first(self):
        self.assertEqual(self.choose(), 'GE-Proton10-3')

    def test_the_proton_that_ran_the_prefix(self):
        self.assertEqual(self.choose('GE-Proton9-20'), 'GE-Proton9-20')
        self.assertEqual(self.choose('9.0-102'), 'Proton 9.0')
        self.assertEqual(self.choose('GE-Proton7-1'), 'GE-Proton10-3')   # not installed any more

    def test_valve_then_custom(self):
        for name in ('GE-Proton9-20', 'GE-Proton10-3'):
            os.remove(self.tools_dir / name / 'proton')
        self.assertEqual(self.choose(), 'Proton 9.0')   # numbered before Experimental
        proton(self.tools_dir / 'proton-cachyos-9')
        self.assertEqual(self.choose(), 'Proton 9.0')
        for name in ('Proton 9.0', 'Proton 8.0', 'Proton - Experimental'):
            os.remove(self.root / 'steamapps/common' / name / 'proton')
        self.assertEqual(self.choose(), 'proton-cachyos-9')

    def test_natural_sort(self):
        names = ['GE-Proton9-20', 'GE-Proton10-1', 'GE-Proton9-3']
        self.assertEqual(sorted(names, key=join.natural_key), ['GE-Proton9-3', 'GE-Proton9-20', 'GE-Proton10-1'])
        self.assertTrue(join.is_ge('Proton-6.21-GE-2'))
        self.assertFalse(join.is_ge('Proton 9.0'))

    def test_plan(self):
        options = argparse.Namespace(proton=None, compat=None)
        plan = join.plan_start(str(self.game.resolve()), ['-garena'], options, home=self.home, system_tools=())
        self.assertEqual(plan['tool'].name, 'GE-Proton10-3')
        self.assertTrue(plan['init'])
        env = plan['env']
        self.assertEqual(env['STEAM_COMPAT_DATA_PATH'], str(self.prefix.resolve()))
        self.assertEqual(env['STEAM_COMPAT_CLIENT_INSTALL_PATH'], str(self.root.resolve()))
        self.assertEqual(env['PROTON_USE_XALIA'], '0')
        self.assertEqual(env['SteamAppId'], '755790')
        self.assertEqual(plan['command'][1:3], ['run', str(self.game.resolve() / 'Europa_Client.exe')])
        touch(self.prefix / 'version', 'GE-Proton9-20')
        (self.prefix / 'pfx/drive_c/users/steamuser').mkdir(parents=True)
        plan = join.plan_start(str(self.game.resolve()), [], options, home=self.home, system_tools=())
        self.assertEqual(plan['tool'].name, 'GE-Proton9-20')
        self.assertFalse(plan['init'])
        options.proton = str(self.root / 'steamapps/common/Proton 8.0')
        self.assertEqual(join.plan_start(str(self.game), [], options, home=self.home, system_tools=())['tool'].name, 'Proton 8.0')
        options.proton = str(self.home / 'nothing')
        with self.assertRaises(join.Failure):
            join.plan_start(str(self.game), [], options, home=self.home, system_tools=())

    def test_start_creates_the_prefix(self):
        # A stand-in Proton: wineboot makes the prefix, the game run logs its arguments and environment.
        log = Path(self.tmp.name) / 'log'
        fake = touch(Path(self.tmp.name) / 'FakeProton/proton',
                     '#!/bin/sh\n'
                     'if [ "$2" = wineboot ]; then mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx/drive_c/users/steamuser"; exit 0; fi\n'
                     f'echo "$1|$3|$PROTON_USE_XALIA|$SteamGameId|$(pwd)" > "{log}"\n')
        fake.chmod(0o755)
        options = argparse.Namespace(proton=str(fake), compat=str(Path(self.tmp.name) / 'pfx-test'), dry_run=False)
        saved = dict(os.environ)
        os.environ['HOME'] = str(self.home)
        try:
            self.assertEqual(join.start_game(str(self.game.resolve()), ['-garena'], options), 0)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertTrue(join.prefix_ready(Path(self.tmp.name) / 'pfx-test'))
        self.assertEqual(log.read_text().strip(), f'run|-garena|0|755790|{self.game.resolve()}')

    def test_dry_run(self):
        env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'), ROE_JOIN_DRY_RUN='1')
        env.pop('PROTON', None)
        result = subprocess.run([sys.executable, '-I', str(JOIN), '--game', str(self.game / 'XVersion'),
                                 '--server', '127.0.0.1', '--name', 'Tester'],
                                env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)   # the fake exe is not the tested build
        self.assertIn('Verify integrity', result.stdout)
        self.assertIn('Would log in to 127.0.0.1:8002 as Tester', result.stdout)
        self.assertIn('GE-Proton10-3', result.stdout)
        self.assertIn('Would set PROTON_USE_XALIA=0', result.stdout)
        self.assertIn('Would create the prefix', result.stdout)
        self.assertIn('-server=127.0.0.1:8001', result.stdout)
        self.assertFalse((self.home / '.config').exists())   # nothing written
        self.assertFalse(self.prefix.exists())


class VoiceFolders(unittest.TestCase):
    """Fake game folders with the original GCloudVoice.dll and the package with ours."""
    ORIGINAL = fake_dll(b'GetVoiceEngine original voice dll')
    OURS = fake_dll(b'GetVoiceEngine our voice dll')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.game = base / 'common/Ring of Elysium'
        self.xversion = self.game / 'XVersion'
        for folder in (self.game, self.xversion):
            touch(folder / 'Europa_Client.exe', 'not the game')
            (folder / 'GCloudVoice.dll').write_bytes(self.ORIGINAL + folder.name.encode())
        self.source = base / 'package/voice'
        self.source.mkdir(parents=True)
        (self.source / 'GCloudVoice.dll').write_bytes(self.OURS)
        self.backups = base / 'config/roe-join/voice-backup'
        self.not_running = lambda client: False

    def tearDown(self):
        self.tmp.cleanup()

    def dll(self, folder):
        return (folder / 'GCloudVoice.dll').read_bytes()

    def install(self, folder, running=None):
        return join.voice_install(str(folder), self.backups, self.source / 'GCloudVoice.dll', running=running or self.not_running)


class Voice(VoiceFolders):
    """Our GCloudVoice.dll in fake game folders: install, restore, crash, running game, bad hash."""
    def test_install_and_restore(self):
        self.assertTrue(self.install(self.game))
        self.assertEqual(self.dll(self.game), self.OURS)
        self.assertEqual(self.dll(self.xversion), self.ORIGINAL + b'XVersion')   # only the folder that is started
        saved = self.game / 'roe-join-backup'   # in the game folder, under its own name, with a note
        self.assertEqual((saved / 'GCloudVoice.dll').read_bytes(), self.ORIGINAL + self.game.name.encode())
        self.assertIn('copy GCloudVoice.dll from this folder', (saved / 'README.txt').read_text())
        self.assertFalse((join.voice_backup_dir(self.backups, str(self.game)) / 'GCloudVoice.dll').exists())
        self.assertTrue(join.voice_restore(str(self.game), self.backups, self.not_running))
        self.assertEqual(self.dll(self.game), self.ORIGINAL + self.game.name.encode())
        self.assertFalse(list(self.game.glob('*.roe-join')))

    def test_restore_on_exit(self):
        # A stand-in Proton logs the DLL the game sees; after it exits the original is back.
        log = Path(self.tmp.name) / 'log'
        fake = touch(Path(self.tmp.name) / 'FakeProton/proton', f'#!/bin/sh\ncat GCloudVoice.dll > "{log}"\n')
        fake.chmod(0o755)
        compat = Path(self.tmp.name) / 'pfx'
        (compat / 'pfx/drive_c/users/steamuser').mkdir(parents=True)
        options = argparse.Namespace(proton=str(fake), compat=str(compat), dry_run=False)
        code = join.play(str(self.xversion), [], options, dll=self.source / 'GCloudVoice.dll', backups=self.backups)
        self.assertEqual(code, 0)
        self.assertEqual(log.read_bytes(), self.OURS)
        self.assertEqual(self.dll(self.xversion), self.ORIGINAL + b'XVersion')

    def test_restore_after_a_crash(self):
        self.assertTrue(self.install(self.game))
        # The second start before the restore: ours is in place and is not backed up over the original.
        self.assertTrue(self.install(self.game))
        join.voice_restore_all(self.backups, self.not_running)
        self.assertEqual(self.dll(self.game), self.ORIGINAL + self.game.name.encode())
        join.voice_restore_all(self.backups, self.not_running)   # nothing left to do
        self.assertEqual(self.dll(self.game), self.ORIGINAL + self.game.name.encode())

    def test_skip_while_running(self):
        exe = self.game / 'Europa_Client.exe'
        game = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)', str(exe)])
        try:
            self.assertTrue(join.game_running(str(self.game)))
            self.assertFalse(join.game_running(str(self.xversion)))
            self.assertFalse(self.install(self.game, join.game_running))
            self.assertEqual(self.dll(self.game), self.ORIGINAL + self.game.name.encode())
            self.assertTrue(self.install(self.xversion, join.game_running))   # the second player's folder
            # Ours in a running game stays until it exits.
            (self.game / 'GCloudVoice.dll').write_bytes(self.OURS)
            saved = join.voice_backup_dir(self.backups, str(self.game))
            saved.mkdir(parents=True)
            original = self.game / 'roe-join-backup'
            original.mkdir()
            (original / 'GCloudVoice.dll').write_bytes(self.ORIGINAL)
            touch(saved / 'backup.json', json.dumps({'folder': str(self.game), 'original': join.hashlib.sha256(self.ORIGINAL).hexdigest(),
                                                     'installed': join.hashlib.sha256(self.OURS).hexdigest()}))
            join.voice_restore_all(self.backups, join.game_running)
            self.assertEqual(self.dll(self.game), self.OURS)
            self.assertEqual(self.dll(self.xversion), self.ORIGINAL + b'XVersion')   # not running: restored
        finally:
            game.kill()
            game.wait()
        join.voice_restore_all(self.backups, join.game_running)
        self.assertEqual(self.dll(self.game), self.ORIGINAL)

    def test_changed_or_wrong_dll_refused(self):
        # Changed since it was chosen (another hash), or no DLL of ours at all.
        ours = self.source / 'GCloudVoice.dll'
        self.assertFalse(join.voice_install(str(self.game), self.backups, ours, 'another hash', self.not_running))
        ours.write_bytes(b'something else')
        self.assertFalse(self.install(self.game))
        self.assertEqual(self.dll(self.game), self.ORIGINAL + self.game.name.encode())
        self.assertFalse(self.backups.exists())

    def test_missing_backup(self):
        self.assertTrue(self.install(self.game))
        (self.game / 'roe-join-backup/GCloudVoice.dll').unlink()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertFalse(join.voice_restore(str(self.game), self.backups, self.not_running))
        self.assertIn('Verify integrity of game files', out.getvalue())
        self.assertEqual(self.dll(self.game), self.OURS)


    def test_missing_game_dll_with_backup(self):
        original = self.dll(self.game)
        self.assertTrue(self.install(self.game))
        self.assertTrue(join.voice_restore(str(self.game), self.backups, self.not_running))
        # Deleted by hand: the next start puts the original back from the backup ...
        (self.game / 'GCloudVoice.dll').unlink()
        join.voice_restore_all(self.backups, self.not_running)
        self.assertEqual(self.dll(self.game), original)
        # ... and with voice on ours goes in, the original back on exit.
        (self.game / 'GCloudVoice.dll').unlink()
        self.assertTrue(self.install(self.game))
        self.assertEqual(self.dll(self.game), self.OURS)
        self.assertTrue(join.voice_restore(str(self.game), self.backups, self.not_running))
        self.assertEqual(self.dll(self.game), original)

    def test_missing_game_dll_without_backup(self):
        (self.game / 'GCloudVoice.dll').unlink()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertTrue(self.install(self.game))
        self.assertIn('no backup of the original', out.getvalue())
        self.assertEqual(self.dll(self.game), self.OURS)
        join.voice_restore_all(self.backups, self.not_running)   # ours stays: the game needs a DLL
        self.assertEqual(self.dll(self.game), self.OURS)


class Answers:
    """Stands in for ask(): gives the answers in turn and keeps the questions and their defaults."""
    def __init__(self, *answers):
        self.answers = list(answers)
        self.asked = []

    def __call__(self, question, default=''):
        self.asked.append((question, default))
        if not self.answers:
            raise AssertionError(f'not expected: {question}')
        answer = self.answers.pop(0)
        return answer if answer else default


class VoicePath(VoiceFolders):
    """The saved DLL path, the questions for it and the hash confirmation."""
    def setUp(self):
        super().setUp()
        self.saved_source = join.VOICE_SOURCE
        join.VOICE_SOURCE = Path(self.tmp.name) / 'nowhere'
        self.ours = self.source / 'GCloudVoice.dll'
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.out = self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        join.VOICE_SOURCE = self.saved_source
        super().tearDown()

    def setup(self, settings, answers, ask_path=False):
        return join.voice_setup(settings, str(self.game), self.backups, ask_path, answers)

    def test_saved_path_used(self):
        settings = {'voice_dll': str(self.ours)}
        answers = Answers()
        self.assertEqual(self.setup(settings, answers), (self.ours, join.hashlib.sha256(self.OURS).hexdigest()))
        self.assertEqual(answers.asked, [])
        join.VOICE_SOURCE = self.source   # no saved path: voice/ next to the script
        self.assertEqual(self.setup({}, answers)[0], self.ours)

    def test_missing_asks_and_saves(self):
        settings = {'voice_dll': str(Path(self.tmp.name) / 'gone/GCloudVoice.dll')}
        # A wrong answer asks again; the folder in quotes is taken as its GCloudVoice.dll.
        answers = Answers(str(Path(self.tmp.name) / 'nothing'), f'"{self.source}"')
        dll, expected = self.setup(settings, answers)
        self.assertEqual(dll, self.ours.resolve())
        self.assertEqual(settings['voice_dll'], str(self.ours.resolve()))
        self.assertEqual(len(answers.asked), 2)
        self.assertEqual(answers.asked[0][1], '')
        # Nothing entered: no voice this time, the saved path stays.
        settings = {'voice_dll': str(Path(self.tmp.name) / 'gone/GCloudVoice.dll')}
        self.assertEqual(self.setup(settings, Answers('')), (None, None))
        self.assertEqual(settings['voice_dll'], str(Path(self.tmp.name) / 'gone/GCloudVoice.dll'))

    def test_voice_on_asks_again(self):
        settings = {'voice_dll': str(self.ours)}
        answers = Answers('')   # Enter keeps the current one
        self.assertEqual(self.setup(settings, answers, ask_path=True)[0], self.ours.resolve())
        self.assertEqual(answers.asked[0][1], str(self.ours))
        other = Path(self.tmp.name) / 'other'
        other.mkdir()
        (other / 'GCloudVoice.dll').write_bytes(self.OURS)
        answers = Answers(str(other / 'GCloudVoice.dll'))
        self.assertEqual(self.setup(settings, answers, ask_path=True)[0], (other / 'GCloudVoice.dll').resolve())
        self.assertEqual(settings['voice_dll'], str((other / 'GCloudVoice.dll').resolve()))

    def test_voice_choice(self):
        # On by default: a yes (Enter) with the DLL found saves both and is not asked again.
        join.VOICE_SOURCE = self.source
        digest = join.hashlib.sha256(self.OURS).hexdigest()
        settings = {}
        answers = Answers('')
        self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, answers), (True, self.ours.resolve(), digest))
        self.assertEqual(answers.asked, [('Use voice chat? (y/n)', 'y')])
        self.assertEqual(settings['voice_dll'], str(self.ours.resolve()))
        settings['voice'] = True
        self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, Answers()), (True, self.ours.resolve(), digest))
        # The saved file gone: asks for its folder once more and saves the new path.
        other = Path(self.tmp.name) / 'other'
        other.mkdir()
        (other / 'GCloudVoice.dll').write_bytes(self.OURS)
        self.ours.unlink()
        answers = Answers(str(other))
        self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, answers)[:2], (True, (other / 'GCloudVoice.dll').resolve()))
        self.assertTrue(answers.asked[0][0].startswith('Folder with our GCloudVoice.dll'))
        self.assertIn('separate download', self.out.getvalue())
        self.assertEqual(settings['voice_dll'], str((other / 'GCloudVoice.dll').resolve()))
        # A no is saved and not asked again.
        self.assertEqual(join.voice_choice({}, str(self.game), self.backups, None, Answers('n')), (False, None, None))
        self.assertEqual(join.voice_choice({'voice': False}, str(self.game), self.backups, None, Answers()), (False, None, None))
        # A yes without a DLL (nothing entered): no voice now, asked again next start.
        settings = {}
        self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, Answers('y', '')), (None, None, None))
        self.assertNotIn('voice_dll', settings)
        # The saved file missing, nothing entered: stays on, no voice now.
        self.assertEqual(join.voice_choice({'voice': True}, str(self.game), self.backups, None, Answers(''))[:2], (True, None))

    def test_dll_next_to_the_script(self):
        # The DLL right next to the script (no voice folder): found without a path question; only
        # the yes/no is asked, once.
        saved = join.SCRIPT_FOLDER
        join.SCRIPT_FOLDER = self.source
        try:
            settings = {}
            answers = Answers('')
            self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, answers)[:2], (True, self.ours.resolve()))
            self.assertEqual(answers.asked, [('Use voice chat? (y/n)', 'y')])
            settings['voice'] = True
            answers = Answers()
            self.assertEqual(join.voice_choice(settings, str(self.game), self.backups, None, answers)[:2], (True, self.ours.resolve()))
            self.assertEqual(answers.asked, [])
        finally:
            join.SCRIPT_FOLDER = saved

    def test_original_refused(self):
        # The game's own DLL copied elsewhere: never used.
        copy = Path(self.tmp.name) / 'copy'
        copy.mkdir()
        original = self.ORIGINAL + self.game.name.encode()
        (copy / 'GCloudVoice.dll').write_bytes(original)
        settings = {'voice_dll': str(copy / 'GCloudVoice.dll')}
        self.assertEqual(self.setup(settings, Answers('')), (None, None))
        self.assertIn("the game's original", self.out.getvalue())
        self.assertFalse(join.voice_install(str(self.game), self.backups, copy / 'GCloudVoice.dll',
                                            join.hashlib.sha256(original).hexdigest(), self.not_running))
        self.assertEqual(self.dll(self.game), original)
        # Once ours is in, the backup's original is still refused.
        self.assertTrue(self.install(self.game))
        self.assertIn("the game's original", join.voice_problem(copy / 'GCloudVoice.dll', str(self.game), self.backups))
        self.assertEqual(join.voice_problem(self.ours, str(self.game), self.backups), '')
        # A DLL inside a game folder, a file that is no x64 DLL, and a DLL without GetVoiceEngine.
        self.assertIn('game folder', join.voice_problem(self.xversion / 'GCloudVoice.dll', str(self.game), self.backups))
        for data, why in ((b'GetVoiceEngine', '64-bit'), (fake_dll(b'GetVoiceEngine', machine=0x14c), '64-bit'),
                          (fake_dll(b'GetVoiceEngine', flags=0x22), '64-bit'), (fake_dll(b'nothing'), 'GetVoiceEngine')):
            (copy / 'GCloudVoice.dll').write_bytes(data)
            self.assertIn(why, join.voice_problem(copy / 'GCloudVoice.dll', str(self.game), self.backups))

    def test_dry_run_voice_on(self):
        home = Path(self.tmp.name) / 'home'
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), ROE_JOIN_DRY_RUN='1')
        env.pop('PROTON', None)
        result = subprocess.run([sys.executable, '-I', str(JOIN), '--game', str(self.game), '--server', '127.0.0.1',
                                 '--name', 'Tester', '--voice', 'on'],
                                env=env, input=f'{self.source}\n', capture_output=True, text=True, timeout=30)
        self.assertIn('Folder with our GCloudVoice.dll', result.stdout, result.stdout + result.stderr)
        self.assertIn(f'Would put our GCloudVoice.dll ({self.ours.resolve()})', result.stdout)
        self.assertFalse((home / '.config').exists())   # nothing written


class FakeService:
    """Stands in for the account service: replies by request line (None: no answer)."""
    def __init__(self, replies):
        self.replies = dict(replies)
        self.sent = []

    def __call__(self, line):
        self.sent.append(line)
        if line not in self.replies:
            raise AssertionError(f'not expected: {line}')
        return self.replies[line]


T1, T2, T3, T4, T5 = 'a' * 64, 'b' * 64, 'c' * 64, 'd' * 64, 'e' * 64


class AccountMenu(unittest.TestCase):
    """The saved accounts of a server: menu, accounts.json, login and new accounts."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name) / 'roe-join/1.2.3.4'
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.out = self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.tmp.cleanup()

    def saved(self):
        return json.loads((self.folder / 'accounts.json').read_text())['accounts']

    def test_menu_steps(self):
        self.assertEqual(join.menu_step(0, 'up', 3), (2, False))   # wraps
        self.assertEqual(join.menu_step(2, 'down', 3), (0, False))
        self.assertEqual(join.menu_step(1, 'home', 3), (0, False))
        self.assertEqual(join.menu_step(0, 'end', 3), (2, False))
        self.assertEqual(join.menu_step(1, 'x', 3), (1, False))
        self.assertEqual(join.menu_step(1, 'enter', 3), (1, True))

    def test_keys_and_numbered_list(self):
        keys = iter(['down', 'down', 'down', 'up', 'enter'])
        drawn = io.StringIO()
        self.assertEqual(join.pick_with_keys(['Anna', 'Bob', join.NEW_ACCOUNT], lambda: next(keys), drawn.write), 2)
        self.assertIn('\033[7m> Create a new account', drawn.getvalue())
        self.assertIn('\033[3A', drawn.getvalue())   # drawn over itself
        self.assertTrue(drawn.getvalue().endswith('\033[?25h'))
        answers = Answers('x', '7', '2')
        self.assertEqual(join.pick_numbered(['Anna', 'Bob', join.NEW_ACCOUNT], answers), 1)
        self.assertEqual(len(answers.asked), 3)
        self.assertEqual(join.pick_numbered(['Anna', join.NEW_ACCOUNT], Answers('')), 0)   # Enter: the first
        self.assertFalse(join.can_read_keys())   # input is not a terminal here

    def test_menu_order_and_new_account_entry(self):
        path = join.save_accounts(self.folder, [{'name': 'Old', 'token': T1, 'last_used': 10},
                                                {'name': 'Recent', 'token': T2, 'last_used': 30},
                                                {'name': 'Middle', 'token': T3, 'last_used': 20}])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        accounts = join.load_accounts(self.folder)
        shown = []

        def choose(entries):
            shown.append(entries)
            return len(entries) - 1
        self.assertIsNone(join.choose_account(accounts, choose=choose))
        self.assertEqual(shown, [['Recent', 'Middle', 'Old', 'Create a new account']])
        self.assertEqual(join.choose_account(accounts, choose=lambda entries: 1)['token'], T3)
        # --name picks without the menu, case ignored; an unknown one is a new account.
        no_menu = lambda entries: self.fail('menu shown')   # noqa: E731
        self.assertEqual(join.choose_account(accounts, 'recent', choose=no_menu)['token'], T2)
        self.assertIsNone(join.choose_account(accounts, 'Dora', choose=no_menu))
        self.assertIsNone(join.choose_account([], choose=no_menu))   # first start: no menu

    def test_accounts_json_with_byte_order_mark(self):
        # join.cmd's file may start with a byte order mark; entries without a valid key and name are skipped.
        self.folder.mkdir(parents=True)
        rows = [{'name': 'Anna', 'token': T1, 'last_used': 1}, {'name': 'Bob', 'token': T2, 'last_used': 2},
                {'name': 'Bad', 'token': 'x', 'last_used': 3}, {'name': 'Dora', 'token': '', 'last_used': 0}, {'token': ''}]
        (self.folder / 'accounts.json').write_bytes(b'\xef\xbb\xbf' + json.dumps({'accounts': rows}).encode())
        self.assertEqual([(a['name'], a['token']) for a in join.load_accounts(self.folder)], [('Bob', T2), ('Anna', T1), ('Dora', '')])

    def test_refresh_names(self):
        accounts = [{'name': 'Anna', 'token': T1, 'last_used': 3}, {'name': 'Bob', 'token': T2, 'last_used': 2},
                    {'name': 'Carl', 'token': T3, 'last_used': 1}]
        service = FakeService({f'NAME {T1}': 'OK Glacier', f'NAME {T2}': 'DENIED', f'NAME {T3}': 'OK Summit'})
        self.assertTrue(join.refresh_names(accounts, service))
        self.assertEqual([a['name'] for a in accounts], ['Glacier', 'Bob', 'Summit'])
        limit = FakeService({f'NAME {T1}': 'LIMIT'})   # the limit: one request, nothing changed
        self.assertFalse(join.refresh_names(accounts, limit))
        self.assertEqual(limit.sent, [f'NAME {T1}'])

    def test_login_answers_the_name(self):
        accounts = [{'name': 'Anna', 'token': T1, 'last_used': 5}, {'name': 'Bob', 'token': T2, 'last_used': 3}]
        service = FakeService({f'LOGIN2 {T2}': 'OK 123456789012 Bobby One'})
        self.assertEqual(join.login(service, self.fail, self.folder, accounts, accounts[1]), ('123456789012', 'Bobby One'))
        self.assertEqual(self.saved()[0]['name'], 'Bobby One')   # renamed, and on top
        anna = next(a for a in accounts if a['name'] == 'Anna')
        # A released name is claimed again with a new key.
        service = FakeService({f'LOGIN2 {T1}': 'DENIED', 'CLAIM Anna': f'OK {T3}', f'LOGIN2 {T3}': 'OK 78 Anna'})
        self.assertEqual(join.login(service, self.fail, self.folder, accounts, anna), ('78', 'Anna'))
        self.assertIn(T3, [a['token'] for a in self.saved()])
        with self.assertRaisesRegex(join.Failure, 'banned'):
            join.login(FakeService({f'LOGIN2 {T3}': 'BANNED'}), self.fail, self.folder, accounts, anna)
        with self.assertRaisesRegex(join.Failure, 'Too many'):
            join.login(FakeService({f'LOGIN2 {T3}': 'LIMIT'}), self.fail, self.folder, accounts, anna)

    def test_new_account(self):
        # First-login on: the server names it, the game asks for the real name.
        accounts = []
        service = FakeService({'NEW': f'OK {T1} newaccount1234', f'LOGIN2 {T1}': 'OK 90 newaccount1234'})
        self.assertEqual(join.login(service, self.fail, self.folder, accounts, None, name_question=Answers()), ('90', 'newaccount1234'))
        self.assertEqual(self.saved()[0]['token'], T1)
        self.assertIn('you choose its name in the game', self.out.getvalue())
        # First-login off: a name is asked for, again when it is taken.
        answers = Answers('Anna', 'Anja')
        service = FakeService({'NEW': 'NAME-REQUIRED', 'CLAIM Anna': 'TAKEN', 'CLAIM Anja': f'OK {T2}', f'LOGIN2 {T2}': 'OK 91 Anja'})
        self.assertEqual(join.login(service, self.fail, self.folder, accounts, None, name_question=answers), ('91', 'Anja'))
        self.assertEqual(len(answers.asked), 2)
        # --name for a new account claims it directly.
        service = FakeService({'CLAIM Carl': f'OK {T4}', f'LOGIN2 {T4}': 'OK 93 Carl'})
        self.assertEqual(join.login(service, self.fail, self.folder, accounts, None, 'Carl', name_question=Answers()), ('93', 'Carl'))
        self.assertEqual(service.sent[0], 'CLAIM Carl')
        self.assertEqual(sorted(a['name'] for a in self.saved()), ['Anja', 'Carl', 'newaccount1234'])
        with self.assertRaisesRegex(join.Failure, 'banned'):
            join.login(FakeService({'NEW': 'BANNED'}), self.fail, self.folder, accounts, None, name_question=Answers())
        # No account service: the name for the next client from this address.
        plain = []
        self.assertEqual(join.login(FakeService({'NEW': None}), plain.append, self.folder, accounts, None,
                                    name_question=Answers('Dora')), ('1', 'Dora'))
        self.assertEqual(plain, ['Dora'])
        # The plain name is saved without a key and offered next time; picking it registers it again.
        saved = join.load_accounts(self.folder)
        dora = [a for a in saved if a['name'] == 'Dora']
        self.assertEqual([a['token'] for a in dora], [''])
        self.assertEqual(join.login(FakeService({'CLAIM Dora': None}), plain.append, self.folder, saved, dora[0],
                                    name_question=Answers()), ('1', 'Dora'))
        self.assertEqual(len([a for a in self.saved() if a['name'] == 'Dora']), 1)
        # Once the server has accounts, the saved name is claimed and gets its key.
        saved = join.load_accounts(self.folder)
        dora = [a for a in saved if a['name'] == 'Dora'][0]
        service = FakeService({'CLAIM Dora': f'OK {T5}', f'LOGIN2 {T5}': 'OK 94 Dora'})
        self.assertEqual(join.login(service, plain.append, self.folder, saved, dora, name_question=Answers()), ('94', 'Dora'))
        self.assertEqual([a['token'] for a in self.saved() if a['name'] == 'Dora'], [T5])

    def test_dry_run_menu(self):
        # Redirected input: the numbered list.
        home = Path(self.tmp.name) / 'home'
        join.save_accounts(home / '.config/roe-join/127.0.0.1', [{'name': 'Anna', 'token': T1, 'last_used': 2},
                                                                 {'name': 'Bob', 'token': T2, 'last_used': 1}])
        game = Path(self.tmp.name) / 'game'
        touch(game / 'Europa_Client.exe', 'not the game')
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), ROE_JOIN_DRY_RUN='1', PROTON=str(home / 'none'))
        result = subprocess.run([sys.executable, '-I', str(JOIN), '--game', str(game), '--server', '127.0.0.1', '--voice', 'off'],
                                env=env, input='2\n', capture_output=True, text=True, timeout=30)
        self.assertIn('  1. Anna\n  2. Bob\n  3. Create a new account', result.stdout, result.stdout + result.stderr)
        self.assertIn('Would log in to 127.0.0.1:8002 as Bob', result.stdout)


class ServerMenu(unittest.TestCase):
    """The saved servers: menu order, another address, --server and the first start."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'roe-join'
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.out = self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.tmp.cleanup()

    def test_menu_order_and_another_address(self):
        settings = {'servers': [{'address': 'b.example', 'last_used': 20}, {'address': 'a.example', 'last_used': 30},
                                {'address': 'c.example', 'last_used': 25}, {'bad': 1}, {'address': 'A.example', 'last_used': 99}]}
        servers = join.saved_servers(settings)
        self.assertEqual([s['address'] for s in servers], ['a.example', 'c.example', 'b.example'])   # by last use, each once
        shown = []

        def choose(entries):
            shown.append(entries)
            return len(entries) - 1
        answers = Answers('d.example')
        self.assertEqual(join.choose_server(servers, choose=choose, question=answers), 'd.example')
        self.assertEqual(shown, [['a.example', 'c.example', 'b.example', 'Enter another server (IP or domain)']])
        self.assertEqual(answers.asked, [('Server address (IP or domain)', '')])
        self.assertEqual(join.choose_server(servers, choose=lambda entries: 1, question=Answers()), 'c.example')
        servers = join.remember_server(servers, 'C.example', now=99)
        self.assertEqual([(s['address'], s['last_used']) for s in servers],
                         [('C.example', 99), ('a.example', 30), ('b.example', 20)])
        # Folders without an entry in the list are no saved servers.
        join.save_accounts(self.root / 'old.example', [{'name': 'A', 'token': T1, 'last_used': 50}])
        self.assertEqual(join.saved_servers({}), [])

    def test_server_option_and_first_start(self):
        servers = [{'address': 'a.example', 'last_used': 1}]
        no_menu = lambda entries: self.fail('menu shown')   # noqa: E731
        self.assertEqual(join.choose_server(servers, '5.6.7.8', choose=no_menu, question=Answers()), '5.6.7.8')
        self.assertEqual(join.saved_servers({}), [])
        answers = Answers('1.2.3.4')
        self.assertEqual(join.choose_server([], choose=no_menu, question=answers), '1.2.3.4')
        self.assertEqual(len(answers.asked), 1)

    def test_server_addresses(self):
        # ADDRESSES: canonical, each once, loopback and words that are not addresses skipped.
        self.assertEqual(join.server_addresses('OK 203.0.113.5 2001:DB8:0::1 ttl=60 127.0.0.1 ::1 ::ffff:198.51.100.7 1.2.3 203.0.113.5 :: 224.0.0.1'),
                         ['203.0.113.5', '2001:db8::1', '198.51.100.7'])
        self.assertEqual(join.server_addresses('OK'), [])
        self.assertEqual(len(join.server_addresses('OK ' + ' '.join(f'10.0.{i // 250}.{i % 250 + 1}' for i in range(100)))), 64)
        # No OK (a limit, no answer): None, the saved list stays.
        for reply in ('INVALID', 'LIMIT', None, '', 'OKAY 1.2.3.4'):
            self.assertIsNone(join.server_addresses(reply), reply)

    def test_script_version(self):
        # VERSION: no OK means no check, below min stops, below current one line.
        github = 'url=https%3A%2F%2Fgithub.com%2Fmschnati%2Froe-os-client'
        for reply in ('INVALID', 'LIMIT', None, ''):
            self.assertIsNone(join.version_notice(reply, '0.9'), reply)
        self.assertIsNone(join.version_notice(f'OK min=0 current=0.9 {github}', '0.9'))
        self.assertIsNone(join.version_notice(f'OK min=0.9 current=0.9.0 {github} later=x', '0.9'))
        self.assertIsNone(join.version_notice(f'OK min=bad current=x {github}', '0.9'))
        self.assertEqual(join.version_notice(f'OK min=0.9 current=0.10 {github}', '0.9'),
                         'A newer join.py (version 0.10) is at https://github.com/mschnati/roe-os-client; this one (version 0.9) still works.')
        with self.assertRaises(join.Failure) as stop:
            join.version_notice('OK min=1.0 current=1.0 url=https%3A%2F%2Fexample.org%2Froe', '0.9')
        self.assertEqual(str(stop.exception), 'This join.py is version 0.9; the server needs version 1.0 or newer. '
                                              'Download the new join.py from https://example.org/roe and start it again.')
        with self.assertRaises(join.Failure) as stop:
            join.version_notice('OK min=1 current=1 url=javascript%3Ax%0A', '0.9')
        self.assertIn('from https://github.com/mschnati/roe-os-client and', str(stop.exception))

    def test_domain_entry(self):
        # A domain: offered by the prompt, saved and shown as typed, one folder whatever the case.
        self.assertIn('IP or domain', join.SERVER_QUESTION)
        answers = Answers('Play.Example.org')
        server = join.choose_server([], question=answers)
        self.assertEqual(server, 'Play.Example.org')
        servers = join.remember_server([{'address': 'play.example.org', 'last_used': 1, 'name': 'Europa'}], server, now=5)
        self.assertEqual(servers, [{'address': 'Play.Example.org', 'last_used': 5, 'name': 'Europa'}])
        back = join.saved_servers({'servers': servers})
        self.assertEqual([join.server_label(s) for s in back], ['Europa (Play.Example.org)'])
        self.assertEqual(join.server_folder_name(server), 'play.example.org')

    def test_versions_agree(self):
        # join.cmd and join.py carry the same version and URL.
        root = JOIN.parent
        cmd = (root / 'join.cmd').read_text()
        self.assertEqual(re.search(r"^\$joinVersion = '([0-9.]+)'", cmd, re.M).group(1), join.JOIN_VERSION)
        self.assertIn(f"$joinUrl = '{join.JOIN_URL}'", cmd)
        # The server's too, when this folder is inside the server's repository (client/).
        header = root.parent / 'src/lobby/accounts.hpp'
        if not header.is_file():
            self.skipTest('not inside the server repository')
        header = header.read_text()
        self.assertEqual(join.JOIN_VERSION, re.search(r'kJoinScriptVersion = "([0-9.]+)";', header).group(1))
        self.assertEqual(join.JOIN_URL, re.search(r'kDefaultJoinUrl = "([^"]+)"', header).group(1))

    def test_region_stats(self):
        # STATS: a part per region; broken words skipped; an older server or LIMIT shows nothing.
        reply = 'OK 7,normal,12,3,2,EU%20SERVER 6,duel,2,0,1,AS%20SERVER,later 5,normal,x,0,0,NA%20SERVER 9,odd'
        self.assertEqual(join.format_stats(reply), 'EU (normal): 12 online, 3 searching, 2 matches | AS (duel): 2 online, 0 searching, 1 match')
        self.assertEqual(join.format_stats('OK 5,normal,0,0,0,%0A'), 'zone 5 (normal): 0 online, 0 searching, 0 matches')
        for old in ('OK', 'INVALID', 'LIMIT', '', None):
            self.assertEqual(join.format_stats(old), '')
        # The line after the login and while the game runs: every region (the live server's reply),
        # INFO only from a server without STATS, INFO's restart notice either way.
        live = 'OK 7,normal,0,0,0,EU%20SERVER 6,duel,0,0,0,AS%20SERVER'
        self.assertEqual(join.server_now('OK players=0 matches=0 waiting=0 restarting=0 name=ROE-OS', live),
                         'On the server now: EU (normal): 0 online, 0 searching, 0 matches | AS (duel): 0 online, 0 searching, 0 matches.')
        self.assertTrue(join.server_now('OK players=1 restarting=1', live).endswith(
            '0 matches. It restarts for an update soon; new searches are refused until then.'))
        for old in ('INVALID', None):
            self.assertTrue(join.server_now('OK players=2 matches=1 waiting=0 restarting=0', old).startswith(
                'On the server now: 2 players online, 1 match running'))

    def test_server_names(self):
        # The INFO field: decoded, cleaned; an empty or missing one is ''.
        self.assertEqual(join.info_server_name('OK players=1 matches=0 waiting=0 restarting=0 name=Europa%20EU%20%C3%A9'), 'Europa EU \u00e9')
        self.assertEqual(join.info_server_name('OK players=1 matches=0 waiting=0 restarting=0 name='), '')
        self.assertEqual(join.info_server_name('OK players=1 matches=0 waiting=0 restarting=0'), '')
        self.assertEqual(join.info_server_name('OK players=0 name=a%0Ab%1B' + '%41' * 50), 'ab' + 'A' * 38)
        # The counts read as before; a name cannot pass for one.
        self.assertTrue(join.server_info('OK players=2 matches=1 waiting=0 restarting=0 name=players%3D9').startswith(
            'On the server now: 2 players online, 1 match running'))
        # Saved with the server, shown in the menu, updated and removed.
        settings = {'servers': [{'address': 'a.example', 'last_used': 30, 'name': 'Europa'},
                                                       {'address': 'b.example', 'last_used': 20},
                                                       {'address': 'c.example', 'last_used': 10, 'name': 'bad\x07'}]}
        servers = join.saved_servers(settings)
        shown = []
        join.choose_server(servers, choose=lambda entries: shown.append(entries) or 0, question=Answers())
        self.assertEqual(shown, [['Europa (a.example)', 'b.example', 'bad (c.example)', 'Enter another server (IP or domain)']])
        servers = join.remember_server(servers, 'A.example', now=99)
        self.assertEqual(servers[0], {'address': 'A.example', 'last_used': 99, 'name': 'Europa'})
        self.assertFalse(join.name_server(servers, 'A.example', 'Europa'))
        self.assertTrue(join.name_server(servers, 'A.example', 'Europa EU'))
        self.assertEqual(join.server_label(servers[0]), 'Europa EU (A.example)')
        self.assertTrue(join.name_server(servers, 'b.example', 'Dione'))
        self.assertTrue(join.name_server(servers, 'A.example', ''))
        self.assertEqual([join.server_label(s) for s in servers], ['A.example', 'Dione (b.example)', 'bad (c.example)'])
        # Through the settings file and back.
        again = join.saved_servers({'servers': json.loads(json.dumps(servers))})
        self.assertEqual([join.server_label(s) for s in again], ['A.example', 'Dione (b.example)', 'bad (c.example)'])

    def test_dry_run_server_menu(self):
        home = Path(self.tmp.name) / 'home'
        config = home / '.config'
        config.mkdir(parents=True)
        (config / 'roe-join.json').write_text(json.dumps({'servers': [
            {'address': '127.0.0.1', 'last_used': 20}, {'address': '127.0.0.2', 'last_used': 10}]}))
        game = Path(self.tmp.name) / 'game'
        touch(game / 'Europa_Client.exe', 'not the game')
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), ROE_JOIN_DRY_RUN='1', PROTON=str(home / 'none'))
        command = [sys.executable, '-I', str(JOIN), '--game', str(game), '--voice', 'off']
        result = subprocess.run(command, env=env, input='3\n127.0.0.9\n', capture_output=True, text=True, timeout=30)
        self.assertIn('Server:\n  1. 127.0.0.1\n  2. 127.0.0.2\n  3. Enter another server (IP or domain)', result.stdout,
                      result.stdout + result.stderr)
        self.assertIn('Would log in to 127.0.0.9:8002', result.stdout)
        result = subprocess.run(command + ['--server', '127.0.0.3'], env=env, input='', capture_output=True, text=True, timeout=30)
        self.assertNotIn('Server:', result.stdout)
        self.assertIn('Would log in to 127.0.0.3:8002', result.stdout, result.stdout + result.stderr)


def run_powershell(test, harness, prepare, checks):
    """Runs a join.cmd harness through powershell.exe in a Windows temp folder; asserts its OK lines."""
    # On a Windows drive: File.Replace (Copy-Checked) does not work on the WSL share.
    temp = subprocess.run(['cmd.exe', '/c', 'echo %TEMP%'], cwd='/mnt/c', capture_output=True, text=True).stdout.strip()
    temp = subprocess.run(['wslpath', '-u', temp], capture_output=True, text=True).stdout.strip()
    if not temp or not Path(temp).is_dir():
        test.skipTest('no Windows temp folder')
    with tempfile.TemporaryDirectory(dir=temp) as tmp:
        base = Path(tmp)
        prepare(base)
        source = base / 'join.ps1'
        shutil.copyfile(JOIN.parent / 'join.cmd', source)

        def win(path):
            return subprocess.run(['wslpath', '-w', str(path)], capture_output=True, text=True, check=True).stdout.strip()
        script = Path(__file__).resolve().parent / harness
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', win(script),
                                 '-Source', win(source), '-Base', win(base)],
                                cwd='/mnt/c', stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=50)
        lines = [line.strip() for line in result.stdout.splitlines()]
        report = result.stdout + result.stderr
        test.assertEqual(result.returncode, 0, report)
        test.assertFalse([line for line in lines if line.startswith('FAIL')], report)
        test.assertEqual(len([line for line in lines if line.startswith('OK ')]), checks, report)


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinCmdAccounts(unittest.TestCase):
    """join.cmd's account menu, accounts.json and login against a fake service (through powershell.exe)."""
    def test_functions(self):
        run_powershell(self, 'join_cmd_accounts.ps1', lambda base: None, 30)


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinCmdServers(unittest.TestCase):
    """join.cmd's server menu, the servers list and -Server (through powershell.exe)."""
    def test_functions(self):
        run_powershell(self, 'join_cmd_servers.ps1', lambda base: None, 47)


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinCmdFirewall(unittest.TestCase):
    """join.cmd's ADDRESSES parsing, blocked ranges, trusted servers and rule updates (through powershell.exe)."""
    def test_functions(self):
        run_powershell(self, 'join_cmd_firewall.ps1', lambda base: None, 49)


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinCmdExport(unittest.TestCase):
    """join.cmd's account backup: export, import, merge and a different certificate (through powershell.exe)."""
    def test_functions(self):
        def prepare(base):
            # A backup written by join.py, for join.cmd's import.
            root = base / 'py'
            join.save_accounts(root / 'linux.example', [{'name': 'Penny', 'token': 'f' * 64, 'last_used': 7}])
            (root / 'linux.example/server.pin').write_text('4' * 64 + '\n', encoding='ascii')
            join.export_accounts(root, {'servers': [{'address': 'linux.example', 'last_used': 7, 'name': 'Linux EU'}]}, base / 'py-backup.json')
        run_powershell(self, 'join_cmd_export.ps1', prepare, 13)


class AccountBackup(unittest.TestCase):
    """join.py's --export / --import: the same file as join.cmd's, merged, a different certificate asked."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_export_import_merge(self):
        root = self.base / 'one'
        join.save_accounts(root / 'play.example.org', [{'name': 'Anna', 'token': 'a' * 64, 'last_used': 50},
                                                       {'name': 'Ben', 'token': 'b' * 64, 'last_used': 40}])
        (root / 'play.example.org/server.pin').write_text('1' * 64 + '\n', encoding='ascii')
        join.save_accounts(root / '203.0.113.5', [{'name': 'Cleo', 'token': 'c' * 64, 'last_used': 30}])
        (root / '203.0.113.5/server.pin').write_text('2' * 64 + '\n', encoding='ascii')
        settings = {'servers': [{'address': 'Play.Example.org', 'last_used': 50, 'name': 'Europa'},
                                {'address': '203.0.113.5', 'last_used': 30}]}
        backup = self.base / 'backup.json'
        self.assertEqual(join.export_accounts(root, settings, backup), (2, 3))
        data = json.loads(backup.read_text())
        self.assertEqual((data['format'], data['version'], data['servers'][0]['address'], data['servers'][0]['name']),
                         ('roe-join-accounts', 1, 'Play.Example.org', 'Europa'))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertIn('account keys', join.BACKUP_WARNING)

        other = self.base / 'two'
        join.save_accounts(other / 'play.example.org', [{'name': 'Anna', 'token': 'a' * 64, 'last_used': 10},
                                                         {'name': 'Dora', 'token': 'd' * 64, 'last_used': 99},
                                                         {'name': 'Ben', 'token': 'e' * 64, 'last_used': 90}])
        (other / 'play.example.org/server.pin').write_text('1' * 64 + '\n', encoding='ascii')
        (other / '203.0.113.5').mkdir()
        (other / '203.0.113.5/server.pin').write_text('3' * 64 + '\n', encoding='ascii')
        mine = {'servers': [{'address': 'play.example.org', 'last_used': 99}]}
        answers = Answers('n')
        with contextlib.redirect_stdout(io.StringIO()):
            done = join.import_accounts(other, mine, backup, answers)
        merged = {a['name']: a for a in join.load_accounts(other / 'play.example.org')}
        self.assertEqual((merged['Anna']['last_used'], merged['Ben']['token'], len(merged)), (50, 'e' * 64, 3))
        self.assertEqual((done['added'], done['updated'], done['skipped']), (0, 1, ['203.0.113.5']))
        self.assertEqual(answers.asked[0][1], 'n')
        self.assertEqual(join.read_pin(other / '203.0.113.5'), '3' * 64)
        self.assertFalse((other / '203.0.113.5/accounts.json').exists())
        with contextlib.redirect_stdout(io.StringIO()):
            done = join.import_accounts(other, mine, backup, Answers('y'))
        self.assertEqual((done['added'], join.read_pin(other / '203.0.113.5')), (1, '2' * 64))
        self.assertEqual([(s['address'], s.get('name')) for s in done['servers']], [('play.example.org', 'Europa'), ('203.0.113.5', None)])
        done = join.import_accounts(other, mine, backup, Answers())  # nothing new, nothing asked
        self.assertEqual((done['added'], done['updated']), (0, 0))

    def test_join_cmd_file_and_refusals(self):
        # A file as join.cmd writes it (BOM-less UTF-8, its own layout) and unsafe or foreign files.
        backup = self.base / 'cmd.json'
        backup.write_text(json.dumps({'format': 'roe-join-accounts', 'version': 1, 'servers': [
            {'address': 'Play.Example.org', 'name': 'Europa', 'pin': '1' * 64, 'accounts': [{'name': 'Anna', 'token': 'a' * 64, 'last_used': 5}]},
            {'address': '../../x', 'name': '', 'pin': '', 'accounts': [{'name': 'X', 'token': 'b' * 64, 'last_used': 1}]}]}), encoding='utf-8')
        fresh = self.base / 'fresh'
        done = join.import_accounts(fresh, {}, backup)
        self.assertEqual(done['added'], 1)
        self.assertEqual(done['servers'], [{'address': 'Play.Example.org', 'last_used': 5, 'name': 'Europa'}])
        self.assertFalse((self.base / 'x').exists())
        backup.write_text('{"accounts": []}', encoding='utf-8')
        with self.assertRaises(join.Failure):
            join.import_accounts(fresh, {}, backup)

    def test_options(self):
        self.assertEqual(join.parse_arguments(['--export']).export, '')
        self.assertEqual(join.parse_arguments(['--export', 'x.json']).export, 'x.json')
        self.assertEqual(join.parse_arguments(['--import', 'x.json']).import_, 'x.json')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            join.parse_arguments(['--export', 'a', '--import', 'b'])


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinCmdVoice(unittest.TestCase):
    """join.cmd parses, and its voice DLL functions work on fake folders (through powershell.exe)."""
    def test_functions(self):
        def prepare(base):
            ours = fake_dll(b'GetVoiceEngine our voice dll')
            original = fake_dll(b'GetVoiceEngine original voice dll')
            touch(base / 'game/Europa_Client.exe', 'not the game')
            (base / 'game/GCloudVoice.dll').write_bytes(original)
            for folder, data in (('package/voice', ours), ('copy', original), ('nohash', fake_dll(b'GetVoiceEngine 2')),
                                 ('x86', fake_dll(b'GetVoiceEngine', machine=0x14c)), ('noexport', fake_dll(b'nothing'))):
                (base / folder).mkdir(parents=True)
                (base / folder / 'GCloudVoice.dll').write_bytes(data)
        run_powershell(self, 'join_cmd_voice.ps1', prepare, 32)


@unittest.skipUnless(shutil.which('powershell.exe') and shutil.which('wslpath'), 'needs powershell.exe (WSL)')
class JoinGui(unittest.TestCase):
    """join-gui.cmd loads join.cmd, its windows parse, its worker and its server and play steps (no window shown)."""
    def test_functions(self):
        def prepare(base):
            shutil.copyfile(JOIN.parent / 'join-gui.cmd', base / 'join-gui.cmd')
            (base / 'game').mkdir()
        run_powershell(self, 'join_gui.ps1', prepare, 22)


if __name__ == '__main__':
    unittest.main()
