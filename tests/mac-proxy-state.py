"""Exercise the real SystemConfiguration bridge against a private plist only."""
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'lib/proxy-state.js'
BYPASS = ['localhost', '127.0.0.1', '*.local', '169.254/16', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']


class ProxyReceipt(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='enana proxy receipt ')
        self.root = pathlib.Path(self.temp.name)
        self.prefs = self.root / 'preferences.plist'
        self.receipt = self.root / 'receipt.json'
        self.script = self.root / 'bridge.js'
        self.script.write_text(SOURCE.read_text().replace('var preferencesID = $.nil;', f'var preferencesID = $({json.dumps(str(self.prefs))});'))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, proxies):
        self.document = {'NetworkServices': {'wifi': {'UserDefinedName': 'Wi-Fi', 'Proxies': proxies, 'DNS': {'ServerAddresses': ['192.0.2.1']}}}, 'Other': 'preserve'}
        self.prefs.write_bytes(plistlib.dumps(self.document))
        # Guard against accidentally exercising the system preferences rather
        # than the private file, especially when this test runs as root in CI.
        self.assertEqual(list(json.loads(self.run_bridge('snapshot'))['services']), ['wifi'])

    def run_bridge(self, action):
        return subprocess.check_output(['/usr/bin/osascript', '-l', 'JavaScript', str(self.script), action, '17890', str(self.receipt)], text=True).strip()

    def bridge(self, action, *receipt):
        # Like run_bridge, but the receipt argument is optional (root passes none when enana has no receipt) and failures are returned.
        return subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', str(self.script), action, '17890', *receipt], capture_output=True, text=True)

    def assert_rejected(self, receipt_bytes):
        # A receipt restore must not trust: check and restore both refuse it before touching the preferences.
        self.receipt.write_bytes(receipt_bytes)
        before = self.prefs.read_bytes()
        for action in ('check', 'restore'):
            result = self.bridge(action, str(self.receipt))
            self.assertNotEqual(result.returncode, 0, (action, result.stdout))
            self.assertIn('Invalid proxy receipt', result.stderr, action)
        self.assertEqual(self.prefs.read_bytes(), before)

    def installed(self):
        return {'HTTPProxy': '127.0.0.1', 'HTTPPort': 17890, 'HTTPEnable': 1,
                'HTTPSProxy': '127.0.0.1', 'HTTPSPort': 17890, 'HTTPSEnable': 0,
                'SOCKSProxy': '127.0.0.1', 'SOCKSPort': 17890, 'SOCKSEnable': 1,
                'ExceptionsList': BYPASS, 'ProxyAutoConfigURLString': 'https://example.test/proxy.pac'}

    def restored(self):
        doc = plistlib.loads(self.prefs.read_bytes())
        self.assertEqual(doc['Other'], 'preserve')
        self.assertEqual(doc['NetworkServices']['wifi']['DNS'], self.document['NetworkServices']['wifi']['DNS'])
        return doc['NetworkServices']['wifi']['Proxies']

    def test_restores_original_proxy_and_bypass_and_leaves_dns(self):
        original = {'HTTPProxy': 'proxy.example.test', 'HTTPPort': 8123, 'HTTPEnable': 1, 'HTTPProxyAuthenticated': 1, 'ExceptionsList': ['*.company.test'], 'FTPPassive': 1}
        self.write(original)
        self.receipt.write_text(self.run_bridge('snapshot'))
        current = self.installed() | {'FTPPassive': 1}
        self.write(current)
        self.assertEqual(self.run_bridge('check'), 'changed')
        self.run_bridge('restore')
        expected = original | {'ProxyAutoConfigURLString': current['ProxyAutoConfigURLString']}
        self.assertEqual(self.restored(), expected)
        self.assertEqual(self.run_bridge('check'), 'clean')
        self.run_bridge('restore')
        self.assertEqual(self.restored(), expected)

    def test_foreign_endpoint_edits_are_preserved(self):
        current = self.installed()
        current.update(HTTPProxy='other.example.test', HTTPPort=8888)
        self.write(current)
        self.run_bridge('restore')
        expected = {'HTTPProxy': 'other.example.test', 'HTTPPort': 8888, 'HTTPEnable': 1, 'ProxyAutoConfigURLString': current['ProxyAutoConfigURLString']}
        self.assertEqual(self.restored(), expected)

    def test_missing_legacy_receipt_clears_disabled_owned_fields(self):
        self.write(self.installed())
        self.run_bridge('restore')
        self.assertEqual(self.restored(), {'ProxyAutoConfigURLString': 'https://example.test/proxy.pac'})

    def test_legacy_receipt_pointing_to_self_is_not_restored(self):
        self.write(self.installed())
        self.receipt.write_text(self.run_bridge('snapshot'))
        self.run_bridge('restore')
        self.assertEqual(self.restored(), {'ProxyAutoConfigURLString': 'https://example.test/proxy.pac'})

    def test_foreign_bypass_list_is_not_overwritten(self):
        current = self.installed() | {'ExceptionsList': ['*.new.test']}
        self.write(current)
        self.run_bridge('restore')
        self.assertEqual(self.restored()['ExceptionsList'], ['*.new.test'])

    def test_malformed_receipt_fails_before_mutation(self):
        self.write(self.installed())
        before = self.prefs.read_bytes()
        self.receipt.write_text('{broken')
        result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', str(self.script), 'restore', '17890', str(self.receipt)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.prefs.read_bytes(), before)

    def test_restore_without_receipt_argument_clears_owned_fields(self):
        # What root runs when enana has no receipt: no third argument at all.
        self.write(self.installed())
        self.assertEqual(self.bridge('check').stdout.strip(), 'changed')
        result = self.bridge('restore')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restored(), {'ProxyAutoConfigURLString': 'https://example.test/proxy.pac'})

    def test_empty_receipt_is_rejected_before_mutation(self):
        self.write(self.installed())
        self.assert_rejected(b'')

    def test_invalid_receipt_shapes_are_rejected_before_mutation(self):
        self.write(self.installed())
        good = {'HTTPProxy': 'proxy.example.test', 'HTTPPort': 8080, 'HTTPEnable': 1, 'ExceptionsList': ['*.example.test']}
        self.receipt.write_text(json.dumps({'schema': 1, 'services': {'wifi': good}}))
        self.assertEqual(self.run_bridge('check'), 'changed')       # the base receipt is accepted: each rejection below is the one bad field
        for bad in ({'HTTPProxy': {'nested': 'object'}}, {'HTTPProxy': ['a', 'list']}, {'HTTPPort': 70000}, {'HTTPPort': '70000'}, {'HTTPPort': '80a'}, {'SOCKSPort': -1},
                    {'HTTPEnable': 2}, {'HTTPSProxyAuthenticated': 'yes'}, {'SOCKSProxy': 'x' * 256}, {'HTTPUser': 'line\nbreak'},
                    {'ExceptionsList': [1]}, {'ExceptionsList': '*.example.test'}, {'ExceptionsList': ['*.example.test'] * 1025}):
            with self.subTest(bad=bad):
                self.assert_rejected(json.dumps({'schema': 1, 'services': {'wifi': good | bad}}).encode())
        for document in ([], {'schema': 1, 'services': []}, {'schema': 1, 'services': {'wifi': []}}, {'schema': 1, 'services': {'wifi': None}}):
            with self.subTest(document=document):
                self.assert_rejected(json.dumps(document).encode())

    def test_digit_strings_from_other_tools_are_restored_as_they_were(self):
        # Some tools store a port or a flag as a digit string. Refusing such a receipt would stop uninstall, so it is accepted and written back unchanged.
        self.write(self.installed())
        original = {'HTTPProxy': 'proxy.example.test', 'HTTPPort': '8080', 'HTTPEnable': '1'}
        self.receipt.write_text(json.dumps({'schema': 1, 'services': {'wifi': original}}))
        self.assertEqual(self.run_bridge('check'), 'changed')
        self.run_bridge('restore')
        got = self.restored()
        self.assertEqual({key: got.get(key) for key in original}, original)

    def test_snapshot_restore_round_trip_with_realistic_values(self):
        # Everything enana's own snapshot captures must still be accepted by the validator.
        original = {'HTTPEnable': 1, 'HTTPProxy': 'proxy.corp.example.test', 'HTTPPort': 3128, 'HTTPProxyAuthenticated': 1, 'HTTPUser': 'proxy.user',
                    'HTTPSEnable': True, 'HTTPSProxy': 'proxy.corp.example.test', 'HTTPSPort': 3129, 'HTTPSProxyAuthenticated': 0,
                    'SOCKSEnable': 0, 'SOCKSProxy': '', 'SOCKSPort': 0,
                    'ExceptionsList': ['*.local', '169.254/16', 'intranet.example.test', '10.0.0.0/8'],
                    'ExcludeSimpleHostnames': 1, 'FTPPassive': 1, 'ProxyAutoConfigEnable': 0, 'ProxyAutoDiscoveryEnable': 0,
                    'ProxyAutoConfigURLString': 'https://example.test/proxy.pac'}
        self.write(original)
        self.receipt.write_text(self.run_bridge('snapshot'))
        kept = {key: value for key, value in original.items() if not key.startswith(('HTTP', 'SOCKS')) and key != 'ExceptionsList'}
        self.write(self.installed() | kept)
        self.assertEqual(self.run_bridge('check'), 'changed')
        self.run_bridge('restore')
        self.assertEqual(self.restored(), original)
        self.assertEqual(self.run_bridge('check'), 'clean')


if __name__ == '__main__':
    unittest.main()
