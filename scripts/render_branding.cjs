// Run after npm ci --prefix remote_lab_ui. All platform assets share one SVG.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('../remote_lab_ui/node_modules/sharp');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'design/branding/expert-chat-mark.svg'));
async function png(name, size) {
  const output = path.join(root, name);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  let asset = sharp(source).resize(size, size);
  if (name.startsWith('ios/')) asset = asset.flatten({ background: '#F6F0E7' });
  await asset.png().toFile(output);
}
async function main() {
  await png('assets/branding/assistant.png', 512);
  await png('design/branding/expert-chat-preview.png', 1024);
  for (const [density, size] of Object.entries({mdpi:48, hdpi:72, xhdpi:96, xxhdpi:144, xxxhdpi:192})) {
    await png('android/app/src/main/res/mipmap-' + density + '/ic_expert_chat.png', size);
  }
  for (const platform of ['ios', 'macos']) {
    const folder = platform + '/Runner/Assets.xcassets/AppIcon.appiconset';
    const contents = JSON.parse(fs.readFileSync(path.join(root, folder, 'Contents.json'), 'utf8'));
    for (const item of contents.images) {
      if (!item.filename) continue;
      const size = Math.round(parseFloat(item.size) * parseFloat(item.scale));
      await png(folder + '/' + item.filename, size);
    }
  }
  for (const size of [192, 512]) {
    await png('web/icons/expert-chat-' + size + '.png', size);
    await png('web/icons/expert-chat-maskable-' + size + '.png', size);
  }
  await png('web/favicon-expert-chat.png', 64);
  await png('linux/runner/resources/expert_chat_icon.png', 256);
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const images = await Promise.all(sizes.map(size => sharp(source).resize(size, size).png().toBuffer()));
  const header = Buffer.alloc(6 + 16 * images.length);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach((bytes, i) => {
    const pos = 6 + i * 16;
    header[pos] = header[pos + 1] = sizes[i] === 256 ? 0 : sizes[i];
    header.writeUInt16LE(1, pos + 4); header.writeUInt16LE(32, pos + 6);
    header.writeUInt32LE(bytes.length, pos + 8); header.writeUInt32LE(offset, pos + 12);
    offset += bytes.length;
  });
  fs.writeFileSync(path.join(root, 'windows/runner/resources/expert_chat.ico'), Buffer.concat([header, ...images]));
  console.log('Rendered cat assistant icons for Android, Windows, iOS, macOS, Linux and Web.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
