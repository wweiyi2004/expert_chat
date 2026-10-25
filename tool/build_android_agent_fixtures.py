"""Build two tiny owned demo APKs for isolated emulator Agent verification.

No signing/user account material is read. Output contains a throwaway fixture key.
"""
from pathlib import Path
import os
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tmp' / 'device-agent-fixtures'
SDK = Path(os.environ.get('ANDROID_HOME', Path.home() / 'AppData/Local/Android/sdk'))
TOOLS = SDK / 'build-tools/36.0.0'
JAR = SDK / 'platforms/android-35/android.jar'


def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    key = OUT / 'fixture.jks'
    if not key.exists():
        run(shutil.which('keytool'), '-genkeypair', '-keystore', key, '-storepass', 'fixture-only',
            '-keypass', 'fixture-only', '-alias', 'fixture', '-dname', 'CN=ExpertChatFixture',
            '-keyalg', 'RSA', '-validity', '30', '-noprompt')
    for number in [1, 2]:
        pkg = f'com.expertchat.fixture{number}'
        folder = OUT / str(number)
        folder.mkdir(exist_ok=True)
        classes = folder / 'classes'
        classes.mkdir(exist_ok=True)
        source = folder / 'MainActivity.java'
        source.write_text(f'''package {pkg};
import android.app.Activity;
import android.os.Bundle;
import android.widget.*;
public class MainActivity extends Activity {{
  public void onCreate(Bundle saved) {{
    super.onCreate(saved);
    LinearLayout layout = new LinearLayout(this); layout.setOrientation(1);
    TextView title = new TextView(this); title.setText("Agent Demo {number}"); layout.addView(title);
    EditText input = new EditText(this); input.setHint("Fixture input"); input.setContentDescription("Fixture input"); layout.addView(input);
    TextView result = new TextView(this); result.setText("Ready"); result.setContentDescription("Fixture result");
    Button save = new Button(this); save.setText("Save fixture"); save.setOnClickListener(v -> result.setText("Saved: " + input.getText())); layout.addView(save); layout.addView(result);
    ScrollView scroll = new ScrollView(this); LinearLayout rows = new LinearLayout(this); rows.setOrientation(1);
    for (int i=0;i<60;i++) {{ TextView row = new TextView(this); row.setText("Row " + i); row.setTextSize(24); rows.addView(row); }}
    scroll.addView(rows); layout.addView(scroll); setContentView(layout);
  }}
}}
''', encoding='utf-8')
        manifest = folder / 'AndroidManifest.xml'
        manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{pkg}">
<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35"/>
<application android:label="Agent Demo {number}" android:theme="@android:style/Theme.Material.Light.NoActionBar">
<activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity>
</application></manifest>''', encoding='utf-8')
        run(shutil.which('javac'), '-source', '8', '-target', '8', '-classpath', JAR, '-d', classes, source)
        run(TOOLS / 'd8.bat', '--lib', JAR, '--output', folder, *classes.rglob('*.class'))
        unsigned = folder / 'unsigned.apk'
        run(TOOLS / 'aapt.exe', 'package', '-f', '-M', manifest, '-I', JAR, '-F', unsigned)
        with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(folder / 'classes.dex', 'classes.dex')
        aligned = folder / 'aligned.apk'
        run(TOOLS / 'zipalign.exe', '-f', '4', unsigned, aligned)
        target = OUT / f'demo-{number}.apk'
        run(TOOLS / 'apksigner.bat', 'sign', '--ks', key, '--ks-key-alias', 'fixture',
            '--ks-pass', 'pass:fixture-only', '--key-pass', 'pass:fixture-only', '--out', target, aligned)
        print(target)


if __name__ == '__main__':
    main()
