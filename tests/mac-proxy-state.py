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


if __name__ == '__main__':
    unittest.main()
