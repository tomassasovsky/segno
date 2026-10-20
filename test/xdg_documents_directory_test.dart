import 'package:flutter_test/flutter_test.dart';
import 'package:segno/xdg_documents_directory.dart';

void main() {
  group(xdgDocumentsDirectory, () {
    /// Reads [files] by path; any other path has no file.
    String? Function(String) files(Map<String, String> files) =>
        (path) => files[path];

    test('reads the appliance launcher seed', () {
      // What segno-kiosk-launch writes on the console.
      const seed =
          'XDG_DESKTOP_DIR="\$HOME/Desktop"\n'
          'XDG_DOCUMENTS_DIR="\$HOME/Documents"\n'
          'XDG_DOWNLOAD_DIR="\$HOME/Downloads"\n';
      expect(
        xdgDocumentsDirectory(
          const {'HOME': '/data', 'XDG_CONFIG_HOME': '/data/.config'},
          files({'/data/.config/user-dirs.dirs': seed}),
        ),
        '/data/Documents',
      );
    });

    test('defaults the config directory to ~/.config', () {
      expect(
        xdgDocumentsDirectory(
          const {'HOME': '/home/me', 'XDG_CONFIG_HOME': ''},
          files({
            '/home/me/.config/user-dirs.dirs': 'XDG_DOCUMENTS_DIR="/srv/docs"',
          }),
        ),
        '/srv/docs',
      );
    });

    test('takes the last assignment and skips comments', () {
      const dirs =
          '# XDG_DOCUMENTS_DIR="\$HOME/commented"\n'
          'XDG_DOCUMENTS_DIR="\$HOME/first"\n'
          '  XDG_DOCUMENTS_DIR="\$HOME/second"  \n';
      expect(
        xdgDocumentsDirectory(
          const {'HOME': '/home/me'},
          files({'/home/me/.config/user-dirs.dirs': dirs}),
        ),
        '/home/me/second',
      );
    });

    test(r'expands a bare $HOME', () {
      expect(
        xdgDocumentsDirectory(
          const {'HOME': '/home/me'},
          files({
            '/home/me/.config/user-dirs.dirs': r'XDG_DOCUMENTS_DIR="$HOME"',
          }),
        ),
        '/home/me',
      );
    });

    test('keeps an environment value the file does not override', () {
      expect(
        xdgDocumentsDirectory(const {
          'HOME': '/home/me',
          'XDG_DOCUMENTS_DIR': '/env/docs',
        }, files(const {})),
        '/env/docs',
      );
    });

    test(r'falls back to $HOME, as xdg-user-dir does', () {
      expect(
        xdgDocumentsDirectory(const {'HOME': '/home/me'}, files(const {})),
        '/home/me',
      );
    });

    test('throws without a HOME', () {
      expect(
        () => xdgDocumentsDirectory(const {}, files(const {})),
        throwsStateError,
      );
    });
  });
}
