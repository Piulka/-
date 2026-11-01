import importlib.util
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('build_inspector', Path(__file__).resolve().parents[1] / 'BuildInspector.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IPAInspectionTests(unittest.TestCase):
    def archive(self, path, extra=None):
        info = {'CFBundleIdentifier': 'example.qa.client', 'CFBundleShortVersionString': '2.3', 'CFBundleVersion': '42', 'MinimumOSVersion': '15.0', 'CFBundleDisplayName': 'QA Sample'}
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Sample.app/Info.plist', plistlib.dumps(info))
            executable = zipfile.ZipInfo('Payload/Sample.app/Sample')
            executable.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(executable, b'signed-binary-bytes')
            archive.writestr('Payload/Sample.app/_CodeSignature/CodeResources', b'signature-bytes')
            archive.writestr('OtherFile.txt', b'not part of the app')
            if extra:
                archive.writestr(*extra)

    def test_metadata_and_extraction_preserve_signature_contents(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sample.ipa'
            self.archive(path)
            info = module.inspect(path)
            self.assertEqual((info['package'], info['version'], info['build']), ('example.qa.client', '2.3', '42'))
            app = Path(module.extract_ipa(path, Path(folder) / 'out'))
            self.assertEqual((app / 'Sample').read_bytes(), b'signed-binary-bytes')
            self.assertEqual((app / '_CodeSignature/CodeResources').read_bytes(), b'signature-bytes')
            self.assertTrue((app / 'Sample').stat().st_mode & stat.S_IXUSR)
            self.assertFalse((app.parent / 'OtherFile.txt').exists())

    def test_rejects_traversal_before_extracting(self):
        for name in ['Payload/Sample.app/../../escape', '/tmp/escape', 'Payload/Sample.app/a\\b']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'sample.ipa'
                self.archive(path, (name, b'x'))
                out = Path(folder) / 'out'
                with self.assertRaises(module.BuildError):
                    module.extract_ipa(path, out)
                self.assertEqual(list(out.iterdir()), [])

    def test_rejects_symbolic_link(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sample.ipa'
            symlink = zipfile.ZipInfo('Payload/Sample.app/link')
            symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
            self.archive(path, (symlink, b'/outside'))
            with self.assertRaises(module.BuildError):
                module.extract_ipa(path, Path(folder) / 'out')

    def test_rejects_ambiguous_main_application(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sample.ipa'
            self.archive(path, ('Payload/Second.app/Info.plist', b'x'))
            with self.assertRaises(module.BuildError):
                module.inspect(path)

    def test_apk_requires_metadata_tool(self):
        with self.assertRaises(module.BuildError):
            module.inspect('sample.apk')


if __name__ == '__main__':
    unittest.main()
