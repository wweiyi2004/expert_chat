const fs = require('node:fs');
const path = require('node:path');
const sharp = require('../remote_lab_ui/node_modules/sharp');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'design/branding/expert-chat-mark.svg'), 'utf8');
// The adaptive layer contains the character, without the rounded legacy tile.
const character = source.replace(/<rect width="1024"[^>]*\/>/, '').replace(/<rect x="32"[^>]*\/>/, '');
async function writePng(relative, svg, size) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  await sharp(Buffer.from(svg)).resize(size, size).png().toFile(target);
}
async function main() {
  const densities = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
  for (const [density, size] of Object.entries(densities)) {
    await writePng(`android/app/src/main/res/mipmap-${density}/ic_expert_chat.png`, source, size);
    // 108dp layer; the character fits Android's central 66dp safe region.
    const foreground = `<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108" viewBox="0 0 108 108"><g transform="translate(21 21) scale(.064453125)">${character.replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '')}</g></svg>`;
    await writePng(`android/app/src/main/res/mipmap-${density}/ic_expert_chat_foreground.png`, foreground, Math.round(size * 108 / 48));
  }
  const xmlDir = path.join(root, 'android/app/src/main/res/mipmap-anydpi-v26');
  fs.mkdirSync(xmlDir, { recursive: true });
  fs.writeFileSync(path.join(xmlDir, 'ic_expert_chat.xml'), '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n  <background android:drawable="@color/expert_chat_icon_background"/>\n  <foreground android:drawable="@mipmap/ic_expert_chat_foreground"/>\n</adaptive-icon>\n');
  fs.writeFileSync(path.join(root, 'android/app/src/main/res/values/expert_chat_icon.xml'), '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="expert_chat_icon_background">#163E51</color></resources>\n');
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const images = await Promise.all(sizes.map(size => sharp(Buffer.from(source)).resize(size, size).png().toBuffer()));
  const header = Buffer.alloc(6 + 16 * images.length);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach((bytes, i) => {
    const pos = 6 + 16 * i;
    header[pos] = header[pos + 1] = sizes[i] === 256 ? 0 : sizes[i];
    header.writeUInt16LE(1, pos + 4); header.writeUInt16LE(32, pos + 6);
    header.writeUInt32LE(bytes.length, pos + 8); header.writeUInt32LE(offset, pos + 12);
    offset += bytes.length;
  });
  fs.writeFileSync(path.join(root, 'windows/runner/resources/expert_chat.ico'), Buffer.concat([header, ...images]));
  console.log('Generated effective Android legacy/adaptive and Windows multi-size icons.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
