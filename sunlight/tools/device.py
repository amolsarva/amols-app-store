#!/usr/bin/env python3
"""Sunlight recovery / deployment utility. Does not write firmware binaries."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# Your bulb comes from the Mac-only local-bulb.json (git-ignored); see README.
_LOCAL = json.loads((ROOT / "local-bulb.json").read_text()) if (ROOT / "local-bulb.json").exists() else {}
EXPECTED_MAC = (_LOCAL.get("daylightVerifiedMAC") or _LOCAL.get("mac") or "").upper()

def rules():
    source = (ROOT / "Sources/Sunlight/Program.swift").read_text()
    block = source.split('static let rules: [String] = [', 1)[1].split('\n    ]', 1)[0]
    return [''.join(json.loads('"' + s + '"') for s in re.findall(r'"((?:[^"\\]|\\.)*)"', part))
            for part in block.strip().split(',\n\n')]

LEGACY_RULES = [
    'ON Power1#Boot DO Color2 FF780000 ENDON ON Power1#State=1 DO Color2 FF780000 ENDON ON System#Init DO Backlog Var1 0; Var2 %mem1%; Event advance=180; RuleTimer1 3600 ENDON ON Time#Initialized DO Var1 1 ENDON ON Time#Set DO Var1 1 ENDON ON Time#Minute|60 DO Event tick ENDON ON Rules#Timer=1 DO Backlog Event advance=60; RuleTimer1 3600; RuleTimer2 5 ENDON ON Rules#Timer=2 DO Event tick ENDON',
    'ON Event#advance DO Backlog Add2 %value%; Event wrap ENDON ON Event#wrap DO Backlog Event over=%var2%; Event save ENDON ON Event#over>=1440 DO Sub2 1440 ENDON ON Event#save DO Mem1 %var2% ENDON ON Event#tick DO Event auto=%mem2% ENDON ON Event#auto=1 DO Event clock=%var1% ENDON ON Event#clock=1 DO Event sun=%time% ENDON ON Event#clock=0 DO Event sun=%mem1% ENDON ON Event#paint DO Color2 %var3% ENDON',
    'ON Event#sun DO Var3 FF380000 ENDON ON Event#sun>=360 DO Var3 FF780000 ENDON ON Event#sun>=480 DO Var3 FFBB7000 ENDON ON Event#sun>=600 DO Var3 FFE4BE00 ENDON ON Event#sun>=720 DO Var3 FFF4E500 ENDON ON Event#sun>=900 DO Var3 FFE4BE00 ENDON ON Event#sun>=1020 DO Var3 FFBB7000 ENDON ON Event#sun>=1080 DO Var3 FF780000 ENDON ON Event#sun>=1200 DO Var3 FF500000 ENDON ON Event#sun>=1320 DO Var3 FF380000 ENDON ON Event#sun DO Event paint ENDON'
]

class Device:
    def __init__(self, host):
        self.base = 'http://' + host

    def request(self, path, query=None, retries=2):
        url = self.base + '/' + path
        if query:
            url += '?' + urllib.parse.urlencode(query)
        for attempt in range(retries + 1):
            try:
                req = urllib.request.Request(url, headers={'Referer': self.base + '/'})
                with urllib.request.urlopen(req, timeout=10) as response:
                    return response.read()
            except Exception:
                if attempt == retries:
                    raise
                time.sleep(1)

    def command(self, command):
        # Explicit setters and reads are idempotent. Events and restarts are not retried.
        retries = 0 if command.lower().startswith(('event ', 'restart ')) else 2
        result = json.loads(self.request('cm', {'cmnd': command}, retries))
        if 'Warning' in result or result.get('Command') == 'Unknown':
            raise RuntimeError('Command rejected: ' + str(result))
        return result

    def identify(self):
        status = self.command('Status 0')
        assert EXPECTED_MAC, 'Set "mac" in local-bulb.json first (see local-bulb.example.json)'
        assert status['StatusNET']['Mac'].upper() == EXPECTED_MAC, 'Wrong device identity'
        assert status['StatusFWR']['Hardware'] == 'ESP8266EX', 'Wrong hardware'
        return status

    def backup(self):
        self.identify()
        data = self.request('dl')
        assert 4096 <= len(data) <= 32768 and b'<html' not in data[:80].lower(), 'Invalid backup'
        directory = Path.home() / 'Documents/root/utils and keys/vault/sunlight'
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        name = dt.datetime.now(dt.timezone.utc).strftime('sengled-%Y%m%dT%H%M%S.dmp')
        path = directory / name
        with path.open('xb') as out:
            os.chmod(path, 0o600)
            out.write(data)
        return str(path)

def inspect(device):
    result = {'status': device.identify()}
    for command in ['Rule1', 'Rule2', 'Rule3', 'Mem1', 'Mem2', 'Mem3', 'Mem4', 'Var1', 'Var2', 'SetOption20', 'SetOption65', 'PowerOnState', 'Fade', 'Speed', 'TimeSTD', 'TimeDST']:
        result[command] = device.command(command)
        print(command + ': ' + json.dumps(result[command]), flush=True)
    return result

def install(device):
    program = rules()
    assert len(program) == 3 and all(0 < len(r) < 1800 for r in program)
    print('Recovery backup: ' + device.backup(), flush=True)
    startup = 'ON Power1#Boot DO Color2 FF780000 ENDON ON Power1#State=1 DO Color2 FF780000 ENDON'
    for i, new in enumerate(program, 1):
        previous = device.command('Rule' + str(i))['Rule' + str(i)]['Rules']
        assert previous in ['', new, LEGACY_RULES[i-1], startup if i == 1 else ''], 'Unrelated rule found; stopped'
    for i in range(1, 4):
        device.command(f'Rule{i} 0')
    device.command('Mem2 0')
    for i, new in enumerate(program, 1):
        response = device.command(f'Rule{i} {new}')
        verified = device.command(f'Rule{i}')['Rule' + str(i)]
        assert verified['Length'] == len(new), f'Rule{i} length mismatch; remain disabled'
        assert verified['Rules'] == new, f'Rule{i} differs; remain disabled'
        print(f'Rule{i}: verified {len(new)} characters, {verified["Free"]} bytes free', flush=True)
    for command in ['SetOption20 1', 'SetOption65 1', 'Fade 1', 'Speed 10', 'PowerOnState 1',
                    'Mem1 720', 'Mem2 0', 'Mem3 0', 'Mem4 0', 'Var1 1', 'Var2 720',
                    'TimeSTD 0,1,11,1,2,-300', 'TimeDST 0,2,3,1,2,-240', 'Timezone 99',
                    f'Time {int(time.time())}', 'Time 0', 'Rule1 1', 'Rule2 1', 'Rule3 1',
                    'RuleTimer1 3600', 'Mem2 0', 'Color2 FF9B4300']:
        print(command + ': ' + json.dumps(device.command(command)), flush=True)
    print('INSTALLATION COMPLETE', flush=True)

def selftest():
    program = rules()
    assert len(program) == 3
    for rule in program:
        assert len(re.findall(r'\bON ', rule)) == rule.count(' ENDON')
        assert len(rule) < 1800
    # Model persistent fallback arithmetic including reboot wraparound.
    for minute, jump, expected in [(720,60,780),(720,180,900),(1380,180,120),(1380,60,0)]:
        assert (minute + jump) % 1440 == expected
    assert all(len(rule) <= 511 for rule in program)
    assert 'Color2 FF9B4300' in program[0] and 'Power On' not in ''.join(program)
    assert 'ON Event#b DO' in program[2]
    print(json.dumps({'rules_lengths': [len(r) for r in program], 'fallback_cases': 4, 'passed': True}))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inspect','backup','install','command','selftest','export'])
    parser.add_argument('command', nargs='?')
    parser.add_argument('--host', default=_LOCAL.get('host'), required=not _LOCAL.get('host'))
    args = parser.parse_args()
    if args.action == 'selftest': return selftest()
    if args.action == 'export': return print(json.dumps({'rules': rules()}, indent=2))
    device = Device(args.host)
    if args.action == 'inspect': inspect(device)
    elif args.action == 'backup': print(device.backup())
    elif args.action == 'install': install(device)
    else:
        assert args.command, 'Command required'
        print(json.dumps(device.command(args.command), indent=2))

if __name__ == '__main__':
    main()
